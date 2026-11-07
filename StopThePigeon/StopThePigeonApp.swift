import SwiftUI

@main
struct StopThePigeonApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // A single window, since the camera can only feed one capture session.
        Window("Stop the Pigeon", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Open Project…") { model.openProject() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Export Movie…") { model.exportMovie() }
                    .keyboardShortcut("e")
                    .disabled(model.frames.isEmpty)
            }
        }
    }
}
