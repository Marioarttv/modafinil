import AppKit
import ModafinilShared
import SwiftUI

/// A rounded content panel used throughout the main window.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

/// A compact metric with a title, value and optional footnote.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String
    var tint: Color = .accentColor
    var action: (() -> Void)?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(tint: tint))
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Large circular status symbol with a soft tinted background.
struct StatusBadge: View {
    let tone: AppSnapshot.Tone
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().fill(tone.color.opacity(tone == .off ? 0.12 : 0.18))
            Image(systemName: tone.symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tone == .off ? Color.secondary : tone.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Small coloured capsule, e.g. "Listening".
struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
    }
}

/// A thin 24-hour strip of power states, drawn with Canvas (no chart overhead).
struct MiniTimeline: View {
    let segments: [PowerSegment]
    let from: Date
    let to: Date

    var body: some View {
        Canvas { context, size in
            let span = max(1, to.timeIntervalSince(from))
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                         with: .color(Color.gray.opacity(0.2)))
            for segment in segments {
                let x = (segment.start - from.timeIntervalSince1970) / span * size.width
                let width = max(1, segment.duration / span * size.width)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                             with: .color(UIFormat.stateColor(segment.state)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityLabel("Power states over the last 24 hours")
    }
}

/// App icon for a blocking process, when it is a regular app.
struct ProcessIcon: View {
    let pid: Int32

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "gearshape.2")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }
}

extension SleepBlocker.Effect {
    var color: Color {
        switch self {
        case .systemSleep: return .red
        case .idleSleep: return .orange
        case .display: return .yellow
        case .background: return .secondary
        case .userActive: return .blue
        }
    }
}
