import Foundation

// Broker-neutral model. Each broker adapter (Dhan today; Zerodha, Upstox… later) maps its own
// API into these types, and the rest of the app never sees broker-specific JSON.

struct Position: Identifiable, Equatable {
    /// Stable per instrument + product, unique within one broker's position list.
    let id: String
    let symbol: String
    let underlying: String
    let strike: Double?
    /// "CE", "PE", "FUT", or nil for cash/equity.
    let tag: String?
    let expiry: Date?
    let netQty: Int
    let avgPrice: Double?
    /// Totals across day + carry-forward legs, already in rupees.
    let buyValue: Double
    let sellValue: Double
    let realized: Double
    let unrealized: Double
    /// Contract multiplier. Only 1 is marked to live prices; anything else uses broker P&L.
    let multiplier: Double
    /// Last price derived from the broker's P&L, for accounts without a market-data feed.
    let impliedPrice: Double?
    /// Whether Chillar may place an exit order for this position (derivatives only).
    let exitable: Bool
    /// Opaque broker data needed to place orders (segment, product, instrument id).
    let brokerRef: [String: String]

    var isOpen: Bool { netQty != 0 }
    var reportedPnL: Double { realized + unrealized }

    /// Key shared by every product type of one instrument, for matching orders to positions.
    var instrumentKey: String { brokerRef["instrument"] ?? id }

    /// Total P&L: marked to `ltp` when given (and the multiplier is 1), else the broker's figure.
    func pnl(ltp: Double?) -> Double {
        guard let ltp, multiplier == 1 else { return reportedPnL }
        return sellValue - buyValue + Double(netQty) * ltp
    }
}

struct Funds: Equatable {
    let available: Double
    let used: Double
}

struct OrderSummary: Equatable {
    let orderId: String
    /// Nil when the broker's response doesn't identify the instrument (e.g. order placement replies).
    let instrumentKey: String?
    let status: String
    let tag: String?

    private static let terminal: Set<String> = ["TRADED", "CANCELLED", "REJECTED", "EXPIRED", "CLOSED"]

    /// Anything not known to be finished counts as working, so new or unknown statuses fail safe.
    var isWorking: Bool { !Self.terminal.contains(status.uppercased()) }
    var isFilled: Bool { status.uppercased() == "TRADED" }
    var isRejected: Bool { status.uppercased() == "REJECTED" }
}

/// What a set of exit-order slices adds up to.
enum ExitOutcome: Equatable {
    /// No slices reported: the order may or may not exist.
    case unknown
    case filled
    case working
    case rejected
    /// Mixed results (some rejected, cancelled or expired): the user must check.
    case partial

    init(_ slices: [OrderSummary]) {
        if slices.isEmpty { self = .unknown }
        else if slices.allSatisfy(\.isFilled) { self = .filled }
        else if slices.allSatisfy(\.isRejected) { self = .rejected }
        else if slices.allSatisfy({ $0.isWorking || $0.isFilled }) { self = .working }
        else { self = .partial }
    }
}

enum BrokerError: LocalizedError {
    case missingCredentials
    case unauthorized
    case noMarketData
    case http(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Add your broker credentials in Settings."
        case .unauthorized: return "Token rejected. Generate a new access token and paste it in Settings."
        case .noMarketData: return "Live market data isn't enabled on this account."
        case .http(let code, let msg): return msg ?? "Request failed (HTTP \(code))."
        case .invalidResponse: return "Unexpected response from the broker."
        }
    }
}

/// One broker account. Adapters run on the main actor (their state, like a rotating token, is then
/// never touched from two threads) and must only talk to their broker's own API host via HTTPClient.
@MainActor
protocol Broker: AnyObject {
    static var name: String { get }

    func positions() async throws -> [Position]
    func funds() async throws -> Funds
    /// Live prices keyed by Position.id. Throws `.noMarketData` if the account has no feed.
    func lastPrices(for positions: [Position]) async throws -> [String: Double]

    /// Today's orders. Must throw (never return a partial list) if the response can't be fully
    /// understood: the exit flow relies on it to refuse while another order is working.
    func orders() async throws -> [OrderSummary]
    /// Places a LIMIT exit for the full quantity, tagged so it can be found after a timeout.
    /// Returns one entry per slice; empty means the broker didn't say.
    func placeExit(_ p: Position, limitPrice: Double, tag: String) async throws -> [OrderSummary]
    /// Every slice placed with `tag`; empty if the broker never received the order.
    func orders(tag: String) async throws -> [OrderSummary]

    /// When the current session token expires, if known.
    var sessionExpiry: Date? { get }
    /// Exchanges the current token for a fresh one, returning the new secret, or nil if the
    /// broker doesn't support renewal. The old token may be invalid once this returns.
    func renewSession() async throws -> String?
    /// Cancels in-flight requests and releases the network session.
    func shutdown()
}
