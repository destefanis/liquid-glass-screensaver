//
//  LiquidGlassScreensaverView.swift
//  liquid-glass-screensaver
//
//  Hosts the liquid glass shader composition inside a ScreenSaverView.
//  The @objc name matches INFOPLIST_KEY_NSPrincipalClass so the system
//  can instantiate this class from the bundle.
//

import ScreenSaver
import MetalKit

@objc(liquid_glass_screensaverView)
class LiquidGlassScreensaverView: ScreenSaverView {

    private var metalView: MTKView?
    private var renderer: LiquidGlassRenderer?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        Self.breadcrumb("init frame=\(Int(frame.width))x\(Int(frame.height)) isPreview=\(isPreview)")
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        Self.breadcrumb("deinit")
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 60.0
        setupLifecycleObservers()
        setupMetal()
    }

    /// (Re)creates the Metal view + renderer.  Called from init and
    /// again from startAnimation after a teardown — each run renders
    /// with a fresh MTKView, mirroring the teardown/rebuild lifecycle
    /// that keeps the legacyScreenSaver host from wedging.
    private func setupMetal() {
        guard metalView == nil else { return }

        let mtkView = MTKView(frame: bounds)
        // Self-driving rendering: the MTKView's own display link draws
        // at 60fps regardless of whether the legacyScreenSaver host
        // delivers animateOneFrame/startAnimation.  The wedged host is
        // known to drop those lifecycle calls, and a saver that depends
        // on them renders black when relaunched into a stale host.
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60

        guard let renderer = LiquidGlassRenderer(metalView: mtkView) else {
            return
        }

        addSubview(mtkView)
        self.metalView = mtkView
        self.renderer = renderer
        renderer.fresnelIntensityScale = Self.storedFresnelScale()
        renderer.setDarkMode(Self.systemUsesDarkMode(), animated: false)
        mtkView.frame = aspectFillFrame()
    }

    /// Full teardown of the rendering stack.  Releasing the MTKView and
    /// renderer on stop (rather than pausing them) is part of the
    /// anti-wedge lifecycle: a stopped instance keeps no GPU state.
    private func teardownMetal() {
        metalView?.removeFromSuperview()
        metalView = nil
        renderer = nil
    }

    /// The composition renders at its baked canvas aspect ratio (16:9).
    /// Cover the view proportionally (center-crop the overflow) instead
    /// of letting the final blit stretch to the screen's aspect.
    private func aspectFillFrame() -> NSRect {
        guard let renderer, bounds.width > 0, bounds.height > 0 else { return bounds }
        let canvas = renderer.canvasSize
        let scale = max(bounds.width / canvas.width, bounds.height / canvas.height)
        let size = NSSize(width: canvas.width * scale, height: canvas.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    override func layout() {
        super.layout()
        metalView?.frame = aspectFillFrame()
    }

    override func startAnimation() {
        Self.breadcrumb("startAnimation frame=\(Int(frame.width))x\(Int(frame.height)) isPreview=\(isPreview)")
        super.startAnimation()
        setupMetal()
    }

    override func stopAnimation() {
        Self.breadcrumb("stopAnimation isPreview=\(isPreview)")
        super.stopAnimation()
        teardownMetal()
    }

    // The host sometimes removes the view without ever calling
    // stopAnimation — make removal force the teardown path.
    override func removeFromSuperview() {
        Self.breadcrumb("removeFromSuperview isPreview=\(isPreview)")
        teardownMetal()
        super.removeFromSuperview()
    }

    override func animateOneFrame() {
        // Rendering is driven by the MTKView's own display link (see
        // setupMetal) — nothing to do here.  Kept because the host
        // expects the override to exist for legacy savers.
    }

    // Keep the Metal layer in sync with the screen the way the host
    // expects — it can move the view between displays/backing scales
    // without resizing it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            metalView?.layer?.contentsScale = window.backingScaleFactor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = self.window {
            metalView?.layer?.contentsScale = window.backingScaleFactor
        }
    }

    // MARK: - Host process lifecycle
    //
    // ⚠️ AGENT / MAINTAINER INSTRUCTIONS — do not remove the exit(0)
    // below, and do not "fix" it by replacing it with ordinary cleanup.
    //
    // On modern macOS (Sonoma and later) third-party savers run inside
    // the out-of-process `legacyScreenSaver` host. That host does NOT
    // reliably tear the saver down after a run: once the preview (or
    // the real saver) stops, the process lingers with this view still
    // loaded and wedged. The observable symptoms without this code:
    //
    //   1. The "Preview" button in System Settings works exactly once —
    //      further clicks do nothing until the user manually kills
    //      `legacyScreenSaver` in Activity Monitor.
    //   2. The `legacyScreenSaver` process never exits on its own and
    //      keeps the GPU/Metal resources alive in the background.
    //
    // Calling exit(0) when the system announces the saver is stopping
    // (or the machine is going to sleep) terminates the host process so
    // macOS spawns a fresh one for the next run. The host is disposable
    // by design, so exiting it is safe.
    //
    private func setupLifecycleObservers() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screensaverWillStop),
            name: Notification.Name("com.apple.screensaver.willstop"),
            object: nil
        )
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(interfaceThemeDidChange),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    @objc private func screensaverWillStop(_ notification: Notification) {
        Self.breadcrumb("willstop")
        exit(0)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        Self.breadcrumb("willsleep")
        exit(0)
    }

    @objc private func interfaceThemeDidChange(_ notification: Notification) {
        renderer?.setDarkMode(Self.systemUsesDarkMode(), animated: true)
    }

    // MARK: - Settings (Options sheet)

    private static let fresnelScaleKey = "fresnelIntensityScale"

    private static var saverDefaults: ScreenSaverDefaults? {
        let moduleName = Bundle(for: LiquidGlassScreensaverView.self).bundleIdentifier
            ?? "com.example.daniel.liquid-glass-screensaver"
        return ScreenSaverDefaults(forModuleWithName: moduleName)
    }

    static func storedFresnelScale() -> Float {
        guard let defaults = saverDefaults else { return 0.5 }
        defaults.register(defaults: [fresnelScaleKey: 0.5])
        return defaults.float(forKey: fresnelScaleKey)
    }

    private static func saveFresnelScale(_ value: Float) {
        guard let defaults = saverDefaults else { return }
        defaults.set(value, forKey: fresnelScaleKey)
        defaults.synchronize()
    }

    private static func systemUsesDarkMode() -> Bool {
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private var configSheet: NSWindow?
    private var fresnelSlider: NSSlider?

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        // Build a fresh sheet on every Options open.  Returning a cached
        // NSWindow from a previously-wedged host re-presents a frozen
        // sheet (same trap as the exit(0) lifecycle above).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Liquid Gas"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 170))

        let label = NSTextField(labelWithString: "Fresnel glow")
        label.frame = NSRect(x: 20, y: 128, width: 200, height: 20)
        content.addSubview(label)

        let slider = NSSlider(value: Double(Self.storedFresnelScale()),
                              minValue: 0.0, maxValue: 1.0,
                              target: nil, action: nil)
        slider.frame = NSRect(x: 20, y: 96, width: 340, height: 24)
        content.addSubview(slider)
        fresnelSlider = slider

        let offLabel = NSTextField(labelWithString: "Off")
        offLabel.font = .systemFont(ofSize: 10)
        offLabel.textColor = .secondaryLabelColor
        offLabel.frame = NSRect(x: 20, y: 78, width: 60, height: 14)
        content.addSubview(offLabel)

        let fullLabel = NSTextField(labelWithString: "Full")
        fullLabel.font = .systemFont(ofSize: 10)
        fullLabel.textColor = .secondaryLabelColor
        fullLabel.alignment = .right
        fullLabel.frame = NSRect(x: 300, y: 78, width: 60, height: 14)
        content.addSubview(fullLabel)

        let appearanceLabel = NSTextField(labelWithString: "Appearance follows the system Light/Dark Mode setting.")
        appearanceLabel.font = .systemFont(ofSize: 12)
        appearanceLabel.textColor = .secondaryLabelColor
        appearanceLabel.frame = NSRect(x: 20, y: 54, width: 340, height: 18)
        content.addSubview(appearanceLabel)

        let cancelButton = NSButton(title: "Cancel", target: self,
                                    action: #selector(cancelConfig))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 196, y: 14, width: 84, height: 32)
        content.addSubview(cancelButton)

        let doneButton = NSButton(title: "Done", target: self,
                                  action: #selector(saveConfig))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: 284, y: 14, width: 84, height: 32)
        content.addSubview(doneButton)

        window.contentView = content
        configSheet = window
        return window
    }

    @objc private func saveConfig() {
        if let slider = fresnelSlider {
            let value = Float(slider.doubleValue)
            Self.saveFresnelScale(value)
            renderer?.fresnelIntensityScale = value
        }
        dismissConfig()
    }

    @objc private func cancelConfig() {
        dismissConfig()
    }

    private func dismissConfig() {
        if let window = configSheet {
            window.sheetParent?.endSheet(window)
            configSheet = nil
        }
        fresnelSlider = nil
    }

    // MARK: - Debug breadcrumbs
    //
    // Apple's unified log hides screensaver activity, so lifecycle
    // events are appended to a plain file instead.  Read with:
    //   cat /tmp/liquid-glass-saver-lifecycle.log
    // Remove this section once the lifecycle work has settled.
    static func breadcrumb(_ event: String) {
        let line = "\(Date()) pid=\(ProcessInfo.processInfo.processIdentifier) \(event)\n"
        // The sandboxed host may deny /tmp, so also log to its own
        // temp directory (find it under ~/Library/Containers/…legacyScreenSaver…/Data/tmp).
        let paths = ["/tmp/liquid-glass-saver-lifecycle.log",
                     NSTemporaryDirectory() + "liquid-glass-saver-lifecycle.log"]
        for path in paths {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
