import Charts
import ModafinilShared
import SwiftUI

struct HistoryPage: View {
    @EnvironmentObject private var model: AppUIModel
    @State private var range: RangeKind = .last24Hours
    @State private var dayOffset = 0
    @State private var data = Loaded()

    enum RangeKind: String, CaseIterable, Identifiable {
        case last24Hours = "24 Hours", last7Days = "7 Days", day = "Day"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let id: String
        let start: Date
        let end: Date?
        let state: PowerSegment.State?
        let text: String
    }

    struct Loaded {
        var from = Date()
        var to = Date()
        var segments: [PowerSegment] = []
        var markers: [PowerMarker] = []
        var summary = PowerSummary()
        var rows: [Row] = []
    }

    var body: some View {
        Page {
            controls
            summaryTiles
            Card(title: "Timeline", symbol: "chart.bar.xaxis") {
                timelineChart
                legend
            }
            if !data.summary.wakeCauses.isEmpty { causesCard }
            eventsCard
            Text("Modafinil records only when the Mac goes to sleep or wakes up, so the time in between is shown as asleep. It does no work while the Mac sleeps. Grey means Modafinil was not running.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onChange(of: range) { _ in reload() }
        .onChange(of: dayOffset) { _ in reload() }
        .onChange(of: model.historyRevision) { _ in reload() }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $range) {
                ForEach(RangeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            if range == .day {
                Button { dayOffset = min(6, dayOffset + 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(dayOffset >= 6)
                Text(dayTitle).font(.headline).frame(minWidth: 120)
                Button { dayOffset = max(0, dayOffset - 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(dayOffset == 0)
            }
            Spacer()
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private var dayTitle: String {
        let day = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!
        if dayOffset == 0 { return "Today" }
        if dayOffset == 1 { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private var summaryTiles: some View {
        let summary = data.summary
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatTile(title: "Asleep", value: UIFormat.duration(summary.asleep), symbol: "moon.fill", tint: .indigo)
            StatTile(title: "Background", value: UIFormat.duration(summary.background),
                     detail: "\(summary.backgroundWakes) wake\(summary.backgroundWakes == 1 ? "" : "s")"
                        + (summary.longestBackground >= 300 ? ", longest \(UIFormat.duration(summary.longestBackground))" : ""),
                     symbol: "moon.haze.fill", tint: .orange)
            StatTile(title: "Awake", value: UIFormat.duration(summary.awake), symbol: "sun.max.fill", tint: .green)
            if summary.unknown >= 60 {
                StatTile(title: "No data", value: UIFormat.duration(summary.unknown),
                         detail: "Modafinil was not running", symbol: "questionmark.circle", tint: .gray)
            }
        }
    }

    private var timelineChart: some View {
        Chart {
            ForEach(Array(data.segments.enumerated()), id: \.offset) { _, segment in
                RectangleMark(
                    xStart: .value("Start", Date(timeIntervalSince1970: segment.start)),
                    xEnd: .value("End", Date(timeIntervalSince1970: segment.end)),
                    y: .value("Track", "Power")
                )
                .foregroundStyle(UIFormat.stateColor(segment.state))
            }
            ForEach(Array(data.markers.enumerated()), id: \.offset) { _, marker in
                RuleMark(x: .value("Action", Date(timeIntervalSince1970: marker.at)))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .chartXScale(domain: data.from...max(data.to, data.from.addingTimeInterval(60)))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: axisTicks) { _ in
                AxisGridLine()
                AxisValueLabel(format: range == .last7Days
                               ? .dateTime.weekday(.abbreviated)
                               : .dateTime.hour().minute())
            }
        }
        .frame(height: 90)
        .accessibilityLabel("Timeline of awake, background wake and asleep periods")
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach([PowerSegment.State.awake, .background, .asleep, .unknown], id: \.self) { state in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(UIFormat.stateColor(state)).frame(width: 12, height: 12)
                    Text(UIFormat.stateTitle(state)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: 12)
                Text("Modafinil action").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var causesCard: some View {
        let causes = data.summary.wakeCauses.sorted { $0.value > $1.value }
        return Card(title: "Why the Mac woke", symbol: "bolt.fill") {
            Chart(causes, id: \.key) { cause in
                BarMark(x: .value("Wakes", cause.value), y: .value("Cause", cause.key.title))
                    .foregroundStyle(cause.key.isHousekeeping ? Color.orange : Color.accentColor)
                    .annotation(position: .trailing) {
                        Text("\(cause.value)×").font(.caption).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(causes.count) * 28 + 8)
            Text("macOS maintenance and background tasks are scheduled by macOS, mostly on power. They are not caused by Modafinil.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var eventsCard: some View {
        Card(title: "Events", symbol: "list.bullet") {
            if data.rows.isEmpty {
                Text("Nothing recorded in this period yet.").foregroundStyle(.secondary)
            } else {
                Table(data.rows) {
                    TableColumn("Time") { row in
                        Text(row.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .monospacedDigit()
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("Length") { row in
                        Text(row.end.map { UIFormat.duration($0.timeIntervalSince(row.start)) } ?? "")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("State") { row in
                        if let state = row.state {
                            HStack(spacing: 6) {
                                Circle().fill(UIFormat.stateColor(state)).frame(width: 8, height: 8)
                                Text(UIFormat.stateTitle(state))
                            }
                        } else {
                            Label("Modafinil", systemImage: "eye.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("Why") { row in
                        Text(row.text).help(row.text)
                    }
                }
                .frame(minHeight: 260, idealHeight: 360)
            }
        }
    }

    /// Whole hours (every 3 h) or midnights, kept away from the edges so labels are not clipped.
    private var axisTicks: [Date] {
        let calendar = Calendar.current
        let span = data.to.timeIntervalSince(data.from)
        let margin = span * 0.05
        var ticks: [Date] = []
        if range == .last7Days {
            var day = calendar.startOfDay(for: data.from)
            while day < data.to {
                if day.timeIntervalSince(data.from) >= margin, data.to.timeIntervalSince(day) >= margin { ticks.append(day) }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        } else {
            var hour = calendar.dateInterval(of: .hour, for: data.from)?.start ?? data.from
            while hour < data.to {
                if calendar.component(.hour, from: hour) % 3 == 0,
                   hour.timeIntervalSince(data.from) >= margin, data.to.timeIntervalSince(hour) >= margin {
                    ticks.append(hour)
                }
                hour = hour.addingTimeInterval(3600)
            }
        }
        return ticks
    }

    private var selectedRange: (Date, Date) {
        let now = Date()
        switch range {
        case .last24Hours: return (now.addingTimeInterval(-24 * 3600), now)
        case .last7Days: return (now.addingTimeInterval(-7 * 24 * 3600), now)
        case .day:
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -dayOffset, to: now)!)
            return (start, min(now, calendar.date(byAdding: .day, value: 1, to: start)!))
        }
    }

    private func reload() {
        let (from, to) = selectedRange
        let timeline = model.timeline(from: from, to: to)
        var rows: [Row] = timeline.segments.enumerated().map { index, segment in
            Row(id: "s\(index)", start: Date(timeIntervalSince1970: segment.start),
                end: Date(timeIntervalSince1970: segment.end), state: segment.state, text: segment.reason)
        }
        rows += timeline.markers.enumerated().map { index, marker in
            Row(id: "m\(index)", start: Date(timeIntervalSince1970: marker.at), end: nil, state: nil, text: marker.text)
        }
        data = Loaded(from: from, to: to, segments: timeline.segments, markers: timeline.markers,
                      summary: PowerTimeline.summarize(timeline.segments),
                      rows: rows.sorted { $0.start > $1.start })
    }
}
