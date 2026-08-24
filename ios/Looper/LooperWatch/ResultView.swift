import LooperKit
import SwiftUI

/// The glance you get when you stop: how it went, four figures, and Done.
/// The full Loop Summary — the map, the target comparison, Apple Health —
/// stays on the phone, where there is room for it.
struct ResultView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let result = model.result {
                    Text(result.status.title)
                        .font(.headline)
                        .foregroundStyle(result.status == .complete ? Color.looperAccent : .primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Row(label: "Distance", value: formatDistance(result.distanceMeters, unit: result.displayUnit))
                    Row(label: "Time", value: formatDuration(result.durationSeconds))
                    Row(label: "Pace", value: result.paceSecondsPerKm.map { formatPace($0, unit: result.displayUnit) } ?? "—")
                    if let heart = result.averageHeartRate {
                        Row(label: "Avg heart rate", value: "\(Int(heart.rounded())) bpm")
                    }

                    Button("Done", action: model.dismissResult)
                        .tint(Color.looperAccent)
                        .foregroundStyle(Color.looperOnAccent)
                        .font(.headline)
                        .padding(.top, 4)
                }

                if let notice = model.notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Row: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value == "—" ? "not available" : value)")
    }
}
