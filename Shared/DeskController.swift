// DeskController.swift
// BLE-управление столом с пультом Linak DPG1C (DPG1002, как в IKEA IDÅSEN).
// Протокол: https://github.com/rhyst/linak-controller (открытая реализация на Python).

import Foundation
import CoreBluetooth
import Combine
import Dispatch
import os

private let log = Logger(subsystem: "com.deskwidget", category: "ble")

enum LinakUUID {
    static let control      = CBUUID(string: "99FA0001-338A-1024-8A49-009C0215F78A")
    static let controlChar  = CBUUID(string: "99FA0002-338A-1024-8A49-009C0215F78A")
    static let refOutput    = CBUUID(string: "99FA0020-338A-1024-8A49-009C0215F78A")
    static let heightChar   = CBUUID(string: "99FA0021-338A-1024-8A49-009C0215F78A")
    static let refInput     = CBUUID(string: "99FA0030-338A-1024-8A49-009C0215F78A")
    static let targetChar   = CBUUID(string: "99FA0031-338A-1024-8A49-009C0215F78A")
}

private enum Cmd {
    static let up     = Data([0x47, 0x00])
    static let down   = Data([0x46, 0x00])
    static let stop   = Data([0xFF, 0x00])
    static let wakeup = Data([0xFE, 0x00])
}

@MainActor
final class DeskController: NSObject, ObservableObject {
    enum State: Equatable { case bluetoothOff, notConfigured, searching, connecting, connected, disconnected }

    @Published private(set) var state: State = .bluetoothOff {
        didSet {
            if state != oldValue { log.info("state: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)") }
            SharedState.setDetail(detailText)
        }
    }
    @Published private(set) var heightCm: Double?       // текущая высота столешницы
    @Published private(set) var isMoving = false

    /// Высота стола в самом нижнем положении (у IDÅSEN 62 см). Калибруется в настройках.
    var baseHeightCm: Double = 62.0
    var minHeightCm: Double { baseHeightCm }
    var maxHeightCm: Double = 127.0

    /// Пояснение для виджета, когда связи нет.
    private var detailText: String? {
        let name = "«\(deskName)»"
        switch state {
        case .connected:    return nil
        case .notConfigured:
            let near = nearestDesks.prefix(3).joined(separator: ", ")
            return "Укажите свой стол: правый клик по виджету → «Изменить виджет»"
                + (near.isEmpty ? "" : ". Ближе всего: \(near)")
        case .connecting:   return "Подключаюсь к \(name)…"
        case .searching:
            if timeouts > 0 {
                return "Стол \(name) не отвечает. Закройте IKEA на телефоне, зажмите кнопку Bluetooth на пульте"
            }
            return deskSeen ? "Ищу стол \(name)…" : "Стол \(name) не найден рядом. Проверьте название"
        case .disconnected: return "Связь с \(name) потеряна. Закройте приложение IKEA на телефоне"
        case .bluetoothOff:
            switch central?.state {
            case .unauthorized: return "Нет доступа к Bluetooth: Настройки → Конфиденциальность → Bluetooth"
            case .poweredOff:   return "Bluetooth на Mac выключен"
            default:            return "Bluetooth недоступен"
            }
        }
    }

    private var central: CBCentralManager!
    private var desk: CBPeripheral?
    private var controlC: CBCharacteristic?
    private var heightC: CBCharacteristic?
    private var targetC: CBCharacteristic?
    private var moveTimer: Timer?
    private var targetRaw: UInt16?
    private let savedDeskKey = "deskPeripheralUUID"
    private let savedDeskNameKey = "deskPeripheralName"

    /// В офисе может быть много столов IKEA («Desk 1234»). Подключаемся только к столу
    /// с названием, которое пользователь указал в настройках виджета — чужие не трогаем.
    private var deskName: String { SharedState.deskName }
    private var deskSeen = false
    private var timeouts = 0
    /// Столы рядом: имя → последний RSSI. Для подсказки, если стол ещё не выбран.
    private var nearby: [String: Int] = [:]
    private var advSignatures: [String: String] = [:]
    private var nearestDesks: [String] { nearby.sorted { $0.value > $1.value }.map(\.key) }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Команды

    func startMovingUp()   { cancelTarget(); repeatCommand(Cmd.up) }
    func startMovingDown() { cancelTarget(); repeatCommand(Cmd.down) }

    func stop() {
        let wasMoving = isMoving
        safetyStop?.cancel()
        cancelTarget()
        moveTimer?.invalidate(); moveTimer = nil
        write(Cmd.stop, to: controlC)
        isMoving = false
        if wasMoving { SharedState.publish(heightCm: heightCm, connected: state == .connected, moving: false) }
    }

    /// Поехать на заданную высоту (см). Пульт требует повторять цель ~каждые 200 мс.
    func move(toCm cm: Double) {
        let clamped = min(max(cm, minHeightCm), maxHeightCm)
        let raw = UInt16(((clamped - baseHeightCm) * 100).rounded())   // 0.1 мм
        targetRaw = raw
        armSafetyStop()
        SharedState.publish(heightCm: heightCm, connected: state == .connected, moving: true)
        write(Cmd.wakeup, to: controlC)
        write(Cmd.stop, to: controlC)
        isMoving = true
        moveTimer?.invalidate()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickTowardTarget() }
        }
    }

    func nudge(byCm delta: Double) {
        guard let h = heightCm else { return }
        move(toCm: h + delta)
    }

    /// Защита: если цель так и не достигнута (упор, препятствие), остановиться через 30 с.
    private var safetyStop: DispatchWorkItem?
    private func armSafetyStop() {
        safetyStop?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        safetyStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
    }

    // MARK: Внутреннее

    private func repeatCommand(_ cmd: Data) {
        isMoving = true
        write(cmd, to: controlC)
        moveTimer?.invalidate()
        // Пульт останавливается, если команду не повторять.
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.write(cmd, to: self?.controlC) }
        }
    }

    private func tickTowardTarget() {
        guard let raw = targetRaw else { return }
        let targetCm = Double(raw) / 100 + baseHeightCm
        if let h = heightCm, abs(h - targetCm) < 0.3 { stop(); return }
        if targetC != nil {
            write(Data([UInt8(raw & 0xFF), UInt8(raw >> 8)]), to: targetC)
        } else if let h = heightCm {
            // Старые прошивки без «ехать на высоту»: жмём вверх/вниз, пока не доедем.
            if (h < targetCm) != (lastDirectionUp ?? (h < targetCm)) { stop(); return } // проскочили
            lastDirectionUp = h < targetCm
            write(h < targetCm ? Cmd.up : Cmd.down, to: controlC)
        }
    }
    private var lastDirectionUp: Bool?

    private func cancelTarget() { targetRaw = nil; lastDirectionUp = nil }

    private func write(_ data: Data, to c: CBCharacteristic?) {
        guard let c, let desk else { return }
        desk.writeValue(data, for: c, type: .withResponse)
    }

    private func handleHeight(_ data: Data) {
        guard data.count >= 4 else { return }
        let raw = UInt16(data[0]) | UInt16(data[1]) << 8
        let speed = Int16(bitPattern: UInt16(data[2]) | UInt16(data[3]) << 8)
        heightCm = baseHeightCm + Double(raw) / 100
        log.info("height raw=\(raw, privacy: .public) cm=\(self.heightCm ?? 0, privacy: .public) speed=\(speed, privacy: .public)")
        if speed == 0, targetRaw == nil, moveTimer == nil { isMoving = false }
        // Виджет обновляем только в покое: у WidgetKit ограничен бюджет обновлений.
        if speed == 0 { SharedState.publish(heightCm: heightCm, connected: state == .connected, moving: isMoving) }
    }

    private func connectKnownOrScan() {
        guard central.state == .poweredOn else { return }
        let d = UserDefaults.standard
        if !deskName.isEmpty,
           d.string(forKey: savedDeskNameKey)?.caseInsensitiveCompare(deskName) == .orderedSame,
           let s = d.string(forKey: savedDeskKey), let id = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            log.info("connecting to saved desk \(self.deskName, privacy: .public) \(id.uuidString, privacy: .public)")
            connect(p); return
        }
        scan()
    }

    /// Сканируем всё подряд: пульт Linak не всегда кладёт сервис 99FA0001 в рекламу.
    /// Отбираем по имени в didDiscover.
    private func scan() {
        guard central.state == .poweredOn else { return }
        deskSeen = false
        state = deskName.isEmpty ? .notConfigured : .searching
        log.info("scanning; wanted desk=\(self.deskName, privacy: .public)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Пользователь сменил название стола в настройках виджета.
    func reconfigure() {
        log.info("reconfigure: desk=\(self.deskName, privacy: .public)")
        central.stopScan()
        connectTimeout?.cancel()
        if let desk { self.desk = nil; central.cancelPeripheralConnection(desk) }
        controlC = nil; heightC = nil; targetC = nil
        timeouts = 0
        SharedState.publish(heightCm: nil, connected: false, moving: false, force: true)
        connectKnownOrScan()
    }

    fileprivate func discovered(_ p: CBPeripheral, name: String, rssi: Int) {
        if rssi < 0 {
            let before = nearestDesks.first
            nearby[name] = rssi
            if state == .notConfigured, nearestDesks.first != before { SharedState.setDetail(detailText) }
        }
        guard !deskName.isEmpty, name.caseInsensitiveCompare(deskName) == .orderedSame else { return }
        if !deskSeen { deskSeen = true; if state == .searching { SharedState.setDetail(detailText) } }
        guard state == .searching else { return }
        log.info("found desk: \(name, privacy: .public) \(p.identifier.uuidString, privacy: .public) rssi=\(rssi, privacy: .public)")
        central.stopScan()
        connect(p)
    }

    private var connectTimeout: DispatchWorkItem?

    private func connect(_ p: CBPeripheral) {
        desk = p; p.delegate = self
        state = .connecting
        central.connect(p)
        // CoreBluetooth не таймаутит connect сам: обычно это значит, что стол занят телефоном.
        connectTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting, self.desk === p else { return }
            log.error("connect timed out for \(p.identifier.uuidString, privacy: .public)")
            self.timeouts += 1
            self.desk = nil
            self.central.cancelPeripheralConnection(p)
            self.scan()
        }
        connectTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
    }

    nonisolated fileprivate static func isDeskCandidate(_ p: CBPeripheral, _ adv: [String: Any]) -> Bool {
        let services = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if services.contains(LinakUUID.control) { return true }
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        return name.range(of: "desk", options: .caseInsensitive) != nil
    }
}

extension DeskController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Task { @MainActor in
            log.info("central state=\(c.state.rawValue, privacy: .public) auth=\(CBManager.authorization.rawValue, privacy: .public)")
            if c.state == .poweredOn { connectKnownOrScan() } else {
                state = .bluetoothOff
                SharedState.setDetail(detailText)   // текст зависит от c.state, а state мог не измениться
                SharedState.publish(heightCm: heightCm, connected: false, moving: false)
            }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        guard DeskController.isDeskCandidate(p, advertisementData) else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        let r = rssi.intValue
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?
            .map { String(format: "%02x", $0) }.joined() ?? "-"
        let conn = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool).map { "\($0)" } ?? "?"
        let svcs = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
            .map(\.uuidString).joined(separator: ",")
        let sig = "mfg=\(mfg) conn=\(conn) svc=[\(svcs)]"
        Task { @MainActor in
            // Диагностика: стол в режиме сопряжения может менять рекламу — логируем изменения.
            if advSignatures[name] != sig {
                log.info("adv \(name, privacy: .public) rssi=\(r, privacy: .public) \(sig, privacy: .public)")
                advSignatures[name] = sig
            }
            discovered(p, name: name, rssi: r)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        Task { @MainActor in
            log.info("connected: \(p.name ?? "?", privacy: .public)")
            connectTimeout?.cancel()
            timeouts = 0
            UserDefaults.standard.set(p.identifier.uuidString, forKey: savedDeskKey)
            UserDefaults.standard.set(deskName, forKey: savedDeskNameKey)
            p.discoverServices([LinakUUID.control, LinakUUID.refOutput, LinakUUID.refInput])
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard p === desk else { return }
            log.error("failed to connect: \(error?.localizedDescription ?? "nil", privacy: .public)")
            connectTimeout?.cancel()
            desk = nil
            timeouts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scan() }
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, p === desk else { return }   // отменённые/чужие подключения игнорируем
            log.error("disconnected: \(error?.localizedDescription ?? "no error", privacy: .public)")
            controlC = nil; heightC = nil; targetC = nil
            state = .disconnected
            SharedState.publish(heightCm: heightCm, connected: false, moving: false)
            // Автопереподключение (например, когда телефон отпустил стол).
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connectKnownOrScan() }
        }
    }
}

extension DeskController: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log.error("discoverServices error: \(error.localizedDescription, privacy: .public)") }
        log.info("services: \((p.services ?? []).map(\.uuid.uuidString).joined(separator: ", "), privacy: .public)")
        p.services?.forEach { p.discoverCharacteristics(nil, for: $0) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        log.info("characteristics of \(s.uuid.uuidString, privacy: .public): \((s.characteristics ?? []).map(\.uuid.uuidString).joined(separator: ", "), privacy: .public)")
        Task { @MainActor in
            for c in s.characteristics ?? [] {
                switch c.uuid {
                case LinakUUID.controlChar: controlC = c
                case LinakUUID.targetChar:  targetC = c
                case LinakUUID.heightChar:
                    heightC = c
                    p.setNotifyValue(true, for: c)
                    p.readValue(for: c)
                default: break
                }
            }
            if controlC != nil, heightC != nil, state != .connected {
                state = .connected
                SharedState.publish(heightCm: heightCm, connected: true, moving: false)
            }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == LinakUUID.heightChar, let v = c.value else { return }
        Task { @MainActor in handleHeight(v) }
    }
}
