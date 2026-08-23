import SwiftUI
import UIKit

@main
struct LooperApp: App {
    init() {
        // Segmented controls (Distance/Time, km/mi) default to the system
        // blue tint; match the web app's accent-green selected segment.
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(Color.looperAccent)
        segmented.backgroundColor = UIColor(Color.looperRaised)
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 15, weight: .semibold)],
            for: .normal
        )
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor(Color.looperOnAccent), .font: UIFont.systemFont(ofSize: 15, weight: .bold)],
            for: .selected
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
