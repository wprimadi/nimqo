import SwiftUI

@main
struct NimqoApp: App {
    @State private var model = CoreModel()

    var body: some Scene {
        WindowGroup("NIMQO") {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 480)
                .task { model.start() }
        }
    }
}
