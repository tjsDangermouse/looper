import LooperKit
import SwiftUI

struct WalkView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var watch: WatchCompanion

    init(model: AppModel) {
        self.model = model
        _watch = ObservedObject(wrappedValue: model.watch)
    }

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Button(action: model.endWalk) {
                    Text("End")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.looperAccent)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Color.looperSheet, in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)

                Button {
                    model.isPaused ? model.resumeWalk() : model.pauseWalk()
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(IconButtonStyle())
                .foregroundStyle(model.isPaused ? Color.looperAccent : .white)
                .accessibilityLabel(model.isPaused ? "Resume walk" : "Pause walk")

                Button(action: model.returnHome) {
                    Image(systemName: "house.fill")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Home")

                if let route = model.selected {
                    Button {
                        if watch.routeTransfer(for: route.id)?.state == .failed {
                            model.retryOfflineTransfer(route)
                        } else {
                            model.toggleOffline(route)
                        }
                    } label: {
                        watchTransferIcon(for: route)
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Available offline on Apple Watch")
                    .accessibilityValue(watchTransferAccessibilityValue(for: route))
                    .accessibilityHint(watchTransferAccessibilityHint(for: route))
                }

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

            if model.isPaused {
                Text("Paused")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.looperAccent)
                    .padding(.top, 8)
            }

            #if DEBUG
            if model.isSimulatingWalk {
                Label("Developer route simulation", systemImage: "hare.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.looperAccent)
                    .padding(.top, 8)
            }
            #endif

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
                } else if model.selected != nil {
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
                            Text("\(formatDistance(model.remaining, unit: model.unit)) remaining · about \(formatTime(secondsForDistance(model.remaining, paceMinutesPerKm: model.activePaceMinutesPerKm)))")
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

    @ViewBuilder
    private func watchTransferIcon(for route: Route) -> some View {
        if !model.isOffline(route) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.white)
        } else if let transfer = watch.routeTransfer(for: route.id) {
            switch transfer.state {
            case .queued:
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.looperAccent)
            case .receiving:
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: transfer.fractionComplete)
                        .stroke(Color.looperAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(transfer.fractionComplete * 100))")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
            case .ready:
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .foregroundStyle(Color.looperAccent)
            case .failed:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(Color.looperAccent)
        }
    }

    private func watchTransferAccessibilityValue(for route: Route) -> String {
        guard model.isOffline(route) else { return "Not downloaded" }
        guard let transfer = watch.routeTransfer(for: route.id) else { return "Queued for Apple Watch" }
        switch transfer.state {
        case .queued: return "Queued for Apple Watch"
        case .receiving: return "Sending to Apple Watch, \(Int(transfer.fractionComplete * 100)) percent"
        case .ready: return "Downloaded to Apple Watch"
        case .failed: return "Download failed"
        }
    }

    private func watchTransferAccessibilityHint(for route: Route) -> String {
        guard model.isOffline(route) else {
            return "Downloads this route to your Watch so you can walk it without your phone"
        }
        if watch.routeTransfer(for: route.id)?.state == .failed {
            return "Retries the download to your Watch"
        }
        return "Removes this route from your Watch"
    }
}
