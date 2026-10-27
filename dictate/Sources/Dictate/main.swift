import AVFoundation
import AppKit
import DictateCore
import DictateInference
import Foundation

private let recentLimit = 5

if CommandLine.arguments.dropFirst().first == "--check-config" {
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write(Data("Usage: Dictate --check-config CONFIG\n".utf8))
        Foundation.exit(2)
    }
    do {
        _ = try ConfigFile.parse(String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8))
        FileHandle.standardOutput.write(Data("Config is valid\n".utf8))
        Foundation.exit(0)
    } catch {
        FileHandle.standardError.write(Data("Config problem: \(error)\n".utf8))
        Foundation.exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusMenuItem = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    private let statusRow = StatusRowView()
    private let recorder = Recorder()
    private let overlay = Overlay()
    /// Created at launch, which also repairs a volume left down by a crash.
    private let ducker = VolumeDucker()
    private var config: AppConfig?
    private var engine: InferenceEngine?
    private var inferenceTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var retryTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tracker = HoldTracker()
    private var busy = false
    private var micGranted = false
    private var recent: [String] = []
    /// Bumped by each hold and each cancel; a reply from an older session is dropped.
    private var session = 0
    private var holdPoll: Timer?
    /// Toggled by the lock key during a recording. While locked, the hold key is ignored.
    private var locked = false
    private var health: InferenceStatus?
    /// True while the card shows the idle state, so a health change may redraw it.
    private var showingIdle = false
    private var healthTimer: Timer?
    /// Single pass pastes Whisper's text as heard. Two passes also run it through the cleanup model.
    /// Chosen from the menu and kept across launches.
    private var twoPass = UserDefaults.standard.object(forKey: "twoPass") as? Bool ?? false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenuItem.isEnabled = false
        statusMenuItem.view = statusRow
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        setSymbol("mic")
        recorder.onLevel = { [weak self] level in self?.overlay.level(level) }
        overlay.onClose = { [weak self] in self?.cancel() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.prepareModels()
        }
        loadConfig()
        PasteboardPutter.promptForAccessibility()
        requestMicrophone()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        menu.addItem(statusMenuItem)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem()
            header.attributedTitle = NSAttributedString(
                string: "Recent · click to copy",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            header.isEnabled = false
            menu.addItem(header)
            for text in recent {
                let item = NSMenuItem(title: "", action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                item.view = RecentTranscriptView(text: text)
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let passes = NSMenuItem(title: "Two-pass cleanup", action: #selector(togglePasses), keyEquivalent: "")
        passes.target = self
        passes.state = twoPass ? .on : .off
        menu.addItem(passes)
        let quit = NSMenuItem(title: "Quit Dictate", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recent.removeAll { $0 == trimmed }
        recent.insert(trimmed, at: 0)
        if recent.count > recentLimit {
            recent.removeLast(recent.count - recentLimit)
        }
        rebuildMenu()
    }

    @objc private func togglePasses() {
        twoPass.toggle()
        UserDefaults.standard.set(twoPass, forKey: "twoPass")
        rebuildMenu()
        if showingIdle { ready() }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        note("Copied", detail: "The transcript is on the clipboard", style: .done)
    }

    private func loadConfig() {
        let path =
            ProcessInfo.processInfo.environment["DICTATE_CONFIG"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/dictate/config.toml")
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let parsed = try ConfigFile.parse(text)
            config = parsed
            engine = InferenceEngine(config: parsed, configURL: URL(fileURLWithPath: path))
            ready()
            prepareModels()
            checkHealth()
        } catch {
            note("Config problem", detail: "\(error)", style: .problem)
        }
    }

    private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
            armHotkey()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.micGranted = granted
                    if granted {
                        self?.armHotkey()
                    } else {
                        self?.noteMicrophoneDenied()
                    }
                }
            }
        default:
            noteMicrophoneDenied()
        }
    }

    private func armHotkey() {
        guard config != nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.onFlags(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.onFlags(event)
            return event
        }
        if globalMonitor == nil {
            note(
                "Input Monitoring needed",
                detail: "Allow Dictate in System Settings > Privacy & Security, then relaunch", style: .problem)
        }
    }

    private func onFlags(_ event: NSEvent) {
        guard let spec = config?.hotkey else { return }
        let flags = UInt(event.modifierFlags.rawValue)
        if let lock = config?.lockKey, event.keyCode == lock.keyCode, flags & lock.modifierBit != 0,
            recorder.isRecording
        {
            locked ? unlockRecording() : lockRecording()
            return
        }
        // The tracker follows the hold key even while locked, so an unlock knows whether it is down.
        let edge = tracker.handle(keyCode: event.keyCode, flags: flags, spec: spec)
        if locked { return }
        switch edge {
        case .pressed:
            if !busy { begin() }
        case .released:
            if recorder.isRecording { finish() }
        case nil:
            break
        }
    }

    private func begin() {
        guard micGranted else {
            noteMicrophoneDenied()
            overlay.failed("Microphone access needed")
            return
        }
        guard health?.speech.state == .ready else {
            ready()
            overlay.notice("Speech model is not ready")
            return
        }
        do {
            // Start fading the output before opening the microphone.
            ducker.duck()
            try recorder.start()
            session += 1
            setSymbol("mic.fill")
            note("Listening", detail: "Let go of \(keyName) to finish", style: .listening)
            overlay.listening()
            watchHold()
        } catch {
            ducker.restore()
            fail(error.localizedDescription)
        }
    }

    private func lockRecording() {
        locked = true
        holdPoll?.invalidate()
        holdPoll = nil
        note("Listening, locked", detail: "Press \(lockName) to unlock", style: .listening)
        overlay.locked()
    }

    /// Back to a normal hold if the hold key is down, otherwise the recording is done.
    private func unlockRecording() {
        locked = false
        guard let spec = config?.hotkey else { return }
        let live = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        if tracker.holding && live & spec.anySideBit != 0 {
            note("Listening", detail: "Let go of \(keyName) to finish", style: .listening)
            overlay.listening()
            watchHold()
        } else {
            tracker.reset()
            finish()
        }
    }

    /// A missed release event would otherwise leave the microphone on. Twice a
    /// second, check that the key is still down.
    private func watchHold() {
        holdPoll?.invalidate()
        holdPoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let spec = self.config?.hotkey else { return }
            let flags = UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
            if self.tracker.check(flags: flags, spec: spec) == .released, self.recorder.isRecording {
                self.finish()
            }
        }
    }

    /// The overlay's close button: stop recording or ignore the pending reply, and paste nothing.
    private func cancel() {
        guard recorder.isRecording || inferenceTask != nil else {
            overlay.dismiss()
            return
        }
        ducker.restore()
        session += 1
        inferenceTask?.cancel()
        inferenceTask = nil
        locked = false
        holdPoll?.invalidate()
        holdPoll = nil
        tracker.reset()
        if recorder.isRecording {
            _ = try? recorder.stop()
        }
        busy = false
        setSymbol("mic")
        note("Cancelled", detail: "Nothing was pasted", style: .info)
        overlay.dismiss()
    }

    private func finish() {
        ducker.restore()
        locked = false
        holdPoll?.invalidate()
        holdPoll = nil
        let recording: Recording
        do {
            recording = try recorder.stop()
        } catch RecorderError.empty {
            // A tap so quick the microphone delivered nothing.
            dropTap()
            return
        } catch {
            setSymbol("mic")
            fail(error.localizedDescription)
            return
        }
        let wav = recording.wav
        // Ignore a tap of the key. 0.15 s of 16 kHz mono PCM16 plus the 44-byte header.
        if wav.count < 44 + 16000 * 2 * 15 / 100 {
            dropTap()
            return
        }
        // Letting go without talking is how a hold gets abandoned, so it is not an error.
        if !recording.hasSpeech {
            setSymbol("mic")
            note("Nothing heard", detail: "Nothing was pasted", style: .info)
            overlay.notice("Nothing heard")
            return
        }
        transcribe(wav: wav, cleanup: twoPass)
    }

    /// UI and debug writes stay on the main actor; the engine owns all model work.
    private func transcribe(wav: Data, cleanup: Bool) {
        guard let engine else { return }
        var trail: DebugTrail?
        if config?.debugEnabled == true {
            do {
                let begun = try DebugTrail.begin()
                try begun.write(name: "01-audio.wav", data: wav)
                trail = begun
            } catch {
                setSymbol("mic")
                fail(error.localizedDescription)
                return
            }
        }
        busy = true
        setSymbol("ellipsis.circle")
        note("Transcribing", detail: nil, style: .working)
        overlay.working()
        let current = session
        inferenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.session == current {
                    self.busy = false
                    self.inferenceTask = nil
                    self.setSymbol("mic")
                }
            }
            var phase = "recognition"
            do {
                let recognized = try await engine.recognize(wav: wav)
                try Task.checkCancellation()
                guard self.session == current else { return }
                try? trail?.write(
                    name: "02-phase1.txt",
                    text: "raw:\n\(recognized.raw)\n\nreplaced:\n\(recognized.replaced)\n")
                guard !recognized.replaced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.fail("Nothing heard", detail: "The recording had no speech in it")
                    return
                }
                var text = recognized.replaced
                if cleanup {
                    phase = "cleanup"
                    let result = try await engine.cleanup(text: text)
                    try Task.checkCancellation()
                    guard self.session == current else { return }
                    text = result.text
                    try? trail?.write(name: "03-phase2.txt", text: text + "\n")
                }
                try Task.checkCancellation()
                guard self.session == current else { return }
                self.deliver(text, stamp: trail?.stamp)
            } catch is CancellationError {
                try? trail?.write(name: "cancelled.txt", text: "Cancelled during \(phase)\n")
            } catch {
                guard self.session == current, !Task.isCancelled else { return }
                try? trail?.write(name: "error.txt", text: "\(phase)\n\(error.localizedDescription)\n")
                self.fail(error.localizedDescription)
            }
        }
    }

    private func deliver(_ text: String, stamp: String?) {
        remember(text)
        if PasteboardPutter.paste(text) {
            note("Pasted", detail: stamp.map { "Debug trail \($0)" }, style: .done)
            overlay.done("Pasted")
        } else {
            note("Copied, not pasted", detail: "Allow Dictate under Accessibility to paste", style: .problem)
            overlay.failed("Copied, not pasted")
        }
    }

    private func setSymbol(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dictate")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func note(_ title: String, detail: String?, style: StatusStyle) {
        showingIdle = false
        statusMenuItem.title = title
        statusRow.show(style, title: title, detail: detail)
    }

    /// A tap of the key, such as half of a double tap, is not a failed dictation.
    private func dropTap() {
        setSymbol("mic")
        ready()
        overlay.dismiss()
    }

    /// The idle card says whether dictation will work right now, from the last health check.
    private func ready() {
        let hold = "Hold \(keyName) to dictate"
        if let speech = health?.speech, speech.state != .ready {
            switch speech.state {
            case .downloading:
                note("Downloading speech model", detail: "Dictation works when it finishes", style: .working)
            case .failed:
                note("Speech model unavailable", detail: speech.detail, style: .problem)
            default:
                note("Loading speech model", detail: "Dictation works in a moment", style: .working)
            }
        } else if health == nil {
            note("Loading speech model", detail: "Dictation works in a moment", style: .working)
        } else if !twoPass {
            note("Ready", detail: "\(hold). Single pass: no cleanup", style: .ready)
        } else if let cleanup = health?.cleanup, [.failed, .unreachable, .off].contains(cleanup.state) {
            note("Ready", detail: "\(hold). Cleanup is off: \(cleanup.detail)", style: .ready)
        } else if health?.cleanup.state == .downloading {
            note("Ready", detail: "\(hold). The cleanup model is downloading", style: .ready)
        } else if health?.cleanup.state == .loading {
            note("Ready", detail: "\(hold). Cleanup starts in a moment", style: .ready)
        } else {
            note("Ready", detail: hold, style: .ready)
        }
        showingIdle = true
    }

    private func checkHealth() {
        guard let engine else { return }
        Task { @MainActor [weak self] in
            let reading = await engine.status()
            guard let self else { return }
            let changed = reading != self.health
            self.health = reading
            if changed {
                FileHandle.standardOutput.write(
                    Data(
                        "Models speech=\(reading.speech.state.rawValue) cleanup=\(reading.cleanup.state.rawValue)\n"
                            .utf8))
                if self.showingIdle { self.ready() }
            }
        }
    }

    private func prepareModels() {
        guard prepareTask == nil, let engine else { return }
        prepareTask = Task { @MainActor [weak self] in
            await engine.prepare()
            self?.prepareTask = nil
            self?.checkHealth()
        }
    }

    private func noteMicrophoneDenied() {
        note(
            "Microphone access needed", detail: "Allow Dictate in System Settings > Privacy & Security", style: .problem
        )
    }

    private var keyName: String { Self.displayName(config?.hotkey.name) ?? "the key" }
    private var lockName: String { Self.displayName(config?.lockKey?.name) ?? "the lock key" }

    /// "fn" reads as Fn, "right_option" as Right Option.
    private static func displayName(_ name: String?) -> String? {
        guard let name else { return nil }
        if name == "fn" { return "Fn" }
        return name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    /// A failure during a dictation: the menu keeps the full text, the overlay shows it briefly.
    private func fail(_ text: String, detail: String? = nil) {
        note(text, detail: detail, style: .problem)
        overlay.failed(text)
    }

    @objc private func quit() {
        inferenceTask?.cancel()
        prepareTask?.cancel()
        ducker.restoreNow()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        inferenceTask?.cancel()
        prepareTask?.cancel()
        ducker.restoreNow()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        checkHealth()
    }
}
