import LooperKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel(apiBase: Config.apiBase)
    @State private var mapStyle: MapStyleChoice = .default

    var body: some View {
        Group {
            if model.screen == .welcome {
                WelcomeView(model: model)
            } else {
                ZStack(alignment: .bottom) {
                    MapLibreMapView(
                        mapStyle: mapStyle,
                        start: model.start,
                        waypoints: model.waypoints,
                        routes: model.screen == .choices || model.screen == .walk ? model.mapRoutes : [],
                        selectedRouteID: model.selected?.id,
                        position: model.position,
                        follow: model.following && model.screen == .walk,
                        walking: model.screen == .walk,
                        heading: model.heading,
                        courseUp: model.courseUp && model.screen == .walk,
                        padding: model.padding,
                        onFollowChange: { model.following = $0 },
                        onUserLocation: model.updateMapLocation,
                        onPoint: { point in
                            if model.screen == .planner { model.start = point }
                        },
                        onLongPress: model.addWaypoint
                    )
                    .ignoresSafeArea()

                    switch model.screen {
                    case .welcome:
                        EmptyView()
                    case .planner:
                        PlannerView(model: model)
                    case .choices:
                        ChoicesView(model: model)
                    case .walk:
                        WalkView(model: model)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if model.screen != .walk {
                        BrandBadge()
                            .padding(.top, 8)
                            .padding(.leading, 14)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.screen != .walk {
                        HStack(spacing: 10) {
                            Button(action: model.returnHome) {
                                Image(systemName: "house.fill")
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(IconButtonStyle())
                            .accessibilityLabel("Home")

                            Button {
                                model.showingVoiceSettings = true
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(IconButtonStyle())
                            .accessibilityLabel("Settings")
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 14)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if model.screen != .walk {
                        MapStylePicker(selection: $mapStyle)
                            .padding(.leading, 12)
                            .padding(.bottom, model.padding.bottom + 12)
                            .animation(.easeInOut(duration: 0.3), value: model.padding.bottom)
                    }
                }
                .onPreferenceChange(SheetHeightKey.self) { height in
                    model.padding = (bottom: height, right: 0)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingVoiceSettings) {
            SettingsView(model: model)
        }
        // Presented off the model's own summary rather than a view-local
        // flag, so a summary restored after the app was killed mid-walk still
        // appears, and dismissing it is what marks the loop as seen. Bound by
        // presentation rather than by item so the Apple Health row keeps
        // updating while the sheet is open.
        .sheet(isPresented: Binding(
            get: { model.summary != nil },
            set: { if !$0 { model.dismissSummary() } }
        )) {
            if let summary = model.summary {
                LoopSummaryView(model: model, summary: summary)
                    .interactiveDismissDisabled()
            }
        }
        .alert("Waypoints exceed your plan", isPresented: Binding(
            get: { model.expectationMessage != nil },
            set: { if !$0 { model.expectationMessage = nil } }
        )) {
            Button("Change plan") {
                model.expectationMessage = nil
                model.screen = .planner
            }
            Button("Remove waypoints", role: .destructive) {
                model.expectationMessage = nil
                model.clearWaypoints()
            }
            Button("Cancel", role: .cancel) { model.expectationMessage = nil }
        } message: {
            Text(model.expectationMessage ?? "")
        }
    }
}

private struct MapStylePicker: View {
    @Binding var selection: MapStyleChoice

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MapStyleChoice.allCases) { choice in
                Button { selection = choice } label: {
                    HStack(spacing: 7) {
                        Capsule()
                            .fill(selection == choice ? Color.looperAccent : Color(hex: "61717b"))
                            .frame(width: 5, height: 15)
                            .rotationEffect(.degrees(13))
                        Text(choice.label)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selection == choice ? .white : Color(hex: "c5d0d5"))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(selection == choice ? Color.looperLine : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("\(choice.label) map style")
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "82929b").opacity(0.35)))
        .shadow(color: .black.opacity(0.45), radius: 9, y: 5)
    }
}
