import AppKit
import ModafinilShared

/// Shows when the Mac was awake, in a background wake, or asleep, and why.
/// It reads the recorder's in-memory events only when opened or refreshed.
final class SleepHistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Timeline = (segments: [PowerSegment], markers: [PowerMarker])

    var loadTimeline: ((Date, Date) -> Timeline)?
    var onClose: (() -> Void)?

    private struct Row {
        let start: Date
        let end: Date?
        let state: String
        let reason: String
        let color: NSColor
    }

    private let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let causesLabel = NSTextField(wrappingLabelWithString: "")
    private let timelineView = PowerTimelineView()
    private let tableView = NSTableView()
    private var rows: [Row] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sleep History"
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ModafinilSleepHistoryWindow")
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        if !window.setFrameUsingName("ModafinilSleepHistoryWindow") { window.center() }
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func buildContent(in window: NSWindow) {
        let content = NSView()
        window.contentView = content

        let calendar = Calendar.current
        rangePopup.addItems(withTitles: ["Last 24 hours", "Last 7 days"])
        for offset in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -offset, to: Date())!
            let title = offset == 0 ? "Today" : offset == 1 ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            rangePopup.addItem(withTitle: title)
        }
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(rangeChanged))
        refreshButton.bezelStyle = .rounded
        let header = NSStackView(views: [rangePopup, refreshButton])
        header.spacing = 8

        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        causesLabel.font = .systemFont(ofSize: 12)
        causesLabel.textColor = .secondaryLabelColor

        let legend = NSTextField(wrappingLabelWithString:
            "Green: awake · Orange: background wake (display off) · Indigo: asleep · Grey: no data. "
            + "Modafinil records only when the Mac goes to sleep or wakes up, so the time between is shown as asleep. "
            + "It does no work while the Mac sleeps.")
        legend.font = .systemFont(ofSize: 11)
        legend.textColor = .secondaryLabelColor

        timelineView.translatesAutoresizingMaskIntoConstraints = false
        timelineView.heightAnchor.constraint(equalToConstant: 44).isActive = true

        for (identifier, title, width) in [("time", "Time", 190.0), ("length", "Length", 90.0),
                                           ("state", "State", 130.0), ("reason", "Why", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.resizingMask = identifier == "reason" ? .autoresizingMask : .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [header, summaryLabel, causesLabel, timelineView, legend, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            timelineView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            causesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            legend.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func rangeChanged() { reload() }

    private var selectedRange: (Date, Date) {
        let now = Date()
        let calendar = Calendar.current
        switch rangePopup.indexOfSelectedItem {
        case 0: return (now.addingTimeInterval(-24 * 3600), now)
        case 1: return (now.addingTimeInterval(-7 * 24 * 3600), now)
        default:
            let offset = rangePopup.indexOfSelectedItem - 2
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!)
            let end = min(now, calendar.date(byAdding: .day, value: 1, to: start)!)
            return (start, end)
        }
    }

    func reload() {
        guard let loadTimeline else { return }
        let (from, to) = selectedRange
        let timeline = loadTimeline(from, to)
        timelineView.update(segments: timeline.segments, markers: timeline.markers,
                            from: from.timeIntervalSince1970, to: to.timeIntervalSince1970)

        let summary = PowerTimeline.summarize(timeline.segments)
        func text(_ seconds: Double) -> String { Self.duration(seconds) }
        var parts = ["Asleep \(text(summary.asleep))",
                     "Background \(text(summary.background)) (\(summary.backgroundWakes) wake\(summary.backgroundWakes == 1 ? "" : "s"))",
                     "Awake \(text(summary.awake))"]
        if summary.unknown >= 60 { parts.append("No data \(text(summary.unknown))") }
        summaryLabel.stringValue = parts.joined(separator: " · ")
        let causes = summary.wakeCauses.sorted { $0.value > $1.value }
            .map { "\($0.key.title) \($0.value)×" }.joined(separator: ", ")
        var causeText = causes.isEmpty ? "No wakes recorded in this period." : "Wake causes: \(causes)."
        if summary.longestBackground >= 300 {
            causeText += " Longest background wake: \(text(summary.longestBackground)) (macOS background work such as indexing or photo analysis)."
        }
        causesLabel.stringValue = causeText

        var newRows: [Row] = timeline.segments.map { segment in
            Row(start: Date(timeIntervalSince1970: segment.start), end: Date(timeIntervalSince1970: segment.end),
                state: Self.stateTitle(segment.state), reason: segment.reason, color: PowerTimelineView.color(segment.state))
        }
        newRows += timeline.markers.map {
            Row(start: Date(timeIntervalSince1970: $0.at), end: nil, state: "Modafinil", reason: $0.text, color: .controlAccentColor)
        }
        rows = newRows.sorted { $0.start > $1.start }
        tableView.reloadData()
    }

    static func stateTitle(_ state: PowerSegment.State) -> String {
        switch state {
        case .awake: return "Awake"
        case .background: return "Background wake"
        case .asleep: return "Asleep"
        case .unknown: return "No data"
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        switch identifier {
        case "time":
            let start = item.start.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
            label.stringValue = item.end.map { "\(start) – \($0.formatted(date: .omitted, time: .shortened))" } ?? start
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "length":
            label.stringValue = item.end.map { Self.duration($0.timeIntervalSince(item.start)) } ?? ""
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "state":
            label.stringValue = item.state
            label.textColor = item.color
            label.font = .systemFont(ofSize: 12, weight: .medium)
        default:
            label.stringValue = item.reason
            label.toolTip = item.reason
        }
        return label
    }
}

final class PowerTimelineView: NSView {
    private var segments: [PowerSegment] = []
    private var markers: [PowerMarker] = []
    private var from: Double = 0
    private var to: Double = 1

    static func color(_ state: PowerSegment.State) -> NSColor {
        switch state {
        case .awake: return .systemGreen
        case .background: return .systemOrange
        case .asleep: return .systemIndigo
        case .unknown: return .tertiaryLabelColor
        }
    }

    func update(segments: [PowerSegment], markers: [PowerMarker], from: Double, to: Double) {
        self.segments = segments; self.markers = markers
        self.from = from; self.to = max(from + 1, to)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: 16, width: bounds.width, height: bounds.height - 16)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        let scale = bounds.width / (to - from)
        for segment in segments {
            let x = (segment.start - from) * scale
            let width = max(1, (segment.end - segment.start) * scale)
            Self.color(segment.state).setFill()
            NSRect(x: x, y: bar.minY, width: width, height: bar.height).fill()
        }
        NSColor.labelColor.withAlphaComponent(0.7).setFill()
        for marker in markers {
            NSRect(x: (marker.at - from) * scale, y: bar.maxY - 6, width: 1.5, height: 6).fill()
        }
        // Tick labels: hours for a day or less, days for longer ranges.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let span = to - from
        let step: Double = span > 2 * 24 * 3600 ? 24 * 3600 : 6 * 3600
        let calendar = Calendar.current
        var tick = calendar.startOfDay(for: Date(timeIntervalSince1970: from)).timeIntervalSince1970
        while tick < from { tick += step }
        while tick < to {
            let x = (tick - from) * scale
            NSColor.separatorColor.setFill()
            NSRect(x: x, y: bar.minY, width: 1, height: bar.height).fill()
            let date = Date(timeIntervalSince1970: tick)
            let label = step >= 24 * 3600 ? date.formatted(.dateTime.weekday(.abbreviated))
                : date.formatted(date: .omitted, time: .shortened)
            (label as NSString).draw(at: NSPoint(x: x + 2, y: 1), withAttributes: attributes)
            tick += step
        }
    }
}
