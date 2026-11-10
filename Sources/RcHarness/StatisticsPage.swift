import Charts
import SwiftUI

enum StatisticsRange: String, CaseIterable, Identifiable {
    case day, lastSevenDays, all
    var id: String { rawValue }
    var title: String {
        switch self { case .day: "今天"; case .lastSevenDays: "最近 7 天"; case .all: "全部" }
    }
}

/// Observes only the usage store, so it is the only view that re-renders
/// when a press or voice session is recorded.
struct StatisticsPage: View {
    @ObservedObject var store: UsageStore
    let range: StatisticsRange

    var body: some View {
        // Derive every figure once per render instead of once per use.
        let summary = UsageSummary(usage: store.usage, range: range)
        let recordedButtons = summary.buttonRanking.filter { $0.value > 0 }
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.groups) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(range.title) · \(summary.dateRangeLabel)")
                    .font(SettingsStyle.Typography.body.weight(.medium))
                Text("所有遥控器累计 · 同名按键合并，不区分型号；以下指标、图表与排行使用同一范围。")
                    .font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SettingsStyle.Spacing.controls) {
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
                HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
                    usageChart(summary, voice: false)
                    usageChart(summary, voice: true)
                }
                HStack(alignment: .top, spacing: SettingsStyle.Spacing.groups) {
                    SettingsPanel("按键使用排行 · 全部按键", symbol: "chart.bar.xaxis") {
                        if recordedButtons.isEmpty {
                            Text("此时间范围内还没有按键记录").font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: SettingsStyle.Spacing.inline) {
                                ForEach(Array(recordedButtons.enumerated()), id: \.element.key) { index, entry in
                                    HStack {
                                        rank(index)
                                        Text(ControllerInput(rawValue: entry.key)?.label ?? entry.key).font(SettingsStyle.Typography.body)
                                        Spacer()
                                        Text("\(entry.value) 次").font(.system(size: 12, design: .monospaced))
                                    }.frame(minHeight: 24)
                                }
                            }
                        }
                    }
                    SettingsPanel("单次语音时长排行 · 前 \(UsageSummary.voiceRankingLimit) 次", symbol: "waveform") {
                        if summary.rankedSessions.isEmpty {
                            Text("此时间范围内还没有语音记录").font(.callout).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: SettingsStyle.Spacing.inline) {
                                ForEach(Array(summary.rankedSessions.enumerated()), id: \.element.id) { index, session in
                                    HStack {
                                        rank(index)
                                        Text(duration(session.seconds)).fontWeight(.semibold).monospacedDigit()
                                        Spacer()
                                        Text(session.date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                                    }.font(SettingsStyle.Typography.caption).frame(minHeight: 24)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsStyle.Spacing.controls) {
            Text(title).font(SettingsStyle.Typography.body).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(SettingsStyle.panelPadding)
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

    private func usageChart(_ summary: UsageSummary, voice: Bool) -> some View {
        let buckets = summary.chartBuckets
        return SettingsPanel {
            HStack(spacing: SettingsStyle.Spacing.inline) {
                Image(systemName: voice ? "waveform" : "circle.dotted")
                    .foregroundStyle(voice ? Color.orange : .blue)
                Text(voice ? "语音时长" : "按键次数").font(SettingsStyle.Typography.panelTitle)
                Spacer(minLength: 8)
                Text(summary.chartResolution.title).font(SettingsStyle.Typography.caption).foregroundStyle(.secondary)
            }
            if buckets.contains(where: { voice ? $0.voiceSeconds > 0 : $0.count > 0 }) {
                chart(buckets, resolution: summary.chartResolution, voice: voice)
            } else {
                Text("此时间范围内还没有\(voice ? "语音" : "按键")记录")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 185)
            }
        }
    }

    private func chart(_ days: [UsageDay], resolution: UsageChartResolution, voice: Bool) -> some View {
        Chart(days) { day in
            BarMark(x: .value("日期", day.date, unit: resolution.component), y: .value(voice ? "秒" : "次", voice ? day.voiceSeconds : Double(day.count)), width: .ratio(0.55))
                .foregroundStyle(voice ? Color.orange : Color.blue).cornerRadius(4)
                .annotation(position: .top, spacing: 4) {
                    if days.count <= 14 {
                        Text(voice ? "\(day.voiceSeconds.formatted(.number.precision(.fractionLength(0...1))))秒" : "\(day.count)")
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
        }
        .chartYScale(domain: 0...max(1, days.map { voice ? $0.voiceSeconds : Double($0.count) }.max() ?? 0),
                     range: .plotDimension(endPadding: 24))
        .chartXAxis {
            AxisMarks(values: .stride(by: resolution.component, count: max(1, (days.count + 6) / 7))) { _ in
                AxisValueLabel(format: resolution.axisFormat, centered: true)
            }
        }
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

enum UsageChartResolution {
    case day, month, year

    var component: Calendar.Component {
        switch self { case .day: .day; case .month: .month; case .year: .year }
    }

    var title: String {
        switch self { case .day: "按天汇总"; case .month: "按月汇总"; case .year: "按年汇总" }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .day: .dateTime.month().day()
        case .month: .dateTime.year().month(.twoDigits)
        case .year: .dateTime.year()
        }
    }
}

/// One calendar window and device scope feed every metric, chart and ranking.
/// History has no remote identity; all known and legacy input keys remain visible.
struct UsageSummary {
    static let voiceRankingLimit = 15
    let days: [UsageDay]
    let sessions: [VoiceUsageSession]
    let rankedSessions: [VoiceUsageSession]
    let chartBuckets: [UsageDay]
    let chartResolution: UsageChartResolution
    let startDate: Date
    let endDate: Date
    let dateRangeLabel: String
    let buttonRanking: [(key: String, value: Int)]
    var pressCount: Int { days.reduce(0) { $0 + $1.count } }
    var voiceSeconds: Double { days.reduce(0) { $0 + $1.voiceSeconds } }
    var activeDays: Int { days.filter { $0.count > 0 || $0.voiceSeconds > 0 }.count }

    init(usage: LocalUsage, range: StatisticsRange, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let availableDays = usage.days.filter { calendar.startOfDay(for: $0.date) <= today }
        let availableSessions = usage.sessions.filter { $0.date <= now }
        let firstRecord = (availableDays.map(\.date) + availableSessions.map(\.date)).min() ?? today
        let start: Date = switch range {
        case .all: calendar.startOfDay(for: firstRecord)
        case .day: today
        case .lastSevenDays: calendar.date(byAdding: .day, value: -6, to: today) ?? today
        }
        startDate = start
        endDate = today
        var dateFormat = Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits)
        dateFormat.calendar = calendar
        dateFormat.timeZone = calendar.timeZone
        let firstLabel = start.formatted(dateFormat)
        let lastLabel = today.formatted(dateFormat)
        dateRangeLabel = start == today ? firstLabel : firstLabel + " – " + lastLabel

        // Normalize and merge days before deriving totals, including legacy data.
        var byDay: [Date: UsageDay] = [:]
        for day in availableDays {
            let date = calendar.startOfDay(for: day.date)
            guard date >= start else { continue }
            var total = byDay[date] ?? UsageDay(date: date)
            for (key, count) in day.presses { total.presses[key, default: 0] += count }
            total.voiceSeconds += day.voiceSeconds
            byDay[date] = total
        }
        days = byDay.values.sorted { $0.date < $1.date }
        sessions = availableSessions.filter { $0.date >= start }.sorted {
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        rankedSessions = Array(sessions.prefix(Self.voiceRankingLimit))

        let dayCount = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        chartResolution = dayCount > 366 ? .year : dayCount > 31 ? .month : .day
        let component = chartResolution.component
        var grouped: [Date: UsageDay] = [:]
        for day in days {
            let date = calendar.dateInterval(of: component, for: day.date)?.start ?? day.date
            var bucket = grouped[date] ?? UsageDay(date: date)
            for (key, count) in day.presses { bucket.presses[key, default: 0] += count }
            bucket.voiceSeconds += day.voiceSeconds
            grouped[date] = bucket
        }
        var buckets: [UsageDay] = []
        var date = calendar.dateInterval(of: component, for: start)?.start ?? start
        while date <= today {
            buckets.append(grouped[date] ?? UsageDay(date: date))
            guard let next = calendar.date(byAdding: component, value: 1, to: date), next > date else { break }
            date = next
        }
        chartBuckets = buckets

        var totals = Dictionary(uniqueKeysWithValues: ControllerInput.allCases.map { ($0.rawValue, 0) })
        for day in days { for (key, count) in day.presses { totals[key, default: 0] += count } }
        buttonRanking = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    }
}
