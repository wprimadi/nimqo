import SwiftUI

@main
struct NimqoApp: App {
    @State private var model = CoreModel()

    var body: some Scene {
        WindowGroup("NIMQO") {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .task { model.start() }
        }
    }
}
