import Foundation

// Private IOHID symbols used to read Apple Silicon thermal sensors.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

struct SensorReading {
    let name: String
    let celsius: Double
}

final class ThermalSensors {
    private let client: AnyObject?
    private var services: [AnyObject] = []

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
        guard let client else { return }
        let match: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = IOHIDEventSystemClientSetMatching(client, match as CFDictionary)
        if let list = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] {
            services = list
        }
    }

    func read() -> [SensorReading] {
        var out: [SensorReading] = []
        for s in services {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let ev = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = IOHIDEventGetFloatValue(ev, 15 << 16)
            if v > 0, v < 150 { out.append(SensorReading(name: name, celsius: v)) }
        }
        return out
    }
}
