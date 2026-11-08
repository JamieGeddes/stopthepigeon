import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            cameraSection
            voiceSection
            effectsSection
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
            // Label above the menu: camera names are long and the menu won't shrink
            // to fit beside a label.
            VStack(alignment: .leading, spacing: 6) {
                Text("Source")
                Picker("Source", selection: Binding(
                    get: { model.camera.selectedDeviceID ?? "" },
                    set: { model.camera.selectDevice(id: $0) }
                )) {
                    if model.camera.devices.isEmpty { Text("None").tag("") }
                    ForEach(model.camera.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.camera.photoSizeDescription.isEmpty {
                LabeledContent("Photo size", value: model.camera.photoSizeDescription)
            }
            if let warning = model.camera.effectsWarning {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning).wrapping()
                }
                .foregroundStyle(.orange)
                .font(.callout)
            }

            lockToggle("Lock focus", model.camera.focus, model.camera.setFocusLocked)
            lockToggle("Lock exposure", model.camera.exposure, model.camera.setExposureLocked)
            lockToggle("Lock white balance", model.camera.whiteBalance, model.camera.setWhiteBalanceLocked)
            if model.camera.status == .running,
               !(model.camera.focus.supported || model.camera.exposure.supported || model.camera.whiteBalance.supported) {
                Text("This camera doesn't allow locking. Use steady lighting and block out daylight to avoid flicker.")
                    .caption()
            }
        }
    }

    private var voiceSection: some View {
        let voice = model.voice
        return Section("Voice control") {
            Toggle("Capture when I say “Now”", isOn: Binding(
                get: { voice.isEnabled },
                set: { enabled in Task { await voice.setEnabled(enabled) } }
            ))
            switch voice.state {
            case .off:
                EmptyView()
            case .starting:
                Label("Starting…", systemImage: "mic")
                    .foregroundStyle(.secondary)
            case .listening:
                HStack(spacing: 8) {
                    Image(systemName: voice.isHearingSpeech ? "waveform" : "mic.fill")
                        .foregroundStyle(voice.isHearingSpeech ? Color.accentColor : .green)
                        .frame(width: 18)
                    Text(voice.isHearingSpeech ? "Hearing speech…" : "Listening")
                    Spacer()
                    LevelMeter(level: voice.level, active: voice.isHearingSpeech)
                        .frame(width: 70, height: 6)
                }
                if let heard = voice.lastHeard {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: heard.accepted ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(heard.accepted ? .green : .secondary)
                        Text(heard.accepted ? "Heard “\(heard.text)”: captured" : "Ignored “\(heard.text)” (\(heard.note ?? ""))")
                            .wrapping()
                    }
                    .font(.callout)
                }
                Text("Say “Now” on its own, then pause. Longer phrases, other words and noises are ignored. Speech is recognised on this Mac only.")
                    .caption()
            case .unavailable(let reason):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(reason).wrapping()
                }
                .foregroundStyle(.orange)
                .font(.callout)
            }
        }
    }

    private var effectsSection: some View {
        Section("Effects") {
            Toggle("Green screen", isOn: $model.greenScreen.enabled)
            if model.greenScreen.enabled {
                Picker("Screen colour", selection: $model.greenScreen.keyColour) {
                    ForEach(GreenScreenSettings.KeyColour.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Backdrop") {
                    if let url = model.project?.backdropURL {
                        FrameImageView(url: url, maxPixelSize: 240, cache: model.images, contentMode: .fill)
                            .frame(width: 64, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(model.greenScreen.backdrop == nil ? "Choose…" : "Change…") { model.chooseBackdrop() }
                    if model.greenScreen.backdrop != nil {
                        Button("Remove") { model.removeBackdrop() }
                    }
                }

                Slider(value: $model.greenScreen.tolerance, in: 0...1) { Text("Tolerance") }
                    .help("Increase if patches of screen show through; decrease if parts of characters vanish.")
                Slider(value: $model.greenScreen.softness, in: 0...1) { Text("Edge softness") }
                Slider(value: $model.greenScreen.spillSuppression, in: 0...1) { Text("Spill removal") }
                    .help("Removes the coloured fringe the screen reflects onto characters.")
                Text("Light the screen evenly and avoid that colour on your characters.")
                    .caption()
            }
        }
        .disabled(model.project == nil)
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
                .caption()
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
                LabeledContent("Name") {
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.name)
                }
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

private struct LevelMeter: View {
    let level: Double
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(active ? Color.accentColor : Color.green)
                    .frame(width: geometry.size.width * level)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

private extension Text {
    /// Wraps onto as many lines as needed instead of widening the sidebar.
    func wrapping() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }

    func caption() -> some View {
        font(.caption).foregroundStyle(.secondary).wrapping()
    }
}
