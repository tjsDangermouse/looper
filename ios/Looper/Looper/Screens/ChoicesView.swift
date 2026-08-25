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

                    WaypointHint(model: model)

                    ForEach(Array(model.shownRoutes.enumerated()), id: \.element.id) { index, route in
                        HStack(spacing: 0) {
                            Button {
                                model.selected = route
                                model.showsRouteOverlay = true
                            } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: routeColours[index % routeColours.count]))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name).font(.headline)
                                    Text("\(formatDistance(route.distanceMeters, unit: model.unit)) · \(formatTime(secondsForDistance(route.distanceMeters, paceMinutesPerKm: model.activePaceMinutesPerKm))) · \(abs(Int(route.targetDifferencePercent)))% \(route.targetDifferencePercent < 0 ? "shorter" : "longer")")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selected?.id == route.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "9cc36b"))
                                }
                            }
                            .padding(.leading, 12)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                model.toggleFavorite(route)
                            } label: {
                                Image(systemName: model.isFavorite(route) ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(model.isFavorite(route) ? Color.looperAccent : .secondary)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(model.isFavorite(route) ? "Remove \(route.name) from saved routes" : "Save \(route.name) for later")
                        }
                        .frame(minHeight: 64)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(model.selected?.id == route.id ? Color.white.opacity(0.08) : Color.clear)
                        )
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let selected = model.selected {
                VStack(spacing: 6) {
                    Button {
                        if model.waypointsNeedSearch { model.findRoutes() }
                        else { model.beginWalk(selected) }
                    } label: {
                        Label(
                            model.waypointsNeedSearch
                                ? (model.waypoints.isEmpty ? "Find new loops" : "Find waypoint loops")
                                : "Start walk",
                            systemImage: model.waypointsNeedSearch ? "point.topleft.down.to.point.bottomright.curvepath" : "figure.walk"
                        )
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!model.startupNotice.isEmpty || model.busy)

                    // Only ever on screen for the few seconds the Watch is
                    // given to bring its workout up.
                    if !model.startupNotice.isEmpty {
                        Text(model.startupNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 8)
                .animation(.easeOut(duration: 0.2), value: model.startupNotice)
            }
        }
        // The Watch is shown whichever loop is chosen here, so Start on the
        // wrist knows what it is starting before a walk begins.
        .onAppear { if let selected = model.selected { model.prepareWatch(for: selected) } }
        .onChange(of: model.selected?.id) { _, _ in
            if let selected = model.selected { model.prepareWatch(for: selected) }
        }
        .onDisappear { model.clearWatch() }
    }
}
