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
            CommandMenu("Effects") {
                Toggle("Green Screen", isOn: $model.greenScreen.enabled)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Picker("Screen Colour", selection: $model.greenScreen.keyColour) {
                    ForEach(GreenScreenSettings.KeyColour.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!model.greenScreen.enabled)
                Divider()
                Button("Choose Backdrop…") { model.chooseBackdrop() }
                Button("Remove Backdrop") { model.removeBackdrop() }
                    .disabled(model.greenScreen.backdrop == nil)
            }
        }
    }
}
