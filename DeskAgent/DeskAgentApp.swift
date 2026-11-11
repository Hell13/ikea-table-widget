// DeskAgentApp.swift
// Фоновое приложение без иконки (LSUIElement): держит Bluetooth со столом
// и выполняет команды, которые присылает виджет.

import SwiftUI
import ServiceManagement

@main
struct DeskAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let desk: DeskController

    override init() {
        // Название стола можно задать при запуске: open -a "IKEA table widget" --args -deskName "Desk 1234"
        // (аргумент попадает в UserDefaults.standard). Иначе берётся из настроек виджета.
        if let n = UserDefaults.standard.string(forKey: "deskName")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            SharedState.deskName = n
        }
        desk = DeskController()
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Автозапуск при входе в систему.
        try? SMAppService.mainApp.register()

        // До подключения к столу виджет должен показывать «нет связи», а не старое состояние.
        SharedState.publish(heightCm: nil, connected: false, moving: false, force: true)
        SharedState.heartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            SharedState.heartbeat()
        }

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in me.handleCommand() }
            },
            SharedState.commandNotification, nil, .deliverImmediately)
    }

    private var heartbeatTimer: Timer?

    func applicationWillTerminate(_ n: Notification) {
        desk.stop()
        SharedState.setDetail(nil)
        SharedState.defaults.set(0, forKey: "heartbeat")
        SharedState.publish(heightCm: nil, connected: false, moving: false, force: true)
    }

    private func handleCommand() {
        guard let (cmd, value) = SharedState.takeCommand() else { return }
        if cmd == .config { desk.reconfigure(); return }
        guard desk.state == .connected else { return }   // без связи кнопки просто игнорируем
        switch cmd {
        case .config: break
        case .up:     desk.isMoving ? desk.stop() : desk.nudge(byCm: SharedState.stepCm)
        case .down:   desk.isMoving ? desk.stop() : desk.nudge(byCm: -SharedState.stepCm)
        case .stop:   desk.stop()
        case .preset: desk.isMoving ? desk.stop() : desk.move(toCm: value)
        }
    }
}
