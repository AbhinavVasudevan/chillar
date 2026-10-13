import AppKit
import Foundation
import Security
import ServiceManagement

/// Product identity in one place, so renaming the app is a one-line change.
enum AppInfo {
    static let name = "Chillar"
    static let keychainService = "chillar"
}

/// Secrets live in the login Keychain, readable by this app's code signature.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppInfo.keychainService,
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                    // Excludes iCloud Keychain sync.
                                    kSecAttrSynchronizable as String: false]
        var status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(key).merging(attrs) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var positions: [Position] = []
    @Published private(set) var prices: [String: Double] = [:]
    @Published private(set) var liveFeed = true
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var funds: Funds?
    /// Transient refresh error; cleared by the next successful refresh.
    @Published private(set) var error: String?
    /// Problem the user should know about (Keychain, Login Items). Never stops refreshing.
    @Published private(set) var warning: String?
    /// The session is unusable (expired, rejected, lost in renewal): refreshing stops until new credentials.
    @Published private(set) var authProblem: String?
    /// Today's P&L extremes; only these two numbers are persisted (UserDefaults, keyed by date).
    @Published private(set) var dayRange = DayRange.loadToday()
    @Published private(set) var clientId: String
    @Published private(set) var tokenExpiry: Date?

    /// Off by default: the app is read-only unless the user opts in to placing exit orders.
    @Published var ordersEnabled: Bool = UserDefaults.standard.bool(forKey: "ordersEnabled") {
        didSet { UserDefaults.standard.set(ordersEnabled, forKey: "ordersEnabled") }
    }
    @Published var showInDock: Bool = UserDefaults.standard.bool(forKey: "showInDock") {
        didSet { UserDefaults.standard.set(showInDock, forKey: "showInDock"); applyDockPolicy() }
    }
    @Published var openOnly: Bool = UserDefaults.standard.bool(forKey: "openOnly") {
        didSet { UserDefaults.standard.set(openOnly, forKey: "openOnly") }
    }

    /// Opening at login keeps the session renewed, so it's on by default (set once on first
    /// launch) and the user can turn it off in Settings.
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            warning = "Couldn't change Login Items: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func registerLoginItemOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        setLaunchAtLogin(true)
    }

    private var broker: DhanBroker? {
        didSet { if oldValue !== broker { oldValue?.shutdown() } }
    }
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var lastRenewAttempt = Date.distantPast
    private var lastFunds = Date.distantPast
    private var tick = 0

    var hasCredentials: Bool { broker != nil }

    init() {
        #if CHILLAR_DEV
        // Dev builds are unsandboxed and ad-hoc signed: they never read real credentials, never
        // touch the network or Login Items, and only render fixture data.
        clientId = ""
        #else
        let id = Keychain.get("dhan.clientId")
        let token = Keychain.get("dhan.accessToken")
        clientId = id ?? ""
        if let id, let token { broker = DhanBroker(clientId: id, accessToken: token) }
        tokenExpiry = broker?.sessionExpiry

        // NSApp isn't ready during App init; apply dock policy on the next run loop.
        DispatchQueue.main.async { [weak self] in self?.applyDockPolicy() }
        // A long off-hours sleep would leave stale numbers after the Mac wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSoon() }
        }
        registerLoginItemOnFirstLaunch()
        restart()
        #endif
    }

    // MARK: Credentials

    /// Returns an error message, or nil on success.
    func saveCredentials(clientId: String, token: String) -> String? {
        let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...16).contains(id.count), id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else {
            return "Client ID should be the number shown on your Dhan profile."
        }
        guard let exp = JWT.expiry(of: tok) else { return "That doesn't look like a Dhan access token (it starts with eyJ)." }
        guard exp > Date() else { return "That token has already expired. Generate a new one." }
        guard Keychain.set("dhan.accessToken", tok) else { return "Couldn't save to the Keychain. Nothing was stored." }
        guard Keychain.set("dhan.clientId", id) else {
            Keychain.delete("dhan.accessToken")
            return "Couldn't save to the Keychain. Nothing was stored."
        }
        loop?.cancel()
        self.clientId = id
        broker = DhanBroker(clientId: id, accessToken: tok)
        tokenExpiry = exp
        resetAccountState()
        restart()
        return nil
    }

    func signOut() {
        loop?.cancel()
        broker = nil   // in-flight work sees this and drops its results
        Keychain.delete("dhan.clientId")
        Keychain.delete("dhan.accessToken")
        clientId = ""; tokenExpiry = nil
        resetAccountState()
    }

    private func resetAccountState() {
        positions = []; funds = nil; prices = [:]; lastUpdate = nil
        error = nil; warning = nil; authProblem = nil
        liveFeed = true; tick = 0; lastFunds = .distantPast; lastRenewAttempt = .distantPast
        closeState = [:]; closeQty = [:]
        tracking.values.forEach { $0.cancel() }; tracking = [:]
        updateDockBadge()
    }

    // MARK: Refresh loop

    /// Starts a fresh loop. Only for credential changes: renewal runs outside the loop,
    /// so cancelling it never interrupts a token rotation.
    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.sleep(self?.pollInterval ?? 60)
            }
        }
    }

    private func sleep(_ seconds: Double) async {
        let t = Task { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleeper = t
        await t.value
    }

    /// Refreshes now (panel opened, Mac woke) unless data is only seconds old.
    /// Interrupts the loop's sleep instead of restarting it, so in-flight work is never cancelled.
    func refreshSoon() {
        guard lastUpdate.map({ Date().timeIntervalSince($0) > 5 }) ?? true else { return }
        sleeper?.cancel()
    }

    enum Session { case open, preOpen, settling, closed }

    /// NSE session by IST clock (exchange holidays aren't known, so they count as "open").
    static var session: Session {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let c = cal.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let wd = c.weekday, (2...6).contains(wd), let h = c.hour, let m = c.minute else { return .closed }
        switch h * 60 + m {
        case (9 * 60)..<(9 * 60 + 15): return .preOpen
        case (9 * 60 + 15)..<(15 * 60 + 30): return .open
        case (15 * 60 + 30)..<(16 * 60): return .settling   // closing prices still being applied
        default: return .closed
        }
    }

    static var marketOpen: Bool { session == .open }

    /// Seconds between refreshes: fast while trading, slow once nothing is moving.
    private var pollInterval: Double {
        switch Store.session {
        case .open: return 1   // positions are "non-trading" APIs: 20 req/s allowed, so 1/s is ~5% of it
        case .preOpen, .settling: return 30
        case .closed: return 900   // keeps the token renewed; opening the panel refreshes instantly
        }
    }

    /// While open: with a data feed, LTP every 1s (its rate limit is exactly 1 req/s) and positions
    /// every 5s; without one, positions every 1s. Outside market hours each refresh fetches everything once.
    private func refresh() async {
        guard let b = broker else {
            error = BrokerError.missingCredentials.errorDescription
            return
        }
        guard authProblem == nil else { return }
        if let exp = b.sessionExpiry, exp < Date() {
            authProblem = "Access token expired. Generate a new one on web.dhan.co and paste it in Settings."
            return
        }
        await renewIfNeeded(b)
        guard broker === b, authProblem == nil else { return }
        defer { tick += 1 }
        do {
            if !liveFeed || !Store.marketOpen || tick % 5 == 0 || positions.isEmpty {
                let fresh = try await b.positions()
                guard broker === b else { return }
                apply(fresh)
            }
            let open = positions.filter(\.isOpen)
            if liveFeed && Store.marketOpen && !open.isEmpty {
                do {
                    let p = try await b.lastPrices(for: open)
                    guard broker === b else { return }
                    prices = p
                } catch BrokerError.noMarketData {
                    liveFeed = false
                    prices = [:]
                } catch is CancellationError {
                    return
                } catch {
                    prices = [:]   // never mark P&L to stale prices; fall back to broker P&L
                }
            } else if !Store.marketOpen {
                prices = [:]
            }
            if Date().timeIntervalSince(lastFunds) > 30 || funds == nil {
                let f = try? await b.funds()
                guard broker === b else { return }
                funds = f
                lastFunds = Date()
            }
            error = nil
            lastUpdate = Date()
            recordDayRange()
        } catch is CancellationError {
        } catch BrokerError.unauthorized {
            if broker === b { authProblem = BrokerError.unauthorized.errorDescription }
        } catch {
            if broker === b { self.error = error.localizedDescription }
        }
        updateDockBadge()
    }

    private func apply(_ fresh: [Position]) {
        // A fill moves the balance: fetch funds now instead of waiting up to 30s.
        if fresh.map(\.netQty) != positions.map(\.netQty) || fresh.map(\.id) != positions.map(\.id) {
            lastFunds = .distantPast
        }
        positions = fresh
        // Forget exit status once a position's quantity changes, so it can be closed again later.
        for (id, qty) in closeQty where fresh.first(where: { $0.id == id })?.netQty != qty {
            closeState[id] = nil
            closeQty[id] = nil
            tracking[id]?.cancel(); tracking[id] = nil
        }
    }

    // MARK: Token renewal

    /// Renews once fewer than 20h remain, so the Mac only needs to be awake with the app
    /// running once every ~24h. Runs in its own task that nothing cancels: a rotation cut
    /// short after Dhan issued the new token would leave no working token at all.
    private func renewIfNeeded(_ b: DhanBroker) async {
        if let r = renewal { await r.value; return }
        guard let exp = b.sessionExpiry, exp.timeIntervalSinceNow < 20 * 3600,
              Date().timeIntervalSince(lastRenewAttempt) > 300 else { return }
        lastRenewAttempt = Date()
        let r = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRenewal(b)
        }
        renewal = r
        await r.value
        renewal = nil
    }

    private func performRenewal(_ b: DhanBroker) async {
        do {
            guard let fresh = try await b.renewSession() else { return }
            guard broker === b else { return }   // signed out or replaced meanwhile
            tokenExpiry = b.sessionExpiry
            if !Keychain.set("dhan.accessToken", fresh) {
                warning = "Token renewed but couldn't be saved to the Keychain. You'll need a new token after restarting."
            }
        } catch {
            // The request may have reached Dhan before failing. Check the old token still works.
            do {
                _ = try await b.funds()
            } catch BrokerError.unauthorized {
                if broker === b { authProblem = "Token renewal failed and the old token no longer works. Paste a new token in Settings." }
            } catch {}
        }
    }

    // MARK: Closing positions

    enum CloseState: Equatable {
        case sending
        /// The exit order is live at the exchange but not (fully) filled yet.
        case working(String)
        case filled(String)
        /// Definitely no order is working; safe to retry.
        case failed(String)
        /// An order may or may not exist; retrying could double the exit.
        case unknown(String)
    }
    @Published private(set) var closeState: [String: CloseState] = [:]
    private var closeQty: [String: Int] = [:]
    private var tracking: [String: Task<Void, Never>] = [:]

    /// The price an exit is based on: live quote, else the price implied by the broker's P&L
    /// (only when that P&L is non-zero, since 0 can mean "not computed yet").
    private func referencePrice(_ p: Position) -> Double? {
        if let live = prices[p.id], live > 0 { return live }
        guard p.unrealized != 0, let implied = p.impliedPrice, implied > 0 else { return nil }
        return implied
    }

    /// Limit price shown on the confirm button, from what the user is looking at.
    func previewLimit(_ p: Position) -> Double? {
        referencePrice(p).map { ExitPricing.limit(selling: p.netQty > 0, reference: $0) }
    }

    func close(_ p: Position, confirmedLimit: Double) async {
        guard ordersEnabled, authProblem == nil, let b = broker, p.isOpen, p.exitable else { return }
        switch closeState[p.id] {
        case .sending, .working, .unknown: return   // never stack a second exit
        default: break
        }
        closeState[p.id] = .sending
        closeQty[p.id] = p.netQty
        func fail(_ msg: String) { if broker === b { closeState[p.id] = .failed(msg) } }

        // Don't send with a token that's mid-rotation.
        if let r = renewal { await r.value }
        guard broker === b, authProblem == nil else { return fail("Session changed. No order sent.") }

        let cur: Position
        do {
            // Re-read the position right before ordering: a stale quantity could open a reverse position.
            let fresh = try await b.positions()
            guard broker === b else { return }
            apply(fresh)
            closeQty[p.id] = p.netQty
            guard let c = fresh.first(where: { $0.id == p.id }), c.isOpen else {
                return fail("Position is already closed. No order sent.")
            }
            guard c.netQty == p.netQty else { return fail("Quantity changed to \(c.netQty) since you clicked. No order sent.") }
            cur = c
        } catch {
            return fail("Couldn't re-check the position, so no order was sent. \(error.localizedDescription)")
        }

        // A working order (from here or the broker's app) means the position may already be exiting.
        do {
            let working = try await b.orders().filter { $0.instrumentKey == cur.instrumentKey && $0.isWorking }
            guard broker === b else { return }
            if let w = working.first {
                return fail("Order \(w.orderId) on this instrument is still \(w.status.lowercased()). No order sent.")
            }
        } catch {
            return fail("Couldn't check your open orders on \(DhanBroker.name), so no order was sent.")
        }

        // Fresh reference price: live quote if available, else the price implied by the P&L just fetched.
        var ref: Double?
        if liveFeed, let q = try? await b.lastPrices(for: [cur])[cur.id], q > 0 { ref = q }
        if ref == nil, cur.unrealized != 0, let implied = cur.impliedPrice, implied > 0 { ref = implied }
        guard broker === b else { return }
        guard let ref else { return fail("No reliable current price, so no order was sent.") }

        // Never worse than the price the user confirmed.
        let selling = cur.netQty > 0
        let freshLimit = ExitPricing.limit(selling: selling, reference: ref)
        let limit = selling ? max(freshLimit, confirmedLimit) : min(freshLimit, confirmedLimit)
        let tag = "chillar-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()

        do {
            let slices = try await b.placeExit(cur, limitPrice: limit, tag: tag)
            guard broker === b else { return }
            if slices.isEmpty {
                await resolve(tag: tag, id: p.id, limit: limit, broker: b)
            } else {
                show(ExitOutcome(slices), id: p.id, limit: limit)
            }
        } catch BrokerError.http(let code, let msg) where code < 500 {
            fail(msg ?? "Rejected by \(DhanBroker.name) (HTTP \(code)). No order is working.")
        } catch BrokerError.unauthorized {
            fail("\(DhanBroker.name) rejected the session. No order was placed.")
        } catch {
            // Timeout, connection lost, 5xx or unreadable reply: the order may have gone through.
            await resolve(tag: tag, id: p.id, limit: limit, broker: b)
        }
        if case .working = closeState[p.id] { track(tag: tag, id: p.id, limit: limit, broker: b) }
        if let refreshed = try? await b.positions(), broker === b { apply(refreshed) }
    }

    private func show(_ outcome: ExitOutcome, id: String, limit: Double) {
        let at = Fmt.price(limit)
        switch outcome {
        case .filled: closeState[id] = .filled("Exited at ≤ \(at) limit")
        case .working: closeState[id] = .working("Exit order open at \(at)")
        case .rejected: closeState[id] = .failed("Rejected by \(DhanBroker.name). No order is working.")
        case .partial: closeState[id] = .unknown("Some slices were rejected or cancelled. Check your order book.")
        case .unknown: closeState[id] = .unknown("Couldn't confirm whether the order reached \(DhanBroker.name). Check your order book before trying again.")
        }
    }

    /// After an unclear failure, ask the broker whether the tagged order exists.
    private func resolve(tag: String, id: String, limit: Double, broker b: DhanBroker) async {
        let slices = (try? await b.orders(tag: tag)) ?? []
        guard broker === b else { return }
        show(ExitOutcome(slices), id: id, limit: limit)
    }

    /// Follows a working exit until it fills or ends, so the row never claims more than it knows.
    private func track(tag: String, id: String, limit: Double, broker b: DhanBroker) {
        tracking[id]?.cancel()
        tracking[id] = Task { [weak self] in
            for _ in 0..<90 {   // ~3 minutes; afterwards the position re-check takes over
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.broker === b else { return }
                guard let slices = try? await b.orders(tag: tag), !slices.isEmpty else { continue }
                guard self.broker === b, case .working = self.closeState[id] else { return }
                let outcome = ExitOutcome(slices)
                self.show(outcome, id: id, limit: limit)
                if outcome != .working { return }
            }
        }
    }

    // MARK: Derived values

    /// Live price if available, otherwise the price implied by the broker's P&L.
    func displayPrice(_ p: Position) -> Double? { prices[p.id] ?? p.impliedPrice }
    func pnl(_ p: Position) -> Double { p.pnl(ltp: prices[p.id]) }

    var totalPnL: Double { positions.reduce(0) { $0 + pnl($1) } }
    var realizedPnL: Double { positions.reduce(0) { $0 + $1.realized } }
    var unrealizedPnL: Double { totalPnL - realizedPnL }
    var dayHigh: Double? { dayRange.high }
    var dayLow: Double? { dayRange.low }

    /// Capital in use: the broker's margin used today plus premium still held from earlier days,
    /// which the broker has already settled and leaves out (else "Used" shows just today's charges).
    var capitalUsed: Double? {
        guard let f = funds else { return nil }
        return f.used + positions.reduce(0) { $0 + $1.carriedCost }
    }

    /// Return on capital: the larger of capital in use and premium paid today, so a position
    /// closed during the day still counts towards the base.
    var returnPct: Double? {
        let base = max(capitalUsed ?? 0, positions.reduce(0) { $0 + $1.buyValue })
        return base > 0 ? totalPnL / base * 100 : nil
    }

    var visiblePositions: [Position] {
        let list = openOnly ? positions.filter(\.isOpen) : positions
        return list.sorted { ($0.isOpen ? 0 : 1, $0.symbol) < ($1.isOpen ? 0 : 1, $1.symbol) }
    }

    var hasPnL: Bool { lastUpdate != nil && !positions.isEmpty }

    /// Most important message for the footer and panel.
    var problem: String? { authProblem ?? warning ?? error }

    var menuTitle: String {
        // Always a P&L figure; "₹ —" until real data arrives.
        guard hasCredentials, lastUpdate != nil else { return "₹ —" }
        let pnl = positions.isEmpty ? "₹0" : Fmt.signedRupees(totalPnL, compact: true)
        return problem == nil ? pnl : "\(pnl) ⚠︎"
    }

    private func recordDayRange() {
        if dayRange.day != DayRange.today { dayRange = DayRange(day: DayRange.today) }
        let v = totalPnL
        if v > (dayRange.high ?? -.infinity) || v < (dayRange.low ?? .infinity) {
            dayRange.high = max(dayRange.high ?? v, v)
            dayRange.low = min(dayRange.low ?? v, v)
            dayRange.save()
        }
    }

    #if CHILLAR_DEV
    /// Dev aid for snapshots: loads a Dhan positions.json from a directory. No credentials, no network.
    func loadFixture(dir: String) {
        let url = URL(fileURLWithPath: dir)
        if let d = try? Data(contentsOf: url.appendingPathComponent("positions.json")) {
            positions = (try? DhanBroker.decodePositions(d)) ?? []
        }
        funds = Funds(available: 22_299, used: 13_670)
        clientId = "1000000000"
        broker = DhanBroker(clientId: "1000000000", accessToken: "fixture")   // never used: no loop runs
        liveFeed = false
        // A plausible day: peaked above the current total and dipped below zero in the morning.
        dayRange = DayRange(day: DayRange.today, high: (totalPnL * 1.32).rounded(), low: -(totalPnL * 0.18).rounded())
        lastUpdate = Date()
    }
    #endif

    private func applyDockPolicy() {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
        updateDockBadge()
    }

    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = showInDock && !positions.isEmpty
            ? Fmt.signedRupees(totalPnL, compact: true) : nil
    }
}

struct DayRange: Codable {
    var day: String
    var high: Double?
    var low: Double?

    init(day: String, high: Double? = nil, low: Double? = nil) {
        self.day = day; self.high = high; self.low = low
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return f.string(from: Date())
    }

    static func loadToday() -> DayRange {
        if let d = UserDefaults.standard.data(forKey: "dayRange"),
           let r = try? JSONDecoder().decode(DayRange.self, from: d), r.day == today { return r }
        return DayRange(day: today)
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "dayRange") }
    }
}
