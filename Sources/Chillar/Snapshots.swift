#if CHILLAR_DEV
import AppKit
import SwiftUI

/// Dev-only renderer for README images, from fixture data. Compiled only with `./build.sh dev`.
///
///     Chillar --snapshot out.png --fixture Fixtures          hero: desktop, menu bar, open panel
///     Chillar --snapshot out.png --fixture Fixtures --pills  menu bar in profit and in loss
@MainActor
enum Snapshots {
    static func run(store: Store, args: [String]) {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        if let fx = args.firstIndex(of: "--fixture"), fx + 1 < args.count { store.loadFixture(dir: args[fx + 1]) }
        let out = URL(fileURLWithPath: args[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let view: AnyView = args.contains("--pills")
                ? AnyView(PillsScene())
                : AnyView(HeroScene().environmentObject(store))
            let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: out)
            }
            exit(0)
        }
    }
}

/// A soft macOS-style wallpaper.
private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.86), Color(red: 0.62, green: 0.48, blue: 0.84),
                                    Color(red: 0.95, green: 0.62, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.35), .clear], center: .init(x: 0.2, y: 0.85),
                           startRadius: 10, endRadius: 420)
        }
    }
}

/// A translucent menu bar with the usual system items and Chillar's pill.
private struct MenuBar: View {
    let pnl: Double
    let title: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "applelogo").font(.system(size: 14, weight: .medium))
            Text("Finder").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(nsImage: menuBarImage(title, pnl: pnl))
            Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
            Image(systemName: "battery.75percent").font(.system(size: 15))
            Image(systemName: "switch.2").font(.system(size: 13, weight: .semibold))
            Text("Tue 13 Oct  11:42").font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: width, height: 30)
        .background(Color.black.opacity(0.18))
    }
}

private struct HeroScene: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let width: CGFloat = 880
        ZStack(alignment: .topTrailing) {
            Wallpaper()
            VStack(alignment: .trailing, spacing: 6) {
                MenuBar(pnl: store.totalPnL, title: store.menuTitle, width: width)
                PanelView()
                    .environmentObject(store)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.black.opacity(0.10)))
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                    .padding(.trailing, 110)
            }
        }
        .frame(width: width, height: 345)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct PillsScene: View {
    var body: some View {
        VStack(spacing: 14) {
            row(pnl: 4_115, title: "+₹4,115", caption: "In profit")
            row(pnl: -1_240, title: "−₹1,240", caption: "In loss")
        }
        .padding(18)
        .frame(width: 520)
        .background(Wallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(pnl: Double, title: String, caption: String) -> some View {
        HStack(spacing: 16) {
            Text(caption).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 70, alignment: .leading)
            HStack(spacing: 16) {
                Spacer()
                Image(nsImage: menuBarImage(title, pnl: pnl))
                Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
                Image(systemName: "battery.75percent").font(.system(size: 15))
                Text("11:42").font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
#endif
