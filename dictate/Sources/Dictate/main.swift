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
    private let recorder = Recorder()
    private var config: ServiceConfig?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var tracker = HoldTracker()
    private var busy = false
    private var micGranted = false
    private var recent: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenuItem.isEnabled = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        setSymbol("mic")
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
                string: "Recent",
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
        note("Copied")
    }

    private func loadConfig() {
        let path = ProcessInfo.processInfo.environment["STT_CONFIG"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/stt-service/config.toml")
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            config = try ConfigFile.parse(text)
            note("Hold \(config?.hotkey.name ?? "key")")
        } catch {
            note("Config: \(error)")
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
                        self?.note("Microphone permission denied")
                    }
                }
            }
        default:
            note("Microphone permission denied")
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
            note("Grant Input Monitoring to Dictate, then relaunch")
        }
    }

    private func onFlags(_ event: NSEvent) {
        guard let spec = config?.hotkey else { return }
        let edge = tracker.handle(keyCode: event.keyCode, spec: spec)
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
            note("Microphone permission denied")
            return
        }
        do {
            try recorder.start()
            setSymbol("mic.fill")
            note("Listening")
        } catch {
            note(error.localizedDescription)
        }
    }

    private func finish() {
        let wav: Data
        do {
            wav = try recorder.stop()
        } catch {
            setSymbol("mic")
            note(error.localizedDescription)
            return
        }
        // Ignore a tap of the key. 0.15 s of 16 kHz mono PCM16 plus the 44-byte header.
        if wav.count < 44 + 16000 * 2 * 15 / 100 {
            setSymbol("mic")
            note("Too short")
            return
        }
        guard let baseURL = config?.sttBaseURL else { return }
        if config?.debugEnabled == true {
            transcribeInSteps(wav: wav, baseURL: baseURL)
        } else {
            transcribeOnce(wav: wav, baseURL: baseURL)
        }
    }

    private func transcribeOnce(wav: Data, baseURL: String) {
        busy = true
        setSymbol("ellipsis.circle")
        note("Transcribing")
        SpeechClient.transcribe(baseURL: baseURL, wav: wav) { [weak self] result in
            DispatchQueue.main.async {
                self?.busy = false
                self?.setSymbol("mic")
                switch result {
                case .success(let text):
                    self?.deliver(text, stamp: nil)
                case .failure(let error):
                    self?.note(error.localizedDescription)
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
            note(error.localizedDescription)
            return
        }
        busy = true
        setSymbol("ellipsis.circle")
        note("Transcribing")
        SpeechClient.recognize(baseURL: baseURL, wav: wav) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    try? trail.write(name: "error.txt", text: "phase 1\n\(error.localizedDescription)\n")
                    self?.busy = false
                    self?.setSymbol("mic")
                    self?.note(error.localizedDescription)
                case .success(let phase1):
                    let phase1Text = "raw:\n\(phase1.raw)\n\nreplaced:\n\(phase1.replaced)\n"
                    try? trail.write(name: "02-phase1.txt", text: phase1Text)
                    if phase1.replaced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self?.busy = false
                        self?.setSymbol("mic")
                        self?.note("Nothing to paste")
                        return
                    }
                    SpeechClient.cleanup(baseURL: baseURL, text: phase1.replaced) { result2 in
                        DispatchQueue.main.async {
                            self?.busy = false
                            self?.setSymbol("mic")
                            switch result2 {
                            case .failure(let error):
                                try? trail.write(name: "error.txt", text: "phase 2\n\(error.localizedDescription)\n")
                                self?.note(error.localizedDescription)
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
        let suffix = stamp.map { " \($0)" } ?? ""
        if PasteboardPutter.paste(text) {
            note("Pasted" + suffix)
        } else {
            note("Copied. Grant Accessibility to paste")
        }
    }

    private func setSymbol(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dictate")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func note(_ text: String) {
        statusMenuItem.title = text
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
