import Foundation

// Minimal test runner (no XCTest dependency, so it runs with just the Command Line Tools).
// Run with ./scripts/test.sh

var failures = 0
var passed = 0

func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { passed += 1 } else { failures += 1; print("FAIL \(URL(fileURLWithPath: file).lastPathComponent):\(line)  \(what)") }
}

func near(_ a: Double?, _ b: Double, _ eps: Double = 0.001) -> Bool { a.map { abs($0 - b) < eps } ?? false }

func row(_ fields: [String: Any]) -> Data {
    var r: [String: Any] = [
        "tradingSymbol": "TEST-Oct2026-100-CE", "securityId": "1", "exchangeSegment": "NSE_FNO",
        "productType": "MARGIN", "buyAvg": 10.0, "sellAvg": 0.0, "costPrice": 10.0, "netQty": 100,
        "realizedProfit": 0.0, "unrealizedProfit": 0.0, "multiplier": 1,
        "carryForwardBuyValue": 0.0, "carryForwardSellValue": 0.0, "dayBuyValue": 1000.0, "daySellValue": 0.0,
        "drvExpiryDate": "2026-10-27 14:30:00", "drvOptionType": "CALL", "drvStrikePrice": 100.0,
    ]
    r.merge(fields) { $1 }
    return try! JSONSerialization.data(withJSONObject: [r])
}

@main
struct Tests {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Fixtures")

        // MARK: Exit pricing
        check(near(ExitPricing.limit(selling: true, reference: 100), 97.00), "sell limit is exactly 3% below, no extra tick")
        check(near(ExitPricing.limit(selling: false, reference: 100), 103.00), "buy limit is exactly 3% above")
        check(near(ExitPricing.limit(selling: true, reference: 9.25), 9.00), "sell limit rounds up to the 0.05 tick")
        check(near(ExitPricing.limit(selling: false, reference: 9.25), 9.50), "buy limit rounds down to the 0.05 tick")
        check(near(ExitPricing.limit(selling: true, reference: 0.04), 0.05), "never below one tick")
        for ref in stride(from: 0.5, through: 500, by: 7.37) {
            let s = ExitPricing.limit(selling: true, reference: ref), b = ExitPricing.limit(selling: false, reference: ref)
            check(s >= ref * 0.97 - 1e-9 || s == 0.05, "sell cap never exceeded at \(ref)")
            check(b <= ref * 1.03 + 1e-9, "buy cap never exceeded at \(ref)")
            check(abs((s / 0.05).rounded() * 0.05 - s) < 1e-9, "sell limit on tick at \(ref)")
        }

        // MARK: Dhan position mapping (fixture covers long, short, closed, and multiplier 1000)
        let ps = try DhanBroker.decodePositions(try Data(contentsOf: fixtures.appendingPathComponent("positions.json")))
        check(ps.count == 3, "fixture decodes 3 positions")
        let nifty = ps.first { $0.underlying == "NIFTY" }, bnf = ps.first { $0.underlying == "BANKNIFTY" }
        let rel = ps.first { $0.underlying == "RELIANCE" }
        check(near(nifty?.impliedPrice, 132.70), "carry-forward row ignores Dhan's multiplier 1000")
        check(nifty?.multiplier == 1, "equity F&O multiplier normalised to 1")
        check(near(bnf?.impliedPrice, 225.50), "short implied price = cost + unrealized / netQty")
        check(bnf?.netQty == -30 && bnf?.tag == "PE" && bnf?.strike == 54000, "short PE fields")
        check(rel?.isOpen == false && rel?.impliedPrice == nil, "closed position has no implied price")
        check(nifty?.exitable == true, "NSE_FNO positions are exitable")
        check(nifty?.instrumentKey == "NSE_FNO-40001", "instrument key")

        // MARK: Edge cases
        check((try? DhanBroker.decodePositions(row(["netQty": 1.5]))) == nil, "fractional quantity is rejected")
        check((try? DhanBroker.decodePositions(Data("{not json".utf8))) == nil, "malformed JSON throws, no crash")
        let cur = try DhanBroker.decodePositions(row(["exchangeSegment": "NSE_CURRENCY", "multiplier": 1000,
                                                      "unrealizedProfit": 500.0, "drvOptionType": "XX"]))[0]
        check(cur.impliedPrice == nil, "no derived price for currency (multiplier may be real)")
        check(cur.exitable == false, "currency positions aren't exitable")
        check(near(cur.pnl(ltp: 12), 500), "multiplier != 1 uses broker P&L even with a live price")
        let eq = try DhanBroker.decodePositions(row(["exchangeSegment": "NSE_EQ", "drvExpiryDate": "0001-01-01 00:00:00",
                                                     "drvOptionType": "NA", "drvStrikePrice": 0.0]))[0]
        check(eq.exitable == false && eq.tag == nil && eq.strike == nil, "equity rows: not exitable, no tag/strike")

        // MARK: P&L
        let long = try DhanBroker.decodePositions(row(["unrealizedProfit": 250.0]))[0]
        check(near(long.pnl(ltp: nil), 250), "no live price: broker P&L")
        check(near(long.pnl(ltp: 12.5), 250), "live price: sell − buy + qty × ltp")

        // MARK: Orders
        check(OrderSummary(orderId: "1", instrumentKey: "k", status: "PENDING", tag: nil).isWorking, "pending is working")
        check(!OrderSummary(orderId: "1", instrumentKey: "k", status: "TRADED", tag: nil).isWorking, "traded isn't working")
        check(!OrderSummary(orderId: "1", instrumentKey: "k", status: "REJECTED", tag: nil).isWorking, "rejected isn't working")

        // MARK: Order parsing is strict (the working-order check must fail closed)
        func orders(_ json: String, instrument: Bool = true) -> [OrderSummary]? {
            try? DhanBroker.parseOrders(Data(json.utf8), requireInstrument: instrument)
        }
        check(orders("[]")?.isEmpty == true, "empty order book parses as empty")
        check(orders(#"[{"orderId":"1","orderStatus":"PENDING","exchangeSegment":"NSE_FNO","securityId":"40001"}]"#)?
                .first?.instrumentKey == "NSE_FNO-40001", "order row maps instrument key")
        check(orders(#"[{"orderId":123,"orderStatus":"TRADED","exchangeSegment":"NSE_FNO","securityId":40001}]"#)?
                .first?.orderId == "123", "numeric ids accepted")
        check(orders(#"{"data":[{"orderId":"1","orderStatus":"PENDING"}]}"#) == nil, "wrapped response throws")
        check(orders(#"[{"orderId":"1","orderStatus":"PENDING"}]"#) == nil, "row without instrument throws for the order book")
        check(orders(#"[{"orderId":"1","orderStatus":"PENDING"}]"#, instrument: false)?.count == 1, "placement replies may omit instrument")
        check(orders(#"[{"orderStatus":"PENDING","exchangeSegment":"NSE_FNO","securityId":"1"}]"#) == nil, "row without id throws")
        check(orders(#"[{"orderId":"1","exchangeSegment":"NSE_FNO","securityId":"1"}]"#) == nil, "row without status throws")
        check(orders("not json") == nil, "garbage throws")
        check(orders(#"{"orderId":"9","orderStatus":"TRANSIT"}"#, instrument: false)?.first?.orderId == "9", "single object accepted")

        // MARK: Order status and exit outcome
        func o(_ status: String) -> OrderSummary { OrderSummary(orderId: "1", instrumentKey: "k", status: status, tag: nil) }
        check(o("TRIGGERED").isWorking && o("SOMETHING_NEW").isWorking, "unknown statuses count as working")
        check(!o("CANCELLED").isWorking && !o("EXPIRED").isWorking && !o("CLOSED").isWorking, "terminal statuses")
        check(ExitOutcome([]) == .unknown, "no slices reported is unknown, never success")
        check(ExitOutcome([o("TRADED"), o("TRADED")]) == .filled, "all slices traded")
        check(ExitOutcome([o("TRADED"), o("PENDING")]) == .working, "some still working")
        check(ExitOutcome([o("REJECTED"), o("REJECTED")]) == .rejected, "all rejected")
        check(ExitOutcome([o("REJECTED"), o("PENDING")]) == .partial, "mixed rejection needs attention")
        check(ExitOutcome([o("TRADED"), o("CANCELLED")]) == .partial, "cancelled slice needs attention")

        // MARK: JWT
        func jwt(_ payload: String) -> String {
            let b = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzUxMiJ9.\(b).sig"
        }
        check(JWT.expiry(of: jwt(#"{"exp":1791881368}"#)) == Date(timeIntervalSince1970: 1791881368), "reads exp")
        check(JWT.expiry(of: "a.b") == nil, "two-part token rejected")
        check(JWT.expiry(of: jwt(#"{"sub":"x"}"#)) == nil, "missing exp rejected")
        check(JWT.expiry(of: "") == nil, "empty token rejected")

        print(failures == 0 ? "All \(passed) checks passed." : "\(failures) failed, \(passed) passed.")
        exit(failures == 0 ? 0 : 1)
    }
}
