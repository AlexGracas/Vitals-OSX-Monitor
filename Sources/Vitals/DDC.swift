import Foundation
import IOKit

// Private IOAVService symbols (Apple Silicon DDC/CI over I2C).
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn
@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(_ service: CFTypeRef, _ chip: UInt32, _ offset: UInt32, _ buf: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
}

/// One DDC/CI channel to an external display.
final class DDCChannel {
    let service: CFTypeRef
    let productName: String?
    private let queue = DispatchQueue(label: "ddc.channel")

    init(service: CFTypeRef, productName: String?) {
        self.service = service
        self.productName = productName
    }

    private func write(_ payload: [UInt8]) -> Bool {
        var buf: [UInt8] = [UInt8(0x80 | payload.count)] + payload
        var chk: UInt8 = 0x6E ^ 0x51
        for b in buf { chk ^= b }
        buf.append(chk)
        var ok = false
        for _ in 0..<3 {
            usleep(10_000)
            if IOAVServiceWriteI2C(service, 0x37, 0x51, &buf, UInt32(buf.count)) == kIOReturnSuccess { ok = true; break }
        }
        return ok
    }

    /// True if the monitor ACKs DDC/CI writes at all (false when DDC/CI is disabled or unsupported on this link).
    func probe() -> Bool {
        queue.sync { write([0x01, VCP.brightness.rawValue]) }
    }

    func set(_ code: VCP, _ value: Int) {
        queue.async { _ = self.write([0x03, code.rawValue, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]) }
    }

    /// Blocking read; call off the main thread.
    func get(_ code: VCP) -> (current: Int, max: Int)? {
        queue.sync {
            for _ in 0..<3 {
                guard write([0x01, code.rawValue]) else { continue }
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: 12)
                guard IOAVServiceReadI2C(service, 0x37, 0x51, &reply, 12) == kIOReturnSuccess else { continue }
                guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue else { continue }
                let maxV = Int(reply[6]) << 8 | Int(reply[7])
                let cur = Int(reply[8]) << 8 | Int(reply[9])
                if maxV > 0 { return (cur, maxV) }
            }
            return nil
        }
    }
}

enum DDCDiscovery {
    /// External DCPAVServiceProxy nodes, paired with the product name of the nearest preceding display node.
    static func channels() -> [DDCChannel] {
        var iter: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }

        var result: [DDCChannel] = []
        var lastName: String?
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iter) }

            if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let prod = attrs["ProductAttributes"] as? [String: Any],
               let name = prod["ProductName"] as? String {
                lastName = name
            }

            var cls = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &cls)
            guard String(cString: cls) == "DCPAVServiceProxy" else { continue }
            let loc = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard loc == "External",
                  let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            result.append(DDCChannel(service: svc, productName: lastName))
            lastName = nil
        }
        return result
    }
}
