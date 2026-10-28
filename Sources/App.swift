import AppKit
import ServiceManagement

@MainActor
enum LoginItem {
    static var agent: SMAppService { SMAppService.agent(plistName: "com.alejandro.tapacerrada.agent.plist") }

    static var isEnabled: Bool { agent.status == .enabled }
    static var needsApproval: Bool { agent.status == .requiresApproval }

    static func ensureRegistered() {
        let d = UserDefaults.standard
        if d.bool(forKey: "loginConfigured") { return }
        d.set(true, forKey: "loginConfigured")
        setEnabled(true)
    }

    static func setEnabled(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
            Log.write("Inicio de sesión: \(on ? "activado" : "desactivado")")
        } catch {
            Log.write("Inicio de sesión (\(on)): \(error)")
        }
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Una sola instancia (el agente de inicio de sesión y un doble clic podrían abrir dos).
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty { exit(0) }

        // Si se abre desde Descargas (o un .zip), macOS la ejecuta en una copia temporal
        // ("App Translocation") y no puede registrarse para el inicio de sesión.
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || !(path.hasPrefix("/Applications/") || path.contains("/Applications/")) {
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "Mueve Tapa Cerrada a Aplicaciones"
            a.informativeText = "Arrastra «Tapa Cerrada» a la carpeta Aplicaciones y ábrela desde allí. Así podrá abrirse sola al iniciar sesión."
            a.addButton(withTitle: "Salir")
            a.addButton(withTitle: "Abrir de todas formas")
            if a.runModal() == .alertFirstButtonReturn { exit(0) }
        }

        Settings.register()
        // Evita App Nap: si no, los temporizadores en segundo plano se ralentizan.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Vigilar la tapa y las pantallas")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(updateIcon),
                                               name: .estadoCambiado, object: nil)
        installSignalHandlers()
        Controller.shared.start()
        LoginItem.ensureRegistered()

        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(tick),
                                     userInfo: nil, repeats: true)
        timer?.tolerance = 1
        updateIcon()

        if !Controller.shared.hasPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.askForPermission() } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Controller.shared.shutdown()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated { Controller.shared.shutdown() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    @objc private func tick() { Controller.shared.evaluate("temporizador") }

    @objc private func updateIcon() {
        let c = Controller.shared
        let name: String
        if !c.hasPermission { name = "exclamationmark.triangle" }
        else if c.sleepDisabled { name = "cup.and.saucer.fill" }
        else { name = "cup.and.saucer" }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Tapa Cerrada")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !Settings.enabled
        statusItem.button?.toolTip = "Tapa Cerrada — \(c.reason)"
    }

    // MARK: - Menú

    func menuNeedsUpdate(_ menu: NSMenu) {
        Controller.shared.evaluate("menú")
        let c = Controller.shared
        menu.removeAllItems()

        func info(_ s: String) {
            let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        func item(_ title: String, _ sel: Selector, on: Bool? = nil, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        func choices(_ title: String, _ values: [Int], current: Int, label: (Int) -> String, _ sel: Selector) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for v in values {
                let i = NSMenuItem(title: label(v), action: sel, keyEquivalent: "")
                i.target = self
                i.representedObject = v
                i.state = v == current ? .on : .off
                sub.addItem(i)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        info("Tapa Cerrada \(version) — " + (c.sleepDisabled ? "reposo bloqueado" : "reposo normal"))
        info(c.reason)
        var detail = c.externalDisplays > 0 ? "Pantallas externas: \(c.externalDisplays)" : "Sin pantalla externa"
        detail += c.power.onAC ? " · Cargador" : " · Batería"
        if let p = c.power.percent { detail += " \(p) %" }
        detail += c.lidClosed ? " · Tapa cerrada" : " · Tapa abierta"
        info(detail)
        if !c.hasPermission { item("Dar permiso de administrador…", #selector(grantPermission)) }

        menu.addItem(.separator())
        item("Activado", #selector(toggleEnabled), on: Settings.enabled)
        item("Mantener despierto con el cargador", #selector(toggleAC), on: Settings.keepOnAC)
        choices("Margen con la tapa cerrada sin pantalla", [0, 2, 5, 10, 15, 30],
                current: Settings.graceMinutes, label: { $0 == 0 ? "Ninguno (reposo al cerrar)" : "\($0) min" },
                #selector(setGrace(_:)))
        choices("Reposo por inactividad (tapa abierta)", [5, 10, 15, 30, 60, 0],
                current: Settings.idleSleepMinutes, label: { $0 == 0 ? "Nunca" : "\($0) min" },
                #selector(setIdle(_:)))
        choices("Dormir si la batería baja de", [5, 10, 15, 20, 30],
                current: Settings.minBattery, label: { "\($0) %" },
                #selector(setMinBattery(_:)))
        if PMSet.acWakeSupported {
            item("Despertar al conectar el cargador", #selector(toggleACWake), on: PMSet.acWakeEnabled())
        }

        menu.addItem(.separator())
        if LoginItem.needsApproval {
            item("Abrir al iniciar sesión (aprobar en Ajustes…)", #selector(openLoginSettings))
        } else {
            item("Abrir al iniciar sesión", #selector(toggleLogin), on: LoginItem.isEnabled)
        }
        item("Dormir ahora", #selector(sleepNow))
        item("Ver registro", #selector(openLog))
        if projectURL != nil { item("Página del proyecto…", #selector(openProject)) }
        if c.hasPermission { item("Quitar permiso de administrador…", #selector(removePermission)) }
        menu.addItem(.separator())
        item("Salir de Tapa Cerrada", #selector(quit), key: "q")
    }

    @objc private func toggleEnabled() { Settings.enabled.toggle(); Controller.shared.evaluate("ajuste") }
    @objc private func toggleAC() { Settings.keepOnAC.toggle(); Controller.shared.evaluate("ajuste") }
    @objc private func setGrace(_ s: NSMenuItem) { Settings.graceMinutes = s.representedObject as? Int ?? 5; Controller.shared.evaluate("ajuste") }
    @objc private func setIdle(_ s: NSMenuItem) { Settings.idleSleepMinutes = s.representedObject as? Int ?? 10; Controller.shared.evaluate("ajuste") }
    @objc private func setMinBattery(_ s: NSMenuItem) { Settings.minBattery = s.representedObject as? Int ?? 15; Controller.shared.evaluate("ajuste") }
    @objc private func toggleACWake() { PMSet.setACWake(!PMSet.acWakeEnabled()) }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func sleepNow() { Controller.shared.sleepNowRequested() }
    private var projectURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "TCProjectURL") as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
    @objc private func openProject() { if let u = projectURL { NSWorkspace.shared.open(u) } }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func grantPermission() { askForPermission() }

    private func askForPermission() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Tapa Cerrada necesita un permiso"
        a.informativeText = """
        Para que el Mac no se duerma al cerrar la tapa hay que cambiar un ajuste del sistema \
        (pmset disablesleep). Eso requiere tu contraseña de administrador, solo esta vez.

        Se crea /etc/sudoers.d/tapacerrada, que únicamente permite activar o desactivar ese ajuste. \
        Puedes quitarlo cuando quieras desde el menú.
        """
        a.addButton(withTitle: "Dar permiso…")
        a.addButton(withTitle: "Ahora no")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let (ok, err) = PMSet.installPermission()
        if !ok {
            Log.write("Permiso no instalado: \(err)")
            if !err.contains("-128") && !err.lowercased().contains("cancel") {
                let e = NSAlert()
                e.messageText = "No se pudo instalar el permiso"
                e.informativeText = err
                e.runModal()
            }
        }
        Controller.shared.permissionChanged()
    }

    @objc private func removePermission() {
        let (ok, err) = PMSet.removePermission()
        if !ok { Log.write("No se pudo quitar el permiso: \(err)") }
        Controller.shared.permissionChanged()
    }
}
