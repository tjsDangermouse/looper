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
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isOpen {
                ForEach(Array(MapStyleChoice.allCases.reversed())) { choice in
                    Button {
                        selection = choice
                        withAnimation(.easeOut(duration: 0.16)) { isOpen = false }
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(choice == .looper ? Color(hex: "dcebd6") : Color(hex: "f3f1eb"))
                                .frame(width: 25, height: 18)
                                .overlay(alignment: .bottomTrailing) {
                                    if choice == .looper {
                                        Circle().fill(Color(hex: "168b95")).frame(width: 7, height: 7).padding(2)
                                    }
                                }
                            Text(choice.label)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: "243640"))
                        .padding(.horizontal, 9)
                        .frame(height: 38)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection == choice ? Color(hex: "6e8e49") : Color(hex: "c6cdcf"), lineWidth: selection == choice ? 2 : 1))
                        .shadow(color: .black.opacity(0.2), radius: 7, y: 4)
                    }
                    .accessibilityLabel("\(choice.label) map style")
                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { isOpen.toggle() }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: "243640"))
                    .frame(width: 44, height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: "b8c1c4")))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
            }
            .accessibilityLabel("Choose map style")
            .accessibilityValue(selection.label)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
        }
    }
}
