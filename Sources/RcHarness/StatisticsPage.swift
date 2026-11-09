import Charts
import SwiftUI

enum StatisticsRange: String, CaseIterable, Identifiable {
    case day, week, all
    var id: String { rawValue }
    var title: String {
        switch self { case .day: "日"; case .week: "周"; case .all: "全部" }
    }
}

/// Observes only the usage store, so it is the only view that re-renders
/// when a press or voice session is recorded.
struct StatisticsPage: View {
    @ObservedObject var store: UsageStore
    let range: StatisticsRange
    let inputs: [ControllerInput]

    var body: some View {
        // Derive every figure once per render instead of once per use.
        let summary = UsageSummary(usage: store.usage, range: range, inputs: inputs)
        let recordedButtons = summary.buttonRanking.filter { $0.value > 0 }
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                metric("按键总次数", value: "\(summary.pressCount)")
                metric("语音时长", value: duration(summary.voiceSeconds))
                metric("使用天数", value: "\(summary.activeDays)")
                metric("最长单次语音", value: duration(summary.sessions.first?.seconds ?? 0))
            }
            if summary.activeDays == 0 && summary.sessions.isEmpty {
                SettingsPanel {
                    SettingsEmpty(symbol: "chart.bar", title: "此时间范围内还没有使用记录",
                                  detail: "使用遥控器按键或语音后，这里会显示次数、时长和排行。统计仅保存在这台 Mac。")
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    usageChart(summary.chartDays, voice: false)
                    usageChart(summary.chartDays, voice: true)
                }
                HStack(alignment: .top, spacing: 16) {
                    SettingsPanel("按键使用排行", symbol: "chart.bar.xaxis") {
                        if recordedButtons.isEmpty {
                            Text("此时间范围内还没有按键记录").font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(recordedButtons.enumerated()), id: \.element.key) { index, entry in
                                    HStack {
                                        rank(index)
                                        Text(ControllerInput(rawValue: entry.key)?.label ?? entry.key).font(.system(size: 12))
                                        Spacer()
                                        Text("\(entry.value) 次").font(.system(size: 12, design: .monospaced))
                                    }.frame(minHeight: 24)
                                }
                            }
                        }
                    }
                    SettingsPanel("单次语音时长排行", symbol: "waveform") {
                        if summary.rankedSessions.isEmpty {
                            Text("此时间范围内还没有语音记录").font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(summary.rankedSessions.enumerated()), id: \.element.id) { index, session in
                                    HStack {
                                        rank(index)
                                        Text(duration(session.seconds)).fontWeight(.semibold).monospacedDigit()
                                        Spacer()
                                        Text(session.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                                    }.font(.system(size: 11)).frame(minHeight: 24)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(SettingsStyle.subtle, in: RoundedRectangle(cornerRadius: SettingsStyle.panelRadius))
            .overlay { RoundedRectangle(cornerRadius: SettingsStyle.panelRadius).strokeBorder(Color.primary.opacity(0.07)) }
    }

    private func rank(_ index: Int) -> some View {
        Text("\(index + 1)")
            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(index < 3 ? Color.accentColor : .secondary)
            .frame(width: 22, height: 22)
            .background(index < 3 ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func usageChart(_ days: [UsageDay], voice: Bool) -> some View {
        SettingsPanel {
            HStack(spacing: 8) {
                Image(systemName: voice ? "waveform" : "circle.dotted")
                    .foregroundStyle(voice ? Color.orange : .blue)
                Text(voice ? "语音时长" : "按键次数").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text(range == .day ? "今天" : "最近 7 天").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if days.contains(where: { voice ? $0.voiceSeconds > 0 : $0.count > 0 }) {
                chart(days, voice: voice)
            } else {
                Text(range == .day ? "今天还没有\(voice ? "语音" : "按键")记录" : "最近 7 天没有\(voice ? "语音" : "按键")记录")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 185)
            }
        }
    }

    private func chart(_ days: [UsageDay], voice: Bool) -> some View {
        Chart(days) { day in
            BarMark(x: .value("日期", day.date, unit: .day), y: .value(voice ? "秒" : "次", voice ? day.voiceSeconds : Double(day.count)), width: .ratio(0.55))
                .foregroundStyle(voice ? Color.orange : Color.blue).cornerRadius(4)
                .annotation(position: .top, spacing: 4) {
                    Text(voice ? "\(day.voiceSeconds.formatted(.number.precision(.fractionLength(0...1))))秒" : "\(day.count)")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
        }
        .chartYScale(domain: 0...max(1, days.map { voice ? $0.voiceSeconds : Double($0.count) }.max() ?? 0),
                     range: .plotDimension(endPadding: 24))
        .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) } }
        .chartYAxis {
            if voice {
                AxisMarks(values: .automatic(desiredCount: 4))
            } else {
                AxisMarks(values: .automatic(minimumStride: 1, desiredCount: 4)) { value in
                    if let count = value.as(Double.self), count.rounded() == count {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            Text(count.formatted(.number.precision(.fractionLength(0))))
                        }
                    }
                }
            }
        }
        .frame(height: 185)
    }

    private func duration(_ seconds: Double) -> String { let value = max(0, Int(seconds)); return String(format: "%d:%02d", value / 60, value % 60) }
}

/// Figures for one statistics range, computed together.
struct UsageSummary {
    let days: [UsageDay]
    let sessions: [VoiceUsageSession]
    let rankedSessions: [VoiceUsageSession]
    let chartDays: [UsageDay]
    let buttonRanking: [(key: String, value: Int)]
    var pressCount: Int { days.reduce(0) { $0 + $1.count } }
    var voiceSeconds: Double { days.reduce(0) { $0 + $1.voiceSeconds } }
    var activeDays: Int { days.filter { $0.count > 0 || $0.voiceSeconds > 0 }.count }

    init(usage: LocalUsage, range: StatisticsRange, inputs: [ControllerInput] = RemoteProfiles.xiaomiRC003.inputs,
         now: Date = Date(), calendar: Calendar = .current) {
        let start: Date? = switch range {
        case .all: nil
        case .day: calendar.startOfDay(for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        }
        days = start.map { start in usage.days.filter { $0.date >= start } } ?? usage.days
        sessions = start.map { start in usage.sessions.filter { $0.date >= start } } ?? usage.sessions
        rankedSessions = Array(sessions.prefix(inputs.count))
        let count = range == .day ? 1 : 7
        let byDay = Dictionary(usage.days.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
        chartDays = (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - count + 1, to: calendar.startOfDay(for: now)) else { return nil }
            return byDay[date] ?? UsageDay(date: date)
        }
        var totals = Dictionary(uniqueKeysWithValues: inputs.map { ($0.rawValue, 0) })
        for day in days { for (key, count) in day.presses { totals[key, default: 0] += count } }
        buttonRanking = totals.filter { entry in inputs.contains { $0.rawValue == entry.key } }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }
}
