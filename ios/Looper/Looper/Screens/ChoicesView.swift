import LooperKit
import SwiftUI

struct ChoicesView: View {
    @ObservedObject var model: AppModel
    @State private var refreshPulse = false

    var body: some View {
        VStack(spacing: 0) {
            BottomSheet {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("your choices")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Pick a loop")
                                .font(.title2.bold())
                        }
                        Spacer()
                        Button {
                            model.findRoutes()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(IconButtonStyle(background: .looperRaised, bordered: true))
                        .foregroundStyle(model.busy ? Color.looperAccent : .white)
                        .scaleEffect(refreshPulse ? 1.12 : 1)
                        .animation(
                            model.busy
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .easeOut(duration: 0.2),
                            value: refreshPulse
                        )
                        .onChange(of: model.busy) { _, busy in
                            refreshPulse = busy
                        }
                        .disabled(model.busy)
                        Button {
                            model.toggleReversed()
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .buttonStyle(IconButtonStyle(background: .looperRaised, bordered: true))
                        .foregroundStyle(model.reversed ? Color.looperAccent : .white)
                        Button {
                            model.screen = .planner
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(IconButtonStyle(background: .looperRaised, bordered: true))
                        .accessibilityLabel("Edit")
                    }

                    if !model.error.isEmpty {
                        Text(model.error).font(.footnote).foregroundStyle(.orange)
                    }

                    ForEach(Array(model.shownRoutes.enumerated()), id: \.element.id) { index, route in
                        Button {
                            model.selected = route
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: routeColours[index % routeColours.count]))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name).font(.headline)
                                    Text("\(formatDistance(route.distanceMeters, unit: model.unit)) · \(formatTime(route.durationSeconds)) · \(abs(Int(route.targetDifferencePercent)))% \(route.targetDifferencePercent < 0 ? "shorter" : "longer")")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selected?.id == route.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "9cc36b"))
                                }
                            }
                            .padding(12)
                            .frame(minHeight: 64)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(model.selected?.id == route.id ? Color.white.opacity(0.08) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let selected = model.selected {
                Button {
                    model.beginWalk(selected)
                } label: {
                    Label("Start walk", systemImage: "figure.walk")
                }
                .buttonStyle(PillButtonStyle())
                .padding(.bottom, 8)
            }
        }
    }
}
