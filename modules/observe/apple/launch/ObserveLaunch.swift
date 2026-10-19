// Observe's launch part, run at the app delegate's init. It does no I/O. It installs
// crash capture, journals the device and network state and each change of it (the
// service attaches the state at TTI, as Observe reads it then), and requests the
// service (which stores and sends) for when startup is over, so that loading it
// (about 5 ms of the main thread) does not delay the TTI it measures.
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
    nonisolated(unsafe) static var path: NWPathMonitor?

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
        context.requestService(.afterStartup, config: config, handoff: { Data() })
    }

    /// A device or network value, journaled on the main thread when it changes: the service
    /// holds the latest of each in journal order.
    static func note(_ key: String, _ value: Any) {
        ExactEvents.journal("device", [key: value])
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
}
