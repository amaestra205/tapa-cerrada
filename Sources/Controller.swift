import AppKit
import IOKit.ps

// Callbacks de C (no pueden capturar nada): solo avisan al controlador.
private func displayCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ ctx: UnsafeMutableRawPointer?) {
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { Controller.shared.evaluate("pantallas") } }
}

private func powerCallback(_ ctx: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async { MainActor.assumeIsolated { Controller.shared.evaluate("alimentación") } }
}

/// Decide si hay que bloquear el reposo (pmset disablesleep) según tapa, pantallas y batería.
@MainActor
final class Controller: NSObject {
    static let shared = Controller()

    private(set) var sleepDisabled = false
    private(set) var hasPermission = false
    private(set) var reason = "Iniciando…"
    private(set) var lidClosed = false
    private(set) var externalDisplays = 0
    private(set) var power = PowerInfo()

    private var lidClosedSince: Date?
    private var lastSleepNow = Date.distantPast
    private var lastVerify = Date.distantPast
    private var manualSleepAt: Date?
    private var manualSleep: Bool {
        guard let t = manualSleepAt else { return false }
        if Date().timeIntervalSince(t) > 120 { manualSleepAt = nil; return false }
        return true
    }

    func start() {
        hasPermission = PMSet.hasPermission()
        sleepDisabled = PMSet.sleepDisabled()
        lastVerify = Date()

        CGDisplayRegisterReconfigurationCallback(displayCallback, nil)
        if let src = IOPSNotificationCreateRunLoopSource(powerCallback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, CFRunLoopMode.defaultMode)
        }
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        wc.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Log.write("Arranque. Permiso: \(hasPermission), disablesleep: \(sleepDisabled ? 1 : 0)")
        evaluate("inicio")
    }

    @objc private func didWake(_ n: Notification) {
        manualSleepAt = nil
        lastVerify = .distantPast
        // Tras despertar, damos un minuto para que aparezcan las pantallas antes de volver a dormir.
        lastSleepNow = Date()
        Log.write("Despertó")
        evaluate("despertar")
    }

    @objc private func willSleep(_ n: Notification) {
        Log.write("Se va a dormir (\(reason))")
    }

    @objc private func screensChanged(_ n: Notification) { evaluate("pantallas") }

    func permissionChanged() {
        hasPermission = PMSet.hasPermission()
        lastVerify = .distantPast
        evaluate("permiso")
    }

    func sleepNowRequested() {
        manualSleepAt = Date()
        if PMSet.setSleepDisabled(false) { sleepDisabled = false }
        Log.write("Dormir ahora (manual)")
        PMSet.sleepNow()
        notify()
    }

    func shutdown() {
        if sleepDisabled || PMSet.sleepDisabled() {
            PMSet.setSleepDisabled(false)
            sleepDisabled = false
        }
        Log.write("Salida: reposo normal restaurado")
    }

    // MARK: - Lógica

    func evaluate(_ trigger: String) {
        lidClosed = SystemState.lidClosed()
        externalDisplays = SystemState.externalDisplayCount()
        power = SystemState.power()
        if lidClosed {
            if lidClosedSince == nil { lidClosedSince = Date() }
        } else {
            if lidClosedSince != nil { lastSleepNow = Date() }
            lidClosedSince = nil
        }

        if Date().timeIntervalSince(lastVerify) > 60 {
            sleepDisabled = PMSet.sleepDisabled()
            hasPermission = PMSet.hasPermission()
            lastVerify = Date()
        }

        let (want, why, goSleep) = decide()
        reason = hasPermission ? why : "Falta el permiso de administrador"

        if want != sleepDisabled && hasPermission {
            if PMSet.setSleepDisabled(want) {
                sleepDisabled = want
                Log.write("disablesleep=\(want ? 1 : 0) — \(why) [\(trigger)]")
            } else {
                hasPermission = PMSet.hasPermission()
            }
        }

        if goSleep && !sleepDisabled && Date().timeIntervalSince(lastSleepNow) > 60 {
            lastSleepNow = Date()
            Log.write("A dormir: \(why)")
            PMSet.sleepNow()
        }
        notify()
    }

    /// (bloquear reposo, motivo, dormir ya)
    private func decide() -> (Bool, String, Bool) {
        if manualSleep { return (false, "Durmiendo a petición tuya", false) }
        if !Settings.enabled { return (false, "Desactivado", false) }

        let onBattery = power.hasBattery && !power.onAC
        if onBattery, let p = power.percent, p <= Settings.minBattery {
            return (false, "Batería baja (\(p) %): reposo normal", lidClosed)
        }
        if externalDisplays > 0 {
            return (true, externalDisplays == 1 ? "Pantalla externa conectada" : "\(externalDisplays) pantallas externas", false)
        }
        if power.onAC && Settings.keepOnAC {
            return (true, "Con cargador: puedes cerrar la tapa", false)
        }

        let grace = Settings.graceMinutes
        if grace <= 0 { return (false, "Sin pantalla: reposo normal", false) }

        if lidClosed, let since = lidClosedSince {
            let left = Double(grace) * 60 - Date().timeIntervalSince(since)
            if left > 0 {
                return (true, "Tapa cerrada: esperando pantalla (\(Int(ceil(left / 60))) min)", false)
            }
            return (false, "Sin pantalla tras \(grace) min: a dormir", true)
        }

        // Tapa abierta en batería: mantenemos el bloqueo para que cerrar la tapa no duerma
        // al instante, y hacemos nosotros el reposo por inactividad.
        let idleLimit = Settings.idleSleepMinutes
        if idleLimit > 0,
           SystemState.idleSeconds() >= Double(idleLimit) * 60,
           !SystemState.otherAppsPreventSleep() {
            return (false, "Inactivo \(idleLimit) min: a dormir", true)
        }
        return (true, "Listo: cierra la tapa y conecta la pantalla", false)
    }

    private func notify() {
        NotificationCenter.default.post(name: .estadoCambiado, object: nil)
    }
}
