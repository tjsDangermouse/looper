import LooperKit
import SwiftUI

/// The workout, as three pages that never scroll: controls to the left,
/// metrics in the middle where the walk starts, guidance to the right. The
/// layout the wrist already knows from Apple's own workout app, so a glance
/// mid-run lands where it expects to.
struct WorkoutPages: View {
    @ObservedObject var model: WatchModel
    @State private var page: Page

    enum Page: Hashable { case controls, metrics, guidance }

    init(model: WatchModel) {
        self.model = model
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let previewingGuidance = environment["LOOPER_WATCH_PREVIEW"] == "guidance" || environment["LOOPER_WATCH_PAGE"] == "guidance"
        _page = State(initialValue: previewingGuidance ? .guidance : environment["LOOPER_WATCH_PAGE"] == "controls" ? .controls : .metrics)
        #else
        _page = State(initialValue: .metrics)
        #endif
    }

    var body: some View {
        TabView(selection: $page) {
            ControlsPage(model: model)
                .tag(Page.controls)
            MetricsPage(model: model)
                .tag(Page.metrics)
            GuidancePage(model: model)
                .tag(Page.guidance)
        }
        .tabViewStyle(.page)
    }
}

/// Pause/resume and end side by side at the top, every setting toggle below.
/// Route choices belong to the phone and the saved-routes list on the start
/// screen.
private struct ControlsPage: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if model.isPaused {
                    controlButton("Resume", systemImage: "play.fill", action: model.resume)
                        .tint(Color.looperAccent)
                        .foregroundStyle(Color.looperOnAccent)
                } else {
                    controlButton("Pause", systemImage: "pause.fill", action: model.pause)
                        .tint(Color.looperRaised)
                }
                controlButton("End", systemImage: "stop.fill", role: .destructive, action: model.end)
            }

            Toggle(isOn: $model.voiceOn) {
                Label("Voice", systemImage: model.voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.footnote)
            }
            .tint(Color.looperAccent)

            Toggle(isOn: $model.standaloneForced) {
                Label("Standalone", systemImage: "iphone.slash")
                    .font(.footnote)
            }
            .tint(Color.looperAccent)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func controlButton(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
    }
}

/// The screen the walk actually happens on. One big number, three supporting
/// ones, and a ring for how far round the loop they are. The adjacent guidance
/// page owns the map, keeping this page readable at a glance.
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

            if model.guidanceOnly {
                Label("Guidance only · Health recording off", systemImage: "heart.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: model.activity == .running ? "figure.run" : "figure.walk")
            Text(model.activity == .running ? "Run" : "Walk")
            if model.isPaused {
                Text("· Paused").foregroundStyle(Color.looperAccent)
            }
            Spacer()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var unit: LooperKit.Unit { model.plan?.displayUnit ?? .km }

    /// The distance the Watch has followed the route for, or what its own
    /// sensors have measured if that is further. Always the Watch's own
    /// figure, so the screen reads the same with or without a phone.
    private var distanceMeters: Double {
        max(model.state?.distanceMeters ?? 0, model.workout.localDistanceMeters)
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

/// How far round the loop, as a compact complement to the full-screen map on
/// the guidance page.
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
