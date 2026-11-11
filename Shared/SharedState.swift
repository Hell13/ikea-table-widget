// SharedState.swift
// Общие данные приложения-агента и виджета (App Group) и канал команд виджет → агент.

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

enum DeskCommand: String {
    case up, down, stop, preset
    case config   // сменилось название стола в настройках виджета
}

enum SharedState {
    /// ID группы берётся из Info.plist (там $(TeamIdentifierPrefix)desk-widget).
    static let appGroup: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "desk-widget"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    /// Darwin-уведомление разрешено в песочнице и доходит от виджета до агента.
    static let commandNotification = "com.deskwidget.command" as CFString

    // MARK: Состояние стола (пишет агент, читает виджет)

    private static var lastPublished: (Double?, Bool, Bool)?

    /// force — записать и перезагрузить виджет, даже если ничего не изменилось
    /// (старт и выход агента).
    static func publish(heightCm: Double?, connected: Bool, moving: Bool, force: Bool = false) {
        let rounded = heightCm.map { ($0 * 2).rounded() / 2 }
        if !force, let l = lastPublished, l.0 == rounded, l.1 == connected, l.2 == moving { return }
        lastPublished = (rounded, connected, moving)
        let d = defaults
        if let rounded { d.set(rounded, forKey: "heightCm") }
        d.set(connected, forKey: "connected")
        d.set(moving, forKey: "moving")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static var heightCm: Double? { defaults.object(forKey: "heightCm") as? Double }
    static var connected: Bool { defaults.bool(forKey: "connected") }
    static var moving: Bool { defaults.bool(forKey: "moving") }

    // MARK: Пульс агента и пояснение к статусу

    /// Агент пишет метку времени раз в минуту (без перезагрузки виджета).
    static func heartbeat() { defaults.set(Date().timeIntervalSince1970, forKey: "heartbeat") }
    /// Пульс старше 3 минут — считаем, что агент не запущен.
    static var agentAlive: Bool {
        let t = defaults.double(forKey: "heartbeat")
        return t > 0 && Date().timeIntervalSince1970 - t < 180
    }

    /// Короткое пояснение, почему нет связи («Bluetooth выключен», «Ищу стол…»).
    static var detail: String? { defaults.string(forKey: "detail") }
    static func setDetail(_ text: String?) {
        let d = defaults
        guard d.string(forKey: "detail") != text else { return }
        d.set(text, forKey: "detail")
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: Команды (пишет виджет, читает агент)

    static func send(_ cmd: DeskCommand, valueCm: Double = 0) {
        let d = defaults
        d.set(cmd.rawValue, forKey: "cmd")
        d.set(valueCm, forKey: "cmdValue")
        d.set(Date().timeIntervalSince1970, forKey: "cmdTime")
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(commandNotification), nil, nil, true)
    }

    static func takeCommand() -> (DeskCommand, Double)? {
        let d = defaults
        guard let raw = d.string(forKey: "cmd"), let cmd = DeskCommand(rawValue: raw),
              Date().timeIntervalSince1970 - d.double(forKey: "cmdTime") < 10 else { return nil }
        d.removeObject(forKey: "cmd")
        return (cmd, d.double(forKey: "cmdValue"))
    }

    // MARK: Настройки

    /// Название своего стола, как его показывает приложение IKEA («Desk 1234»).
    /// Задаётся в настройках виджета; агент подключается только к нему.
    static var deskName: String {
        get { defaults.string(forKey: "deskName") ?? "" }
        set { defaults.set(newValue, forKey: "deskName") }
    }

    /// Шаг кнопок ▲/▼ в виджете.
    static var stepCm: Double {
        get { (defaults.object(forKey: "stepCm") as? Double) ?? 5 }
        set { defaults.set(newValue, forKey: "stepCm") }
    }
}
