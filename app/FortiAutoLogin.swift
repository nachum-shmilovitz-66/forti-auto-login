// Menu bar wrapper for forti-auto-login.sh.
// Shows a shield in the menu bar, runs the watcher as a child process, and
// offers: current status (last log line), Open Log, Restart Watcher, Quit.
// The script is bundled in Contents/Resources (copied by make-app.sh), so the
// app is self-contained and can be shipped as a DMG.
import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var accessibilityItem: NSMenuItem!
    private var watcher: Process?
    private var timer: Timer?
    // the script and its lib/ are copied into Contents/Resources by make-app.sh;
    // FALScriptPath in Info.plist can override that for development
    private let scriptPath = (Bundle.main.object(forInfoDictionaryKey: "FALScriptPath") as? String)
        ?? Bundle.main.path(forResource: "forti-auto-login", ofType: "sh") ?? ""
    private let logPath = NSString(string: "~/Library/Logs/forti-auto-login.log").expandingTildeInPath
    private let confPath = NSString(string: "~/.forti-auto-login.conf").expandingTildeInPath
    private var settingsWindow: NSWindow?
    private let emailField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let prefixField = NSTextField()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(active: false)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "l")
        menu.addItem(withTitle: "Restart Watcher", action: #selector(restartWatcher), keyEquivalent: "r")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        // only shown while the Accessibility grant is missing
        accessibilityItem = menu.addItem(withTitle: "Grant Accessibility Permission…",
                                         action: #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Forti Auto Login", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu

        // UI scripting of the token dialog needs Accessibility for this app
        // (macOS attributes the child osascript calls to us). Prompt once.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            statusLine.title = "Needs Accessibility permission (see menu)"
        }

        startWatcher()
        // first run: no email yet -> open Settings right away
        if !isValidEmail(readConf()["GMAIL_ACCOUNT"] ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSettings() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func applicationWillTerminate(_ note: Notification) { stopWatcher() }

    // MARK: watcher process

    private func startWatcher() {
        stopWatcher()   // never two copies fighting over the same dialog
        guard FileManager.default.isReadableFile(atPath: scriptPath) else {
            statusLine.title = "Script not found: \(scriptPath)"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath, "--watch"]
        p.standardOutput = FileHandle.nullDevice   // the script keeps its own log file
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        do { try p.run(); watcher = p } catch { statusLine.title = "Failed to start: \(error.localizedDescription)" }
    }

    private func stopWatcher() {
        watcher?.terminate()
        watcher = nil
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "^/bin/bash .*forti-auto-login\\.sh --watch$"]
        try? k.run()
        k.waitUntilExit()
    }

    // MARK: menu

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc private func restartWatcher() { startWatcher(); refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: settings (~/.forti-auto-login.conf, sourced by the script)

    private func readConf() -> [String: String] {
        var out: [String: String] = [:]
        guard let text = try? String(contentsOfFile: confPath, encoding: .utf8) else { return out }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            out[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return out
    }

    private func writeConf(_ values: [String: String]) {
        var lines = ["# written by Forti Auto Login Settings; sourced by forti-auto-login.sh"]
        for key in ["GMAIL_ACCOUNT", "VPN_IP_PREFIX"] {
            let v = (values[key] ?? "").trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "$", with: "")
            if !v.isEmpty { lines.append("\(key)=\"\(v)\"") }
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: confPath, atomically: true, encoding: .utf8)
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = buildSettingsWindow() }
        let conf = readConf()
        emailField.stringValue = conf["GMAIL_ACCOUNT"] ?? ""
        prefixField.stringValue = conf["VPN_IP_PREFIX"] ?? ""
        errorLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.makeFirstResponder(emailField)
    }

    private func isValidEmail(_ s: String) -> Bool {
        let re = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        return s.range(of: re, options: .regularExpression) != nil
    }

    @objc private func saveSettings() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        guard isValidEmail(email) else {
            errorLabel.stringValue = "Enter a valid email address, e.g. first.last@example.com"
            settingsWindow?.makeFirstResponder(emailField)
            NSSound.beep()
            return
        }
        writeConf(["GMAIL_ACCOUNT": email,
                   "VPN_IP_PREFIX": prefixField.stringValue])
        settingsWindow?.orderOut(nil)
        startWatcher()
        refresh()
    }

    @objc private func cancelSettings() { settingsWindow?.orderOut(nil) }

    private func buildSettingsWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Forti Auto Login Settings"
        w.isReleasedWhenClosed = false

        func row(_ label: String, _ field: NSTextField, _ placeholder: String) -> NSView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 110).isActive = true
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: 310).isActive = true
            let h = NSStackView(views: [l, field])
            h.orientation = .horizontal
            h.spacing = 8
            return h
        }
        let hint = NSTextField(wrappingLabelWithString:
            "The Google account that receives the FortiClient AuthCode mail. Chrome must be signed in to it. " +
            "VPN prefix empty = any FortiClient connection.")
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 428).isActive = true
        errorLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.widthAnchor.constraint(equalToConstant: 428).isActive = true

        let save = NSButton(title: "Save & Restart", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY

        let v = NSStackView(views: [
            row("Email address:", emailField, "first.last@example.com"),
            row("VPN IP prefix:", prefixField, "optional, e.g. 10.0."),
            hint, errorLabel, buttons])
        v.orientation = .vertical
        v.alignment = .trailing
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        v.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = v
        return w
    }

    private func refresh() {
        var last = ""
        if let data = FileManager.default.contents(atPath: logPath),
           let text = String(data: data, encoding: .utf8),
           let line = text.split(separator: "\n").last {
            last = String(line)
            if last.count > 20 { last = String(last.dropFirst(11)) }   // drop the date, keep HH:MM:SS
            if last.count > 90 { last = String(last.prefix(90)) + "…" }
        }
        let running = watcher?.isRunning ?? false
        let trusted = AXIsProcessTrusted()
        accessibilityItem.isHidden = trusted
        let hasEmail = isValidEmail(readConf()["GMAIL_ACCOUNT"] ?? "")
        statusLine.title = (!trusted ? "NO ACCESSIBILITY PERMISSION" : !hasEmail ? "SET YOUR EMAIL IN SETTINGS" : running ? "Watching" : "Stopped")
            + (last.isEmpty ? "" : "  ·  " + last)
        let busy = running && (last.contains("token dialog detected") || last.contains("got code"))
        setIcon(active: busy)
        statusItem.button?.toolTip = running ? "Forti Auto Login: watching for the token dialog"
                                             : "Forti Auto Login: watcher stopped"
    }

    private func setIcon(active: Bool) {
        let name = active ? "lock.shield.fill" : "lock.shield"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Forti Auto Login") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "F"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
