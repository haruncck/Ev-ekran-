import SwiftUI
import UIKit

/// Address of the home screen. The page updates itself; this app never needs changing for that.
let homeURL = URL(string: "https://haruncck.github.io/Ev-ekran-/")!

@main
struct EvEkraniApp: App {
    @StateObject private var sensor = SensorReader()

    var body: some Scene {
        WindowGroup {
            HomeWebView(sensor: sensor)
                .background(Color.black)
                .ignoresSafeArea()
                .statusBar(hidden: true)
                .onAppear {
                    // A wall screen: never let the iPad lock while the app is open.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
