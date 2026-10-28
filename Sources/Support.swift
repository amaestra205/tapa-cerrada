import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

extension Notification.Name {
    static let estadoCambiado = Notification.Name("TapaCerradaEstadoCambiado")
}

// MARK: - Ajustes

enum Settings {
    static var d: UserDefaults { .standard }
    static func register() {
        d.register(defaults: [
            "enabled": true,
            "keepOnAC": true,
            "graceMinutes": 5,
            "idleSleepMinutes": 10,
            "minBattery": 15,
        ])
    }
    static var enabled: Bool { get { d.bool(forKey: "enabled") } set { d.set(newValue, forKey: "enabled") } }
    static var keepOnAC: Bool { get { d.bool(forKey: "keepOnAC") } set { d.set(newValue, forKey: "keepOnAC") } }
    static var graceMinutes: Int { get { d.integer(forKey: "graceMinutes") } set { d.set(newValue, forKey: "graceMinutes") } }
    static var idleSleepMinutes: Int { get { d.integer(forKey: "idleSleepMinutes") } set { d.set(newValue, forKey: "idleSleepMinutes") } }
    static var minBattery: Int { get { d.integer(forKey: "minBattery") } set { d.set(newValue, forKey: "minBattery") } }
}

// MARK: - Registro

enum Log {
    static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("TapaCerrada.log")
    }
    static func write(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(f.string(from: Date()))] \(s)\n"
        let u = url
        if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: u)
        }
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: u)
        }
    }
}

// MARK: - Estado del sistema (tapa, pantallas, batería, inactividad)

struct PowerInfo {
    var onAC = true
    var hasBattery = false
    var percent: Int? = nil
}

enum SystemState {
    static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return false }
        return (v as? Bool) ?? false
    }

    static func externalDisplayCount() -> Int {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    static func power() -> PowerInfo {
        var p = PowerInfo()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return p }
        if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            p.onAC = (type as String) == "AC Power"
        }
        let list = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (d["Type"] as? String) == "InternalBattery" {
                p.hasBattery = true
                if let c = d["Current Capacity"] as? Int, let m = d["Max Capacity"] as? Int, m > 0 {
                    p.percent = c * 100 / m
                }
            }
        }
        return p
    }

    /// Segundos desde la última pulsación de teclado/ratón.
    static func idleSeconds() -> Double {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        guard let v = IORegistryEntryCreateCFProperty(svc, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return 0 }
        return Double(v.uint64Value) / 1_000_000_000
    }

    /// ¿Hay alguna app (vídeo, música, descargas…) pidiendo que el sistema no se duerma?
    static func otherAppsPreventSleep() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [String: Any] else { return false }
        for key in ["PreventUserIdleSystemSleep", "PreventSystemSleep"] {
            if let n = d[key] as? Int, n > 0 { return true }
        }
        return false
    }
}

// MARK: - pmset

enum PMSet {
    static let sudoersPath = "/etc/sudoers.d/tapacerrada"

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func setting(_ name: String) -> String? {
        let (_, out) = run("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == name { return String(parts[1]) }
        }
        return nil
    }

    static func sleepDisabled() -> Bool { setting("SleepDisabled") == "1" }

    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        let (st, out) = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        if st != 0 { Log.write("pmset disablesleep \(on ? 1 : 0) falló (\(st)): \(out)") }
        return st == 0
    }

    static var acWakeSupported: Bool {
        run("/usr/bin/pmset", ["-g", "cap"]).1.contains("acwake")
    }
    static func acWakeEnabled() -> Bool { setting("acwake") == "1" }
    @discardableResult
    static func setACWake(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "acwake", on ? "1" : "0"]).0 == 0
    }

    static func sleepNow() { run("/usr/bin/pmset", ["sleepnow"]) }

    static func hasPermission() -> Bool {
        guard FileManager.default.fileExists(atPath: sudoersPath) else { return false }
        return run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).0 == 0
    }

    /// Pide la contraseña una vez e instala una regla de sudo limitada a estos comandos exactos.
    static func installPermission() -> (Bool, String) {
        let rule = "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a acwake 0, /usr/bin/pmset -a acwake 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tapacerrada-\(UUID().uuidString).sudoers")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch { return (false, "\(error)") }
        let t = "'\(tmp.path)'"
        let shell = "/usr/sbin/visudo -cf \(t) && /usr/bin/install -m 0440 -o root -g wheel \(t) \(sudoersPath)"
        defer { try? FileManager.default.removeItem(at: tmp) }
        return admin(shell, prompt: "Tapa Cerrada quiere poder impedir el reposo del Mac con la tapa cerrada.")
    }

    static func removePermission() -> (Bool, String) {
        admin("/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(sudoersPath)", prompt: "Tapa Cerrada va a quitar su permiso.")
    }

    private static func admin(_ shell: String, prompt: String) -> (Bool, String) {
        let src = "do shell script \"\(shell)\" with administrator privileges with prompt \"\(prompt)\""
        var err: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { return (false, (err[NSAppleScript.errorMessage] as? String) ?? "\(err)") }
        return (true, "")
    }
}
