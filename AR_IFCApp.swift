import SwiftUI

// main entrypoint, swift requirement
@main
struct AR_IFCApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
    }
}
