// Menu bar wrapper for forti-auto-login.sh.
// Shows a shield in the menu bar, runs the watcher as a child process, and
// offers: a short status (full last log line in its tooltip), Open Log, Restart Watcher, Settings,
// Report a Problem (zip for support, built by lib/collect-report.sh), About, Quit.
// The script is bundled in Contents/Resources (copied by make-app.sh), so the
// app is self-contained and can be shipped in the installer (make-pkg.sh).
import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var accessibilityItem: NSMenuItem!
    private var reportItem: NSMenuItem!
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
        reportItem = menu.addItem(withTitle: "Report a Problem…", action: #selector(reportProblem), keyEquivalent: "")
        menu.addItem(withTitle: "About", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
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
        p.environment = ProcessInfo.processInfo.environment.merging(["FAL_APP_VERSION": appVersion]) { $1 }
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

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = "Forti Auto Login \(appVersion)"
        a.informativeText = "Fills the FortiClient email token dialog from Gmail, clicks OK, " +
            "and closes the FortiClient window once the VPN is up.\n\n" +
            "Source and releases: github.com/nachum-shmilovitz-66/forti-auto-login" +
            // NSHumanReadableCopyright is written into Info.plist by make-app.sh
            ((Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String).map { "\n\n" + $0 } ?? "")
        a.alertStyle = .informational
        if let icon = NSApp.applicationIconImage { a.icon = icon }
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Open GitHub")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/nachum-shmilovitz-66/forti-auto-login/releases")!)
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc private func restartWatcher() { startWatcher(); refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: problem report (zip built by lib/collect-report.sh, run as our child
    // so its permission probes see this app's grants, not Terminal's)

    @objc private func reportProblem() {
        let a = NSAlert()
        a.messageText = "Report a Problem"
        a.informativeText = "Creates a zip file with the log, the settings and checks of the " +
            "permissions, Chrome and FortiClient that show why the auto-login failed. " +
            "Send it to whoever supports you.\n\n" +
            "It contains no codes, passwords or mail; email addresses are partly masked."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 64))
        field.placeholderString = "Optional: what happened, and roughly when"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        a.accessoryView = field
        a.addButton(withTitle: "Create Report")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        collectReport(description: field.stringValue)
    }

    private func collectReport(description: String) {
        let collector = (scriptPath as NSString).deletingLastPathComponent + "/lib/collect-report.sh"
        guard FileManager.default.isReadableFile(atPath: collector) else {
            reportFinished(zip: nil, output: "Report script not found: \(collector)")
            return
        }
        // action nil = disabled by the menu, so a second report cannot start meanwhile
        reportItem.title = "Creating Report… (up to a minute)"
        reportItem.action = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [collector]
        p.environment = ProcessInfo.processInfo.environment.merging([
            "FAL_APP_VERSION": appVersion,
            "FAL_APP_PATH": Bundle.main.bundlePath,
            "FAL_AX_TRUSTED": AXIsProcessTrusted() ? "1" : "0",
            "FAL_WATCHER_RUNNING": (watcher?.isRunning ?? false) ? "1" : "0",
            "FAL_DESCRIPTION": description,
        ]) { $1 }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        DispatchQueue.global(qos: .userInitiated).async {
            var output = "", ok = false
            do {
                try p.run()
                // read until EOF before waiting, so a chatty script cannot fill the pipe and stall
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch { output = "Failed to start the report script: \(error.localizedDescription)" }
            // the script prints the zip's path as its last line
            let last = output.split(separator: "\n").last.map(String.init) ?? ""
            let zip = ok && last.hasSuffix(".zip") && FileManager.default.fileExists(atPath: last) ? last : nil
            DispatchQueue.main.async { self.reportFinished(zip: zip, output: output) }
        }
    }

    private func reportFinished(zip: String?, output: String) {
        reportItem.title = "Report a Problem…"
        reportItem.action = #selector(reportProblem)
        let a = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        guard let zip = zip else {
            a.messageText = "Could not create the report"
            a.informativeText = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            a.alertStyle = .warning
            a.runModal()
            return
        }
        a.messageText = "Report created"
        a.informativeText = (zip as NSString).lastPathComponent +
            "\n\nAttach this file to an email or chat message to whoever supports you."
        a.addButton(withTitle: "Show in Finder")
        a.addButton(withTitle: "Done")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: zip)])
        }
    }

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
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: confPath)
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = buildSettingsWindow() }
        let conf = readConf()
        emailField.stringValue = conf["GMAIL_ACCOUNT"] ?? ""
        prefixField.stringValue = conf["VPN_IP_PREFIX"] ?? ""
        showError("")
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
            showError("Enter a valid email address, e.g. first.last@example.com")
            settingsWindow?.makeFirstResponder(emailField)
            NSSound.beep()
            return
        }
        let prefix = prefixField.stringValue.trimmingCharacters(in: .whitespaces)
        guard prefix.range(of: "^[0-9.]*$", options: .regularExpression) != nil else {
            showError("VPN IP prefix may contain only digits and dots, e.g. 10.0.")
            settingsWindow?.makeFirstResponder(prefixField)
            NSSound.beep()
            return
        }
        writeConf(["GMAIL_ACCOUNT": email, "VPN_IP_PREFIX": prefix])
        settingsWindow?.orderOut(nil)
        startWatcher()
        refresh()
    }

    @objc private func cancelSettings() { settingsWindow?.orderOut(nil) }

    private var settingsStack: NSStackView?

    private func fitSettingsWindow() {
        guard let w = settingsWindow, let v = settingsStack else { return }
        v.layoutSubtreeIfNeeded()
        w.setContentSize(v.fittingSize)
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = text.isEmpty
        fitSettingsWindow()
    }

    private func buildSettingsWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Forti Auto Login Settings"
        w.isReleasedWhenClosed = false

        let labelWidth: CGFloat = 110, fieldWidth: CGFloat = 320
        let contentWidth = labelWidth + 8 + fieldWidth

        func row(_ label: String, _ field: NSTextField, _ placeholder: String) -> NSView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            let h = NSStackView(views: [l, field])
            h.orientation = .horizontal
            h.alignment = .firstBaseline
            h.spacing = 8
            return h
        }
        func note(_ text: String, color: NSColor) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: text)
            t.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            t.textColor = color
            t.preferredMaxLayoutWidth = contentWidth
            t.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            return t
        }
        let hint = note("The Google account that receives the FortiClient AuthCode mail. " +
                        "Chrome must be signed in to it. Leave the VPN prefix empty to accept any FortiClient connection.",
                        color: .secondaryLabelColor)
        let err = note("", color: .systemRed)
        errorLabel.font = err.font
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.preferredMaxLayoutWidth = contentWidth
        errorLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        errorLabel.isHidden = true

        let save = NSButton(title: "Save & Restart", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let v = NSStackView(views: [
            row("Email address:", emailField, "first.last@example.com"),
            row("VPN IP prefix:", prefixField, "optional, e.g. 10.0."),
            hint, errorLabel, buttons])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.setCustomSpacing(16, after: hint)
        v.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        v.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = v
        settingsStack = v
        w.setContentSize(v.fittingSize)
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
        let busy = running && (last.contains("token dialog detected") || last.contains("got code"))
        // a failed attempt stays the last log line until the next dialog appears
        let failed = ["no AuthCode mail within", "failed to fill dialog", "code rejected",
                      "tunnel not up", "gave up: dialog closed", "cannot inspect windows"].contains { last.contains($0) }
        // short on purpose: the status sets the menu's width; the full line is in the tooltips
        statusLine.title = !trusted ? "Needs Accessibility permission"
            : !hasEmail ? "Set your email in Settings"
            : !running ? "Stopped"
            : busy ? "Filling in the code…"
            : failed ? "Watching · last login failed"
            : "Watching"
        statusLine.toolTip = last.isEmpty ? nil : last
        setIcon(active: busy)
        statusItem.button?.toolTip = "Forti Auto Login" + (last.isEmpty ? "" : ": " + last)
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
