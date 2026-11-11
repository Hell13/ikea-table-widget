// DeskIntents.swift
// Кнопки виджета (App Intents) и настройки виджета (пресеты высоты).

import AppIntents
import WidgetKit

struct NudgeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Поднять стол"
    func perform() async throws -> some IntentResult { SharedState.send(.up); return .result() }
}

struct NudgeDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Опустить стол"
    func perform() async throws -> some IntentResult { SharedState.send(.down); return .result() }
}

struct StopIntent: AppIntent {
    static var title: LocalizedStringResource = "Остановить стол"
    func perform() async throws -> some IntentResult { SharedState.send(.stop); return .result() }
}

struct GoToPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Стол на высоту"
    @Parameter(title: "Высота, см") var heightCm: Double
    init() {}
    init(heightCm: Double) { self.heightCm = heightCm }
    func perform() async throws -> some IntentResult {
        SharedState.send(.preset, valueCm: heightCm); return .result()
    }
}

/// «Изменить виджет» → здесь задаются сохранённые позиции.
struct DeskWidgetConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Позиции стола"
    static var description = IntentDescription("Сохранённые высоты для кнопок виджета.")

    @Parameter(title: "Название стола (как в приложении IKEA, напр. Desk 1234)", default: "")
    var deskName: String
    @Parameter(title: "Сидя, см", default: 72) var sitCm: Double
    @Parameter(title: "Стоя, см", default: 110) var standCm: Double
    @Parameter(title: "Третья позиция, см (0 — скрыть)", default: 0) var thirdCm: Double
    @Parameter(title: "Шаг ▲/▼, см", default: 5) var stepCm: Double
}
