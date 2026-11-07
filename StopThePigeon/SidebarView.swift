import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            cameraSection
            onionSkinSection
            frameSection
            playbackSection
            exportSection
            projectSection
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private var cameraSection: some View {
        Section("Camera") {
            Picker("Source", selection: Binding(
                get: { model.camera.selectedDeviceID ?? "" },
                set: { model.camera.selectDevice(id: $0) }
            )) {
                if model.camera.devices.isEmpty { Text("None").tag("") }
                ForEach(model.camera.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            if !model.camera.photoSizeDescription.isEmpty {
                LabeledContent("Photo size", value: model.camera.photoSizeDescription)
            }
            if let warning = model.camera.effectsWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            lockToggle("Lock focus", model.camera.focus, model.camera.setFocusLocked)
            lockToggle("Lock exposure", model.camera.exposure, model.camera.setExposureLocked)
            lockToggle("Lock white balance", model.camera.whiteBalance, model.camera.setWhiteBalanceLocked)
            if model.camera.status == .running,
               !(model.camera.focus.supported || model.camera.exposure.supported || model.camera.whiteBalance.supported) {
                Text("This camera doesn't allow locking. Use steady lighting and block out daylight to avoid flicker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var onionSkinSection: some View {
        Section("Onion skin") {
            Toggle("Show previous frame", isOn: $model.onionSkinEnabled)
            Slider(value: $model.onionSkinOpacity, in: 0.1...0.8) { Text("Opacity") }
                .disabled(!model.onionSkinEnabled)
        }
    }

    private var frameSection: some View {
        Section("Selected frame") {
            HStack {
                Button("Move Earlier") { model.moveSelectedFrame(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                Button("Move Later") { model.moveSelectedFrame(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
            }
            Button("Delete Frame", role: .destructive) { model.deleteSelectedFrame() }
                .keyboardShortcut(.delete, modifiers: .command)
            Text("Deleted frames go to the project's “Deleted Frames” folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(model.selectedFrame == nil || model.isPlaying)
    }

    private var playbackSection: some View {
        Section("Playback") {
            Stepper(value: Binding(
                get: { model.project?.fps ?? 12 },
                set: { model.setFPS($0) }
            ), in: 1...30) {
                LabeledContent("Frame rate", value: "\(model.project?.fps ?? 12) fps")
            }
            Toggle("Loop", isOn: $model.loopPlayback)
        }
    }

    private var exportSection: some View {
        Section("Export") {
            Picker("Resolution", selection: $model.exportPreset) {
                ForEach(ExportPreset.allCases) { Text($0.label).tag($0) }
            }
            if let progress = model.exportProgress {
                ProgressView(value: progress) { Text("Exporting…") }
            } else {
                Button("Export Movie…") { model.exportMovie() }
                    .disabled(model.frames.isEmpty)
            }
        }
    }

    private var projectSection: some View {
        Section("Project") {
            if let project = model.project {
                LabeledContent("Name", value: project.name)
                Button("Show in Finder") { model.showProjectInFinder() }
            }
            HStack {
                Button("New…") { model.newProject() }
                Button("Open…") { model.openProject() }
            }
        }
    }

    private func lockToggle(_ title: String, _ capability: CameraController.Capability, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { capability.locked }, set: set))
            .disabled(!capability.supported)
    }
}
