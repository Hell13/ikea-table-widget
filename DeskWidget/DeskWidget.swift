// DeskWidget.swift
// Виджет «Стол» для рабочего стола и Центра уведомлений macOS.

import WidgetKit
import SwiftUI
import AppIntents

struct DeskEntry: TimelineEntry {
    let date: Date
    let heightCm: Double?
    let connected: Bool
    let moving: Bool
    let agentAlive: Bool
    let detail: String?
    let presets: [(name: String, cm: Double)]
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DeskEntry {
        DeskEntry(date: .now, heightCm: 108, connected: true, moving: false, agentAlive: true,
                  detail: nil, presets: [("Сидя", 72), ("Стоя", 110)])
    }
    func snapshot(for c: DeskWidgetConfig, in context: Context) async -> DeskEntry {
        entry(c, applySettings: !context.isPreview)
    }
    func timeline(for c: DeskWidgetConfig, in context: Context) async -> Timeline<DeskEntry> {
        // Агент сам перезагружает виджет при изменениях. Плюс раз в 10 минут перечитываем
        // состояние сами — так заметим, что агент умер и пульс устарел.
        Timeline(entries: [entry(c, applySettings: !context.isPreview)], policy: .after(.now.addingTimeInterval(10 * 60)))
    }
    /// applySettings: false для превью в галерее — там настройки по умолчанию,
    /// и они не должны затирать выбранный стол.
    private func entry(_ c: DeskWidgetConfig, applySettings: Bool = true) -> DeskEntry {
        let name = c.deskName.trimmingCharacters(in: .whitespacesAndNewlines)
        if applySettings { SharedState.stepCm = c.stepCm }
        if applySettings, !name.isEmpty, name != SharedState.deskName {
            SharedState.deskName = name
            SharedState.send(.config)          // агент переподключится к новому столу
        }
        var p: [(String, Double)] = [("Сидя", c.sitCm), ("Стоя", c.standCm)]
        if c.thirdCm > 0 { p.append(("Поз. 3", c.thirdCm)) }
        let alive = SharedState.agentAlive
        return DeskEntry(date: .now, heightCm: SharedState.heightCm,
                         connected: alive && SharedState.connected,
                         moving: alive && SharedState.moving,
                         agentAlive: alive, detail: SharedState.detail, presets: p)
    }
}

struct DeskWidgetView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetRenderingMode) var renderingMode
    let e: DeskEntry
    private var fullColor: Bool { renderingMode == .fullColor }
    private var offline: Bool { !e.connected }

    /// Поднят/опущен — относительно середины между «сидя» и «стоя».
    var statusText: String {
        if e.moving { return "Едет…" }
        guard let h = e.heightCm, e.presets.count >= 2 else { return "—" }
        return h >= (e.presets[0].cm + e.presets[1].cm) / 2 ? "Поднят" : "Опущен"
    }

    var hintText: String {
        e.agentAlive ? (e.detail ?? "Закройте приложение IKEA на телефоне")
                     : "Приложение IKEA table widget не запущено"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // В маленьком виджете плашка — во всю ширину сверху. В среднем места по высоте
            // на плашку + 3 ряда кнопок нет, поэтому она занимает левую колонку вместо высоты.
            if offline && family == .systemSmall { banner }
            HStack(spacing: 12) {
                if offline && family != .systemSmall {
                    banner.frame(maxHeight: .infinity)
                } else {
                VStack(alignment: .leading, spacing: 2) {
                    if !offline {
                        Label(SharedState.deskName.isEmpty ? "IKEA table" : SharedState.deskName,
                              systemImage: "table.furniture")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.primary.opacity(0.75))
                        Spacer(minLength: 0)
                    }
                    Text(offline ? "—" : e.heightCm.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: offline ? 26 : 34, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        + Text(" см").font(.callout.weight(.medium)).foregroundColor(Color.primary.opacity(0.75))
                    if !offline {
                        Text(statusText).font(.caption.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                    }
                    if family == .systemSmall { arrows.opacity(offline ? 0.35 : 1) }
                }
                }
                if family != .systemSmall {
                    VStack(spacing: 6) {
                        ForEach(e.presets, id: \.cm) { p in
                            Button(intent: GoToPresetIntent(heightCm: p.cm)) {
                                HStack { Text(p.name); Spacer(); Text("\(Int(p.cm))").monospacedDigit() }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(DeskButtonStyle(highlighted: !offline && isAt(p.cm), fullColor: fullColor))
                            .widgetAccentable(!offline && isAt(p.cm))
                        }
                        arrows
                    }
                    .frame(maxWidth: 150)
                    .opacity(offline ? 0.35 : 1)
                }
            }
        }
        .buttonStyle(DeskButtonStyle(fullColor: fullColor))
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    /// Ошибка связи — вариант B из мокапа: крупный красный блок вместо высоты.
    /// В обесцвеченном режиме рабочего стола красный пропадает, поэтому там
    /// остаются крупная иконка, жирный текст и толстая рамка.
    var banner: some View {
        let small = family == .systemSmall
        return VStack(alignment: .leading, spacing: small ? 2 : 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: small ? 16 : 26, weight: .bold))
            Text(small ? "Нет связи" : "Нет связи\nсо столом")
                .font(.system(size: small ? 14 : 17, weight: .heavy))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(hintText)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(small ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(fullColor ? Color.white : Color.primary)
        .padding(small ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: small ? nil : .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fullColor ? Color(red: 0.90, green: 0.20, blue: 0.16) : Color.primary.opacity(0.18))
        }
        .overlay {
            if !fullColor {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary, lineWidth: 2.5)
            }
        }
        .widgetAccentable()
    }

    var arrows: some View {
        HStack(spacing: 6) {
            Button(intent: NudgeDownIntent()) { Image(systemName: "chevron.down").frame(maxWidth: .infinity) }
            if e.moving {
                Button(intent: StopIntent()) { Image(systemName: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(DeskButtonStyle(destructive: true, fullColor: fullColor))
            }
            Button(intent: NudgeUpIntent()) { Image(systemName: "chevron.up").frame(maxWidth: .infinity) }
        }
    }

    func isAt(_ cm: Double) -> Bool { e.heightCm.map { abs($0 - cm) < 1 } ?? false }
}

/// Контрастные кнопки: сплошная заливка и основной цвет текста, без системного
/// «приглушения» от .bordered/.disabled. Кнопки всегда активны: без связи агент просто
/// игнорирует команду. В обесцвеченном режиме рабочего стола (accented/vibrant) цвета
/// заливки теряются, поэтому там — только .primary текст на полупрозрачной подложке.
struct DeskButtonStyle: ButtonStyle {
    var highlighted = false
    var destructive = false
    var fullColor = true

    func makeBody(configuration: Configuration) -> some View {
        let colored = fullColor && (destructive || highlighted)
        let fill: Color = !colored ? Color.primary.opacity(highlighted && !fullColor ? 0.30 : 0.12)
                                   : destructive ? .red : .accentColor
        return configuration.label
            .font(.callout.weight(highlighted ? .semibold : .medium))
            .foregroundStyle(colored ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

@main
struct DeskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "DeskWidget", intent: DeskWidgetConfig.self, provider: Provider()) {
            DeskWidgetView(e: $0)
        }
        .configurationDisplayName("IKEA table widget")
        .description("Высота стола, кнопки вверх/вниз и сохранённые позиции.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
