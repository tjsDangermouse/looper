import LooperKit
import SwiftUI

/// The workout, as three pages that never scroll: controls to the left,
/// metrics in the middle where the walk starts, guidance to the right. The
/// layout the wrist already knows from Apple's own workout app, so a glance
/// mid-run lands where it expects to.
struct WorkoutPages: View {
    @ObservedObject var model: WatchModel
    @State private var page = Page.metrics

    enum Page: Hashable { case controls, metrics, guidance }

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(model: model)
                .tag(Page.controls)
            MetricsPage(model: model)
                .tag(Page.metrics)
            GuidancePage(model: model, isVisible: page == .guidance)
                .tag(Page.guidance)
        }
        .tabViewStyle(.page)
    }
}

/// Pause, resume, end. Nothing else — every other decision belongs on the
/// phone.
private struct ControlsPage: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(spacing: 12) {
            if model.workout.phase == .paused {
                Button(action: model.resume) {
                    Label("Resume", systemImage: "play.fill")
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
                .tint(Color.looperAccent)
                .foregroundStyle(Color.looperOnAccent)
            } else {
                Button(action: model.pause) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
                .tint(Color.looperRaised)
            }

            Button(role: .destructive, action: model.end) {
                Label("End", systemImage: "stop.fill")
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)
        }
        .font(.headline)
        .padding(.horizontal, 4)
    }
}

/// The screen the walk actually happens on. One big number, three supporting
/// ones, and a ring for how far round the loop they are.
private struct MetricsPage: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(distanceText)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.looperAccent)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ProgressRing(fraction: model.state?.progressFraction ?? 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Distance covered, \(distanceText). \(Int(((model.state?.progressFraction ?? 0) * 100).rounded())) percent of the loop.")

            Text(targetLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityLabel(targetLine)

            Divider().overlay(Color.white.opacity(0.15))

            HStack(alignment: .top, spacing: 10) {
                Metric(value: formatDuration(elapsed), label: "Time")
                Metric(value: paceText, label: "Pace")
                Metric(value: heartText, label: "BPM", tint: model.workout.heartRate == nil ? nil : .looperHeart)
            }

            if !model.isPhoneLive {
                Label("iPhone not connected", systemImage: "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("iPhone not connected. Distance and time are measured on your Watch.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: model.activity == .running ? "figure.run" : "figure.walk")
            Text(model.activity == .running ? "Run" : "Walk")
            if model.workout.phase == .paused {
                Text("· Paused").foregroundStyle(Color.looperAccent)
            }
            Spacer()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var unit: LooperKit.Unit { model.plan?.displayUnit ?? .km }

    /// The phone's recorded distance while it is being heard from; the
    /// Watch's own once it isn't. Which of the two is on screen is never left
    /// ambiguous — the "iPhone not connected" line below says so.
    private var distanceMeters: Double {
        if model.isPhoneLive, let state = model.state { return state.distanceMeters }
        return model.workout.localDistanceMeters
    }

    private var distanceText: String { formatDistance(distanceMeters, unit: unit) }

    private var elapsed: Double {
        model.workout.elapsedSeconds > 0 ? model.workout.elapsedSeconds : (model.state?.elapsedSeconds ?? 0)
    }

    private var targetLine: String {
        guard let plan = model.plan else { return "" }
        let remaining = model.state?.remainingMeters
        let target = plan.mode == .distance
            ? "Target \(plan.targetDescription)"
            : "Loop \(formatDistance(plan.plannedDistanceMeters, unit: unit))"
        guard let remaining else { return target }
        return "\(target) · \(formatDistance(remaining, unit: unit)) to go"
    }

    private var paceText: String {
        // Walking and running are both read as minutes per kilometre or mile
        // here, which is the same pace the phone's own settings are kept in.
        guard let pace = livePace else { return "—" }
        return formatPace(pace, unit: unit).replacingOccurrences(of: " /\(unit == .km ? "km" : "mi")", with: "")
    }

    private var livePace: Double? {
        if model.isPhoneLive, let pace = model.state?.paceSecondsPerKm { return pace }
        guard distanceMeters >= 100, elapsed >= 60 else { return nil }
        return elapsed / (distanceMeters / 1000)
    }

    private var heartText: String {
        guard let rate = model.workout.heartRate else { return "—" }
        return "\(Int(rate.rounded()))"
    }
}

/// One of the three small figures under the headline.
private struct Metric: View {
    let value: String
    let label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint ?? .primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value == "—" ? "not available" : value)")
    }
}

/// How far round the whole loop, as a ring. The guidance page owns the
/// street-scale map around the next turn; this page keeps the outing's overall
/// progress glanceable instead of squeezing the entire loop into 2 cm.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Color.looperAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}
