import ModafinilShared
import SwiftUI

/// The compact card shown from the menu bar icon.
struct MenuBarPopoverView: View {
    @EnvironmentObject private var model: AppUIModel

    private static let presets: [(String, Int)] = [("15 minutes", 15), ("30 minutes", 30), ("1 hour", 60),
                                                    ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)]

    var body: some View {
        let snapshot = model.snapshot
        let now = Date()
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatusBadge(tone: snapshot.tone, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title).font(.headline)
                    Text(snapshot.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Keep awake", isOn: Binding(
                    get: { snapshot.isKeepAwakeRequested },
                    set: { _ in model.actions?.uiToggleKeepAwake() }))
                    .toggleStyle(.switch)
                    .tint(.green)
                    .labelsHidden()
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("popoverKeepAwake")
            }

            if let error = snapshot.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            VStack(spacing: 10) {
                row("Sleep timer", symbol: "moon.zzz.fill", tint: .indigo) {
                    if let date = snapshot.scheduledSleepDate, date > now {
                        Text(timerInterval: now...date, countsDown: true).monospacedDigit()
                        Button { model.actions?.uiCancelSleepTimer() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Cancel sleep timer")
                    } else {
                        Menu("Off") {
                            ForEach(Self.presets, id: \.1) { title, minutes in
                                Button("Sleep in \(title)") { model.actions?.uiScheduleSleep(after: minutes * 60) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!snapshot.canScheduleSleep)
                    }
                }
                row("Wake alarm", symbol: "alarm.fill", tint: .orange) {
                    Text(snapshot.scheduledWakeDate.map(UIFormat.dayAndTime) ?? "Off")
                        .foregroundStyle(.secondary)
                }
                row("iPhone", symbol: "iphone", tint: .blue) {
                    Text(snapshot.companionStatus).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last 24 hours").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    let important = snapshot.blockers.filter { $0.effect < .background }.count
                    if important > 0 {
                        Text("\(important) app\(important == 1 ? "" : "s") affecting sleep")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                MiniTimeline(segments: model.timeline(from: dayAgo, to: now).segments, from: dayAgo, to: now)
                    .frame(height: 10)
            }

            Divider()

            HStack {
                Button("Open Modafinil…") { model.actions?.uiOpenMainWindow(.overview) }
                Button("History") { model.actions?.uiOpenMainWindow(.history) }
                Spacer()
                Button { model.actions?.uiQuit() } label: { Image(systemName: "power") }
                    .help("Quit Modafinil")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row<Trailing: View>(_ title: String, symbol: String, tint: Color,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            Text(title)
            Spacer()
            trailing()
        }
        .font(.callout)
    }
}
