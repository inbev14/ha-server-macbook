import Cocoa
import CoreGraphics

let helper = "/Library/PrivilegedHelperTools/com.local.ha-server-control"
let utmctl = "/Applications/UTM.app/Contents/MacOS/utmctl"

struct CommandResult {
    let output: String
    let status: Int32
}

func runCommand(_ path: String, _ arguments: [String]) -> CommandResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CommandResult(output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", status: p.terminationStatus)
    } catch {
        return CommandResult(output: error.localizedDescription, status: -1)
    }
}

func helperRead(_ command: String) -> String { runCommand(helper, [command]).output }
func helperWrite(_ command: String) -> CommandResult { runCommand("/usr/bin/sudo", ["-n", helper, command]) }
func serverStatus() -> String { helperRead("status") }
func flagStatus(_ key: String) -> Bool { helperRead(key) == "YES" }

func batteryInfo() -> (percent: Int, onAC: Bool) {
    let text = runCommand("/usr/bin/pmset", ["-g", "batt"]).output
    let percent: Int
    if let range = text.range(of: #"\d+%"#, options: .regularExpression) {
        percent = Int(text[range].dropLast()) ?? -1
    } else { percent = -1 }
    return (percent, text.contains("AC Power"))
}

func externalDisplayConnected() -> Bool {
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            if CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) == 0 { return true }
        }
    }
    return false
}

func getAgentPath() -> String { return (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.local.ha-server-menu.plist") }
func isAutostartEnabled() -> Bool { return FileManager.default.fileExists(atPath: getAgentPath()) }
func setAutostart(_ enable: Bool) {
    let agentPath = getAgentPath()
    let execPath = Bundle.main.executablePath ?? ""
    if enable {
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>com.local.ha-server-menu</string>
          <key>ProgramArguments</key><array><string>\(execPath)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
        </dict>
        </plist>
        """
        try? plistContent.write(toFile: agentPath, atomically: true, encoding: .utf8)
        _ = runCommand("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPath])
    } else {
        _ = runCommand("/bin/launchctl", ["bootout", "gui/\(getuid())/com.local.ha-server-menu"])
        try? FileManager.default.removeItem(atPath: agentPath)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var menuIsOpen = false
    var timer: Timer?
    var lastHeartbeat = Date.distantPast
    var onBatterySince: Date?
    var batteryWarningSent = false
    
    var localWebhookID = ""
    var remoteWebhookID = ""

    // Динамічні налаштування (завантажуються з бази Mac)
    var haURL: String { UserDefaults.standard.string(forKey: "localHAURL") ?? "http://192.168.0.215:8123" }
    var remoteHAURL: String { UserDefaults.standard.string(forKey: "remoteHAURL") ?? "https://ha.smart-home-server.pp.ua" }
    var vmIdentifier: String { UserDefaults.standard.string(forKey: "utmVMUUID") ?? "" }
    var localWebhookURL: String { "\(haURL)/api/webhook/\(localWebhookID)" }
    var remoteWebhookURL: String { "\(remoteHAURL)/api/webhook/\(remoteWebhookID)" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        
        loadWebhookIDs()
        applyPreferences()
        updateMenu()
        ensureHomeAssistantVM()
        sendHeartbeat(event: "app_started")
    }
    
    func loadWebhookIDs() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/HA Server/webhook-ids.conf")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in content.components(separatedBy: .newlines) {
            if line.hasPrefix("LOCAL_ID=") { localWebhookID = String(line.dropFirst(9)) }
            if line.hasPrefix("REMOTE_ID=") { remoteWebhookID = String(line.dropFirst(10)) }
        }
    }

    func ensureHomeAssistantVM() {
        let id = vmIdentifier
        if id.isEmpty { return } // Не запускаємо, якщо UUID не вказано
        
        DispatchQueue.global(qos: .utility).async {
            var status = runCommand(utmctl, ["status", id])
            if status.status != 0 {
                _ = runCommand("/usr/bin/open", ["-a", "UTM"])
                Thread.sleep(forTimeInterval: 2)
                status = runCommand(utmctl, ["status", id])
            }
            let lower = status.output.lowercased()
            if status.status == 0 && (lower.contains("started") || lower.contains("starting") || lower.contains("resuming")) { return }
            _ = runCommand(utmctl, ["start", id])
        }
    }

    func applyPreferences() {
        timer?.invalidate()
        let interval = Double(UserDefaults.standard.string(forKey: "heartbeatInterval") ?? "10") ?? 10.0
        timer = Timer.scheduledTimer(withTimeInterval: max(interval, 5.0), repeats: true) { [weak self] _ in self?.pollState() }
    }

    func pollState() {
        let power = batteryInfo()
        let active = serverStatus() == "ON" || serverStatus() == "PAUSED"
        
        if active && !power.onAC {
            if onBatterySince == nil { onBatterySince = Date() }
            if !batteryWarningSent, let since = onBatterySince, Date().timeIntervalSince(since) >= 600 {
                batteryWarningSent = true
                sendHeartbeat(event: "battery_warning", eventID: UUID().uuidString.lowercased())
            }
        } else {
            onBatterySince = nil
            batteryWarningSent = false
        }

        let interval = Double(UserDefaults.standard.string(forKey: "heartbeatInterval") ?? "10") ?? 10.0
        if Date().timeIntervalSince(lastHeartbeat) >= interval {
            sendHeartbeat()
            lastHeartbeat = Date()
        }
        updateMenu()
    }

    func sendHeartbeat(event: String = "heartbeat", eventID: String? = nil) {
        if localWebhookID.isEmpty { return } 
        let power = batteryInfo()
        let payload: [String: Any] = [
            "status": serverStatus(),
            "event": event,
            "event_id": eventID ?? UUID().uuidString.lowercased(),
            "battery_percent": power.percent,
            "power_source": power.onAC ? "ac" : "battery",
            "external_display": externalDisplayConnected()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        
        var req = URLRequest(url: URL(string: localWebhookURL)!)
        req.httpMethod = "POST"; req.timeoutInterval = 2.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let good = error == nil && ((response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false)
            if !good, let strongSelf = self, let fbURL = URL(string: strongSelf.remoteWebhookURL) {
                var req2 = URLRequest(url: fbURL)
                req2.httpMethod = "POST"; req2.timeoutInterval = 5
                req2.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req2.httpBody = data
                URLSession.shared.dataTask(with: req2).resume()
            }
        }.resume()
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    func updateMenu() {
        let status = serverStatus()
        let power = batteryInfo()
        let showBatt = UserDefaults.standard.bool(forKey: "showBatteryInIcon")
        let iconText = (power.percent >= 0 && showBatt) ? " \(power.percent)%" : " HA"
        
        if menu != nil && menuIsOpen {
            switch status {
            case "ON": statusItem.button?.title = "🟢\(iconText)"
            case "PAUSED": statusItem.button?.title = "🟠\(iconText)"
            default: statusItem.button?.title = "🔴\(iconText)"
            }
            return
        }
        
        let active = status == "ON" || status == "PAUSED"
        let protected = flagStatus("protection-status")
        
        switch status {
        case "ON": statusItem.button?.title = "🟢\(iconText)"
        case "PAUSED": statusItem.button?.title = "🟠\(iconText)"
        default: statusItem.button?.title = "🔴\(iconText)"
        }
        
        menu.removeAllItems()
        let titleText = status == "ON" ? "🟢 Серверний режим активний" : (status == "PAUSED" ? "🟠 Очікування живлення" : "🔴 Звичайний режим Mac")
        let title = NSMenuItem(title: titleText, action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        
        let battery = NSMenuItem(title: "🔋 АКБ: \(power.percent >= 0 ? "\(power.percent)%" : "?") · \(power.onAC ? "Мережа" : "Батарея")", action: nil, keyEquivalent: "")
        battery.isEnabled = false; menu.addItem(battery)
        
        menu.addItem(NSMenuItem.separator())
        let toggle = NSMenuItem(title: active ? "Вимкнути серверний режим" : "Увімкнути серверний режим", action: #selector(toggleServer), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        
        let batteryToggle = NSMenuItem(title: "Захист батареї (≈80% / сон при 20%)", action: #selector(toggleBatteryProtection(_:)), keyEquivalent: "")
        batteryToggle.target = self; batteryToggle.state = protected ? .on : .off; menu.addItem(batteryToggle)
        
        menu.addItem(NSMenuItem.separator())
        
        let startVM = NSMenuItem(title: "Запустити VM Home Assistant", action: #selector(startVMNow), keyEquivalent: "")
        startVM.target = self; menu.addItem(startVM)
        
        let prefs = NSMenuItem(title: "Налаштування...", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self; menu.addItem(prefs)
        
        let open = NSMenuItem(title: "Відкрити Home Assistant", action: #selector(openHomeAssistant), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        
        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Вийти", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }

    @objc func toggleServer() {
        let active = serverStatus() == "ON" || serverStatus() == "PAUSED"
        _ = helperWrite(active ? "stop" : "start")
        sendHeartbeat(event: "mode_changed")
        updateMenu()
    }

    @objc func toggleBatteryProtection(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        _ = helperWrite(enable ? "protection-on" : "protection-off")
        updateMenu()
    }
    
    @objc func startVMNow() { ensureHomeAssistantVM() }

    @objc func showPreferences() {
        let alert = NSAlert()
        alert.messageText = "Налаштування HA Server"
        
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 420))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        
        func createLabel(_ text: String, bold: Bool = false, small: Bool = false) -> NSTextField {
            let lbl = NSTextField(labelWithString: text)
            if bold { lbl.font = NSFont.boldSystemFont(ofSize: 13) }
            if small {
                lbl.font = NSFont.systemFont(ofSize: 11); lbl.textColor = NSColor.secondaryLabelColor
                lbl.cell?.wraps = true; lbl.maximumNumberOfLines = 4; lbl.preferredMaxLayoutWidth = 410
            }
            lbl.isEditable = false; lbl.isBordered = false; lbl.drawsBackground = false
            return lbl
        }
        func createInput(_ text: String) -> NSTextField {
            let tf = NSTextField(string: text); tf.translatesAutoresizingMaskIntoConstraints = false; tf.widthAnchor.constraint(equalToConstant: 410).isActive = true
            return tf
        }
        func createCheckbox(_ text: String, checked: Bool) -> NSButton {
            let btn = NSButton(checkboxWithTitle: text, target: nil, action: nil); btn.state = checked ? .on : .off
            return btn
        }
        
        let ud = UserDefaults.standard
        stack.addArrangedSubview(createLabel("Локальна адреса HA:", bold: true))
        let localInput = createInput(ud.string(forKey: "localHAURL") ?? "")
        stack.addArrangedSubview(localInput)
        
        stack.addArrangedSubview(createLabel("Хмарна адреса HA:", bold: true))
        let remoteInput = createInput(ud.string(forKey: "remoteHAURL") ?? "")
        stack.addArrangedSubview(remoteInput)
        
        stack.addArrangedSubview(createLabel("UTM VM UUID (Ідентифікатор машини):", bold: true))
        let vmInput = createInput(ud.string(forKey: "utmVMUUID") ?? "")
        stack.addArrangedSubview(vmInput)
        
        stack.addArrangedSubview(createLabel("Інтервал оновлення (сек):", bold: true))
        let intervalInput = createInput(ud.string(forKey: "heartbeatInterval") ?? "10")
        stack.addArrangedSubview(intervalInput)
        
        let showBattCheck = createCheckbox("Показувати відсотки заряду на іконці меню", checked: ud.bool(forKey: "showBatteryInIcon"))
        stack.addArrangedSubview(showBattCheck)
        
        let autostartCheck = createCheckbox("Автозапуск при увімкненні Mac", checked: isAutostartEnabled())
        stack.addArrangedSubview(autostartCheck)
        
        let box = NSBox(); box.boxType = .separator; box.translatesAutoresizingMaskIntoConstraints = false; box.widthAnchor.constraint(equalToConstant: 410).isActive = true
        stack.addArrangedSubview(box)
        
        stack.addArrangedSubview(createLabel("⚠️ Push-сповіщення (Після зміни запустіть Installer.sh)", bold: true))
        let notifyInput = createInput(ud.string(forKey: "notifyService") ?? "")
        stack.addArrangedSubview(notifyInput)
        
        alert.accessoryView = stack
        alert.addButton(withTitle: "Зберегти")
        alert.addButton(withTitle: "Скасувати")
        
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ud.set(localInput.stringValue, forKey: "localHAURL")
            ud.set(remoteInput.stringValue, forKey: "remoteHAURL")
            ud.set(vmInput.stringValue, forKey: "utmVMUUID")
            ud.set(intervalInput.stringValue, forKey: "heartbeatInterval")
            ud.set(notifyInput.stringValue, forKey: "notifyService")
            ud.set(showBattCheck.state == .on, forKey: "showBatteryInIcon")
            setAutostart(autostartCheck.state == .on)
            self.applyPreferences()
            self.updateMenu()
        }
    }

    @objc func openHomeAssistant() { if let u = URL(string: haURL) { NSWorkspace.shared.open(u) } }
    @objc func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
