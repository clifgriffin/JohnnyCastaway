// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Peter Smith
//
// This file is part of the Johnny Castaway macOS screensaver, a derivative
// work of 'Johnny Reborn' (jc_reborn) by Jeremie Guillaume.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file or <https://www.gnu.org/licenses/>.

// JohnnyScreenSaverView.swift
//
// The ScreenSaverView subclass loaded by macOS's legacyScreenSaver
// host process. Each connected display gets its own instance with its
// own engine + renderer; we deliberately do NOT share state across
// instances so multi-display works without cross-screen sync.
//
// Lifecycle (Sonoma-aware):
//   • init(frame:isPreview:) — set up CAMetalLayer backing, defaults
//   • startAnimation()       — load resources, kick off engine
//   • animateOneFrame()      — pace engine ticks, render to drawable
//   • viewDidMoveToWindow(nil) — TEAR DOWN renderer & engine. macOS 14+
//     stopAnimation() is unreliable; relying on it leaks the
//     legacyScreenSaver process at high CPU after dismissal.
//
// Resource onboarding: the user picks a folder via the configure sheet
// or the first-run floating panel.  The configure sheet (System Settings)
// stores only a plain path (used for the display label).  The first-run
// panel runs inside legacyScreenSaver, so its NSOpenPanel result carries
// the right sandbox context; save(folder:) creates a security-scoped
// bookmark that persists across launches.  See ResourceFolder.swift.

import ScreenSaver
import AppKit
import Metal
import QuartzCore
import JohnnyResources
import JohnnyEngine
import JohnnyMetalRenderer

/// Fires once when the dylib is dlopened by the host. Lets us prove
/// the bundle loaded (in System Settings or legacyScreenSaver) before
/// any class methods are touched.
private let _bundleLoadMarker: Void = {
    NSLog("[Johnny] dylib loaded by %@", ProcessInfo.processInfo.processName)
}()

@objc(JohnnyScreenSaverView)
public final class JohnnyScreenSaverView: ScreenSaverView {

    // ---------------------------------------------------------------
    // MARK: Engine state (per-instance — never shared across displays)
    // ---------------------------------------------------------------

    private var renderer:    EngineRenderer?
    private var storyRunner: StoryRunner?
    private var rng          = SystemRandomNumberGenerator()
    private var soundSink: SoundSink = NullSoundSink()

    /// Background-thread watchdog that detects (and logs) a wedged main
    /// thread — the "spin / freeze".  Diagnostic only: it never exits the
    /// process or changes engine behaviour.  See MainThreadStallMonitor.swift
    /// for why a *background* thread is the only thing that can observe this
    /// failure (every other recovery path runs on the main thread that wedges).
    private let stallMonitor = MainThreadStallMonitor()

    /// Wall-clock time of the last engine tick. Used to pace ticks
    /// against the engine's `mini` value (×20 ms per tick — see
    /// jc_reborn events.c:108).
    private var lastTickWall: CFTimeInterval = 0

    /// Minimum wall-clock interval (ms) between engine ticks, derived
    /// from the previous tick's `mini` return. Floored at 4 so we
    /// never spin at display refresh rate when the engine reports 0.
    private var lastMiniMS: Int = 4

    /// Animation-speed multiplier captured at startup (settings sheet).
    /// 1.0 = faithful pacing; 2.0 doubles speed; 0.5 halves it.
    private var animationSpeed: Double = 1.0

    /// Whether THIS instance persists story progress.  On multi-display
    /// setups every display runs its own StoryRunner; if they all wrote
    /// ProgressStoryDay the persisted day would be last-writer-wins and
    /// could regress.  Only the main-display instance writes (same gate as
    /// audio); the nil-main fallback keeps single-instance/test contexts
    /// persisting.  Set during startupIfNeeded.
    private var persistsStoryProgress = false

    // ---- Debug overlay (only created when ResourceFolder.debugOverlayEnabled) ----

    /// HUD displayed in the top-left when the user enables "Show debug overlay"
    /// in the configure sheet.  Native AppKit (NSTextField) — avoids the
    /// SwiftUI / EngineDebugState plumbing that the saver doesn't otherwise need.
    private var debugOverlay: NSTextField?

    /// Frame counter and timestamp used for the overlay's FPS readout.
    private var debugFrameCount:    Int            = 0
    private var debugLastFPSTime:   CFTimeInterval = 0
    private var debugLastFPS:       Double         = 0

    /// Reason the engine isn't running, surfaced for the idle frame.
    private enum LoadState {
        case notLoaded
        case loaded
        case error(String)
    }
    private var loadState: LoadState = .notLoaded

    /// True once we have scheduled (or shown) the first-run resource
    /// picker panel. Prevents re-presenting on every startAnimation call
    /// (the preview pane can call startAnimation many times).
    private var didScheduleResourcePicker = false

    // ---- Tahoe runaway-host defenses --------------------------------
    //
    // On macOS 14+ (and especially Tahoe), legacyScreenSaver routinely
    // fails to terminate after the user dismisses the screensaver: the
    // standard ScreenSaverView lifecycle callbacks (stopAnimation,
    // viewDidMoveToWindow(nil), viewWillMove(toSuperview:nil)) often
    // never fire.  The host process keeps ticking the engine in the
    // background, AVAudioPlayer keeps queueing sounds, and CGEventTaps
    // installed by AppKit can interfere with the user's mouse.
    //
    // We defend with two complementary mechanisms:
    //
    //  1. A distributed-notification subscription on
    //     "com.apple.screensaver.didstop" — this fires on real
    //     dismissal even when the view callbacks don't.
    //
    //  2. A watchdog DispatchWorkItem armed in stopAnimation that
    //     calls exit(0) after 8s of no startAnimation, BUT only when
    //     processName == "legacyScreenSaver" AND the view was full-
    //     screen at last startAnimation.  System Settings preview
    //     pauses fire stopAnimation too, so a naive watchdog would
    //     kill the preview process.

    private static let isInLegacyScreenSaver: Bool = {
        ProcessInfo.processInfo.processName.lowercased().contains("legacyscreensaver")
    }()

    /// True if the most recent startAnimation was on a full-screen sized
    /// window.  Gates the exit watchdog so System Settings preview is never
    /// killed (preview windows are typically <800px wide).
    private var wasFullScreenAtStart: Bool = false

    /// Pending watchdog that calls exit(0) if the host doesn't terminate
    /// us within a reasonable window after dismissal.  Cancelled by the
    /// next startAnimation() call.
    private var emergencyExitWork: DispatchWorkItem? = nil

    /// Cached so we can unsubscribe in deinit (best-effort).
    private var didStopObserver: NSObjectProtocol? = nil

    /// Subscription to the IN-PROCESS settings fan-out
    /// (ResourceFolder.settingsAppliedLocally).  Persistence of bridged
    /// changes is handled once per process by ResourceFolder's own
    /// distributed-notification observer; this token only lets this view
    /// apply the already-persisted value to its running engine.
    private var settingsObserver: NSObjectProtocol? = nil

    // (Polling-based zombie detection via getppid() was removed: on Tahoe
    // legacyScreenSaver is spawned by launchd directly, so PPID is 1 from
    // birth and a parent change can never be observed.  The idle gate below
    // and the stale-instance reaper in startAnimation replace its intent.)

    // ---- Idle-based engine gate (Tahoe) ------------------------------
    //
    // Measured June 2026 (see project memory): on Tahoe the WallpaperAgent-
    // hosted legacyScreenSaver calls startAnimation on the wallpaper-window
    // view at process spawn and NEVER stops it.  A full-screen saver session
    // merely exposes that always-animating desktop-level window; dismissal
    // hides it again.  No AppKit or distributed-notification signal reaches
    // this process in either direction, and every window-visibility API lies
    // (isVisible always true, occlusionState never .visible, CGWindowList
    // redacted by the sandbox).  The ONLY trustworthy signal is kernel-level
    // HID idle time: while a saver session is genuinely displayed there is
    // no user input (input would dismiss it), so
    //   • idle time below the threshold  → user is at the machine → the
    //     session is over (or never started) → freeze engine + rendering;
    //   • idle time above the threshold  → user away → animate (if the
    //     session isn't actually displayed, macOS would have started it
    //     within the system idle timeout anyway).
    // Cost of the trade: after a hot-corner activation the saver shows a
    // frozen frame for the first few seconds until idle crosses the
    // threshold.

    /// Engine runs only when the user has been idle at least this long.
    private static let engineResumeIdleSeconds: Double = 5.0

    /// Current gate state (true = engine frozen because user is active).
    private var gateQuiesced = false

    /// Cached idle reading, refreshed at most every 0.1 s (the CG call is
    /// an IPC; no need to pay it at 100 Hz).
    private var cachedIdleSeconds: Double = .infinity
    private var lastIdlePoll: CFTimeInterval = 0

    /// Cached session-lock and Settings-frontmost state, refreshed at most
    /// every 0.5 s.
    private var cachedScreenLocked = false
    private var cachedSettingsFrontmost = false
    private var lastLockPoll: CFTimeInterval = 0

    /// True once at least one frame reached the layer; the idle gate stays
    /// open until then so a spawn during user activity still paints the
    /// wallpaper instead of leaving it black.
    private var hasRenderedOnce = false

    /// True when the engine produced a frame that hasn't been rendered yet.
    /// animateOneFrame fires at 100 Hz for pacing, but engine ticks are much
    /// rarer — rendering only when the framebuffer actually changed cuts the
    /// constant 100 fps drawable/encode churn observed in diagnostics.
    private var framePending = true

    /// Wall clock of the most recent startAnimation, used to tell the
    /// start-of-session didstop broadcast (aimed at other instances) from a
    /// genuine stop directed at us.
    private var lastStartAnimationAt: CFTimeInterval = 0

    /// Weak registry of every view instance in this process.  Sonoma+ leaks
    /// ScreenSaverView instances (38 observed in one process); whenever a new
    /// instance starts animating, it reaps engines of stale siblings whose
    /// windows are gone.
    private static let allInstances = NSHashTable<JohnnyScreenSaverView>.weakObjects()

    // ---- Diagnostic instrumentation (instance-pile-up investigation) ----
    //
    // Sonoma+ leaks ScreenSaverView instances (38 observed in one
    // legacyScreenSaver process), and at least one leaked view keeps
    // animating at full engine rate.  Each instance gets a short ID and
    // logs a one-line window-state snapshot on every lifecycle event plus
    // a rate-limited heartbeat from animateOneFrame, so `log stream` can
    // show which instance is burning CPU and what its window looks like
    // (level / visibility / occlusion) at the time.

    /// Monotonic per-process counter giving each view a stable log ID.
    private static var diagNextInstanceID: Int = 0

    private let instanceID: Int = {
        JohnnyScreenSaverView.diagNextInstanceID += 1
        return JohnnyScreenSaverView.diagNextInstanceID
    }()

    /// Wall clock of the last animateOneFrame heartbeat log.
    private var diagLastHeartbeat: CFTimeInterval = 0

    /// animateOneFrame invocations since the last heartbeat (timer rate check).
    private var diagFrameCount: Int = 0

    /// Diag lines go to a file in the sandbox container's tmp dir — NSLog
    /// from the legacyScreenSaver appex never reaches the unified log on
    /// Tahoe, so a file the saver can write without a security scope
    /// (readable from outside at ~/Library/Containers/com.apple.ScreenSaver
    /// .Engine.legacyScreenSaver/Data/tmp/) is the only reliable channel.
    private static let diagFileURL =
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("johnny-diag.log")

    private static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func diagAppend(_ line: String) {
        let msg = "\(diagTimeFormatter.string(from: Date())) \(line)\n"
        guard let data = msg.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: diagFileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: diagFileURL, options: .atomic)
        }
    }

    /// Seconds since the last HID input event of any kind in this login
    /// session.  kCGAnyInputEventType == (CGEventType)(~0); imported ObjC
    /// enums accept arbitrary raw values, so the force-unwrap is safe.
    private static var secondsSinceLastUserInput: Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~0)!)
    }

    /// True while the session is locked — i.e. the saver's clock/password
    /// unlock UI is up.  Input during that state is the user *unlocking*,
    /// not working, so the engine must keep animating (Apple's savers do).
    /// The key is ABSENT from the session dictionary when unlocked; only a
    /// truthy value means locked (checking mere presence is wrong — the
    /// sandboxed appex sees the key with a false value while unlocked).
    private static var screenIsLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let value = dict["CGSSessionScreenIsLocked"]
        else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// True while System Settings is the frontmost app — i.e. the user may
    /// be looking at the Screen Saver pane's live preview, which must keep
    /// animating despite their mouse activity.  This is the ONLY way to
    /// exempt the preview: measured June 2026, preview views are pixel-for-
    /// pixel indistinguishable from real saver views (same process, same
    /// NSServiceViewControllerWindow class, same desktop window level —
    /// which is even dynamic — same 1512×982 frame, isPreview false).
    /// NSWorkspace IS available to the sandboxed appex (verified: returns
    /// com.apple.loginwindow during lock).
    private static var settingsIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == "com.apple.systempreferences"
    }

    /// One-line state snapshot logged on lifecycle events and gate
    /// transitions.  Always sent to NSLog (effectively invisible on Tahoe —
    /// the appex's NSLog never reaches the unified log — but free); written
    /// to the diag file only while the user's debug-overlay toggle is on,
    /// so a release install doesn't grow a log file forever.
    private func diagLog(_ context: String) {
        let w = window
        let frame = w.map { NSStringFromRect($0.frame) } ?? "(no window)"
        let level = w.map { String($0.level.rawValue) } ?? "-"
        let cls   = w.map { String(describing: type(of: $0)) } ?? "-"
        let behav = w.map { String($0.collectionBehavior.rawValue) } ?? "-"
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        let line = String(
            format: "pid=%d #%d %@ anim=%d engine=%d gate=%@ locked=%d idle=%.1f preview=%d level=%@ cls=%@ behav=%@ front=%@ frame=%@",
            getpid(), instanceID, context,
            isAnimating ? 1 : 0,
            renderer != nil ? 1 : 0,
            gateQuiesced ? "Q" : "R",
            cachedScreenLocked ? 1 : 0,
            Self.secondsSinceLastUserInput,
            isPreview ? 1 : 0,
            level, cls, behav, front, frame)
        NSLog("[Johnny][diag] %@", line)
        if ResourceFolder.debugOverlayEnabled {
            Self.diagAppend(line)
        }
    }

    // ---------------------------------------------------------------
    // MARK: Init
    // ---------------------------------------------------------------

    public override init?(frame: NSRect, isPreview: Bool) {
        _ = _bundleLoadMarker
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        // ScreenSaverView's animationTimeInterval is the cadence at
        // which animateOneFrame() is called. We pace internally via
        // lastMiniMS (each engine mini-tick = 20 ms in jc_reborn), so
        // the timer must fire faster than 20 ms to allow accurate tick
        // timing. 1/100 s (10 ms) means the pacing logic can hit 20 ms
        // steps to within one timer interval, matching grFadeOut()'s
        // eventsWaitTick(1) = 20 ms per wipe step.
        animationTimeInterval = 1.0 / 100.0
        NSLog("[Johnny] init(frame:isPreview:) preview=%d process=%@",
              isPreview ? 1 : 0, ProcessInfo.processInfo.processName)
        installDismissalObservers()
        Self.allInstances.add(self)
        diagLog("init(frame:isPreview:)")
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        animationTimeInterval = 1.0 / 100.0
        NSLog("[Johnny] init(coder:)")
        installDismissalObservers()
        Self.allInstances.add(self)
    }

    // ---------------------------------------------------------------
    // MARK: CAMetalLayer backing
    // ---------------------------------------------------------------

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat        = .bgra8Unorm
        layer.framebufferOnly    = true
        layer.backgroundColor    = CGColor.black
        layer.displaySyncEnabled = true
        return layer
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = convertToBacking(bounds.size)
        }
        framePending = true
    }

    // ---------------------------------------------------------------
    // MARK: Animation lifecycle
    // ---------------------------------------------------------------

    public override func startAnimation() {
        // Cancel any pending emergency-exit watchdog from a prior
        // stopAnimation — System Settings preview pauses fire
        // start/stop pairs in rapid succession, and we don't want the
        // watchdog to kill us during one of those cycles.
        emergencyExitWork?.cancel()
        emergencyExitWork = nil

        // Capture window size to gate the exit watchdog: only kill the
        // process if we WERE running full-screen.  Preview windows are
        // small (typically < 800 px wide) and Settings keeps them
        // installed for as long as the panel is open.
        if let w = window {
            wasFullScreenAtStart = (w.frame.width >= 800 && w.frame.height >= 600)
        } else {
            wasFullScreenAtStart = false
        }
        NSLog("[Johnny] startAnimation: wasFullScreenAtStart=%d windowSize=%@",
              wasFullScreenAtStart ? 1 : 0,
              NSStringFromSize(window?.frame.size ?? .zero))

        super.startAnimation()
        lastStartAnimationAt = CACurrentMediaTime()
        diagLog("startAnimation")

        // Reap stale siblings: Sonoma+ leaks old view instances, and some
        // keep a live engine ticking after their window is gone.  Any other
        // instance without a visible window can't be a legitimate display
        // (multi-monitor instances all have visible windows), so drop its
        // engine.  teardown() is idempotent and cheap on already-clean views.
        for stale in Self.allInstances.allObjects where stale !== self {
            let windowGone = stale.window == nil || stale.window?.isVisible == false
            if windowGone, stale.renderer != nil {
                NSLog("[Johnny] reaping stale instance with live engine (window gone)")
                stale.diagLog("reaped")
                stale.teardown()
            }
        }

        startupIfNeeded()
        framePending = true
        stallMonitor.start()

        // Arm the stall monitor only for genuine full-screen activation inside
        // legacyScreenSaver.  This keeps the System Settings preview pane (and
        // its normal start/stop churn) from being misread as a wedge, and
        // resets the heartbeat so the just-started session begins clean.
        stallMonitor.setActive(Self.isInLegacyScreenSaver && wasFullScreenAtStart)

        // Re-apply the debug overlay setting on every startAnimation call.
        // startupIfNeeded() handles this for fresh starts (renderer was nil),
        // but returns early when the engine is already running.  This covers
        // the case where the user toggles the overlay in System Settings while
        // the screensaver is active and then the screensaver restarts or a
        // preview cycle fires another startAnimation.
        if case .loaded = loadState {
            if ResourceFolder.debugOverlayEnabled {
                installDebugOverlay()
            } else {
                removeDebugOverlay()
            }
        }

        // First-run / error-recovery onboarding: if the engine didn't
        // start (no folder configured, or archive failed to load), show
        // the resource-picker panel.
        //
        // We intentionally do NOT gate on !isPreview: on macOS 26 Tahoe
        // isPreview can be true even for full-screen activation (a known
        // Sequoia-era regression), so filtering on it silently suppresses
        // the dialog for everyone.  The didScheduleResourcePicker flag
        // already prevents repeated presentation on rapid start/stop cycles.
        let needsOnboarding: Bool = {
            switch loadState {
            case .notLoaded, .error: return true
            case .loaded:            return false
            }
        }()
        NSLog("[Johnny] startAnimation: isPreview=%d loadState=%@ needsOnboarding=%d",
              isPreview ? 1 : 0,
              { switch loadState { case .notLoaded: return "notLoaded"
                                   case .loaded:    return "loaded"
                                   case .error(let e): return "error(\(e))" } }(),
              needsOnboarding ? 1 : 0)

        if needsOnboarding, !didScheduleResourcePicker {
            didScheduleResourcePicker = true
            DispatchQueue.main.async { [weak self] in
                self?.presentResourcePickerIfNeeded()
            }
        }
    }

    public override func stopAnimation() {
        super.stopAnimation()
        diagLog("stopAnimation")
        // A real stopAnimation runs on the main thread, which proves it's
        // alive — so stand the stall monitor down to avoid flagging the
        // (legitimate) heartbeat gap that follows as a wedge.
        stallMonitor.setActive(false)
        // Silence audio synchronously every time stopAnimation fires.
        //
        // We intentionally do NOT tear down the engine / Metal here —
        // viewDidMoveToWindow(nil) is the reliable teardown point on
        // macOS 14+, and stopAnimation can fire repeatedly when the
        // System Settings preview pane pauses.  But AVAudioPlayer
        // keeps audio in a hardware buffer that survives object release,
        // so silencing it on every stopAnimation is the only way to
        // guarantee sound stops the instant the user dismisses the
        // screensaver — even if the view-removal callbacks lag.
        soundSink.stopAll()
        NSLog("[Johnny] stopAnimation: audio silenced")

        // Commit the latest story day to cfprefsd while the engine is still
        // alive (stopAnimation does not tear it down).  No-ops when nothing
        // changed; the engine survives, so this is cheap.
        persistStoryProgressNow()

        // Arm the runaway-host watchdog (gated by process name and
        // full-screen mode — see scheduleEmergencyExitIfNeeded).
        scheduleEmergencyExitIfNeeded()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        diagLog("viewDidMoveToWindow")
        if window == nil {
            // Sonoma+ workaround: stopAnimation() doesn't fire
            // reliably when the screensaver dismisses. Tear down
            // explicitly when the view leaves the window so the
            // legacyScreenSaver process drops to ~0% CPU.
            teardown()
        }
    }

    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        diagLog(newSuperview == nil ? "viewWillMove(toSuperview: nil)"
                                    : "viewWillMove(toSuperview: set)")
        if newSuperview == nil {
            teardown()
        }
    }

    // ---------------------------------------------------------------
    // MARK: Startup
    // ---------------------------------------------------------------

    private func startupIfNeeded() {
        guard renderer == nil else {
            NSLog("[Johnny] startupIfNeeded: already running, skipping")
            return
        }

        // Drop the in-process preferences cache before reading any settings,
        // so values written by another saver instance (or persisted by the
        // bridge just before a previous process was killed) are re-fetched
        // from cfprefsd — the daemon is the shared source of truth for every
        // process in the container.
        ResourceFolder.flushPreferences()

        NSLog("[Johnny] startupIfNeeded: starting — process=%@",
              ProcessInfo.processInfo.processName)

        // 1. Metal device + renderer
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("[Johnny] startupIfNeeded: no Metal device")
            loadState = .error("No Metal device")
            return
        }
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device       = device
            metalLayer.drawableSize = convertToBacking(bounds.size)
        }
        do {
            renderer = try EngineRenderer(device: device)
            renderer?.displayStyle        = DisplayStyle(rawValue: ResourceFolder.displayStyle) ?? .crisp
            renderer?.crtCurvatureEnabled = ResourceFolder.crtCurvatureEnabled
            NSLog("[Johnny] startupIfNeeded: renderer created (style=%ld curvature=%d)",
                  ResourceFolder.displayStyle, ResourceFolder.crtCurvatureEnabled ? 1 : 0)
        } catch {
            NSLog("[Johnny] startupIfNeeded: renderer error — %@", error.localizedDescription)
            loadState = .error("Renderer: \(error.localizedDescription)")
            return
        }

        // 2. Resolve user's resource folder from stored path
        guard let folder = ResourceFolder.resolve() else {
            NSLog("[Johnny] startupIfNeeded: no resource folder — showing idle frame")
            loadState = .notLoaded
            return
        }

        // Point the stall monitor's file sink at the (sandbox-writable)
        // resource folder so a wedge that happens hours from now leaves a
        // persistent record next to the data files, retrievable after the fact.
        stallMonitor.configure(
            logFileURL: folder.appendingPathComponent("JohnnyCastaway-stall.log"))

        // 3. Sound sink — create before the StoryRunner so the sink's
        //    AVAudioPlayers are preloaded from the same folder.
        //    On multi-monitor setups macOS starts one legacyScreenSaver per
        //    display.  Restrict audio to the main display only; all others use
        //    a silent sink so we don't get a cacophony of simultaneous audio.
        let isMainDisplay = window?.screen == NSScreen.main || NSScreen.main == nil
        // Same gate elects the single story-progress writer for this session.
        persistsStoryProgress = isMainDisplay
        if ResourceFolder.soundEnabled && isMainDisplay {
            soundSink = AVAudioPlayerSoundSink(folder: folder)
            NSLog("[Johnny] startupIfNeeded: sound ON")
        } else {
            soundSink = NullSoundSink()
            NSLog("[Johnny] startupIfNeeded: sound OFF%@",
                  ResourceFolder.soundEnabled ? " (secondary display — muted)" : "")
        }

        // 4. Parse archive + spin up StoryRunner
        do {
            let mapURL       = folder.appendingPathComponent("RESOURCE.MAP")
            let containerURL = folder.appendingPathComponent("RESOURCE.001")
            NSLog("[Johnny] startupIfNeeded: loading archive from %@", folder.path)
            let mapData       = try Data(contentsOf: mapURL)
            let containerData = try Data(contentsOf: containerURL)
            let archive = try ResourceArchive.parse(map: mapData, container: containerData)
            NSLog("[Johnny] startupIfNeeded: archive parsed OK")

            // Apply configure-sheet settings (§2.4):
            //
            // • Force Holiday: if non-zero, the StoryRunner sees a synthesised
            //   date inside the holiday window so SceneScheduler.holiday()
            //   triggers the matching decoration.
            // • Force Story Day: post-init override on StoryRunner's
            //   forceStoryDay, applied to every beginNextSequence call.
            // • Animation Speed: cached for animateOneFrame pacing.
            let holidayCode = ResourceFolder.forceHoliday
            let dateProvider: DateProvider = {
                if let forced = ResourceFolder.dateForForcedHoliday(holidayCode) {
                    NSLog("[Johnny] startupIfNeeded: forcing holiday=%d (date=%@)",
                          holidayCode, "\(forced)")
                    return FixedDateProvider(forced)
                }
                return SystemDateProvider()
            }()

            // Restore persisted story progression from a prior activation.
            // Without this, every screensaver launch creates a fresh
            // StoryRunner stuck at day 1 — Sierra's 11-day arc (raft
            // growing, Johnny leaving the island) would be unreachable.
            let persistedDay    = ResourceFolder.persistedStoryDay
            let persistedCalDay = ResourceFolder.persistedLastCalendarDay
            let runner = try StoryRunner(
                archive:                archive,
                dateProvider:           dateProvider,
                sound:                  soundSink,
                initialStoryDay:        persistedDay,
                initialLastCalendarDay: persistedCalDay
            )
            let forcedDay = ResourceFolder.forceStoryDay
            runner.forceStoryDay = (forcedDay > 0) ? forcedDay : nil
            self.animationSpeed  = ResourceFolder.animationSpeed
            NSLog("[Johnny] startupIfNeeded: settings — forceDay=%d speed=%.2f overlay=%d storyDay=%d (persisted, lastCalDay=%d)",
                  forcedDay,
                  self.animationSpeed,
                  ResourceFolder.debugOverlayEnabled ? 1 : 0,
                  persistedDay,
                  persistedCalDay)

            NSLog("[Johnny] startupIfNeeded: StoryRunner created — engine is live")
            self.storyRunner  = runner
            self.loadState    = .loaded
            self.lastTickWall = CACurrentMediaTime()

            // Install the debug HUD if enabled.
            if ResourceFolder.debugOverlayEnabled {
                installDebugOverlay()
            } else {
                removeDebugOverlay()
            }
        } catch {
            NSLog("[Johnny] startupIfNeeded: archive/engine error — %@", error.localizedDescription)
            loadState = .error("Resources: \(error.localizedDescription)")
        }
    }

    // ---------------------------------------------------------------
    // MARK: First-run resource picker (Option B fallback)
    // ---------------------------------------------------------------
    //
    // Called asynchronously from startAnimation when the engine couldn't
    // start because no resource folder has been configured. This is the
    // fallback path for macOS 26 Tahoe where System Settings no longer
    // contacts the .saver bundle for its configure sheet.
    //
    // We present a floating NSPanel at window level .floating (above the
    // screensaver view), then attach the NSOpenPanel as a *sheet* on that
    // panel so it inherits the correct z-order and doesn't slip behind
    // other windows.

    @MainActor
    private func presentResourcePickerIfNeeded() {
        // Skip the panel only if the engine actually loaded.  We deliberately
        // do NOT call ResourceFolder.resolve() here — on macOS 26 Tahoe the
        // legacyScreenSaver sandbox allows stat() but blocks open() on
        // ~/Documents, so fileExists() returns true and resolve() returns a
        // non-nil URL even when Data(contentsOf:) will fail.  Using loadState
        // avoids that false-positive and ensures the panel is always shown
        // when the engine hasn't come up.
        if case .loaded = loadState {
            NSLog("[Johnny] presentResourcePickerIfNeeded: engine loaded — skipping panel")
            return
        }

        NSLog("[Johnny] presentResourcePickerIfNeeded: showing setup panel (loadState=%@)",
              { switch loadState { case .notLoaded:     return "notLoaded"
                                   case .loaded:        return "loaded"
                                   case .error(let e): return "error(\(e))" } }())

        // ---- Informational panel ----------------------------------------

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Johnny Castaway — Setup"
        panel.isReleasedWhenClosed = false
        // Must be above the screensaver window (NSWindow.Level.screenSaver = 1000).
        // .floating (level 3) is hidden behind it during full-screen activation.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.center()

        let content = panel.contentView!

        let heading = NSTextField(labelWithString: "Sierra Resource Files Required")
        heading.font = .boldSystemFont(ofSize: 14)
        heading.frame = NSRect(x: 20, y: 156, width: 440, height: 20)
        content.addSubview(heading)

        let body = NSTextField(wrappingLabelWithString:
            "Johnny Castaway requires the original Sierra resource files to run. "
          + "Click \u{201C}Choose Folder\u{2026}\u{201D} and select the folder that "
          + "contains RESOURCE.MAP and RESOURCE.001.\n\n"
          + "If you\u{2019}ve already set this in Screen Saver Options, "
          + "select the same folder again \u{2014} macOS requires it to grant access."
        )
        body.frame = NSRect(x: 20, y: 76, width: 440, height: 72)
        content.addSubview(body)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.frame = NSRect(x: 20, y: 56, width: 440, height: 16)
        content.addSubview(statusLabel)

        // Keep a strong reference for the lifetime of the handler closures.
        let panelRef = panel

        let chooseButton = NSButton(
            title: "Choose Folder…",
            target: nil,
            action: nil
        )
        chooseButton.bezelStyle = .rounded
        chooseButton.frame = NSRect(x: 20, y: 16, width: 140, height: 32)
        content.addSubview(chooseButton)

        let cancelButton = NSButton(
            title: "Cancel",
            target: nil,
            action: nil
        )
        cancelButton.bezelStyle  = .rounded
        cancelButton.frame = NSRect(x: 360, y: 16, width: 100, height: 32)
        content.addSubview(cancelButton)

        // ---- Button handlers -------------------------------------------
        // Capture self weakly to avoid a retain cycle.

        let chooseClosure: @Sendable @MainActor () -> Void = { [weak self] in
            let openPanel = NSOpenPanel()
            openPanel.message                 = "Select the folder containing RESOURCE.MAP and RESOURCE.001"
            openPanel.prompt                  = "Choose"
            openPanel.canChooseFiles          = false
            openPanel.canChooseDirectories    = true
            openPanel.allowsMultipleSelection = false

            // Pre-navigate to the stored path's parent directory so the
            // user can find their folder immediately without navigating.
            // (Opening *inside* the target folder would require the user
            // to go up one level to select it, so we use the parent.)
            if let storedPath = ResourceFolder.displayPath {
                openPanel.directoryURL = URL(fileURLWithPath: storedPath)
                    .deletingLastPathComponent()
            }

            // Present as a sheet attached to our floating panel so it
            // inherits the .floating window level and can't slip behind
            // other windows.
            openPanel.beginSheetModal(for: panelRef) { [weak self] response in
                guard response == .OK, let url = openPanel.url else { return }
                NSLog("[Johnny] openPanel chose: %@", url.path)
                do {
                    try ResourceFolder.save(folder: url)
                    panelRef.close()
                    self?.resetAndStartup()
                } catch {
                    NSLog("[Johnny] openPanel save error: %@", error.localizedDescription)
                    statusLabel.stringValue = error.localizedDescription
                }
            }
        }

        let cancelClosure: @Sendable @MainActor () -> Void = {
            NSLog("[Johnny] setup panel cancelled")
            panelRef.close()
        }

        // Wrap closures in shim targets so AppKit can call them.
        let chooseTarget = ClosureTarget(closure: chooseClosure)
        let cancelTarget = ClosureTarget(closure: cancelClosure)

        chooseButton.target = chooseTarget
        chooseButton.action = #selector(ClosureTarget.invoke)
        cancelButton.target = cancelTarget
        cancelButton.action = #selector(ClosureTarget.invoke)

        // Retain the targets for the panel's lifetime via associated objects.
        objc_setAssociatedObject(panel, &assocKeyChooseTarget, chooseTarget, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, &assocKeyCancelTarget, cancelTarget, .OBJC_ASSOCIATION_RETAIN)

        panel.makeKeyAndOrderFront(nil)
    }

    // ---------------------------------------------------------------
    // MARK: Reset + restart helper
    // ---------------------------------------------------------------

    /// Reset engine state so `startupIfNeeded()` will re-run.
    /// Used after the user configures the resource folder at runtime.
    private func resetAndStartup() {
        NSLog("[Johnny] resetAndStartup")
        renderer    = nil
        storyRunner = nil
        startupIfNeeded()
    }

    // ---------------------------------------------------------------
    // MARK: Story-progress persistence at teardown
    // ---------------------------------------------------------------

    /// Hand the engine's current story progress to cfprefsd at a lifecycle
    /// hook.  During a run we only save when the day actually changes; this
    /// makes sure the latest state is committed when the saver is dismissed
    /// or torn down.  Best-effort and idempotent — `saveStoryProgress`
    /// no-ops when nothing changed.  Gated identically to the in-run save:
    /// never persist a forced (diagnostic) day, and only from the elected
    /// main-display writer so secondary displays can't race the day back.
    ///
    /// Note: on Tahoe the wallpaper instance often receives neither
    /// stopAnimation nor viewDidMoveToWindow(nil), so this is a belt-and-
    /// suspenders commit — the reliable persistence path is the per-day
    /// save during the run.  It still helps on real dismissals and on
    /// macOS versions that do deliver these callbacks.
    private func persistStoryProgressNow() {
        guard let runner = storyRunner,
              runner.forceStoryDay == nil,
              persistsStoryProgress else { return }
        ResourceFolder.saveStoryProgress(day: runner.storyDay,
                                         lastCalendarDay: runner.lastCalendarDay)
    }

    // ---------------------------------------------------------------
    // MARK: Teardown (Sonoma-reliable)
    // ---------------------------------------------------------------

    private func teardown() {
        diagLog("teardown")
        // Commit the latest story day before we drop the engine.
        persistStoryProgressNow()
        // Stop the 100 Hz animation timer for good.  macOS rarely sends
        // stopAnimation itself, so without this every torn-down leaked view
        // keeps firing animateOneFrame forever (measured: 6 dead views ≈ 3%
        // CPU just in empty timer fires).  Call super directly — our own
        // stopAnimation override would arm the exit watchdog.  macOS sends
        // startAnimation on the next activation (observed June 2026), which
        // re-arms the timer and rebuilds the engine via startupIfNeeded.
        super.stopAnimation()
        // Teardown runs on the main thread (proving it's alive); stop the
        // monitor thread entirely — leaked instances must not each keep a
        // poller thread alive (37 observed before this fix).  startAnimation
        // restarts it if this view is ever revived.
        stallMonitor.stop()
        NSLog("[Johnny] teardown — loadState was %@",
              { switch loadState { case .notLoaded: return "notLoaded"
                                   case .loaded:    return "loaded"
                                   case .error(let e): return "error(\(e))" } }())
        // Detach Metal *before* releasing the renderer so the GPU
        // command queue drains.  Without this, CAMetalLayer keeps
        // submitting frames in the background even after our
        // EngineRenderer is gone.
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.device = nil
        }
        renderer    = nil
        storyRunner = nil
        soundSink.stopAll()             // halt in-flight audio before releasing
        soundSink   = NullSoundSink()   // drop AVAudioPlayer instances
        ResourceFolder.stopAccessing()  // release security-scoped sandbox token
        removeDebugOverlay()
        // If we never successfully loaded, allow the picker to reappear
        // next time startAnimation fires (e.g. user dismisses screensaver
        // then re-triggers the hot corner without ever having configured).
        if case .loaded = loadState { } else {
            didScheduleResourcePicker = false
        }
    }

    // ---------------------------------------------------------------
    // MARK: Per-frame
    // ---------------------------------------------------------------

    public override func animateOneFrame() {
        // Diag heartbeat (low rate; file write only when the debug-overlay
        // toggle is on): confirms timer rate (fires ≈ 60×4 quiesced,
        // 60×100 running) and gate state during soak testing.
        let nowDiag = CACurrentMediaTime()
        diagFrameCount += 1
        if nowDiag - diagLastHeartbeat >= 60.0 {
            diagLastHeartbeat = nowDiag
            diagLog("tick.heartbeat fires=\(diagFrameCount)")
            diagFrameCount = 0
        }

        // Idle-based engine gate (see the property block at the top of the
        // class for the full rationale).  Applies ONLY to the desktop-level
        // wallpaper/saver window (level -2147483625 measured on Tahoe; all
        // preview windows — System Settings pane included — have normal
        // non-negative levels and must keep animating while the user mouses
        // around).  Size is NOT a usable discriminator: the Settings pane's
        // large preview exceeds 800×600 and was wrongly gated.
        // (hasRenderedOnce: never gate before the first frame is on the
        // layer, or a spawn while the user is active leaves the wallpaper
        // black until the first resume.)
        if Self.isInLegacyScreenSaver, hasRenderedOnce,
           let w = window, w.level.rawValue < 0 {
            if nowDiag - lastIdlePoll >= 0.1 {
                cachedIdleSeconds = Self.secondsSinceLastUserInput
                lastIdlePoll = nowDiag
            }
            // While the session is locked, the saver IS the active UI (the
            // user is looking at the clock / typing their password) — input
            // there must not freeze the animation.  Likewise while System
            // Settings is frontmost: the user may be watching the Screen
            // Saver pane's preview.  Poll both at 0.5 s; these calls are
            // heavier than the idle query.
            if nowDiag - lastLockPoll >= 0.5 {
                cachedScreenLocked      = Self.screenIsLocked
                cachedSettingsFrontmost = Self.settingsIsFrontmost
                lastLockPoll = nowDiag
            }
            if cachedIdleSeconds < Self.engineResumeIdleSeconds,
               !cachedScreenLocked, !cachedSettingsFrontmost {
                if !gateQuiesced {
                    gateQuiesced = true
                    // Halt the in-flight sample but keep the players loaded —
                    // the next session resumes on the same engine and sink.
                    (soundSink as? AVAudioPlayerSoundSink)?.stopCurrent()
                    // Even an empty animateOneFrame costs real CPU at 100 Hz
                    // (each fire runs inside NSAnimationContext machinery) —
                    // drop to 4 Hz while frozen.  Resume latency is bounded
                    // by one quiesced frame (≤ 0.25 s).
                    animationTimeInterval = 0.25
                    diagLog("gate.quiesce")
                }
                // Frozen frame stays on the layer; no tick, no render.
                return
            }
            if gateQuiesced {
                gateQuiesced = false
                animationTimeInterval = 1.0 / 100.0
                framePending = true     // push a frame immediately on resume
                diagLog("gate.resume")
            }
        }

        guard let metalLayer = layer as? CAMetalLayer,
              let renderer   = renderer else { return }

        // Pace engine ticks against the previous tick's `mini`, scaled by
        // the user's animation-speed multiplier.  Higher multiplier =>
        // shorter wall-clock interval between ticks => faster animation.
        if let runner = storyRunner {
            let now       = CACurrentMediaTime()
            let elapsedMS = (now - lastTickWall) * 1000.0
            if elapsedMS >= Double(lastMiniMS) {
                do {
                    if runner.sequenceFinished {
                        stallMonitor.beat("engine.beginNextSequence day=\(runner.storyDay)")
                        try runner.beginNextSequence(rng: &rng)
                        // Persist story progression — but only when the
                        // user hasn't pinned the day via the configure
                        // sheet's force-day override.  Persisting while
                        // forced would let a temporary diagnostic override
                        // (e.g. "preview day 8") leak into the permanent
                        // natural-progression state.  Also only from the
                        // elected writer instance (main display) so
                        // secondary displays' runners don't race the
                        // persisted day backwards.
                        if runner.forceStoryDay == nil, persistsStoryProgress {
                            ResourceFolder.saveStoryProgress(
                                day:             runner.storyDay,
                                lastCalendarDay: runner.lastCalendarDay
                            )
                        }
                    }
                    let summary = runner.diagnosticSummary
                    stallMonitor.beat("engine.tick/update \(summary)", snapshot: summary)
                    let mini = try runner.tick(rng: &rng)
                    let scaledMS = Double(mini * 20) / max(0.1, animationSpeed)
                    lastMiniMS   = max(4, Int(scaledMS.rounded()))
                } catch {
                    NSLog("[Johnny] animateOneFrame tick error: %@", error.localizedDescription)
                    loadState = .error("Tick: \(error.localizedDescription)")
                    // Back off ~2 s before retrying so a persistent resource
                    // error doesn't spin the engine at 100 ticks/s.
                    lastMiniMS = 100
                }
                // Always advance the wall clock and push a frame, even on
                // error. Without this, lastTickWall stays frozen, every timer
                // fire re-enters the tick path, and renderer.update is never
                // called — leaving the display permanently black.
                lastTickWall = now
                renderer.update(framebuffer: runner.composedFramebuffer,
                                palette:    runner.palette)
                framePending = true
            }
        }
        // (If no story runner, the initial framePending=true pushed one
        // frame at startup and the layer holds it; nothing to animate.)

        // Render only when the engine actually produced a new frame (or a
        // resize/resume forced one).  animateOneFrame fires at 100 Hz for
        // tick pacing, but encoding + presenting 100 identical frames per
        // second was measured to be the bulk of the saver's steady-state
        // CPU cost.  CAMetalLayer keeps presenting the last frame.
        guard framePending else { return }

        stallMonitor.beat("nextDrawable")
        guard let drawable = metalLayer.nextDrawable() else { return }
        stallMonitor.beat("render")
        renderer.render(to: drawable, drawableSize: metalLayer.drawableSize)
        framePending = false
        hasRenderedOnce = true

        // Update the debug HUD (cheap; only allocates a string once per frame).
        if debugOverlay != nil { updateDebugOverlay() }
    }

    // ---------------------------------------------------------------
    // MARK: Tahoe runaway-host defenses
    // ---------------------------------------------------------------

    /// Subscribe to the distributed notification the system posts when a
    /// screensaver session ends.  Reliable on Tahoe even when the
    /// ScreenSaverView callbacks (stopAnimation / viewDidMoveToWindow)
    /// don't fire.  Idempotent — only attaches once per instance.
    ///
    /// Also subscribes to the configure-sheet settings bridge notification
    /// so that changes made in System Settings are applied live to a running
    /// screensaver instance without needing a restart.
    private func installDismissalObservers() {
        guard didStopObserver == nil else { return }
        didStopObserver = DistributedNotificationCenter.default().addObserver(
            forName:   NSNotification.Name("com.apple.screensaver.didstop"),
            object:    nil,
            queue:     .main
        ) { [weak self] _ in
            guard let self else { return }
            // com.apple.screensaver.didstop is a system-wide distributed
            // notification.  (Measured June 2026: on Tahoe it never fires at
            // all — the wallpaper-window architecture sends this process
            // nothing — so this handler matters only on macOS versions that
            // still post it.)  When a screensaver session starts, macOS
            // posts it to tell the WallpaperAgent's background screensaver
            // to stop — a freshly-started full-screen instance receives it
            // too and must not act on it.  Guarding on isAnimating was a
            // dead spot: a LEAKED view never gets stopAnimation, stays
            // isAnimating forever, and so ignored the very notification
            // that should stop it.  Discriminate by time instead: only a
            // view whose startAnimation was moments ago is the new session
            // the broadcast isn't aimed at.
            let sinceStart = CACurrentMediaTime() - self.lastStartAnimationAt
            guard !(self.isAnimating && sinceStart < 2.0) else {
                self.diagLog("didstop.ignored(justStarted)")
                NSLog("[Johnny] didstop received but ignored — startAnimation %.2fs ago (not our stop)", sinceStart)
                return
            }
            self.diagLog("didstop.teardown")
            NSLog("[Johnny] didstop received — tearing down")
            self.teardown()
            // No scheduleEmergencyExitIfNeeded() here: on wallpaper-duty
            // views an exit(0) would just churn WallpaperAgent respawns
            // (observed May 2026).  The watchdog stays tied to stopAnimation.
        }

        // Settings bridge: persistence of incoming changes is handled by ONE
        // process-wide observer (ResourceFolder.installSettingsBridge) —
        // Sonoma+ never destroys piled-up view instances, so persisting here
        // per-instance would rewrite the preferences domain N times per
        // change.  Each view only listens for the in-process fan-out to
        // apply the already-persisted value to its own running engine.
        ResourceFolder.installSettingsBridge()
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: ResourceFolder.settingsAppliedLocally,
            object:  nil,
            queue:   .main
        ) { [weak self] notification in
            guard let key = notification.object as? String else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyLiveSettingChange(key: key)
            }
        }
    }

    /// Arm a one-shot watchdog: if we're still alive in 8 s and no
    /// startAnimation has cancelled it, the host has leaked us — call
    /// exit(0) so audio/CPU stop and the user's mouse works again.
    ///
    /// Strict gating prevents accidental termination of the System
    /// Settings preview process:
    ///   • processName must contain "legacyScreenSaver"
    ///   • the most recent startAnimation must have been on a window
    ///     ≥ 800×600 (full-screen, not preview)
    private func scheduleEmergencyExitIfNeeded() {
        guard Self.isInLegacyScreenSaver else { return }
        guard wasFullScreenAtStart else {
            NSLog("[Johnny] watchdog: skipped (not full-screen)")
            return
        }
        emergencyExitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSLog("[Johnny] watchdog: forcing exit(0) — host failed to terminate")
            // Best-effort final teardown so any in-flight audio is killed
            // before exit() pulls the rug.
            self?.teardown()
            // CFRunLoopStop won't help — the runloop will just be re-entered.
            // exit(0) is the only reliable termination from inside a leaked
            // legacyScreenSaver host.
            exit(0)
        }
        emergencyExitWork = work
        // 8 s window leaves room for a legitimate stop/start preview-pane
        // cycle (the cycle is normally < 1 s).  If a real dismissal
        // happened, no startAnimation will follow and the work item fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
        NSLog("[Johnny] watchdog: armed (8s) — will exit if no startAnimation")
    }

    // No deinit — JohnnyScreenSaverView is rarely deallocated on Tahoe
    // (legacyScreenSaver leaks the view), and the distributed-notification
    // observer captures `self` weakly so a stale self is harmless.  The
    // host process eventually dying (either naturally or via our exit
    // watchdog) reclaims everything.

    // ---------------------------------------------------------------
    // MARK: Live settings application
    // ---------------------------------------------------------------
    //
    // When the configure-sheet settings bridge delivers a change via
    // distributed notification, applyLiveSettingChange() applies it to
    // the running engine/view immediately so no screensaver restart is
    // needed.  Settings that require a full engine restart (e.g. sound,
    // holiday/date-provider) are silently skipped — they take effect on
    // the next activation.

    /// Apply a setting change to the running engine/view without a restart.
    /// `key` is the raw ScreenSaverDefaults key string from ResourceFolder;
    /// the current value is read from ResourceFolder (already persisted by
    /// the process-wide bridge before the fan-out fires).
    private func applyLiveSettingChange(key: String) {
        NSLog("[Johnny] applyLiveSettingChange: key=%@", key)
        // Keys are the raw ScreenSaverDefaults key strings from ResourceFolder.
        if key == "ShowDebugOverlay" {
            if ResourceFolder.debugOverlayEnabled {
                installDebugOverlay()
            } else {
                removeDebugOverlay()
            }
        } else if key == "AnimationSpeed" {
            animationSpeed = ResourceFolder.animationSpeed
            NSLog("[Johnny] applyLiveSettingChange: animationSpeed=%.2f", animationSpeed)
        } else if key == "ForceStoryDay" {
            let day = ResourceFolder.forceStoryDay
            storyRunner?.forceStoryDay = day > 0 ? day : nil
        } else if key == "DisplayStyle" {
            renderer?.displayStyle = DisplayStyle(rawValue: ResourceFolder.displayStyle) ?? .crisp
            NSLog("[Johnny] applyLiveSettingChange: displayStyle=%ld", ResourceFolder.displayStyle)
        } else if key == "CRTCurvature" {
            renderer?.crtCurvatureEnabled = ResourceFolder.crtCurvatureEnabled
            NSLog("[Johnny] applyLiveSettingChange: crtCurvature=%d", ResourceFolder.crtCurvatureEnabled ? 1 : 0)
        }
        // SoundEnabled, ForceHoliday: require engine restart; no live apply.
        // ProgressStoryDay / ProgressLastCalendarDay (Restart Story): the
        // process-wide bridge persists them; the reset is read on the next
        // activation, so there is no live-apply case here.
    }

    // ---------------------------------------------------------------
    // MARK: Debug overlay (HUD)
    // ---------------------------------------------------------------
    //
    // Native AppKit text label pinned to the top-left.  Shown only when
    // ResourceFolder.debugOverlayEnabled is true.  This is intentionally
    // simpler than the SwiftUI DebugOverlayView from JohnnyDebug — the
    // saver doesn't host an `Engine` (only `StoryRunner`), so the full
    // EngineDebugState wiring would add code without unique value here.

    private func installDebugOverlay() {
        guard debugOverlay == nil else { return }
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        label.drawsBackground = true
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 0   // multi-line
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
        debugOverlay      = label
        debugFrameCount   = 0
        debugLastFPSTime  = CACurrentMediaTime()
        debugLastFPS      = 0
        NSLog("[Johnny] debug overlay installed")
    }

    private func removeDebugOverlay() {
        debugOverlay?.removeFromSuperview()
        debugOverlay = nil
    }

    /// Refresh the HUD text using the StoryRunner diagnostics.
    /// Called once per `animateOneFrame` when the overlay is installed.
    private func updateDebugOverlay() {
        guard let label = debugOverlay else { return }
        debugFrameCount += 1
        let now = CACurrentMediaTime()
        let dt  = now - debugLastFPSTime
        if dt >= 0.5 {
            debugLastFPS     = Double(debugFrameCount) / dt
            debugFrameCount  = 0
            debugLastFPSTime = now
        }

        let runner    = storyRunner
        let lastSamp  = (soundSink as? AVAudioPlayerSoundSink)?.lastSampleID
        let day       = runner?.storyDay ?? 0
        let active    = runner?.activeThreadCount ?? 0
        let allocated = runner?.allocatedThreadCount ?? 0
        let opcodes   = runner?.coveredTTMOpcodes.count ?? 0
        let holiday   = ResourceFolder.forceHoliday
        let holidayLabel: String = {
            switch holiday {
            case 1: return "Halloween"
            case 2: return "St Patrick"
            case 3: return "Christmas"
            case 4: return "New Year"
            default: return "auto"
            }
        }()

        let text = """
        Johnny Castaway — debug
        day:       \(day)\(runner?.forceStoryDay != nil ? " (forced)" : "")
        threads:   \(active)/\(allocated) active
        opcodes:   \(opcodes) covered
        holiday:   \(holidayLabel)
        speed:     \(String(format: "%.1f×", animationSpeed))
        last snd:  \(lastSamp.map(String.init) ?? "—")
        fps:       \(String(format: "%.1f", debugLastFPS))
        """
        label.stringValue = text
    }

    // ---------------------------------------------------------------
    // MARK: Configuration sheet
    // ---------------------------------------------------------------

    @objc public override var hasConfigureSheet: Bool {
        NSLog("[Johnny] hasConfigureSheet -> true")
        return true
    }

    @objc public override var configureSheet: NSWindow? {
        NSLog("[Johnny] configureSheet getter called")
        let sheet = ConfigureSheetController.shared
        // Access window first — this triggers the lazy makeWindow() which
        // sets up all the controls.  Only then call refresh() to flush
        // cfprefsd and re-read all control states from persisted defaults.
        let win = sheet.window
        sheet.refresh()
        NSLog("[Johnny] configureSheet returning window=%@ visible=%d",
              String(describing: win), win.isVisible ? 1 : 0)
        return win
    }
}

// ---------------------------------------------------------------------------
// MARK: - ClosureTarget
//
// A minimal Objective-C-compatible shim that lets us use a Swift closure as
// the `target` of an NSButton.  AppKit's target/action mechanism requires
// the target to respond to the selector via the ObjC runtime, which plain
// Swift closures don't support.
// ---------------------------------------------------------------------------

@MainActor
private final class ClosureTarget: NSObject {
    private let closure: @MainActor () -> Void
    init(closure: @escaping @MainActor () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

// ---------------------------------------------------------------------------
// MARK: - Associated-object keys
//
// objc_setAssociatedObject requires a stable UnsafeRawPointer key.
// The canonical Swift pattern is a file-scope `nonisolated(unsafe) var`
// whose address is stable for the process lifetime.  Swift 6 strict
// concurrency requires the `nonisolated(unsafe)` annotation.
// ---------------------------------------------------------------------------

private nonisolated(unsafe) var assocKeyChooseTarget: UInt8 = 0
private nonisolated(unsafe) var assocKeyCancelTarget: UInt8 = 0
