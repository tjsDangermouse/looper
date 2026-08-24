import LooperKit
import SwiftUI

/// The loop the phone last prepared, and one button. Everything on this
/// screen is something the walker chose on the phone — the Watch offers no
/// second way to plan a route.
struct StartLoopView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let plan = model.plan {
                    Label(plan.activity == .running ? "Run" : "Walk",
                          systemImage: plan.activity == .running ? "figure.run" : "figure.walk")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.looperAccent)

                    Text(plan.routeName)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    Text(plan.targetDescription)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(plan.mode == .distance ? "target distance" : "target time")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button(action: model.startFromWatch) {
                        if model.starting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Start")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .tint(Color.looperAccent)
                    .foregroundStyle(Color.looperOnAccent)
                    .disabled(model.starting)
                    .padding(.top, 4)
                    .accessibilityLabel("Start \(plan.activity == .running ? "run" : "walk"), \(plan.routeName), \(plan.targetDescription)")

                    // Said before the walk rather than after it goes wrong:
                    // this release navigates from the phone, and the Watch
                    // never pretends otherwise.
                    Text("Turn-by-turn guidance comes from your iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // The reason for the permission sheet, on screen before
                    // the sheet is. Plain, and no broader than the truth:
                    // this records the walk you chose, and shows your heart
                    // rate while you do it.
                    if model.workout.needsAuthorization {
                        Text("Starting asks Apple Health for permission to record this \(plan.activity == .running ? "run" : "walk") and show your heart rate.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
