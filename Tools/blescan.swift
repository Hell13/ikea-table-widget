// blescan.swift — диагностика: какие столы Linak видны по Bluetooth.
// Сборка: swiftc -O Tools/blescan.swift -o Tools/blescan && Tools/blescan [секунды]
// Только сканирует и печатает, ни к чему не подключается.

import Foundation
import CoreBluetooth

let linak = CBUUID(string: "99FA0001-338A-1024-8A49-009C0215F78A")
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 15

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen: [UUID: (name: String, rssi: [Int], linak: Bool, connectable: Bool)] = [:]

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("Bluetooth state=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData adv: [String: Any], rssi: NSNumber) {
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isLinak = services.contains(linak)
        guard isLinak || name.range(of: "desk", options: .caseInsensitive) != nil else { return }
        let conn = (adv[CBAdvertisementDataIsConnectable] as? Bool) ?? false
        var e = seen[p.identifier] ?? (name, [], false, false)
        if !name.isEmpty { e.name = name }
        if rssi.intValue < 0 { e.rssi.append(rssi.intValue) }
        e.linak = e.linak || isLinak
        e.connectable = e.connectable || conn
        seen[p.identifier] = e
    }

    func report() {
        print("\nНайдено столов: \(seen.count) (ближе к 0 dBm — ближе к Mac)")
        let rows = seen.map { (id, e) -> (String, Int, Int, Bool, Bool, UUID) in
            let avg = e.rssi.isEmpty ? -999 : e.rssi.reduce(0, +) / e.rssi.count
            return (e.name, avg, e.rssi.max() ?? -999, e.linak, e.connectable, id)
        }.sorted { $0.1 > $1.1 }
        for r in rows {
            print(String(format: "%-14@ avg %4d dBm  max %4d  linakSvc=%@  connectable=%@  %@",
                         r.0 as NSString, r.1, r.2, r.3 ? "yes" : "no", r.4 ? "yes" : "no",
                         r.5.uuidString as NSString))
        }
    }
}

let s = Scanner()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { s.report(); exit(0) }
RunLoop.main.run()
