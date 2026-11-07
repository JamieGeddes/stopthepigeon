import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    private static let lastProjectKey = "lastProjectPath"

    let camera = CameraController()
    let images = FrameImageCache()

    private(set) var project: StopMotionProject?
    /// The frame shown on stage. `nil` means the live camera view.
    var selectedFrame: String?
    var onionSkinEnabled = true
    var onionSkinOpacity = 0.35
    var loopPlayback = true
    var exportPreset: ExportPreset = .hd1080

    private(set) var isCapturing = false
    private(set) var isPlaying = false
    private(set) var playbackFrame: String?
    private(set) var exportProgress: Double?
    var errorMessage: String?

    private var playbackTask: Task<Void, Never>?

    var frames: [String] { project?.frames ?? [] }
    var lastFrameURL: URL? { project.flatMap { p in p.frames.last.map(p.url(for:)) } }

    func launch() async {
        openLastOrDefaultProject()
        await camera.start()
    }

    // MARK: Projects

    static var defaultProjectsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stop the Pigeon", isDirectory: true)
    }

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Project name:"
        panel.nameFieldStringValue = Self.defaultProjectName()
        try? FileManager.default.createDirectory(at: Self.defaultProjectsFolder, withIntermediateDirectories: true)
        panel.directoryURL = Self.defaultProjectsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try self.setProject(.create(at: url)) }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.defaultProjectsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try self.setProject(.open(at: url)) }
    }

    func showProjectInFinder() {
        guard let project else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.folder])
    }

    private func openLastOrDefaultProject() {
        if let path = UserDefaults.standard.string(forKey: Self.lastProjectKey),
           FileManager.default.fileExists(atPath: path),
           let project = try? StopMotionProject.open(at: URL(fileURLWithPath: path)) {
            setProject(project)
            return
        }
        let url = Self.defaultProjectsFolder.appendingPathComponent(Self.defaultProjectName(), isDirectory: true)
        perform { try self.setProject(.create(at: url)) }
    }

    private func setProject(_ newProject: StopMotionProject) {
        stopPlayback()
        project = newProject
        selectedFrame = nil
        UserDefaults.standard.set(newProject.folder.path, forKey: Self.lastProjectKey)
    }

    private static func defaultProjectName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Untitled \(formatter.string(from: Date()))"
    }

    // MARK: Frames

    func capture() async {
        guard !isCapturing, project != nil else { return }
        isCapturing = true
        defer { isCapturing = false }
        stopPlayback()
        do {
            let photo = try await camera.capturePhoto()
            try project?.appendFrame(data: photo.data, fileExtension: photo.fileExtension)
            selectedFrame = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelectedFrame() {
        guard let frame = selectedFrame, let index = frames.firstIndex(of: frame) else { return }
        perform {
            try self.project?.deleteFrame(frame)
            let remaining = self.frames
            self.selectedFrame = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
    }

    func moveSelectedFrame(by offset: Int) {
        guard let frame = selectedFrame else { return }
        perform { try self.project?.moveFrame(frame, by: offset) }
    }

    func selectAdjacentFrame(_ offset: Int) {
        guard !frames.isEmpty else { return }
        guard let frame = selectedFrame, let index = frames.firstIndex(of: frame) else {
            // From the live view, stepping back shows the most recent frame.
            if offset < 0 { selectedFrame = frames.last }
            return
        }
        let target = index + offset
        selectedFrame = target >= frames.count ? nil : frames[max(target, 0)]
    }

    func setFPS(_ fps: Int) {
        perform { try self.project?.setFPS(fps) }
    }

    // MARK: Playback

    func togglePlayback() {
        isPlaying ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        guard let project, !project.frames.isEmpty else { return }
        isPlaying = true
        playbackTask = Task { [weak self] in
            repeat {
                guard let self, let project = self.project else { return }
                for frame in project.frames {
                    if Task.isCancelled { return }
                    self.playbackFrame = frame
                    try? await Task.sleep(for: .seconds(1.0 / Double(max(project.fps, 1))))
                }
            } while self?.loopPlayback == true && !Task.isCancelled
            self?.stopPlayback()
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        playbackFrame = nil
    }

    // MARK: Export

    func exportMovie() {
        guard let project, !project.frames.isEmpty, exportProgress == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Movie"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.name).mp4"
        panel.directoryURL = project.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let urls = project.frameURLs
        let fps = project.fps
        let preset = exportPreset
        exportProgress = 0

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await MovieExporter.export(frameURLs: urls, fps: fps, preset: preset, to: url) { value in
                        Task { @MainActor in self.exportProgress = value }
                    }
                }.value
                exportProgress = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                exportProgress = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Helpers

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}
