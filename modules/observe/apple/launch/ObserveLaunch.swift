// Observe's launch part, run at the app delegate's init. It does no I/O. It installs
// crash capture, starts tracking device and network state, records that state at
// startup, and requests the service (which stores and sends) once startup is over.
import ExactKit
import Foundation
import Network
import os
import QuartzCore
#if os(iOS)
import UIKit
#endif

public enum ObserveLaunch: ExactLaunchPart {
    public static let module = "observe"
    nonisolated(unsafe) static var ring = ExactRing(capacity: 128 * 1024)
    nonisolated(unsafe) static var path: NWPathMonitor?
    /// The device record is in the ring.
    nonisolated(unsafe) static var recorded = false

    public static func launch(_ context: ExactLaunchContext) {
        var config = context.config
        for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "CFBundleDisplayName", "CFBundleName"] {
            if let v = context.app[key] { config["app." + key] = v }
        }
        let session = UUID().uuidString
        config["session"] = session
        config["sessionStart"] = Date().timeIntervalSince1970
        for (k, v) in context.facts { config["fact." + k] = v }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        ObserveCrash.install(directory: context.crashDirectory, session: session, app: context.app["CFBundleIdentifier"] as? String ?? "app",
                             metadata: ["appVersion": context.app["CFBundleShortVersionString"] as? String ?? "", "appBuildNumber": context.app["CFBundleVersion"] as? String ?? "",
                                        "osVersion": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"])
        startDeviceCaches()
        context.subscribe { event in
            // Record the device and network state as of the startup event's time.
            if event.kind == "startup" { recordDevice(at: event.at) }
        }
        // Delivery to subscribers can run after the service loads: then the handoff takes the state now.
        context.requestService(.afterStartup, config: config, handoff: {
            recordDevice(at: CACurrentMediaTime())
            return ring.encoded()
        })
    }

    static func recordDevice(at t: Double) {
        guard !recorded else { return }
        recorded = true
        ring.append(Data(deviceRecord(at: t).utf8))
    }

    /// Device and network changes, timed by `CACurrentMediaTime` (seconds), oldest first.
    nonisolated(unsafe) static var history: [(at: Double, key: String, value: Any)] = []

    static func note(_ key: String, _ value: Any) {
        history.append((CACurrentMediaTime(), key, value))
        if history.count > 64 { history.removeFirst() }
    }

    static func startDeviceCaches() {
        let info = ProcessInfo.processInfo
        note("expo.device.lowPowerMode", info.isLowPowerModeEnabled)
        note("expo.device.thermalState", thermal(info.thermalState))
        let center = NotificationCenter.default
        center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            note("expo.device.lowPowerMode", ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            note("expo.device.thermalState", thermal(ProcessInfo.processInfo.thermalState))
        }
        #if os(iOS)
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            warnings += 1
            ExactEvents.journal("memory.warning", memory().merging(["expo.memory.warningsCount": warnings]) { $1 })
        }
        // Enable monitoring at launch so the first battery reading arrives before startup ends.
        UIDevice.current.isBatteryMonitoringEnabled = true
        center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in noteBattery() }
        center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in noteBattery() }
        DispatchQueue.main.async { noteBattery() }
        #endif
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { p in
            DispatchQueue.main.async {
                let satisfied = p.status == .satisfied
                note("expo.network.connected", satisfied)
                note("expo.network.type", !satisfied ? "none" : p.usesInterfaceType(.wifi) ? "wifi" : p.usesInterfaceType(.cellular) ? "cellular" : p.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other")
                if satisfied {
                    note("expo.network.isExpensive", p.isExpensive)
                    note("expo.network.isConstrained", p.isConstrained)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "observe.path"))
        path = monitor
    }

    #if os(iOS)
    nonisolated(unsafe) static var warnings = 0

    /// Observe's memory snapshot, in bytes: the footprint iOS limits the app by,
    /// its resident memory, and what it may still allocate.
    static func memory() -> [String: Any] {
        var out: [String: Any] = [:]
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount) }
        }
        if vmResult == KERN_SUCCESS { out["expo.memory.allocated"] = Int64(vm.phys_footprint) }
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount) }
        }
        if basicResult == KERN_SUCCESS { out["expo.memory.physical"] = Int64(basic.resident_size) }
        let available = os_proc_available_memory()
        if available > 0 { out["expo.memory.available"] = Int64(available) }
        return out
    }

    static func noteBattery() {
        let d = UIDevice.current
        if d.batteryLevel >= 0 { note("expo.device.batteryLevel", Double(d.batteryLevel)) }
        switch d.batteryState {
        case .charging, .full: note("expo.device.batteryCharging", true)
        case .unplugged: note("expo.device.batteryCharging", false)
        default: break
        }
    }
    #endif

    static func thermal(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// `{"kind":"device","params":{…}}` with each key's last value at or before `at`.
    /// Keys never observed by then are absent. `exact.device.changed` is set when the
    /// thermal state or low power mode changed during launch.
    static func deviceRecord(at: Double) -> String {
        var params: [String: Any] = [:]
        var seen: [String: Int] = [:]
        var oldest: Double?
        for h in history where h.at <= at {
            params[h.key] = h.value
            seen[h.key, default: 0] += 1
            oldest = oldest ?? h.at
        }
        if let oldest { params["exact.device.age_ms"] = ((at - oldest) * 1000).rounded() }
        if seen["expo.device.thermalState", default: 0] > 1 || seen["expo.device.lowPowerMode", default: 0] > 1 { params["exact.device.changed"] = true }
        let o: [String: Any] = ["kind": "device", "params": params]
        let d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}
