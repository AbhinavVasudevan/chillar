import Foundation

/// Exit limit prices: at most `slippage` worse than the reference, on the 0.05 F&O tick.
enum ExitPricing {
    static let slippage = 0.03
    static let tick = 0.05

    static func limit(selling: Bool, reference: Double) -> Double {
        let raw = reference * (selling ? 1 - slippage : 1 + slippage)
        // Round towards the market (up when selling) so the cap is never exceeded;
        // the epsilon stops float noise like 96.99999 from adding a tick.
        let ticks = selling ? (raw / tick - 1e-9).rounded(.up) : (raw / tick + 1e-9).rounded(.down)
        return max(tick, (ticks * tick * 100).rounded() / 100)
    }
}

enum Fmt {
    static func signedRupees(_ v: Double, compact: Bool = false) -> String {
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
        let a = abs(v)
        if compact && a >= 100_000 { return "\(sign)₹\(String(format: "%.2f", a / 100_000))L" }
        if compact && a >= 10_000 { return "\(sign)₹\(String(format: "%.1f", a / 1000))k" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = compact ? 0 : 2
        f.minimumFractionDigits = compact ? 0 : 2
        return "\(sign)₹\(f.string(from: NSNumber(value: a)) ?? "\(a)")"
    }

    static func rupees(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        return "₹" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v))
    }

    static func strike(_ v: Double) -> String {
        v.rounded() == v ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    static func price(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2f", v)
    }
}
