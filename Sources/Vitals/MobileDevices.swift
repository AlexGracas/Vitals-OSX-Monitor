import Foundation

/// Battery of iPhones / iPads through Apple's private MobileDevice framework (the same channel
/// Finder uses for USB and "show this device on Wi-Fi" sync). Requires the device to be trusted by
/// this Mac and either plugged in or with Wi-Fi sync enabled.
///
/// Power strategy: the framework is only active during a short listening window (see
/// `DevicesModel`); it is unsubscribed right after, so nothing runs in between.
enum MobileDeviceReader {
    private typealias Dev = UnsafeMutableRawPointer
    private typealias Callback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW)
    private static func sym<T>(_ n: String) -> T? {
        guard let handle, let p = dlsym(handle, n) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    // "WithOptions" + SearchForPairedDevices makes the framework also surface Apple Watches paired to a nearby iPhone.
    private static let subscribe: (@convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, CFDictionary?) -> Int32)? = sym("AMDeviceNotificationSubscribeWithOptions")
    private static let unsubscribe: (@convention(c) (UnsafeMutableRawPointer?) -> Int32)? = sym("AMDeviceNotificationUnsubscribe")
    private static let connect: (@convention(c) (Dev) -> Int32)? = sym("AMDeviceConnect")
    private static let validate: (@convention(c) (Dev) -> Int32)? = sym("AMDeviceValidatePairing")
    private static let startSession: (@convention(c) (Dev) -> Int32)? = sym("AMDeviceStartSession")
    private static let stopSession: (@convention(c) (Dev) -> Int32)? = sym("AMDeviceStopSession")
    private static let disconnect: (@convention(c) (Dev) -> Int32)? = sym("AMDeviceDisconnect")
    private static let copyValue: (@convention(c) (Dev, CFString?, CFString?) -> Unmanaged<CFTypeRef>?)? = sym("AMDeviceCopyValue")

    private final class Box { var found: [String: BatteryDevice] = [:]; var closed = false }

    /// The framework delivers device callbacks on concurrent dispatch queues, so several can run at
    /// once (e.g. iPhone + paired Watch). Running two sessions in parallel corrupts the heap inside
    /// MobileDevice/libssl, and `found` isn't thread-safe either, so callbacks are fully serialized.
    private static let lock = NSLock()

    private static let callback: Callback = { info, arg in
        guard let info, let arg,
              let d = info.load(as: UnsafeMutableRawPointer?.self),
              info.load(fromByteOffset: 8, as: UInt32.self) == 1,      // 1 = connected
              let connect, let validate, let startSession, let stopSession, let disconnect, let copyValue else { return }
        lock.lock()
        defer { lock.unlock() }
        let box = Unmanaged<Box>.fromOpaque(arg).takeUnretainedValue()
        guard !box.closed, connect(d) == 0 else { return }
        defer { _ = disconnect(d) }
        guard validate(d) == 0, startSession(d) == 0 else { return }
        defer { _ = stopSession(d) }

        func value(_ domain: String?, _ key: String?) -> Any? {
            copyValue(d, domain.map { $0 as CFString }, key.map { $0 as CFString })?.takeRetainedValue()
        }
        guard let name = value(nil, "DeviceName") as? String,
              let bat = value("com.apple.mobile.battery", nil) as? [String: Any],
              let level = (bat["BatteryCurrentCapacity"] as? NSNumber)?.intValue else { return }
        // Watches don't always expose UniqueDeviceID; fall back to the name as a stable key.
        let udid = (value(nil, "UniqueDeviceID") as? String) ?? "name:\(name)"
        let product = (value(nil, "ProductType") as? String) ?? ""
        var dev = BatteryDevice(id: udid, name: name, kind: product.hasPrefix("iPad") ? "iPad" : (product.hasPrefix("iPod") ? "iPod" : (product.hasPrefix("Watch") ? "Watch" : "iPhone")),
                                main: level, left: nil, right: nil, caseLevel: nil)
        dev.charging = (bat["BatteryIsCharging"] as? NSNumber)?.boolValue ?? false
        dev.updatedAt = Date()
        box.found[udid] = dev
    }

    /// Blocking: listens for `window` seconds, then tears everything down. Call from a background thread.
    static func scan(window: TimeInterval = 12) -> [BatteryDevice] {
        guard let subscribe, let unsubscribe else { return [] }
        let box = Box()
        var notif: UnsafeMutableRawPointer?
        // Retained on purpose and never released: a callback already queued when we unsubscribe may
        // still run later, and must find a live (closed) box instead of freed memory.
        let opaque = Unmanaged.passRetained(box).toOpaque()
        guard subscribe(callback, 0, 0, opaque, &notif, ["NotificationOptionSearchForPairedDevices": true] as CFDictionary) == 0 else { return [] }
        let end = Date().addingTimeInterval(window)
        while Date() < end {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }
        _ = unsubscribe(notif)
        lock.lock()
        defer { lock.unlock() }
        box.closed = true
        return Array(box.found.values)
    }
}
