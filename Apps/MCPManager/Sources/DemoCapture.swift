import AppKit
import SwiftUI
import MCPMCore
import MCPMControl

// Demo capture only — the whole file. With `MCPM_DEMO_CAPTURE=<directory>` set, the app becomes its
// own photographer: it drives itself through a handful of scripted scenes and writes the website's
// stills and clip frames out of `NSView.cacheDisplay(in:to:)`, which renders the live hierarchy into
// a bitmap without asking for Screen Recording — the app is only ever photographing itself.
//
// Nothing in here runs and no hook is registered when the variable is unset, which is every run
// that isn't `scripts/render-site-media.sh`.

enum DemoCapture {
    /// Where the stills, the frame folders and the `done` marker go. nil in a normal run, which is
    /// what every other guard in the app is asking about.
    static let output: URL? = {
        guard let path = ProcessInfo.processInfo.environment["MCPM_DEMO_CAPTURE"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static var isActive: Bool { output != nil }

    /// The site's content column is 1160 pt wide, so the window is captured at exactly that width
    /// and never resampled on the way in. The height is what nine servers and the inspector fill
    /// without leaving a field of empty grid under them.
    static let windowSize = CGSize(width: 1160, height: 560)

    /// What the window is composited over. `cacheDisplay` cannot draw a backdrop-sampling layer, so
    /// the material behind the shell comes back transparent — and the design's fill tiers are tints
    /// over it. Flattening over a mid-light grey, roughly what a blurred desktop reads as, keeps the
    /// shell/card/well separation the app actually has; flattening over white would erase it.
    static let backdrop = NSColor(srgbRed: 0.855, green: 0.855, blue: 0.867, alpha: 1)
}

/// The hooks the driver steers the UI with. Each one is the same write the corresponding button or
/// field makes; the views install them from `onAppear`, and only while capture is on.
@MainActor
enum DemoHooks {
    static var showServers: (() -> Void)?
    static var showCatalog: (() -> Void)?
    static var select: ((String?) -> Void)?
    static var openAdd: ((CatalogEntry) -> Void)?
    static var closeAdd: (() -> Void)?
    static var setCatalogQuery: ((String) -> Void)?
}

extension View {
    /// Draws the controls the way they look when the app is in front. The capture runs while the
    /// user's own Mac keeps the frontmost app, and activation is cooperative — an inactive window
    /// draws its accents in the inactive grey, which is not what this app looks like in use.
    /// Untouched in a normal run, where the window's real state is the right answer.
    @ViewBuilder func demoActiveControls() -> some View {
        if DemoCapture.isActive {
            environment(\.controlActiveState, .key)
        } else {
            self
        }
    }

    /// Starts the capture driver. A no-op — not even a modifier — in a normal run.
    @ViewBuilder func demoCapture(_ daemon: DaemonClient) -> some View {
        if DemoCapture.isActive {
            modifier(DemoCaptureModifier(daemon: daemon))
        } else {
            self
        }
    }
}

private struct DemoCaptureModifier: ViewModifier {
    let daemon: DaemonClient
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            // The menu bar label can be rebuilt; the driver runs once per launch.
            guard let out = DemoCapture.output, !DemoDriver.started else { return }
            DemoDriver.started = true
            await DemoDriver(daemon: daemon, out: out, openMainWindow: { openWindow(id: "main") }).run()
        }
    }
}

// MARK: - The driver

@MainActor
final class DemoDriver {
    static var started = false

    private enum Failure: Error, CustomStringConvertible {
        case timedOut(String)
        case blank(String)

        var description: String {
            switch self {
            case .timedOut(let what): "timed out waiting for \(what)"
            case .blank(let name): "\(name) came back with nothing in it"
            }
        }
    }

    private let daemon: DaemonClient
    private let out: URL
    private let openMainWindow: () -> Void

    init(daemon: DaemonClient, out: URL, openMainWindow: @escaping () -> Void) {
        self.daemon = daemon
        self.out = out
        self.openMainWindow = openMainWindow
    }

    func run() async {
        // The site is white, so the app is photographed light whatever the Mac is set to.
        NSApp.appearance = NSAppearance(named: .aqua)
        do {
            try await wait(for: "the background service") { self.daemon.isConnected && self.daemon.status != nil }
            openMainWindow()
            NSApp.activate()
            let window = try await value(of: "the main window") { Self.mainWindow() }
            try await wait(for: "the window's hooks") { DemoHooks.select != nil }
            await prepare(window)
            // Favicons arrive over the network and the first layout settles a beat after that.
            await sleep(2500)

            try await still("grid.png") { await self.captureGrid(window) }
            try await still("popover.png") { await self.capturePopover() }
            await recordLibrary(window)
            await recordSignIn(window)
            await recordCatalog(window)
            try marker("done", "ok")
        } catch {
            try? marker("error", String(describing: error))
        }
        NSApp.terminate(nil)
    }

    // MARK: scenes

    /// The library as the site leads with it: every server as a card, one of them selected so the
    /// inspector is open on a signed-in remote server.
    private func captureGrid(_ window: NSWindow) async -> NSBitmapImageRep? {
        DemoHooks.showServers?()
        DemoHooks.select?("notion")
        // The inspector slides in and the grid reflows around it.
        await sleep(900)
        await activate(window)
        return snapshot(window)
    }

    /// The popover cannot be opened from code — `MenuBarExtra` owns its window — so it is rebuilt:
    /// the same view, at the same width, in the same rounded shell, on a light backdrop wide enough
    /// to sit in the site's media band.
    private func capturePopover() async -> NSBitmapImageRep? {
        let content = MenuBarView()
            .environment(daemon)
            .demoActiveControls()
            .background(Color(nsColor: DemoCapture.backdrop).opacity(0.55))
            .background(.white)
            .clipShape(.rect(cornerRadius: Radius.shell, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.shell, style: .continuous)
                    .strokeBorder(.black.opacity(0.10), lineWidth: Stroke.shell)
            }

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = DemoPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.setFrameOrigin(NSPoint(x: 80, y: 120))
        panel.makeKeyAndOrderFront(nil)
        await sleep(2200)

        let scale = panel.backingScaleFactor
        let popover = snapshot(host, flattened: false)
        panel.orderOut(nil)
        panel.close()
        guard let popover else { return nil }
        return Self.band(around: popover, scale: scale)
    }

    /// Toggling a server on and off for a client, which is the one thing the app is for.
    private func recordLibrary(_ window: NSWindow) async {
        DemoHooks.showServers?()
        DemoHooks.select?(nil)
        await sleep(900)
        await record("demo-library", window) {
            await self.sleep(1800)
            self.daemon.setClient("context7", .claudeDesktop, true)
            await self.sleep(2800)
            self.daemon.setClient("mobbin", .codex, true)
            await self.sleep(2800)
            self.daemon.setClient("context7", .claudeDesktop, false)
            await self.sleep(3200)
        }
    }

    /// A server waiting on a sign-in becoming a signed-in one. The credential is planted in the
    /// scratch store from outside the daemon, so the app asks for a status rather than waiting for
    /// a push nothing would send.
    private func recordSignIn(_ window: NSWindow) async {
        DemoHooks.showServers?()
        DemoHooks.select?("posthog")
        await sleep(1200)
        await record("demo-signin", window) {
            await self.sleep(2400)
            self.signInPostHog()
            await self.daemon._demoRefreshStatus()
            await self.sleep(3400)
            self.daemon._demoInjectTestResult("posthog", TestResult(ok: true, serverName: "PostHog MCP",
                                                                    toolCount: 43, durationMs: 320))
            await self.sleep(3400)
        }
    }

    /// Searching the catalog and opening the Add sheet already filled in. GitHub rather than a
    /// server the library already has: an entry that is already in there says "Added" instead of
    /// offering the button the clip is about.
    private func recordCatalog(_ window: NSWindow) async {
        DemoHooks.select?(nil)
        DemoHooks.showCatalog?()
        try? await wait(for: "the catalog") { DemoHooks.setCatalogQuery != nil }
        await sleep(1400)
        let found = try? await daemon.searchCatalog(query: "github", limit: 10)
        let entry = found?.first { $0.name.caseInsensitiveCompare("GitHub") == .orderedSame } ?? found?.first
        await record("demo-catalog", window) {
            await self.sleep(1200)
            var typed = ""
            for character in "github" {
                typed.append(character)
                DemoHooks.setCatalogQuery?(typed)
                await self.sleep(110)
            }
            await self.sleep(3000)
            if let entry { DemoHooks.openAdd?(entry) }
            await self.sleep(3800)
            DemoHooks.closeAdd?()
            await self.sleep(1400)
        }
        DemoHooks.setCatalogQuery?("")
    }

    /// The sign-in the browser would have finished: the script stages a token file beside the live
    /// one, and this puts it in place. The store is read on every lookup, so the daemon reports the
    /// server as connected the next time it is asked.
    private func signInPostHog() {
        let root = HomeDirectory.url.appendingPathComponent(".mcpm")
        let staged = root.appendingPathComponent("tokens.signed-in.json")
        let live = root.appendingPathComponent("tokens.json")
        guard FileManager.default.fileExists(atPath: staged.path) else { return }
        try? FileManager.default.removeItem(at: live)
        try? FileManager.default.copyItem(at: staged, to: live)
    }

    // MARK: capture

    /// One still, written as a PNG, with a clear failure if the capture came back empty.
    private func still(_ name: String, _ make: () async -> NSBitmapImageRep?) async throws {
        guard let rep = await make(), let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.blank(name)
        }
        try png.write(to: out.appendingPathComponent(name))
    }

    /// Photographs the window every 50 ms for as long as `body` runs, into `frames-<name>/`, and
    /// leaves the measured frame rate beside them so the encode matches real time rather than the
    /// rate the timer was aiming for.
    private func record(_ name: String, _ window: NSWindow, _ body: () async -> Void) async {
        let directory = out.appendingPathComponent("frames-\(name)")
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = FrameRecorder(directory: directory)

        let started = Date()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                let tick = Date()
                // Cheap, and it holds the window key for the length of the clip.
                if !NSApp.isActive || !window.isKeyWindow { self.reactivate(window) }
                if let rep = self.snapshot(window) { recorder.write(rep) }
                let cost = Date().timeIntervalSince(tick)
                // What is left of the 50 ms budget, so a slow frame doesn't push every later one back.
                try? await Task.sleep(for: .milliseconds(max(1, Int((0.05 - cost) * 1000))))
            }
        }
        await body()
        ticker.cancel()
        let elapsed = Date().timeIntervalSince(started)
        let frames = recorder.finish()
        // The measured rate, not the one the timer aimed at: a clip encoded at the nominal 20 fps
        // when only 14 were taken would run half as fast as the thing it filmed.
        let fps = elapsed > 0 ? Double(frames) / elapsed : 20
        try? marker("frames-\(name)/fps", String(format: "%.3f", fps))
    }

    /// The window as the user sees it: the content view, plus whatever sheet is attached to it,
    /// composited where the sheet actually sits — sheets are their own windows, so nothing of them
    /// is in the parent's bitmap.
    private func snapshot(_ window: NSWindow) -> NSBitmapImageRep? {
        // The frame view rather than the content view: it is the same rectangle — the window has a
        // full-size content view — plus the traffic lights, which belong in a picture of a window.
        guard let content = window.contentView?.superview ?? window.contentView,
              let base = snapshot(content, flattened: true) else { return nil }
        guard let sheet = window.attachedSheet, let sheetView = sheet.contentView,
              let top = snapshot(sheetView, flattened: false) else { return base }

        // Rects, not origins: a hosting view is flipped and its origin is its top left, while the
        // window and the bitmap context below both measure from the bottom left. Converting the
        // whole rect is what gets that right.
        let scale = window.backingScaleFactor
        let baseRect = window.convertToScreen(content.convert(content.bounds, to: nil))
        let sheetRect = sheet.convertToScreen(sheetView.convert(sheetView.bounds, to: nil))
        let rect = NSRect(x: (sheetRect.minX - baseRect.minX) * scale,
                          y: (sheetRect.minY - baseRect.minY) * scale,
                          width: CGFloat(top.pixelsWide), height: CGFloat(top.pixelsHigh))
        return Self.draw(size: NSSize(width: base.pixelsWide, height: base.pixelsHigh)) { _ in
            base.draw(in: NSRect(x: 0, y: 0, width: base.pixelsWide, height: base.pixelsHigh))
            NSColor.black.withAlphaComponent(0.10).setFill()
            NSRect(x: 0, y: 0, width: base.pixelsWide, height: base.pixelsHigh).fill(using: .sourceOver)
            top.draw(in: rect)
        }
    }

    private func snapshot(_ view: NSView, flattened: Bool) -> NSBitmapImageRep? {
        guard let rep = Self.cache(view) else { return nil }
        guard flattened else { return rep }
        let scale = view.window?.backingScaleFactor ?? 2
        let patches = Self.glassContent(in: view, scale: scale)
        return Self.draw(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)) { size in
            DemoCapture.backdrop.setFill()
            NSRect(origin: .zero, size: size).fill()
            rep.draw(in: NSRect(origin: .zero, size: size))
            for patch in patches { patch.rep.draw(in: patch.rect) }
        }
    }

    private static func cache(_ view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The inspector column lives inside an `NSGlassEffectView`, and a glass view composites its
    /// content instead of drawing it: from the root, the column photographs as an empty panel with
    /// only its footer. Starting the drawing at the scrolling content inside it gets that content
    /// back, so each one is photographed on its own and pasted where it sits. Rects come back in
    /// pixels, measured from the bottom left like the bitmap context they are drawn into.
    private static func glassContent(in root: NSView, scale: CGFloat) -> [(rep: NSBitmapImageRep, rect: NSRect)] {
        let base = root.convert(root.bounds, to: nil).origin
        var found: [(rep: NSBitmapImageRep, rect: NSRect)] = []
        func collect(_ view: NSView) {
            if String(describing: type(of: view)) == "HostingClipView", let rep = cache(view) {
                let frame = view.convert(view.bounds, to: nil)
                found.append((rep, NSRect(x: (frame.minX - base.x) * scale, y: (frame.minY - base.y) * scale,
                                          width: frame.width * scale, height: frame.height * scale)))
                return
            }
            view.subviews.forEach(collect)
        }
        func walk(_ view: NSView) {
            if String(describing: type(of: view)) == "NSGlassEffectView" {
                collect(view)
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The popover, centred on a band as wide as the site's column so the still is used at its own
    /// size rather than blown up from 332 pt.
    private static func band(around popover: NSBitmapImageRep, scale: CGFloat) -> NSBitmapImageRep? {
        let width = DemoCapture.windowSize.width * scale
        let inset = 64 * scale
        let height = CGFloat(popover.pixelsHigh) + inset * 2
        let origin = NSPoint(x: (width - CGFloat(popover.pixelsWide)) / 2, y: inset)
        return draw(size: NSSize(width: width, height: height)) { size in
            let gradient = NSGradient(starting: NSColor(srgbRed: 0.918, green: 0.918, blue: 0.929, alpha: 1),
                                      ending: NSColor(srgbRed: 0.855, green: 0.855, blue: 0.871, alpha: 1))
            gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
            let target = NSRect(origin: origin, size: NSSize(width: popover.pixelsWide, height: popover.pixelsHigh))
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 26 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
            shadow.set()
            popover.draw(in: target)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    /// A fresh bitmap, drawn into in pixel coordinates. 32 bits with an alpha channel because a
    /// 24-bit rep has no `CGBitmapContext` behind it and cannot be drawn into at all; every caller
    /// fills it edge to edge, so what comes out is opaque anyway.
    private static func draw(size: NSSize, _ body: (NSSize) -> Void) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                         pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        body(size)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: plumbing

    private func prepare(_ window: NSWindow) async {
        window.setContentSize(DemoCapture.windowSize)
        window.center()
        // Nothing is being typed into, so nothing should be carrying a blinking caret.
        window.makeFirstResponder(nil)
        await activate(window)
        try? marker("state", "active=\(NSApp.isActive) key=\(window.isKeyWindow)")
    }

    /// Gets the window key and keeps asking until it is: an inactive window draws every
    /// accent-coloured control in the inactive grey, which is not what the app looks like in use.
    /// Worth re-asserting before every scene — activation granted at launch does not survive
    /// whatever else the Mac is doing.
    private func activate(_ window: NSWindow) async {
        for _ in 0..<20 {
            if NSApp.isActive && window.isKeyWindow { return }
            reactivate(window)
            await sleep(150)
        }
    }

    private func reactivate(_ window: NSWindow) {
        NSApp.activate()
        // Activation is cooperative since macOS 14: asking the app that currently has it is the
        // request that is actually allowed to succeed.
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            NSRunningApplication.current.activate(from: front, options: [.activateAllWindows])
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "MCP Manager" && $0.isVisible && $0.contentView != nil }
    }

    private func marker(_ name: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: out.appendingPathComponent(name))
    }

    private func sleep(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func wait(for what: String, timeout: Duration = .seconds(30),
                      until condition: () -> Bool) async throws {
        _ = try await value(of: what, timeout: timeout) { condition() ? true : nil }
    }

    private func value<T>(of what: String, timeout: Duration = .seconds(30),
                          from make: () -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let value = make() { return value }
            await sleep(100)
        }
        throw Failure.timedOut(what)
    }
}

/// Borderless windows refuse key by default, and a window that isn't key draws its controls in the
/// inactive grey — which is not what the popover looks like when someone is using it.
private final class DemoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Writes frames off the main thread. JPEG rather than PNG: the frames exist only to be handed to
/// ffmpeg, and PNG at this size cannot be encoded 20 times a second without stalling the very
/// animations being filmed.
private final class FrameRecorder {
    /// The bitmap is handed over and never touched on the main thread again.
    private struct Handoff: @unchecked Sendable {
        let rep: NSBitmapImageRep
        let url: URL
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "co.charmtechnologies.mcpmanager.demo-frames",
                                      qos: .userInitiated, attributes: .concurrent)
    private let group = DispatchGroup()
    /// Back-pressure, so a slow encode cannot pile up frames faster than they are written.
    private let slots = DispatchSemaphore(value: 12)
    private var index = 0

    init(directory: URL) { self.directory = directory }

    func write(_ rep: NSBitmapImageRep) {
        index += 1
        let handoff = Handoff(rep: rep, url: directory.appendingPathComponent(String(format: "f%05d.jpg", index)))
        slots.wait()
        queue.async(group: group) { [slots] in
            defer { slots.signal() }
            let data = handoff.rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
            try? data?.write(to: handoff.url)
        }
    }

    /// Waits for the writes still in flight and answers with how many frames there were.
    func finish() -> Int {
        group.wait()
        return index
    }
}
