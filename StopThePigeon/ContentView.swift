import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSplash = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                StageView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                TransportBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                Divider()
                FrameStripView(model: model)
                    .frame(height: 104)
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            SidebarView(model: model)
                .frame(width: 320)
        }
        .frame(minWidth: 960, minHeight: 640)
        .navigationTitle(model.project?.name ?? "Stop the Pigeon")
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK") { model.errorMessage = nil }
        } message: { Text($0) }
        .overlay {
            if showSplash {
                SplashView(status: splashStatus)
                    .onTapGesture { dismissSplash() }
                    .transition(.opacity)
            }
        }
        .task {
            // Long enough to take in: two full swoops of the net. Then wait for the
            // camera (up to 5 seconds more) so the main window appears ready to shoot.
            async let minimumTime: Void = Task.sleep(for: .seconds(PigeonChaseScene.period * 2))
            await model.launch()
            try? await minimumTime
            let deadline = Date.now.addingTimeInterval(5)
            while showSplash, model.camera.status == .starting, Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            dismissSplash()
        }
    }

    private var splashStatus: String {
        model.camera.status == .starting ? "Starting camera…" : "Ready"
    }

    private func dismissSplash() {
        guard showSplash else { return }
        withAnimation(.easeInOut(duration: 0.8)) { showSplash = false }
    }
}

// MARK: - Stage

private struct StageView: View {
    let model: AppModel

    private var stageFrameURL: URL? {
        guard let project = model.project else { return nil }
        if model.isPlaying { return model.playbackFrame.map(project.url(for:)) }
        return model.selectedFrame.map(project.url(for:))
    }

    var body: some View {
        // GeometryReader takes exactly the space it's offered and its contents can't
        // change that, so nothing on stage can push the sidebar out of the window.
        GeometryReader { geometry in
            let size = Self.fit(aspect: model.camera.videoAspect, in: geometry.size)
            stage
                .frame(width: size.width, height: size.height)
                .clipped()
                .overlay(alignment: .topLeading) { badges }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            if let url = stageFrameURL {
                FrameImageView(url: url, maxPixelSize: 2048, cache: model.images, effect: model.activeEffect)
            } else {
                if model.activeEffect != nil {
                    EffectPreviewView(renderer: model.camera.effectPreview)
                } else {
                    CameraPreviewView(session: model.camera.session)
                }
                if model.onionSkinEnabled, let last = model.lastFrameURL {
                    // Fit, not fill: when photos are wider than the video (16:9 stills
                    // from a 4:3 feed) they're a centre crop of it, so matching widths
                    // lines the previous frame up with the live view.
                    FrameImageView(url: last, maxPixelSize: 2048, cache: model.images, effect: model.activeEffect)
                        .opacity(model.onionSkinOpacity)
                        .allowsHitTesting(false)
                }
                CameraStatusOverlay(status: model.camera.status)
            }
        }
    }

    private var badges: some View {
        HStack(spacing: 6) {
            badge(stageLabel)
            if model.activeEffect != nil {
                badge(model.greenScreen.backdrop == nil ? "Green screen: no backdrop" : "Green screen")
            }
        }
        .padding(10)
    }

    /// The largest size with the given aspect ratio that fits in `bounds`.
    static func fit(aspect: Double, in bounds: CGSize) -> CGSize {
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(bounds.width, bounds.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var stageLabel: String {
        if model.isPlaying { return "Playing" }
        if let frame = model.selectedFrame, let index = model.frames.firstIndex(of: frame) {
            return "Frame \(index + 1) of \(model.frames.count)"
        }
        return "Live"
    }
}

private struct CameraStatusOverlay: View {
    let status: CameraController.Status

    var body: some View {
        switch status {
        case .running:
            EmptyView()
        case .starting:
            ProgressView("Starting camera…").foregroundStyle(.white)
        case .disconnected(let name):
            message(
                "\(name) disconnected",
                "Unlock your iPhone and keep it close to the Mac. It reconnects automatically."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.6))
        case .noCamera:
            message("No camera found", "Bring your iPhone close to the Mac, or connect it with a cable.")
        case .unauthorised:
            message("Camera access is off", "Allow it in System Settings > Privacy & Security > Camera.")
        case .failed(let reason):
            message("Camera error", reason)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.callout).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding()
    }
}

// MARK: - Transport

private struct TransportBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.selectAdjacentFrame(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")
            Button { model.selectAdjacentFrame(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")
            Button("Live") { model.stopPlayback(); model.selectedFrame = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to the live camera (Esc)")

            Spacer()

            Button {
                Task { await model.capture() }
            } label: {
                Label("Capture", systemImage: "camera.fill")
                    .frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.camera.status != .running || model.isCapturing)
            .help("Capture a frame (Space)")

            Spacer()

            Button {
                model.togglePlayback()
            } label: {
                Label(model.isPlaying ? "Stop" : "Play", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
            }
            .keyboardShortcut("p", modifiers: [])
            .disabled(model.frames.isEmpty)
            .help("Play or stop the preview (P)")

            Text("\(model.frames.count) frames · \(durationText)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var durationText: String {
        let fps = Double(model.project?.fps ?? 12)
        return String(format: "%.1fs", Double(model.frames.count) / fps)
    }
}
