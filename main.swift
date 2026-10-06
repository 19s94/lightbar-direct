import AppKit

func printState(_ state: LampState) throws {
    let data = try JSONEncoder().encode(state)
    print(String(data: data, encoding: .utf8)!)
}

if CommandLine.arguments.count > 1 {
    do {
        let args = Array(CommandLine.arguments.dropFirst())
        let client = try LampClient(config: LampConfig.load())
        switch args[0] {
        case "--status": try printState(client.state())
        case "--brightness", "--temperature":
            guard args.count == 2, let value = Int(args[1]) else { throw LampError.message("Falta un valor numérico.") }
            try printState(client.set(brightness: args[0] == "--brightness" ? value : nil,
                                      temperature: args[0] == "--temperature" ? value : nil))
        case "--power":
            guard args.count == 2, ["on","off"].contains(args[1]) else { throw LampError.message("Usa --power on u off.") }
            try printState(client.set(on: args[1] == "on"))
        case "--get":   // raw property read for diagnosis: --get <siid> <piid>
            guard args.count == 3, let siid = Int(args[1]), let piid = Int(args[2]) else { throw LampError.message("Usa --get siid piid.") }
            let reply = try client.call("get_properties", params: [["did": client.config.did, "siid": siid, "piid": piid]])
            print(reply["result"] ?? reply)
        case "--self-test":
            let initial = try client.state()
            try printState(initial)
            do {
                try printState(client.set(on: true, brightness: initial.brightness > 50 ? initial.brightness - 10 : initial.brightness + 10))
                try printState(client.set(temperature: initial.temperature > 6200 ? initial.temperature - 200 : initial.temperature + 200))
                try printState(client.set(on: false))
                try printState(client.set(on: true))
            } catch {
                let testError = error
                do { _ = try client.set(on: initial.on, brightness: initial.brightness, temperature: initial.temperature) }
                catch { fputs("ATENCIÓN: no se pudo restaurar el estado inicial.\n", stderr) }
                throw testError
            }
            let restored = try client.set(on: initial.on, brightness: initial.brightness, temperature: initial.temperature)
            guard restored == initial else { throw LampError.message("El estado inicial no se restauró.") }
            print("PASS: lectura, brillo, temperatura, apagado, encendido y restauración por LAN")
            try printState(restored)
        default: throw LampError.message("Opciones: --status, --brightness 1...100, --temperature 2700...6500, --power on|off, --self-test")
        }
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private let queue = DispatchQueue(label: "local.lightbar.direct.udp")
    private var client: LampClient?
    private var current: LampState?
    private var autoOff = false          // we switched it off on leaving; restore on return
    private var automaticItem: NSMenuItem!
    private var timer: Timer?
    private let power = NSButton(title: "…", target: nil, action: nil)
    private let powerSymbol = NSImageView(image: NSImage(systemSymbolName: "power", accessibilityDescription: nil)!)
    private let brightness = NSSlider(value: 100, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let temperature = NSSlider(value: 4000, minValue: 2700, maxValue: 6500, target: nil, action: nil)
    private let values = NSTextField(labelWithString: "")   // "72 % · 6500 K", top left
    private let status = NSMenuItem()   // only shown when there is an error

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: "local.lightbar-direct")
        if duplicates.count > 1 { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: "LightBar Direct")
        item.button?.toolTip = "LightBar Direct · local Wi-Fi control"
        item.button?.setAccessibilityLabel("LightBar Direct")
        menu.delegate = self; menu.autoenablesItems = false
        // Three compact rows: On/Off, brightness, temperature. 220 x 90.
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 90))
        power.frame = NSRect(x: 150, y: 64, width: 58, height: 20)
        power.isBordered = false; power.alignment = .right
        power.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        power.contentTintColor = .secondaryLabelColor
        // The symbol is a fixed view behind the button, so it never shifts when "On" becomes "Off".
        powerSymbol.frame = NSRect(x: 170, y: 68, width: 12, height: 12)
        powerSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        powerSymbol.contentTintColor = .secondaryLabelColor
        panel.addSubview(powerSymbol)
        power.target = self; power.action = #selector(togglePower)
        power.setAccessibilityLabel("Lamp power")
        values.frame = NSRect(x: 14, y: 66, width: 130, height: 16)
        values.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular); values.textColor = .secondaryLabelColor
        panel.addSubview(power); panel.addSubview(values)
        // Icons at x 14, sliders from 36 to 208: same right edge as the On/Off control.
        func row(_ y: CGFloat, _ symbol: String, _ slider: NSSlider, _ selector: Selector, _ label: String) {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!)
            icon.frame = NSRect(x: 14, y: y + 2, width: 16, height: 16); icon.contentTintColor = .secondaryLabelColor
            slider.frame = NSRect(x: 36, y: y, width: 172, height: 20); slider.controlSize = .small
            slider.target = self; slider.action = selector; slider.isContinuous = false
            slider.setAccessibilityLabel(label)
            panel.addSubview(icon); panel.addSubview(slider)
        }
        row(34, "sun.max", brightness, #selector(changeBrightness), "Lamp brightness")
        row(8, "thermometer.medium", temperature, #selector(changeTemperature), "Lamp color temperature")
        let custom = NSMenuItem(); custom.view = panel; menu.addItem(custom)
        status.isEnabled = false; status.isHidden = true; menu.addItem(status)
        menu.addItem(.separator())
        automaticItem = addItem("Follow Mac display", #selector(toggleAutomatic))
        automaticItem.state = automatic ? .on : .off
        automaticItem.toolTip = "With external monitors connected: turns off when the screen locks or sleeps and back on when you return. Does nothing without monitors."
        addItem("Quit", #selector(quit))
        item.menu = menu
        do { client = try LampClient(config: LampConfig.load()); refresh() }
        catch { showError(error) }
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in self?.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(self, selector: #selector(deskLeft), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(deskBack), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let session = DistributedNotificationCenter.default()
        session.addObserver(self, selector: #selector(deskLeft), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        session.addObserver(self, selector: #selector(deskBack), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    // External monitors mean "at the desk on the Mac". Without them (laptop elsewhere, or the
    // monitors moved to the Windows laptop) the lamp is left alone.
    private var atDesk: Bool {
        NSScreen.screens.contains { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) == 0
        }
    }
    private var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "automatic") }
        set { UserDefaults.standard.set(newValue, forKey: "automatic"); automaticItem.state = newValue ? .on : .off }
    }
    @objc func toggleAutomatic() { automatic.toggle() }
    @objc func deskLeft() {
        guard automatic, atDesk, !autoOff else { return }
        run { [weak self] client in
            let state = try client.state()
            guard state.on else { return state }   // turned off by hand: nothing to restore later
            self?.autoOff = true
            return try client.set(on: false)
        }
    }
    @objc func deskBack() {
        guard automatic, atDesk, autoOff else { return }
        autoOff = false
        run { try $0.set(on: true) }
    }
    @discardableResult
    private func addItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self; menu.addItem(entry)
        return entry
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    private func enable(_ value: Bool) {
        power.isEnabled = value; brightness.isEnabled = value; temperature.isEnabled = value
    }
    private func showError(_ error: Error) {
        status.title = "⚠︎ " + error.localizedDescription; status.isHidden = false
        item?.button?.toolTip = "LightBar Direct · \(error.localizedDescription)"
        enable(current != nil)
    }
    private func run(_ operation: @escaping (LampClient) throws -> LampState) {
        // Operations queue serially; the controls stay enabled and only reflect confirmed state,
        // because a menu view may not repaint a transient "working" state while it is open.
        guard let client = client else { return }
        queue.async { [weak self] in
            let result = Result { try operation(client) }
            let host = client.host
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                guard let self = self else { return }
                switch result {
                case .success(let state):
                    self.current = state
                    self.power.title = state.on ? "On" : "Off"
                    self.power.contentTintColor = state.on ? .labelColor : .secondaryLabelColor
                    self.powerSymbol.contentTintColor = state.on ? .labelColor : .secondaryLabelColor
                    self.power.toolTip = state.on ? "Turn off" : "Turn on"
                    self.brightness.doubleValue = Double(state.brightness)
                    self.temperature.doubleValue = Double(state.temperature)
                    self.values.stringValue = "\(state.brightness) % · \(state.temperature) K"
                    self.status.isHidden = true
                    self.item.button?.image = NSImage(systemSymbolName: state.on ? "lightbulb.fill" : "lightbulb", accessibilityDescription: "LightBar Direct")
                    self.item.button?.toolTip = "LightBar Direct · \(host) · \(state.on ? "On" : "Off") · \(state.brightness)% · \(state.temperature) K"
                    self.enable(true)
                    self.power.superview?.needsDisplay = true
                case .failure(let error): self.showError(error)
                }
            }
        }
    }
    @objc func refresh() { run { try $0.state() } }
    @objc func togglePower() {
        guard let state = current else { return }; run { try $0.set(on: !state.on) }
    }
    @objc func changeBrightness() {
        let value = Int(brightness.doubleValue.rounded()); run { try $0.set(brightness: value) }
    }
    @objc func changeTemperature() {
        let value = Int((temperature.doubleValue / 50).rounded()) * 50
        run { try $0.set(temperature: value) }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = MenuApp()
application.delegate = delegate
application.run()
