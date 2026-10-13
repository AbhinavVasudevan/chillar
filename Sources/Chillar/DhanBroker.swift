import Foundation

/// Dhan (DhanHQ v2) adapter. Docs: https://dhanhq.co/docs/v2/
@MainActor
final class DhanBroker: Broker {
    nonisolated static let name = "Dhan"
    nonisolated static let positionsURL = URL(string: "https://web.dhan.co/index/positions")!

    let clientId: String
    private(set) var accessToken: String
    private let http = HTTPClient(host: "api.dhan.co")
    private let base = URL(string: "https://api.dhan.co/v2")!

    init(clientId: String, accessToken: String) {
        self.clientId = clientId
        self.accessToken = accessToken
    }

    // MARK: Requests

    private func request(_ path: String, method: String = "GET", json: Any? = nil) throws -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(accessToken, forHTTPHeaderField: "access-token")
        req.setValue(clientId, forHTTPHeaderField: "client-id")
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        try await http.send(req) { data in
            // Dhan errors look like {"errorType":…, "errorCode":…, "errorMessage":…}.
            (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["errorMessage"] as? String
        }
    }

    // MARK: Account

    func positions() async throws -> [Position] {
        try Self.decodePositions(try await send(request("positions")))
    }

    nonisolated static func decodePositions(_ data: Data) throws -> [Position] {
        try JSONDecoder().decode([DhanPosition].self, from: data).map { try $0.position() }
    }

    func funds() async throws -> Funds {
        struct R: Decodable { let availabelBalance: Double?; let utilizedAmount: Double? }  // sic: Dhan's spelling
        let r = try JSONDecoder().decode(R.self, from: try await send(request("fundlimit")))
        return Funds(available: r.availabelBalance ?? 0, used: r.utilizedAmount ?? 0)
    }

    func lastPrices(for positions: [Position]) async throws -> [String: Double] {
        var bySegment: [String: [Int]] = [:]
        for p in positions {
            if let seg = p.brokerRef["segment"], let id = p.brokerRef["securityId"].flatMap(Int.init) {
                bySegment[seg, default: []].append(id)
            }
        }
        guard !bySegment.isEmpty else { return [:] }
        let data: Data
        do {
            data = try await send(request("marketfeed/ltp", method: "POST", json: bySegment))
        } catch BrokerError.unauthorized, BrokerError.http(400, _) {
            throw BrokerError.noMarketData   // "Data APIs not Subscribed"
        }
        struct R: Decodable { let data: [String: [String: Q]] }
        struct Q: Decodable { let last_price: Double }
        let r = try JSONDecoder().decode(R.self, from: data)
        var bySecurity: [String: Double] = [:]
        for (seg, quotes) in r.data { for (id, q) in quotes { bySecurity["\(seg)-\(id)"] = q.last_price } }
        var out: [String: Double] = [:]
        for p in positions { if let v = bySecurity[p.instrumentKey], v > 0 { out[p.id] = v } }
        return out
    }

    // MARK: Orders

    func orders() async throws -> [OrderSummary] {
        try Self.parseOrders(try await send(request("orders")), requireInstrument: true)
    }

    func orders(tag: String) async throws -> [OrderSummary] {
        guard tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return [] }
        do {
            return try Self.parseOrders(try await send(request("orders/external/\(tag)")), requireInstrument: false)
        } catch BrokerError.http(404, _) {
            return []
        }
    }

    /// Strict: throws unless the body is an order object or a list of them, each with an id and a
    /// status (and, when `requireInstrument`, its segment and security id). Never drops rows.
    nonisolated static func parseOrders(_ data: Data, requireInstrument: Bool) throws -> [OrderSummary] {
        let rows: [DhanOrder]
        if let list = try? JSONDecoder().decode([DhanOrder].self, from: data) {
            rows = list
        } else {
            rows = [try JSONDecoder().decode(DhanOrder.self, from: data)]
        }
        return try rows.map { r in
            let key = r.exchangeSegment.flatMap { seg in r.securityId.map { "\(seg)-\($0)" } }
            if requireInstrument && key == nil { throw BrokerError.invalidResponse }
            return OrderSummary(orderId: r.orderId, instrumentKey: key, status: r.orderStatus, tag: r.correlationId)
        }
    }

    /// Uses the slicing endpoint so quantities above the F&O freeze limit are split.
    /// Dhan only accepts order APIs from a whitelisted static IP.
    func placeExit(_ p: Position, limitPrice: Double, tag: String) async throws -> [OrderSummary] {
        guard p.exitable, p.netQty != 0,
              let seg = p.brokerRef["segment"], let sec = p.brokerRef["securityId"],
              let product = p.brokerRef["product"], !product.isEmpty else { throw BrokerError.invalidResponse }
        let body: [String: Any] = [
            "dhanClientId": clientId,
            "correlationId": tag,
            "transactionType": p.netQty > 0 ? "SELL" : "BUY",
            "exchangeSegment": seg,
            "productType": product,
            "orderType": "LIMIT",
            "validity": "DAY",
            "securityId": sec,
            "quantity": abs(p.netQty),
            "price": limitPrice,
        ]
        let data = try await send(request("orders/slicing", method: "POST", json: body))
        // An unreadable reply is "don't know", not "nothing placed": the caller looks the tag up.
        return (try? Self.parseOrders(data, requireInstrument: false)) ?? []
    }

    func shutdown() { http.invalidate() }

    // MARK: Session

    var sessionExpiry: Date? { JWT.expiry(of: accessToken) }

    /// Dhan Web tokens can be renewed while still valid; the old token stops working.
    func renewSession() async throws -> String? {
        var req = try request("RenewToken")
        req.setValue(clientId, forHTTPHeaderField: "dhanClientId")
        struct R: Decodable { let token: String }
        let fresh = try JSONDecoder().decode(R.self, from: try await send(req)).token
        guard let exp = JWT.expiry(of: fresh), exp > Date() else { throw BrokerError.invalidResponse }
        accessToken = fresh
        return fresh
    }
}

/// Dhan order row. Ids may arrive as strings or numbers.
private struct DhanOrder: Decodable {
    let orderId: String
    let orderStatus: String
    let exchangeSegment: String?
    let securityId: String?
    let correlationId: String?

    enum CodingKeys: String, CodingKey { case orderId, orderStatus, exchangeSegment, securityId, correlationId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flexible(_ k: CodingKeys) throws -> String? {
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let n = try? c.decode(Int64.self, forKey: k) { return String(n) }
            if c.contains(k), try !c.decodeNil(forKey: k) { throw BrokerError.invalidResponse }
            return nil
        }
        guard let id = try flexible(.orderId), !id.isEmpty else { throw BrokerError.invalidResponse }
        orderId = id
        orderStatus = try c.decode(String.self, forKey: .orderStatus)
        exchangeSegment = try c.decodeIfPresent(String.self, forKey: .exchangeSegment)
        securityId = try flexible(.securityId)
        correlationId = try? c.decodeIfPresent(String.self, forKey: .correlationId)
    }
}

/// Dhan's /positions row.
private struct DhanPosition: Decodable {
    let tradingSymbol: String
    let securityId: String
    let exchangeSegment: String
    let productType: String?
    let buyAvg: Double?
    let sellAvg: Double?
    let costPrice: Double?
    let netQty: Double
    let realizedProfit: Double?
    let unrealizedProfit: Double?
    let multiplier: Double?
    let carryForwardBuyValue: Double?
    let carryForwardSellValue: Double?
    let dayBuyValue: Double?
    let daySellValue: Double?
    let drvExpiryDate: String?
    let drvOptionType: String?
    let drvStrikePrice: Double?

    func position() throws -> Position {
        guard let qty = Int(exactly: netQty) else { throw BrokerError.invalidResponse }
        // Dhan sends multiplier 1000 on some equity F&O rows (seen on carry-forward positions) while
        // its P&L is plain (price diff × qty), so for equity and equity derivatives it's ignored.
        // Currency/commodity contracts may really use one: there we trust Dhan's P&L and don't
        // derive a price.
        let unitPriced = exchangeSegment.hasSuffix("_EQ") || ["NSE_FNO", "BSE_FNO"].contains(exchangeSegment)
        let mult = unitPriced ? 1 : ((multiplier ?? 1) == 0 ? 1 : (multiplier ?? 1))
        let tag: String? = switch drvOptionType?.uppercased() {
        case "CALL": "CE"
        case "PUT": "PE"
        default: expiry == nil ? nil : "FUT"
        }
        var avg = qty >= 0 ? buyAvg : sellAvg
        if avg == nil || avg == 0 { avg = costPrice }
        // Implied last price from Dhan's unrealized P&L: cost + P&L per unit.
        var implied: Double?
        if unitPriced, qty != 0, let cost = costPrice, cost > 0, let u = unrealizedProfit {
            implied = cost + u / Double(qty)
        }
        return Position(
            id: "\(exchangeSegment)-\(securityId)-\(productType ?? "")",
            symbol: tradingSymbol,
            underlying: String(tradingSymbol.split(separator: "-").first ?? Substring(tradingSymbol)),
            strike: (drvStrikePrice ?? 0) > 0 ? drvStrikePrice : nil,
            tag: tag,
            expiry: expiry,
            netQty: qty,
            avgPrice: avg,
            buyValue: (dayBuyValue ?? 0) + (carryForwardBuyValue ?? 0),
            sellValue: (daySellValue ?? 0) + (carryForwardSellValue ?? 0),
            realized: realizedProfit ?? 0,
            unrealized: unrealizedProfit ?? 0,
            multiplier: mult,
            impliedPrice: implied,
            exitable: ["NSE_FNO", "BSE_FNO"].contains(exchangeSegment) && productType != nil,
            brokerRef: ["segment": exchangeSegment, "securityId": securityId,
                        "product": productType ?? "", "instrument": "\(exchangeSegment)-\(securityId)"]
        )
    }

    private var expiry: Date? {
        guard let s = drvExpiryDate else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let d = f.date(from: s), d.timeIntervalSince1970 > 0 else { return nil }
        return d
    }
}

enum JWT {
    /// Reads the `exp` claim (unverified; used only for scheduling renewal and UI).
    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
