// Menu bar wrapper for forti-auto-login.sh.
// Shows a shield in the menu bar, runs the watcher as a child process, and
// offers: a short status (full last log line in its tooltip), FortiClient's VPN
// connections (Connect to <name> / Disconnect <name>), Open Log, Restart Watcher, Settings,
// Report a Problem (zip for support, built by lib/collect-report.sh), Check for
// Updates (GitHub releases, also once a day), About, Quit.
// After a Connect from this menu, the token dialog is moved off-screen while the
// watcher fills it in, and put back if the watcher cannot.
// The script is bundled in Contents/Resources (copied by make-app.sh), so the
// app is self-contained and can be shipped in the installer (make-pkg.sh).
import AppKit
import ApplicationServices
import CryptoKit
import Network
import Security

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var accessibilityItem: NSMenuItem!
    private var reportItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var watcher: Process?
    private var timer: Timer?
    private var updateTimer: Timer?
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
    private let updateCheckBox = NSButton(checkboxWithTitle: "Check for updates once a day", target: nil, action: nil)

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
        updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(updatePicked), keyEquivalent: "")
        menu.addItem(withTitle: "About", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        menu.delegate = self   // menuNeedsUpdate adds the VPN connections below the status
        statusItem.menu = menu
        // a hung FortiClient must not freeze this app's Accessibility calls
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)

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
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.checkAutoReconnect()
        }
        RunLoop.main.add(t, forMode: .common)   // keeps running while an alert is open
        timer = t
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.networkUp = path.status == .satisfied }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        // FortiClient disconnects when the Mac sleeps; that counts as a drop
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.autoReconnect else { return }
            self.connectedAtSleep = self.vpnState() == "Connected"
        }
        // the first update check waits a minute (the network may not be up at login);
        // then every 10 min whether a day has passed since the last one
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.maybeCheckForUpdate() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.maybeCheckForUpdate()
        }
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
        a.informativeText = "Connects FortiClient VPN from this menu, fills the email token dialog " +
            "from Gmail, clicks OK, and closes the FortiClient window once the VPN is up.\n\n" +
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

    // MARK: FortiClient connections
    // The profiles come from FortiClient's own config. Connect and Disconnect click
    // FortiClient's menu bar menu (lib/fortitray.applescript), since FortiClient has
    // no command line for SSL VPN. After a Connect from here, the token dialog
    // (a FortiTray window) is moved off-screen as soon as it appears, the watcher
    // fills it in as usual, and it is put back on screen if the watcher cannot.

    private let fortiVPNConf = "/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"
    private let fortiUserConf = NSString(string: "~/Library/Application Support/Fortinet/FortiClient/fct.plist").expandingTildeInPath
    private var vpnItems: [NSMenuItem] = []
    private var connectingTo: String?
    private var connectDeadline = Date.distantPast
    private var hideUntil = Date.distantPast          // token dialogs appearing before then are hidden
    private var userApp: NSRunningApplication?        // frontmost app when Connect was picked
    private var hidden: (window: AXUIElement, origin: CGPoint, since: Date, logOffset: UInt64)?
    private var ownTimer: Timer?
    private var ownTicks = 0
    private var sawTrayWindow = false                 // FortiClient showed a dialog for this connect
    private var trayQuietSince: Date?                 // since when it shows none and is not connecting

    private var vpnProfiles: [String] {
        guard let profiles = NSDictionary(contentsOfFile: fortiVPNConf)?["Profiles"] as? [String: Any] else { return [] }
        return profiles.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // FortiClient records the profile of the current (or last) connection here
    private var lastVPN: String? {
        NSDictionary(contentsOfFile: fortiUserConf)?["VPNLastTimeConnection"] as? String
    }

    // FortiClient's VPN service as macOS sees it: Connected, Connecting, Disconnected,
    // Disconnecting; nil when FortiClient has none
    private func vpnState() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        p.arguments = ["--nc", "list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        // * (Connected)   80CB…  VPN (com.fortinet.forticlient.macos.vpn) "VPN"  [VPN:…]
        guard let line = out.split(separator: "\n").first(where: { $0.contains("com.fortinet.forticlient") }),
              let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        vpnItems.forEach { menu.removeItem($0) }
        vpnItems = []
        let profiles = vpnProfiles
        guard !profiles.isEmpty else { return }
        let state = vpnState() ?? "Disconnected"
        let name = lastVPN ?? "VPN"
        func disabled(_ title: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        }
        var items: [NSMenuItem] = []
        if let target = connectingTo, state != "Connected" {
            items.append(disabled("Connecting to \(target)…"))
        } else if state == "Connected" {
            items.append(NSMenuItem(title: "Disconnect \(name)", action: #selector(disconnectVPN), keyEquivalent: ""))
        } else if state == "Connecting" {
            items.append(disabled("Connecting to \(name)…"))
        } else if state == "Disconnecting" {
            items.append(disabled("Disconnecting \(name)…"))
        } else {
            if let r = reconnect {
                let wait = Int(r.due.timeIntervalSinceNow)
                items.append(disabled("Reconnecting to \(r.name)" + (wait > 0 ? " in \(wait) s" : "…")))
            }
            // the same items FortiClient's own menu offers
            for p in profiles {
                let i = NSMenuItem(title: "Connect to \(p)", action: #selector(connectVPN(_:)), keyEquivalent: "")
                i.representedObject = p
                items.append(i)
            }
        }
        let auto = NSMenuItem(title: "Auto-Reconnect", action: #selector(toggleAutoReconnect), keyEquivalent: "")
        auto.state = autoReconnect ? .on : .off
        auto.toolTip = "Connects again when the VPN drops. Not after you disconnect, " +
            "and only while you are logged in with the screen unlocked."
        items.append(auto)
        items.append(.separator())
        for (n, item) in items.enumerated() { menu.insertItem(item, at: 2 + n) }
        vpnItems = items
    }

    @objc private func connectVPN(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        reconnect = nil   // picking a connection replaces a pending reconnect
        connect(to: name, auto: false)
    }

    // the token dialog is hidden only when the watcher is able to fill it in
    private var watcherReady: Bool {
        (watcher?.isRunning ?? false) && AXIsProcessTrusted() && isValidEmail(readConf()["GMAIL_ACCOUNT"] ?? "")
    }

    private func connect(to name: String, auto: Bool) {
        let canFill = watcherReady
        connectingTo = name
        autoAttempt = auto
        connectDeadline = Date().addingTimeInterval(180)
        hideUntil = canFill ? connectDeadline : .distantPast
        userApp = NSWorkspace.shared.frontmostApplication
        appLog((auto ? "auto-reconnect" : "menu") + ": connect to \(name)"
            + (canFill ? "" : " (the token dialog stays visible: the watcher is not ready)"))
        startOwning()
        refresh()
        runTray(["click", "Connect to \(name)"]) { ok, out in
            guard !ok else { return }
            self.appLog("menu: connect failed: \(out)")
            self.stopOwning(connected: false)
            // nobody may be at the Mac for an automatic attempt; the log has it
            if !auto { self.alert("Could not connect to \(name)", out) }
        }
    }

    @objc private func disconnectVPN() {
        userDisconnectAt = Date()
        reconnect = nil
        appLog("menu: disconnect \(lastVPN ?? "VPN")")
        runTray(["click-first", "Disconnect "]) { ok, out in
            guard !ok else { return }
            self.appLog("menu: disconnect failed: \(out)")
            self.alert("Could not disconnect", out)
        }
    }

    private func runTray(_ args: [String], done: @escaping (Bool, String) -> Void) {
        let script = (scriptPath as NSString).deletingLastPathComponent + "/lib/fortitray.applescript"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [script] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        DispatchQueue.global(qos: .userInitiated).async {
            var out = "", ok = false
            do {
                try p.run()
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch { out = error.localizedDescription }
            // "…/fortitray.applescript:12:34: execution error: <message> (-2700)" -> "<message>"
            var text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = text.range(of: "execution error: ") { text = String(text[r.upperBound...]) }
            if let r = text.range(of: #" \(-?\d+\)$"#, options: .regularExpression) { text.removeSubrange(r) }
            DispatchQueue.main.async { done(ok, text) }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func appLog(_ msg: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let h = FileHandle(forWritingAtPath: logPath) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(f.string(from: Date())) \(msg)\n".utf8))
        h.closeFile()
    }

    // polls FortiTray every 0.1 s while a connect from this menu is under way
    private func startOwning() {
        ownTimer?.invalidate()
        ownTicks = 0
        sawTrayWindow = false
        trayQuietSince = nil
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.ownTick() }
        RunLoop.main.add(t, forMode: .common)
        ownTimer = t
    }

    private func stopOwning(connected: Bool) {
        ownTimer?.invalidate()
        ownTimer = nil
        connectingTo = nil
        hideUntil = .distantPast
        if autoAttempt {
            autoAttempt = false
            if connected { reconnect = nil } else { autoAttemptFailed() }
        }
        refresh()
    }

    private func ownTick() {
        ownTicks += 1
        if let h = hidden {
            if !axAlive(h.window) {
                hidden = nil   // OK was clicked (or FortiClient closed it)
            } else if ownTicks % 10 == 0, let why = giveBackReason(h) {
                restoreDialog(because: why)
            }
        } else if Date() < hideUntil, let w = tokenWindow() {
            hideDialog(w)
        }
        guard ownTicks % 10 == 0, hidden == nil else { return }
        let state = vpnState()
        let trayOpen = trayHasWindow()
        if trayOpen { sawTrayWindow = true }
        let name = connectingTo ?? lastVPN ?? "VPN"
        if state == "Connected" {
            appLog("menu: connected to \(name)")
            stopOwning(connected: true)
        } else if Date() > connectDeadline {
            appLog("menu: connect to \(name) did not finish within 3 minutes")
            stopOwning(connected: false)
        } else if sawTrayWindow && !trayOpen && state == "Disconnected" {
            // after OK it takes FortiClient ~10 s to start connecting; much
            // longer means the dialog was cancelled or the login failed
            let since = trayQuietSince ?? Date()
            trayQuietSince = since
            if Date().timeIntervalSince(since) > 30 {
                appLog("menu: connect to \(name) was cancelled or failed")
                stopOwning(connected: false)
            }
        } else {
            trayQuietSince = nil
        }
    }

    private func trayHasWindow() -> Bool {
        guard let pid = fortiTray()?.processIdentifier else { return false }
        return (axAttr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement])?.isEmpty == false
    }

    private func hideDialog(_ w: AXUIElement) {
        guard let origin = axPoint(w), let size = axSize(w) else { return }
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? UInt64) ?? 0
        guard let visible = parkOffScreen(w, size: size) else {
            axSetPoint(w, origin)
            hideUntil = .distantPast
            appLog("menu: could not move the token dialog off-screen; it stays visible")
            return
        }
        hidden = (w, origin, Date(), logOffset)
        // FortiClient takes the focus when it shows the dialog; give it back
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == fortiTray()?.processIdentifier {
            userApp?.activate(options: [])
        }
        appLog("menu: token dialog moved off-screen (\(Int(visible)) px² left on a display) while the code is filled in")
    }

    // why the hidden dialog must be shown again so the user can type the code, or nil
    private func giveBackReason(_ h: (window: AXUIElement, origin: CGPoint, since: Date, logOffset: UInt64)) -> String? {
        if !(watcher?.isRunning ?? false) { return "the watcher stopped" }
        if let f = FileHandle(forReadingAtPath: logPath) {
            defer { f.closeFile() }
            f.seek(toFileOffset: h.logOffset)
            let text = String(data: f.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let markers = ["no AuthCode mail within", "failed to fill dialog", "code rejected",
                           "gave up", "no valid email", "cannot inspect windows"]
            if let line = text.split(separator: "\n").last(where: { l in markers.contains { l.contains($0) } }) {
                return String(line.dropFirst(20))
            }
        }
        if Date().timeIntervalSince(h.since) > 150 { return "no code after 150 s" }
        return nil
    }

    private func restoreDialog(because why: String) {
        guard let h = hidden else { return }
        hidden = nil
        hideUntil = .distantPast   // it stays visible from now on
        axSetPoint(h.window, h.origin)
        AXUIElementPerformAction(h.window, kAXRaiseAction as CFString)
        fortiTray()?.activate(options: [])
        appLog("menu: token dialog shown again (\(why)); enter the code by hand")
    }

    // Puts the window in a display corner that no other display touches. macOS
    // does not let a window leave all displays, so a sliver (about a pixel) stays.
    // Returns the area still on a display, or nil when no corner hides it.
    private func parkOffScreen(_ w: AXUIElement, size: CGSize) -> CGFloat? {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        // Accessibility coordinates: origin top-left of the main display, y down
        let screens = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: mainHeight - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
        func onScreen(_ r: CGRect) -> CGFloat {
            screens.reduce(0) { sum, s in
                let i = s.intersection(r)
                return sum + (i.isNull ? 0 : i.width * i.height)
            }
        }
        var corners: [CGPoint] = []
        for s in screens.sorted(by: { ($0.maxY, $0.maxX) > ($1.maxY, $1.maxX) }) {
            corners.append(CGPoint(x: s.maxX - 1, y: s.maxY - 1))                // bottom right
            corners.append(CGPoint(x: s.minX - size.width + 1, y: s.maxY - 1))   // bottom left
        }
        let limit = size.width * size.height * 0.02
        for c in corners {
            axSetPoint(w, c)
            guard let got = axPoint(w) else { continue }
            let area = onScreen(CGRect(origin: got, size: size))
            if area <= limit { return area }
        }
        return nil
    }

    private func fortiTray() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.executableURL?.lastPathComponent == "FortiTray" }
    }

    private func tokenWindow() -> AXUIElement? {
        guard let pid = fortiTray()?.processIdentifier else { return nil }
        let windows = axAttr(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { axHasText($0, "Token Code") }
    }

    private func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func axAlive(_ el: AXUIElement) -> Bool { axAttr(el, kAXRoleAttribute) != nil }

    private func axHasText(_ el: AXUIElement, _ needle: String, depth: Int = 0) -> Bool {
        if axAttr(el, kAXRoleAttribute) as? String == kAXStaticTextRole,
           let v = axAttr(el, kAXValueAttribute) as? String, v.contains(needle) { return true }
        guard depth < 4, let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return false }
        return kids.contains { axHasText($0, needle, depth: depth + 1) }
    }

    private func axPoint(_ el: AXUIElement) -> CGPoint? {
        guard let v = axAttr(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func axSize(_ el: AXUIElement) -> CGSize? {
        guard let v = axAttr(el, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private func axSetPoint(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
    }

    // MARK: auto-reconnect (AUTO_RECONNECT="1" in the config file)
    // A drop is FortiClient's VPN service going from Connected to Disconnected
    // without a disconnect by the user: not from this menu, and without FortiClient
    // logging "VPN stopped by user" (its own menu and console). A disconnect by
    // sleep counts as a drop. The last connection is connected again the usual
    // way (token dialog hidden, code from Gmail), only while the user is logged in
    // with the screen unlocked and the network is up; 3 tries, then it gives up.

    private let fortiTrayLog = NSString(string: "~/Library/Application Support/Fortinet/FortiClient/Logs/fortitray.log").expandingTildeInPath
    private let pathMonitor = NWPathMonitor()
    private var networkUp = true
    private var reconnect: (name: String, due: Date, tries: Int, since: Date)?
    private var reconnectWait: String?                // why a due reconnect waits (logged once)
    private var autoAttempt = false                   // the connect under way was started by auto-reconnect
    private var wasConnected = false
    private var connectedAtSleep = false
    private var userDisconnectAt = Date.distantPast

    private var autoReconnect: Bool { readConf()["AUTO_RECONNECT"] == "1" }

    @objc private func toggleAutoReconnect() {
        var conf = readConf()
        conf["AUTO_RECONNECT"] = autoReconnect ? "" : "1"
        writeConf(conf)
        reconnect = nil
        wasConnected = vpnState() == "Connected"
        appLog("auto-reconnect: " + (autoReconnect ? "on" : "off"))
    }

    // logged in = this user's session is the one on screen and it is not locked
    private var userPresent: Bool {
        guard let s = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (s[kCGSessionOnConsoleKey as String] as? Bool ?? false)
            && !(s["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }

    // FortiClient keeps the password only for connections where SavePassword is on;
    // the others would wait at a password prompt
    private func savesPassword(_ name: String) -> Bool {
        let profiles = NSDictionary(contentsOfFile: fortiVPNConf)?["Profiles"] as? [String: Any]
        return ((profiles?[name] as? [String: Any])?["SavePassword"] as? Int ?? 0) == 1
    }

    // time of FortiClient's last "VPN stopped by user" (its menu or console), from its log
    private func lastUserStopInFortiClient() -> Date? {
        guard let h = FileHandle(forReadingAtPath: fortiTrayLog) else { return nil }
        defer { h.closeFile() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 65536 ? size - 65536 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.contains("VPN stopped by user") }) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd HH:mm:ss"   // 20260928 11:47:42.123 TZ=+0300 …
        return f.date(from: String(line.prefix(17)))
    }

    // every 2 s, from the main timer
    private func checkAutoReconnect() {
        guard autoReconnect, connectingTo == nil else { return }
        let state = vpnState()
        if state == "Connected" || state == "Connecting" {
            if state == "Connected" {
                if let r = reconnect { appLog("auto-reconnect: \(r.name) is connected again") }
                reconnect = nil
                wasConnected = true
                connectedAtSleep = false
            }
            return
        }
        if wasConnected && state == "Disconnected" {
            wasConnected = false
            if Date().timeIntervalSince(userDisconnectAt) < 60 { return }   // Disconnect in this menu
            guard let name = lastVPN else { return }
            reconnect = (name, Date().addingTimeInterval(10), 0, Date())
            reconnectWait = nil
            appLog("auto-reconnect: \(name) went down" + (connectedAtSleep ? " (the Mac slept)" : "") + "; reconnecting in 10 s unless it was a disconnect by the user")
        }
        guard let r = reconnect, state == "Disconnected", Date() >= r.due else { return }
        // FortiClient writes "VPN stopped by user" a moment after the tunnel is down, so
        // this is checked when the reconnect is due; after a sleep that line means nothing
        if !connectedAtSleep, let stop = lastUserStopInFortiClient(), stop >= r.since.addingTimeInterval(-30) {
            appLog("auto-reconnect: \(r.name) was disconnected in FortiClient; not reconnecting")
            reconnect = nil
            return
        }
        if !savesPassword(r.name) {
            appLog("auto-reconnect: skipped, FortiClient does not save the password of \(r.name)")
            reconnect = nil
            return
        }
        let wait = !userPresent ? "the Mac is locked or another user is logged in"
            : !networkUp ? "no network" : !watcherReady ? "the watcher is not ready" : nil
        if let wait = wait {
            if reconnectWait != wait { appLog("auto-reconnect: waiting, \(wait)") }
            reconnectWait = wait
            return
        }
        reconnectWait = nil
        reconnect?.tries += 1
        appLog("auto-reconnect: try \(r.tries + 1) of 3")
        connect(to: r.name, auto: true)
    }

    private func autoAttemptFailed() {
        guard var r = reconnect else { return }
        if r.tries >= 3 {
            appLog("auto-reconnect: gave up on \(r.name) after 3 tries; connect from the menu")
            notify("Auto-reconnect gave up on \(r.name)")
            reconnect = nil
            return
        }
        let wait: TimeInterval = r.tries == 1 ? 30 : 120
        r.due = Date().addingTimeInterval(wait)
        reconnect = r
        appLog("auto-reconnect: try \(r.tries) failed; next try in \(Int(wait)) s")
    }

    private func notify(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"Forti Auto Login\"",
                       "-e", "end run", text]
        try? p.run()
    }

    // MARK: updates (GitHub releases of this repo; UPDATE_CHECK="0" in the config
    // file turns the daily check off, Check for Updates… still works)
    //
    // Install downloads the release's .pkg, checks GitHub's SHA-256 of it and that
    // it is signed by a Developer ID Installer certificate of this app's own team,
    // and opens it in Installer. The package's scripts quit this app and start the
    // new version. The last check's result is kept in the app's defaults
    // (latestVersion, latestVersionChecked), where the problem report reads it.

    private let releasesAPI = URL(string: "https://api.github.com/repos/nachum-shmilovitz-66/forti-auto-login/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/nachum-shmilovitz-66/forti-auto-login/releases")!

    private struct Release { let version: String, notes: String, pkgURL: URL, sha256: String? }
    private struct UpdateError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    private var update: Release?          // newer than this app, found by the last check
    private var updateBusy: String?       // menu title while a check or download is under way

    private var updateCheckOn: Bool { readConf()["UPDATE_CHECK"] != "0" }
    // for testing the updater: `defaults write com.nshmilovitz.fortiautologin FALUpdateTestAs 1.0.0`
    // makes it act as that version and stop before opening Installer
    private var testAs: String? { UserDefaults.standard.string(forKey: "FALUpdateTestAs") }
    private var currentVersion: String { testAs ?? appVersion }

    // "1.0.10" is newer than "1.0.9"; anything that is not dotted numbers is never newer
    private func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return p.contains(nil) ? nil : p.compactMap { $0 }
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func refreshUpdateItem() {
        if let busy = updateBusy {
            updateItem.title = busy
            updateItem.action = nil   // disabled by the menu
        } else {
            updateItem.title = update.map { "Install Update \($0.version)…" } ?? "Check for Updates…"
            updateItem.action = #selector(updatePicked)
        }
    }

    @objc private func updatePicked() {
        if let r = update, isNewer(r.version, than: currentVersion) { offerUpdate(r) } else { checkForUpdate(manual: true) }
    }

    private func maybeCheckForUpdate() {
        let next = UserDefaults.standard.double(forKey: "nextUpdateCheck")
        guard updateCheckOn, networkUp, updateBusy == nil, Date().timeIntervalSince1970 >= next else { return }
        checkForUpdate(manual: false)
    }

    private func checkForUpdate(manual: Bool) {
        updateBusy = "Checking for Updates…"
        refreshUpdateItem()
        var req = URLRequest(url: releasesAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Forti-Auto-Login/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result = Result { try self.parseRelease(data, resp, err) }
            DispatchQueue.main.async { self.checkFinished(result, manual: manual) }
        }.resume()
    }

    private func parseRelease(_ data: Data?, _ resp: URLResponse?, _ err: Error?) throws -> Release {
        if let err = err { throw UpdateError(err.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UpdateError("GitHub answered with HTTP status \(status).")
        }
        let tag = json["tag_name"] as? String ?? ""
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil else {
            throw UpdateError("The latest release has no version tag (\"\(tag)\").")
        }
        // only this repository's own release downloads
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let pkg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".pkg") == true }),
              let link = (pkg["browser_download_url"] as? String).flatMap({ URL(string: $0) }),
              link.scheme == "https", link.host == "github.com",
              link.path.hasPrefix(releasesPage.path + "/download/") else {
            throw UpdateError("Release \(tag) has no installer (.pkg) on GitHub.")
        }
        var sha: String?
        if let d = pkg["digest"] as? String, d.hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
        return Release(version: version, notes: json["body"] as? String ?? "", pkgURL: link, sha256: sha)
    }

    private func checkFinished(_ result: Result<Release, Error>, manual: Bool) {
        updateBusy = nil
        let d = UserDefaults.standard
        switch result {
        case .failure(let e):
            d.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: "nextUpdateCheck")
            appLog("update: check failed: \(e.localizedDescription)")
            if manual { alert("Could not check for updates", e.localizedDescription) }
        case .success(let r):
            d.set(Date().addingTimeInterval(86400).timeIntervalSince1970, forKey: "nextUpdateCheck")
            d.set(r.version, forKey: "latestVersion")
            d.set(Date(), forKey: "latestVersionChecked")
            guard isNewer(r.version, than: currentVersion) else {
                update = nil
                appLog("update: \(currentVersion) is the latest version")
                if manual {
                    info("Forti Auto Login is up to date", "You have \(currentVersion)" + (r.version == currentVersion
                        ? ", the latest version." : "; the latest release on GitHub is \(r.version)."))
                }
                break
            }
            if !manual && d.string(forKey: "skippedVersion") == r.version {
                update = nil
                appLog("update: \(r.version) is available but was skipped")
                break
            }
            update = r
            if manual {
                refreshUpdateItem()
                offerUpdate(r)
            } else if d.string(forKey: "notifiedVersion") != r.version {
                // one notification per new version; the menu item stays until it is installed
                d.set(r.version, forKey: "notifiedVersion")
                appLog("update: \(r.version) is available (this is \(currentVersion))")
                notify("Version \(r.version) is available. Pick Install Update in the menu.")
            }
        }
        refreshUpdateItem()
    }

    // the release notes up to the install instructions, without Markdown markers
    private func releaseNotes(_ body: String) -> String {
        var lines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**Install") || line.hasPrefix("🤖") { break }
            lines.append(line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"^[-*] "#, with: "• ", options: .regularExpression)
                .replacingOccurrences(of: #"^#+ *"#, with: "", options: .regularExpression))
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 900 { text = String(text.prefix(900)) + "…" }
        return text
    }

    private func offerUpdate(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Forti Auto Login \(r.version) is available"
        let notes = releaseNotes(r.notes)
        a.informativeText = "You have \(currentVersion).\n\n" + (notes.isEmpty ? "" : notes + "\n\n") +
            "Install downloads it from GitHub, checks that it is signed by the same developer as " +
            "this app, and opens the installer. Settings and permissions are kept."
        if let icon = NSApp.applicationIconImage { a.icon = icon }
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            downloadUpdate(r)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(r.version, forKey: "skippedVersion")
            update = nil
            appLog("update: skipping \(r.version)")
            refreshUpdateItem()
        default:
            break
        }
    }

    private func downloadUpdate(_ r: Release) {
        guard let team = ownTeamID() else {
            // nothing to compare the installer's signature with
            appLog("update: this copy is not signed with a Developer ID; opening the releases page")
            NSWorkspace.shared.open(releasesPage)
            return
        }
        updateBusy = "Downloading \(r.version)…"
        refreshUpdateItem()
        appLog("update: downloading \(r.pkgURL.absoluteString)")
        URLSession.shared.downloadTask(with: URLRequest(url: r.pkgURL, timeoutInterval: 120)) { tmp, resp, err in
            let result = Result<URL, Error> {
                if let err = err { throw UpdateError(err.localizedDescription) }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let tmp = tmp else { throw UpdateError("The download failed (HTTP status \(status)).") }
                // the temporary file is deleted when this handler returns, so move it now
                let fm = FileManager.default
                let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Forti Auto Login")
                try? fm.removeItem(at: dir)   // earlier downloads
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let pkg = dir.appendingPathComponent("Forti Auto Login \(r.version).pkg")
                try fm.moveItem(at: tmp, to: pkg)
                do { try self.verifyPackage(pkg, r, team: team) } catch { try? fm.removeItem(at: pkg); throw error }
                return pkg
            }
            DispatchQueue.main.async { self.downloadFinished(result, r) }
        }.resume()
    }

    private func verifyPackage(_ pkg: URL, _ r: Release, team: String) throws {
        if let want = r.sha256 {
            let got = SHA256.hash(data: try Data(contentsOf: pkg)).map { String(format: "%02x", $0) }.joined()
            guard got == want else {
                throw UpdateError("The download does not match GitHub's checksum (SHA-256 \(got.prefix(12))…, expected \(want.prefix(12))…).")
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        p.arguments = ["--check-signature", pkg.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        // Status: signed by a developer certificate issued by Apple for distribution
        // ...
        //    1. Developer ID Installer: <name> (<team id>)
        let lines = out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.terminationStatus == 0,
              lines.contains(where: { $0.hasPrefix("Status: signed by a developer certificate issued by Apple") }),
              let leaf = lines.first(where: { $0.hasPrefix("1. ") }),
              leaf.hasPrefix("1. Developer ID Installer: "), leaf.hasSuffix("(\(team))") else {
            throw UpdateError("The installer is not signed by this app's developer (team \(team)).\n\n" +
                              out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func downloadFinished(_ result: Result<URL, Error>, _ r: Release) {
        updateBusy = nil
        refreshUpdateItem()
        switch result {
        case .failure(let e):
            appLog("update: not installing \(r.version): \(e.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
            let a = NSAlert()
            a.messageText = "Could not update to \(r.version)"
            a.informativeText = e.localizedDescription
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Open Releases Page")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releasesPage) }
        case .success(let pkg):
            appLog("update: \(pkg.lastPathComponent) passed the checks (" +
                   (r.sha256 == nil ? "" : "SHA-256, ") + "Developer ID signature)")
            if testAs != nil {
                appLog("update: test mode (FALUpdateTestAs); not opening the installer")
                return
            }
            appLog("update: opening the installer; it quits this app and starts \(r.version)")
            NSWorkspace.shared.open(pkg)
        }
    }

    // the Team ID this app is signed with; nil when ad-hoc signed
    private func ownTeamID() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let s = staticCode,
              SecCodeCopySigningInformation(s, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let icon = NSApp.applicationIconImage { a.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

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
        // collect-report.sh saves to Downloads, or next to the log if macOS refused access
        let folder = (zip as NSString).deletingLastPathComponent
        let downloads = NSString(string: "~/Downloads").expandingTildeInPath
        a.informativeText = (zip as NSString).lastPathComponent +
            (folder == downloads ? " is in your Downloads folder." : " is in \(folder).") +
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
        for key in ["GMAIL_ACCOUNT", "VPN_IP_PREFIX", "AUTO_RECONNECT", "UPDATE_CHECK"] {
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
        updateCheckBox.state = conf["UPDATE_CHECK"] == "0" ? .off : .on
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
        var conf = readConf()   // keeps AUTO_RECONNECT
        conf["GMAIL_ACCOUNT"] = email
        conf["VPN_IP_PREFIX"] = prefix
        conf["UPDATE_CHECK"] = updateCheckBox.state == .on ? "" : "0"   // on unless turned off
        writeConf(conf)
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
            hint, updateCheckBox, errorLabel, buttons])
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
        setIcon(active: busy || connectingTo != nil)
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
