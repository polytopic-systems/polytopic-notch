import AppKit
import SwiftUI
import Testing
@testable import PolytopicNotch

/// Notches of different Macs: (screen width, notch width, notch height, menu bar height).
enum TestScreens {
    static let notches: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (1512, 188, 32, 32),   // 14" at default scaling
        (1728, 186, 38, 38),   // 16"
        (2056, 220, 38, 39),   // 16" at More Space: the menu bar is a point deeper than the notch
        (1470, 160, 34, 37),
    ]

    static func geometry(_ notch: (CGFloat, CGFloat, CGFloat, CGFloat)) -> NotchGeometry {
        let (screenWidth, notchWidth, notchHeight, menuBar) = notch
        let side = (screenWidth - notchWidth) / 2
        return NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: screenWidth, height: 1000), safeAreaTop: notchHeight,
                             auxiliaryTopLeft: CGRect(x: 0, y: 1000 - notchHeight, width: side, height: notchHeight),
                             auxiliaryTopRight: CGRect(x: side + notchWidth, y: 1000 - notchHeight, width: side, height: notchHeight),
                             menuBarHeight: menuBar)
    }

    /// An external display without a notch.
    static let external = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                        auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 25)
}

extension NotchViewModel {
    /// A pill on a test screen with settings of its own.
    static func test(_ geometry: NotchGeometry = TestScreens.geometry(TestScreens.notches[0]),
                     settings: NotchSettings = NotchSettings(), content: NotchContent = NotchContent()) -> NotchViewModel {
        NotchViewModel(content: content, settings: InMemoryNotchSettings(settings), geometry: geometry)
    }
}

/// Collects what the notch code logs.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(NotchLog.Level, String)] = []

    var log: NotchLog {
        NotchLog { [self] level, message in
            lock.withLock { lines.append((level, message)) }
        }
    }

    var all: [String] { lock.withLock { lines.map(\.1) } }
}

/// Looking at the UI without a screen: screen capture and computer-use tools may not see these panels (above the
/// menu bar, in agent apps), so tests render views offscreen and write PNGs to look at.
///
/// PNGs are written only when `NOTCH_RENDER_DIR=<folder>` is set (`NOTCH_RENDER_DIR=~/Library/Caches/notch-renders
/// swift test --scratch-path … --filter NotchRenderTests`). Liquid Glass and vibrancy come out blank offscreen;
/// judge layout, spacing and text.
@MainActor
enum OffscreenRender {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Hosts `content` in an offscreen window (Forms and AppKit-backed controls need a real window to lay out),
    /// waits for it to settle and captures it with `cacheDisplay`.
    @discardableResult
    static func window(_ name: String, size: NSSize, dark: Bool = false, settle: Duration = .milliseconds(700),
                       @ViewBuilder content: () -> some View) async throws -> NSBitmapImageRep {
        // Really out of sight: transparent, off every screen, and out of the window cycle (at a screen corner
        // every render flashed by). `cacheDisplay` draws the views themselves, so neither changes the
        // picture; the ink-coverage checks would fail if it did.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.isExcludedFromWindowsMenu = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000)) // AppKit may pull a newly ordered window on screen
        defer { window.orderOut(nil) }
        try await Task.sleep(for: settle)
        // Borderless: the capture is the content alone, no title bar above it.
        let view = window.contentView!
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try write(rep, name: dark ? "\(name)-dark" : name)
        return rep
    }

    static func write(_ rep: NSBitmapImageRep, name: String) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
    }

    /// Fraction of pixels that differ from the corner pixel: a cheap "something was drawn" check.
    static func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let background = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB) else { return 0 }
        var differing = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                total += 1
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent) > 0.08 { differing += 1 }
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    /// Whether the pixel at a point (in points from the top-left of the capture) is close to black.
    static func isBlack(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat, pointSize: NSSize) -> Bool {
        let scaleX = CGFloat(rep.pixelsWide) / pointSize.width, scaleY = CGFloat(rep.pixelsHigh) / pointSize.height
        guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent + color.greenComponent + color.blueComponent < 0.15
    }
}
