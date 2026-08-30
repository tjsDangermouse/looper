import LooperKit
import SwiftUI

struct ChoicesView: View {
    @ObservedObject var model: AppModel
    @State private var refreshPulse = false

    var body: some View {
        VStack(spacing: 0) {
            BottomSheet {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("your choices")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Pick a loop")
                                .font(.system(size: 17, weight: .bold))
                        }
                        Spacer()
                        Button {
                            model.findRoutes()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(IconButtonStyle(diameter: 32, background: .looperRaised, bordered: true))
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
                        .buttonStyle(IconButtonStyle(diameter: 32, background: .looperRaised, bordered: true))
                        .foregroundStyle(model.reversed ? Color.looperAccent : .white)
                        Button {
                            model.screen = .planner
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(IconButtonStyle(diameter: 32, background: .looperRaised, bordered: true))
                        .accessibilityLabel("Edit")
                    }

                    if !model.error.isEmpty {
                        Text(model.error).font(.footnote).foregroundStyle(.orange)
                    }

                    EngineBadge(report: model.engineReport)

                    WaypointHint(model: model)

                    ForEach(Array(model.shownRoutes.enumerated()), id: \.element.id) { index, route in
                        HStack(spacing: 0) {
                            Button {
                                model.selected = route
                                model.showsRouteOverlay = true
                                model.recordRouteChoice(index)
                            } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color(hex: routeColours[index % routeColours.count]))
                                    .frame(width: 12, height: 12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name).font(.subheadline.weight(.semibold))
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
                            .padding(.leading, 10)
                            .padding(.vertical, 8)
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
                        .frame(minHeight: 48)
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
                VStack(spacing: 4) {
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
                .padding(.bottom, 4)
                .animation(.easeOut(duration: 0.2), value: model.startupNotice)
            }
        }
        // The Start walk pill is a bottom safe-area inset, so it lifts the
        // sheet without being part of it. Measuring here — outside the inset
        // — reports the whole bottom chrome, which is what the map (and the
        // layer button floating above it) has to stay clear of.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
            }
        )
        // The Watch is shown whichever loop is chosen here, so Start on the
        // wrist knows what it is starting before a walk begins.
        .onAppear { if let selected = model.selected { model.prepareWatch(for: selected) } }
        .onChange(of: model.selected?.id) { _, _ in
            if let selected = model.selected { model.prepareWatch(for: selected) }
        }
        .onDisappear { model.clearWatch() }
    }
}

/// Which engine drew these walks, while both are being tested on real ground.
///
/// Deliberately small and grey rather than a headline: it is a developer
/// affordance, and it exists so that a tester on a hillside never has to guess
/// what they are comparing. It disappears entirely from a build with
/// `RoutingTrialLog.includedInThisBuild` off, and it says nothing a walker
/// would need in order to use the app.
private struct EngineBadge: View {
    let report: RoutingEngineReport?

    var body: some View {
        if RoutingTrialLog.includedInThisBuild, let report {
            HStack(spacing: 6) {
                Text(report.routingEngine.badge)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(report.routingEngine == .direct ? Color.looperAccent.opacity(0.25) : Color.white.opacity(0.10))
                    )
                if report.didFallBack {
                    Text(fallbackNote(report))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let ms = report.generationMs {
                    Text("\(Int(ms)) ms").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityLabel("Routed by \(report.routingEngine.title)")
        }
    }

    /// Falling back is an ordinary outcome, not an error, so it reads as one.
    private func fallbackNote(_ report: RoutingEngineReport) -> String {
        switch report.engineReason {
        case "waypoint-fallback": return "waypoints use the current engine"
        case "engine-unsupported": return "direct search unavailable here"
        default: return report.fallbackReason.map { "direct search gave way: \($0)" } ?? "fell back"
        }
    }
}
