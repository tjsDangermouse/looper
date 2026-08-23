import LooperKit
import SwiftUI

struct WalkView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Button(action: model.endWalk) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())

                Button(action: model.returnHome) {
                    Image(systemName: "house.fill")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Home")

                Spacer()

                Button {
                    model.following = true
                } label: {
                    Image(systemName: "location.fill")
                }
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(model.following ? Color.looperAccent : .white)

                Button {
                    model.toggleCourseUp()
                } label: {
                    Image(systemName: "location.north.line.fill")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!model.compassAvailable)
                .foregroundStyle(model.courseUp ? Color.looperAccent : .white)

                Button(action: model.toggleMute) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(model.muted ? .secondary : Color.looperAccent)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if !model.locationState.isEmpty {
                Text(model.locationState)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }

            Spacer()

            BottomSheet {
                if model.offRoute {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("You’re off the planned loop").font(.headline)
                        Text("Get back to the route, or finish this walk.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Show route from here") { model.offRoute = false }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(PrimaryButtonStyle(height: 46))
                        Button("End walk", action: model.endWalk)
                            .buttonStyle(TextLinkButtonStyle())
                    }
                } else if let selected = model.selected {
                    let turn = model.turn
                    HStack(spacing: 16) {
                        Image(systemName: turnSymbolName(turnKind(turn?.step)))
                            .font(.system(size: 32))
                            .foregroundStyle(Color(hex: "9cc36b"))
                            .frame(width: 48)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn != nil ? "\(Int(turn!.distanceAway)) m ahead" : "Almost home")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(turn?.instruction ?? "You’re back where you started.")
                                .font(.title3.bold())
                            Text("\(formatDistance(model.remaining, unit: model.unit)) remaining · about \(formatTime(model.remaining / selected.distanceMeters * selected.durationSeconds))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .background(Color.clear)
    }
}
