import ServiceManagement
import SwiftUI

@main
struct ChillarApp: App {
    @StateObject private var store: Store

    init() {
        let store = Store()
        _store = StateObject(wrappedValue: store)
        #if CHILLAR_DEV
        Snapshots.run(store: store, args: CommandLine.arguments)
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(store)
        } label: {
            Image(nsImage: menuBarImage(store.menuTitle, pnl: store.hasPnL ? store.totalPnL : 0))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

// MARK: - Panel

/// Light, quiet palette: color is reserved for P&L.
enum Palette {
    static let bg = Color.white
    static let ink = Color(white: 0.11)
    static let muted = Color(white: 0.45)
    static let faint = Color(white: 0.62)
    static let rule = Color(white: 0.90)
    static let gain = Color(red: 0.05, green: 0.55, blue: 0.30)
    static let loss = Color(red: 0.80, green: 0.16, blue: 0.16)
}

func pnlColor(_ v: Double) -> Color { v > 0 ? Palette.gain : (v < 0 ? Palette.loss : Palette.ink) }

struct PanelView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.hasCredentials {
                CredentialsForm().padding(14)
            } else {
                Summary().padding(.horizontal, 12).padding(.vertical, 10)
                if let w = store.authProblem ?? store.warning {
                    Text(w).font(.system(size: 11)).foregroundStyle(Palette.loss)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Rule()
                PositionsList()
            }
            Rule()
            footer
        }
        .frame(width: 340)
        .onAppear { store.refreshSoon() }
        .background(Palette.bg)
        .foregroundStyle(Palette.ink)
        .environment(\.colorScheme, .light)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            let open = Store.marketOpen
            Circle().fill(open ? Palette.gain : Palette.faint).frame(width: 6, height: 6)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let t = store.lastUpdate {
                    Text(open ? ago(t) : "Closed · \(ago(t))").lineLimit(1).fixedSize()
                }
            }
            .help(store.liveFeed ? "Live prices" : "\(DhanBroker.name) P&L feed")
            if let e = store.problem {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(e)
            }
            Spacer()
            if let f = store.funds, let used = store.capitalUsed {
                Text("Avail \(Fmt.rupees(f.available)) · Used \(Fmt.rupees(used))").monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Button { NSApp.activate(); openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("Settings").padding(.leading, 4)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(IconButtonStyle())
                .help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func ago(_ d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

struct Rule: View {
    var body: some View { Rectangle().fill(Palette.rule).frame(height: 1) }
}

// MARK: - Summary

struct Summary: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let pnl = store.totalPnL
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.signedRupees(pnl))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(pnlColor(pnl))
                    .contentTransition(.numericText(value: pnl))
                    .animation(.smooth(duration: 0.25), value: pnl)
                    .fixedSize()
                if let r = store.returnPct {
                    Text(String(format: "%+.2f%%", r))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(pnlColor(pnl))
                        .fixedSize()
                }
            }
            // One line when it fits, otherwise two.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { bookedOpen; highLow }
                VStack(alignment: .leading, spacing: 2) { HStack(spacing: 12) { bookedOpen }; HStack(spacing: 12) { highLow } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var bookedOpen: some View {
        Stat("Booked", store.realizedPnL)
        Stat("Open", store.unrealizedPnL)
    }

    @ViewBuilder private var highLow: some View {
        Stat("High", store.dayHigh)
        Stat("Low", store.dayLow)
    }
}

struct Stat: View {
    let title: String
    let value: Double?
    init(_ title: String, _ value: Double?) { self.title = title; self.value = value }

    var body: some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(Palette.faint)
            Text(value.map { Fmt.signedRupees($0, compact: true) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(value.map(pnlColor) ?? Palette.faint)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Positions

struct PositionsList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let list = store.visiblePositions
        if list.isEmpty {
            Text(store.problem ?? "No positions today.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, minHeight: 56)
        } else if list.count <= 5 {
            // Plain stack: a ScrollView inside a MenuBarExtra window collapses to zero height.
            rows(list)
        } else {
            ScrollView { rows(list) }.frame(height: 5 * 46)
        }
    }

    private func rows(_ list: [Position]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Rule().padding(.leading, 12) }
                PositionRow(p: p, ltp: store.displayPrice(p), pnl: store.pnl(p),
                            state: store.closeState[p.id],
                            canOrder: store.ordersEnabled && p.exitable,
                            previewLimit: store.previewLimit(p)) { limit in
                    Task { await store.close(p, confirmedLimit: limit) }
                }
            }
        }
    }
}

struct PositionRow: View {
    let p: Position
    let ltp: Double?
    let pnl: Double
    let state: Store.CloseState?
    let canOrder: Bool
    let previewLimit: Double?
    let onClose: (Double) -> Void

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let exp = p.expiry {
                    Text(expiryText(exp)).font(.system(size: 11)).foregroundStyle(daysLeft(exp) <= 2 ? .orange : Palette.faint)
                }
                Spacer(minLength: 8)
                Text(Fmt.signedRupees(pnl))
                    .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(pnlColor(pnl))
            }
            HStack(spacing: 4) {
                if p.isOpen {
                    Text("\(p.netQty > 0 ? "Buy" : "Sell") \(abs(p.netQty)) @ \(Fmt.price(p.avgPrice))").fixedSize()
                    Text("·")
                    Text("LTP \(Fmt.price(ltp))")
                    if let ltp, let avg = p.avgPrice, avg > 0 {
                        Text(String(format: "(%+.2f%%)", (ltp - avg) / avg * 100)).foregroundStyle(pnlColor(pnl))
                    }
                } else {
                    Text("Closed")
                }
                Spacer(minLength: 8)
                if p.isOpen || state != nil {
                    if canOrder {
                        CloseControl(state: state, selling: p.netQty > 0, qty: abs(p.netQty),
                                     limit: previewLimit, onConfirm: onClose)
                    } else {
                        // Read-only mode: hand off to the broker rather than placing orders.
                        Button("Close ↗") { openBrokerPositions() }
                            .buttonStyle(ExitButtonStyle(filled: false))
                            .help("Opens your positions on \(DhanBroker.name). Enable order placement in Settings to close from here.")
                    }
                }
            }
            .font(.system(size: 10.5)).monospacedDigit()
            .foregroundStyle(Palette.muted)
            switch state {
            case .failed(let msg): FailureNote(message: msg)
            case .unknown(let msg): FailureNote(message: msg)
            default: EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hover ? Color(white: 0.975) : .clear)
        .opacity(p.isOpen ? 1 : 0.6)
        .onHover { hover = $0 }
    }

    private var title: String {
        var parts = [p.underlying]
        if let s = p.strike { parts.append(Fmt.strike(s)) }
        if let tag = p.tag { parts.append(tag) }
        return parts.joined(separator: " ")
    }

    private func daysLeft(_ d: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
    }

    private func expiryText(_ d: Date) -> String {
        let n = daysLeft(d)
        return "\(d.formatted(.dateTime.day().month(.abbreviated))) · \(n == 0 ? "expires today" : "\(n)d")"
    }
}

/// Two-step exit: "Close" arms a confirm button showing the limit price. Confirm ignores clicks for
/// the first 0.6s (so a double-click can't arm and confirm at once) and disarms itself after 5s.
struct CloseControl: View {
    let state: Store.CloseState?
    let selling: Bool
    let qty: Int
    let limit: Double?
    let onConfirm: (Double) -> Void
    @State private var armedAt: Date?

    var body: some View {
        switch state {
        case .sending:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Closing…") }
        case .filled(let status):
            Text(status).foregroundStyle(Palette.gain)
        case .working(let status):
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(status) }.foregroundStyle(.orange)
        case .unknown:
            // An order may exist: never offer a one-click retry here.
            Button("Check orders ↗") { openBrokerPositions() }.buttonStyle(ExitButtonStyle(filled: false))
        default:
            if let armedAt, let limit {
                Button("\(selling ? "Sell" : "Buy") \(qty) at \(selling ? "≥" : "≤") \(Fmt.price(limit))") {
                    guard Date().timeIntervalSince(armedAt) > 0.6 else { return }
                    self.armedAt = nil
                    onConfirm(limit)
                }
                .help("Confirm: limit order, at most \(Int(ExitPricing.slippage * 100))% from the current price")
                .buttonStyle(ExitButtonStyle(filled: true))
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    self.armedAt = nil
                }
            } else {
                Button(state == nil ? "Close" : "Retry") { armedAt = Date() }
                    .buttonStyle(ExitButtonStyle(filled: false))
                    .disabled(limit == nil)
                    .help(limit == nil ? "No current price available" : "Exit the full quantity")
            }
        }
    }
}

struct ExitButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 1)
            .foregroundStyle(filled ? Color.white : Palette.ink)
            .background(RoundedRectangle(cornerRadius: 5).fill(filled ? Palette.loss : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(filled ? Color.clear : Color(white: 0.80)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct FailureNote: View {
    let message: String

    var body: some View {
        // Dhan's static-IP rejections mention the IP whitelist; match the word, not any "ip" substring.
        let ipIssue = message.range(of: #"\b(IP|static ip|whitelist\w*)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        VStack(alignment: .leading, spacing: 3) {
            Text(message).foregroundStyle(Palette.loss)
            if ipIssue {
                Text("Dhan only accepts API orders from a whitelisted static IP (Dhan → Access DhanHQ APIs → Static IP Setting).")
            }
            Button("Open \(DhanBroker.name) positions") { openBrokerPositions() }
            .buttonStyle(.link)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
}

// MARK: - Settings

func openBrokerPositions() {
    NSWorkspace.shared.open(DhanBroker.positionsURL)
}

struct CredentialsForm: View {
    @EnvironmentObject var store: Store
    @State private var clientId = ""
    @State private var token = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.hasCredentials ? "Replace access token" : "Connect \(DhanBroker.name)").font(.headline)
            Text("web.dhan.co → My Profile → Access DhanHQ APIs → generate an access token. It's stored only in your Mac's Keychain.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder)
            // The saved token is never loaded back into the UI.
            SecureField(store.hasCredentials ? "New access token" : "Access token", text: $token)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Save") {
                    message = store.saveCredentials(clientId: clientId, token: token)
                    if message == nil { token = "" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clientId.isEmpty || token.isEmpty)
            }
        }
        .onAppear { clientId = store.clientId }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Form {
            Section("\(DhanBroker.name) account") {
                CredentialsForm()
                if let exp = store.tokenExpiry {
                    LabeledContent("Token valid until") {
                        Text(exp.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text("Renews automatically while \(AppInfo.name) runs. Keep it running (add to Login Items) and you won't need to paste a new token.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sign out and delete token", role: .destructive) { store.signOut() }
                }
            }
            Section {
                Toggle("Allow closing positions from \(AppInfo.name) (experimental)", isOn: $store.ordersEnabled)
                Text("Experimental: try with care, at your own risk.")
                    .font(.caption).foregroundStyle(.orange)
                Text("Off by default, so \(AppInfo.name) can only read. When on, Close places a real limit order for the full quantity (F&O only), at most \(Int(ExitPricing.slippage * 100))% from the current price, after a second click that shows the price. It refuses if another order on that instrument is still working. \(DhanBroker.name) also requires your static IP to be whitelisted.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Trading") }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                if store.loginItemNeedsApproval {
                    HStack {
                        Text("Allow \(AppInfo.name) in Login Items to finish.").font(.caption).foregroundStyle(.orange)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Text("Keeps your session renewed. If \(AppInfo.name) is off for more than 24 hours, the token expires.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display") {
                Toggle("Show only open positions", isOn: $store.openOnly)
                Toggle("Show in Dock with P&L badge", isOn: $store.showInDock)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Menu bar labels are forced to monochrome, so draw the P&L as a non-template image:
/// colored figures on a white pill, readable on any wallpaper or menu bar tint.
func menuBarImage(_ text: String, pnl: Double) -> NSImage {
    let color = NSColor(pnl > 0 ? Palette.gain : (pnl < 0 ? Palette.loss : Palette.ink))
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let textSize = str.size()
    let padX: CGFloat = 6, height: CGFloat = 18
    let size = NSSize(width: ceil(textSize.width) + padX * 2, height: height)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        str.draw(at: NSPoint(x: padX, y: (height - textSize.height) / 2))
        return true
    }
    image.isTemplate = false
    return image
}
