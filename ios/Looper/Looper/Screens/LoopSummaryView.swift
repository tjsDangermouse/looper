import LooperKit
import SwiftUI

/// The moment a loop is finished. Everything shown here is read from one
/// `LoopSummary` derived from the recorded outing — no figure is worked out
/// twice, and nothing is shown that wasn't actually measured.
struct LoopSummaryView: View {
    @ObservedObject var model: AppModel
    let summary: LoopSummary

    var body: some View {
        ZStack {
            Color.looperBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    status
                    map
                    headline
                    supporting
                    HealthSaveRow(model: model, state: summary.health)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .preferredColorScheme(.dark)
        .task { await model.health.refreshAvailability() }
    }

    // MARK: Status

    private var status: some View {
        VStack(spacing: 8) {
            Image(systemName: summary.activity == .running ? "figure.run" : "figure.walk")
                .font(.title2)
                .foregroundStyle(Color.looperOnAccent)
                .frame(width: 52, height: 52)
                .background(Color.looperAccent, in: Circle())
                .accessibilityHidden(true)

            Text(summary.status.title)
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text(loopSummaryHeadline(summary))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.status.title). \(loopSummaryHeadline(summary))")
    }

    private var map: some View {
        LoopSummaryMapView(planned: summary.plannedGeometry, track: summary.track)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.looperLine, lineWidth: 1)
            )
            .accessibilityElement()
            .accessibilityLabel(
                summary.hasReliableTrack
                    ? "Map of the route you walked, with the planned loop shown behind it."
                    : "Map of the planned loop."
            )
    }

    // MARK: The result itself

    private var headline: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                HeadlineMetric(
                    value: formatDistance(summary.distanceMeters, unit: summary.displayUnit),
                    label: "Distance",
                    spokenValue: formatDistance(summary.distanceMeters, unit: summary.displayUnit)
                )
                Divider().overlay(Color.looperLine)
                HeadlineMetric(
                    value: formatDuration(summary.durationSeconds),
                    label: "Time",
                    spokenValue: spokenDuration(summary.durationSeconds)
                )
            }

            if let pace = summary.paceSecondsPerKm {
                // Runs and walks both read as pace here, matching the
                // minutes-per-km/mile figure people already set in Settings;
                // speed appears alongside it as a supporting metric.
                Text("Average pace \(formatPace(pace, unit: summary.displayUnit))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.looperAccent)
                    .accessibilityLabel("Average pace, \(spokenPace(pace))")
            }

            if let target = targetLine {
                Text(target)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color.looperSheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// How the outing measured up against what was asked for — only for the
    /// kind of target that was actually set.
    private var targetLine: String? {
        switch summary.target {
        case .distance(let targetMeters, let delta):
            let goal = formatDistance(targetMeters, unit: summary.displayUnit)
            if abs(delta) < 50 { return "Right on your \(goal) target." }
            return delta > 0
                ? "\(formatDistance(delta, unit: summary.displayUnit)) past your \(goal) target."
                : "\(formatDistance(-delta, unit: summary.displayUnit)) short of your \(goal) target."
        case .time(let targetSeconds, let delta):
            let goal = formatTime(targetSeconds)
            if abs(delta) < 60 { return "Right on your \(goal) target." }
            return delta > 0
                ? "\(formatTime(abs(delta))) over your \(goal) target."
                : "\(formatTime(abs(delta))) under your \(goal) target."
        case nil:
            return nil
        }
    }

    // MARK: Supporting metrics — shown only where the data is real

    private var supporting: some View {
        let items = supportingItems
        return Group {
            if !items.isEmpty {
                HStack(spacing: 10) {
                    ForEach(items, id: \.label) { item in
                        VStack(spacing: 4) {
                            Text(item.value).font(.headline)
                            Text(item.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.looperRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.label), \(item.spoken)")
                    }
                }
            }
        }
    }

    private struct SupportingItem {
        var label: String
        var value: String
        var spoken: String
    }

    private var supportingItems: [SupportingItem] {
        var items: [SupportingItem] = []
        if let gain = summary.elevationGainMeters, gain >= 1 {
            items.append(
                SupportingItem(
                    label: "Elevation gain",
                    value: formatElevation(gain, unit: summary.displayUnit),
                    spoken: formatElevation(gain, unit: summary.displayUnit)
                )
            )
        }
        if let speed = summary.averageSpeedMetersPerSecond {
            items.append(
                SupportingItem(
                    label: "Average speed",
                    value: formatSpeed(speed, unit: summary.displayUnit),
                    spoken: formatSpeed(speed, unit: summary.displayUnit)
                )
            )
        }
        // No calories: the app has no honest figure for them, so it shows none.
        return items
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if let route = savableRoute {
                Button { model.toggleFavorite(route) } label: {
                    Text("Save this route").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(height: 48))
                .accessibilityHint("Keeps this loop in your saved routes")
            }
            Button { model.dismissSummary() } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    /// Offers the app's existing saved-routes feature, and only when the loop
    /// just walked is still the selected one and isn't saved already.
    private var savableRoute: Route? {
        guard let record = model.session, record.id == summary.sessionID,
              let route = model.selected, route.id == record.routeID else { return nil }
        return model.isFavorite(route) ? nil : route
    }

    private func spokenDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hours \(minutes) minutes" }
        return "\(minutes) minutes \(total % 60) seconds"
    }

    private func spokenPace(_ secondsPerKm: Double) -> String {
        let perUnit = summary.displayUnit == .km ? secondsPerKm : secondsPerKm / 0.621371
        let total = Int(perUnit.rounded())
        let unitName = summary.displayUnit == .km ? "kilometre" : "mile"
        return "\(total / 60) minutes \(total % 60) seconds per \(unitName)"
    }
}

/// The Apple Health line. Always secondary to the result above it — it never
/// blocks the summary, and it never claims more than it has done.
private struct HealthSaveRow: View {
    @ObservedObject var model: AppModel
    let state: HealthSaveState

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.looperSheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .saving:
            ProgressView().frame(width: 22)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.looperAccent)
                .frame(width: 22)
        case .savedOnWatch:
            Image(systemName: "applewatch")
                .foregroundStyle(Color.looperAccent)
                .frame(width: 22)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .frame(width: 22)
        case .notAttempted, .skipped:
            Image(systemName: "heart.text.square")
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }

    private var title: String {
        switch state {
        case .saving: return "Saving to Apple Health…"
        case .saved: return "Saved to Apple Health"
        case .savedOnWatch: return "Saved to Apple Health by your Apple Watch"
        case .failed: return "Couldn’t save to Apple Health"
        case .notAttempted, .skipped: return "Save future activities to Apple Health"
        }
    }

    private var detail: String? {
        switch state {
        case .failed(let message): return message
        case .skipped(let reason): return reason
        case .notAttempted:
            return model.health.availability == .denied
                ? "Health permissions are turned off for Looper."
                : "Your walks and runs appear alongside your other activity."
        case .savedOnWatch:
            // Said plainly, because "why is there only one workout?" is the
            // obvious question and the answer is the whole point.
            return "Your Watch recorded this one, including your heart rate, so Looper didn’t add a second workout."
        case .saving, .saved: return nil
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .saving, .saved, .savedOnWatch:
            EmptyView()
        case .failed:
            Button("Try again") { Task { await model.saveToHealth() } }
                .buttonStyle(TextLinkButtonStyle())
        case .notAttempted, .skipped:
            if model.health.availability == .denied {
                Button("Open Settings") { model.health.openSystemSettings() }
                    .buttonStyle(TextLinkButtonStyle())
            } else if model.health.availability == .unavailable {
                EmptyView()
            } else if model.health.isRequesting {
                ProgressView()
            } else {
                Button("Connect") { Task { await model.connectHealthAndSave() } }
                    .buttonStyle(TextLinkButtonStyle())
            }
        }
    }
}

/// One of the two figures the whole screen is really about — the distance and
/// the time. Sized to be read at a glance, and scaling with Dynamic Type.
private struct HeadlineMetric: View {
    let value: String
    let label: String
    let spokenValue: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(spokenValue)")
    }
}
