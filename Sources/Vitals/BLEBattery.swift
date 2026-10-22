import Foundation
import CoreBluetooth

/// One-shot reader for the standard GATT Battery Service (0x180F / 0x2A19) of BLE devices that macOS
/// already has connected (e.g. Logitech keyboards that `system_profiler` doesn't report).
///
/// Power strategy: no scanning at all. It only asks the system for peripherals that are *already
/// connected*, reads the characteristic once and drops its own connection right away.
@MainActor
final class BLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let service = CBUUID(string: "180F")
    private static let level = CBUUID(string: "2A19")

    private var manager: CBCentralManager?
    private var pendingStart: (() -> Void)?
    private var peripherals: [CBPeripheral] = []
    private var results: [String: Int] = [:]      // device name -> %
    private var waiting = Set<UUID>()
    private var completion: (([String: Int]) -> Void)?
    private var timeout: DispatchWorkItem?

    func read(_ done: @escaping ([String: Int]) -> Void) {
        guard completion == nil else { return done([:]) }
        completion = done
        results = [:]
        if manager == nil { manager = CBCentralManager(delegate: self, queue: nil) }
        if manager?.state == .poweredOn { start() } else { pendingStart = { [weak self] in self?.start() } }
        schedule(timeout: 10)
    }

    private func schedule(timeout t: TimeInterval) {
        timeout?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.finish() }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    private func start() {
        guard let manager else { return finish() }
        peripherals = manager.retrieveConnectedPeripherals(withServices: [Self.service])
        if peripherals.isEmpty { return finish() }
        for p in peripherals {
            waiting.insert(p.identifier)
            p.delegate = self
            manager.connect(p)
        }
    }

    private func finish() {
        timeout?.cancel()
        for p in peripherals { manager?.cancelPeripheralConnection(p) }
        peripherals = []
        waiting = []
        let done = completion
        completion = nil
        pendingStart = nil
        done?(results)
    }

    private func complete(_ p: CBPeripheral) {
        waiting.remove(p.identifier)
        manager?.cancelPeripheralConnection(p)
        if waiting.isEmpty { finish() }
    }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            if c.state == .poweredOn { pendingStart?(); pendingStart = nil }
            else if c.state != .unknown && c.state != .resetting { finish() }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Self.service])
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { complete(p) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first else { return MainActor.assumeIsolated { complete(p) } }
        p.discoverCharacteristics([Self.level], for: s)
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let c = s.characteristics?.first else { return MainActor.assumeIsolated { complete(p) } }
        p.readValue(for: c)
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let v = c.value?.first.map { Int($0) }
        MainActor.assumeIsolated {
            if let v, let name = p.name { results[name] = v }
            complete(p)
        }
    }
}
