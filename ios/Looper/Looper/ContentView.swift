import LooperKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel(apiBase: Config.apiBase)

    var body: some View {
        Group {
            if model.screen == .welcome {
                WelcomeView(model: model)
            } else {
                ZStack(alignment: .bottom) {
                    MapLibreMapView(
                        start: model.start,
                        routes: model.shownRoutes,
                        selectedRouteID: model.selected?.id,
                        position: model.position,
                        follow: model.following && model.screen == .walk,
                        walking: model.screen == .walk,
                        heading: model.heading,
                        courseUp: model.courseUp && model.screen == .walk,
                        padding: model.padding,
                        onFollowChange: { model.following = $0 },
                        onPoint: { point in
                            if model.screen == .planner { model.start = point }
                        }
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
                .onPreferenceChange(SheetHeightKey.self) { height in
                    model.padding = (bottom: height, right: 0)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
