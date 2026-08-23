import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color(hex: "9cc36b"))

            VStack(spacing: 6) {
                Text("a route with a way back")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                Text("Looper")
                    .font(.system(size: 44, weight: .bold))
                Text("Find your route. Make it loop.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                if model.hasActiveWalk {
                    Button(action: model.continueWalk) {
                        Label("Continue loop", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                Button(action: model.requestLocation) {
                    Label("Use my location", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    model.screen = .planner
                } label: {
                    Text("Choose on map")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)

            if !model.locationState.isEmpty {
                Text(model.locationState)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(spacing: 4) {
                Text("Your location stays on your device.")
                Text("Maps and routes © OpenStreetMap contributors")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Button("How live guidance works") {
                model.locationState = "Looper keeps giving live guidance even while your phone is locked."
            }
            .buttonStyle(TextLinkButtonStyle())

            Spacer()

            Text(AppVersion.displayString)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.looperBackground)
    }
}
