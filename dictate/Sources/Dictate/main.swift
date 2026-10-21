import AppKit
import AVFoundation
import DictateCore

private let recentLimit = 5

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
    private var config: ServiceConfig?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenuItem.isEnabled = false
        statusMenuItem.view = statusRow
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        setSymbol("mic")
        recorder.onLevel = { [weak self] level in self?.overlay.level(level) }
        overlay.onClose = { [weak self] in self?.cancel() }
        loadConfig()
        PasteboardPutter.promptForAccessibility()
        requestMicrophone()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        while menu.items.count > 0 {
            menu.removeItem(at: 0)
        }
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

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        note("Copied", detail: "The transcript is on the clipboard", style: .done)
    }

    private func loadConfig() {
        let path = ProcessInfo.processInfo.environment["STT_CONFIG"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/stt-service/config.toml")
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            config = try ConfigFile.parse(text)
            ready()
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
            note("Input Monitoring needed", detail: "Allow Dictate in System Settings > Privacy & Security, then relaunch", style: .problem)
        }
    }

    private func onFlags(_ event: NSEvent) {
        guard let spec = config?.hotkey else { return }
        let flags = UInt(event.modifierFlags.rawValue)
        if let lock = config?.lockKey, event.keyCode == lock.keyCode, flags & lock.modifierBit != 0,
           recorder.isRecording {
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
        do {
            try recorder.start()
            session += 1
            setSymbol("mic.fill")
            note("Listening", detail: "Let go of \(keyName) to finish", style: .listening)
            overlay.listening()
            watchHold()
        } catch {
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
        session += 1
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
        guard let baseURL = config?.serviceURL else { return }
        if config?.debugEnabled == true {
            transcribeInSteps(wav: wav, baseURL: baseURL)
        } else {
            transcribeOnce(wav: wav, baseURL: baseURL)
        }
    }

    private func transcribeOnce(wav: Data, baseURL: String) {
        busy = true
        setSymbol("ellipsis.circle")
        note("Transcribing", detail: nil, style: .working)
        overlay.working()
        let current = session
        SpeechClient.transcribe(baseURL: baseURL, wav: wav) { [weak self] result in
            DispatchQueue.main.async {
                guard self?.session == current else { return }
                self?.busy = false
                self?.setSymbol("mic")
                switch result {
                case .success(let text):
                    self?.deliver(text, stamp: nil)
                case .failure(let error):
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    /// Saves the WAV, then phase one, then phase two, before the paste.
    private func transcribeInSteps(wav: Data, baseURL: String) {
        let trail: DebugTrail
        do {
            trail = try DebugTrail.begin()
            try trail.write(name: "01-audio.wav", data: wav)
        } catch {
            fail(error.localizedDescription)
            return
        }
        busy = true
        setSymbol("ellipsis.circle")
        note("Transcribing", detail: nil, style: .working)
        overlay.working()
        let current = session
        SpeechClient.recognize(baseURL: baseURL, wav: wav) { [weak self] result in
            DispatchQueue.main.async {
                guard self?.session == current else { return }
                switch result {
                case .failure(let error):
                    try? trail.write(name: "error.txt", text: "phase 1\n\(error.localizedDescription)\n")
                    self?.busy = false
                    self?.setSymbol("mic")
                    self?.fail(error.localizedDescription)
                case .success(let phase1):
                    let phase1Text = "raw:\n\(phase1.raw)\n\nreplaced:\n\(phase1.replaced)\n"
                    try? trail.write(name: "02-phase1.txt", text: phase1Text)
                    if phase1.replaced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self?.busy = false
                        self?.setSymbol("mic")
                        self?.fail("Nothing heard", detail: "The recording had no speech in it")
                        return
                    }
                    SpeechClient.cleanup(baseURL: baseURL, text: phase1.replaced) { result2 in
                        DispatchQueue.main.async {
                            guard self?.session == current else { return }
                            self?.busy = false
                            self?.setSymbol("mic")
                            switch result2 {
                            case .failure(let error):
                                try? trail.write(name: "error.txt", text: "phase 2\n\(error.localizedDescription)\n")
                                self?.fail(error.localizedDescription)
                            case .success(let cleaned):
                                try? trail.write(name: "03-phase2.txt", text: cleaned + "\n")
                                self?.deliver(cleaned, stamp: trail.stamp)
                            }
                        }
                    }
                }
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
        statusMenuItem.title = title
        statusRow.show(style, title: title, detail: detail)
    }

    /// A tap of the key, such as half of a double tap, is not a failed dictation.
    private func dropTap() {
        setSymbol("mic")
        ready()
        overlay.dismiss()
    }

    private func ready() {
        note("Ready", detail: "Hold \(keyName) to dictate", style: .ready)
    }

    private func noteMicrophoneDenied() {
        note("Microphone access needed", detail: "Allow Dictate in System Settings > Privacy & Security", style: .problem)
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
        NSApp.terminate(nil)
    }
}
