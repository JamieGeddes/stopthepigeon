import Foundation

/// A stop-motion project is a folder of image files plus a `project.json`
/// recording the frame order, playback rate and effect settings.
struct StopMotionProject: Equatable {
    static let manifestName = "project.json"
    static let deletedFolderName = "Deleted Frames"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "png"]
    static let backdropPrefix = "backdrop-"

    let folder: URL
    var fps: Int
    var frames: [String]
    var greenScreen = GreenScreenSettings()
    /// Highest frame number ever used, so numbers aren't reused after a delete.
    var lastFrameNumber = 0

    var name: String { folder.lastPathComponent }
    var frameURLs: [URL] { frames.map(url(for:)) }
    var backdropURL: URL? { greenScreen.backdrop.map(url(for:)) }
    var effect: FrameEffect { FrameEffect(greenScreen: greenScreen, backdropURL: backdropURL) }

    func url(for frame: String) -> URL {
        folder.appendingPathComponent(frame)
    }

    // MARK: Creating and opening

    static func create(at folder: URL, fps: Int = 12) throws -> StopMotionProject {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = StopMotionProject(folder: folder, fps: fps, frames: [])
        try project.save()
        return project
    }

    /// Opens a project folder. Folders without a manifest are adopted, using any
    /// images they contain in filename order.
    static func open(at folder: URL) throws -> StopMotionProject {
        let manifestURL = folder.appendingPathComponent(manifestName)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            var project = StopMotionProject(folder: folder, fps: clampedFPS(manifest.fps), frames: [])
            // Only accept entries that are image files inside the project folder.
            project.frames = manifest.frames.filter {
                project.isContainedFrame($0) && FileManager.default.fileExists(atPath: project.url(for: $0).path)
            }
            project.greenScreen = manifest.greenScreen ?? GreenScreenSettings()
            project.lastFrameNumber = max(manifest.lastFrameNumber ?? 0, 0)
            if let backdrop = project.greenScreen.backdrop,
               !(project.isContainedFrame(backdrop) && FileManager.default.fileExists(atPath: project.url(for: backdrop).path)) {
                project.greenScreen.backdrop = nil
            }
            return project
        }

        let images = try imageFiles(in: folder).filter { !$0.hasPrefix(backdropPrefix) }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let project = StopMotionProject(folder: folder, fps: 12, frames: images)
        try project.save()
        return project
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Manifest(version: 1, fps: fps, frames: frames, greenScreen: greenScreen, lastFrameNumber: lastFrameNumber))
        try data.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: Editing

    /// Writes image data as a new frame at the end of the sequence and saves the manifest.
    @discardableResult
    mutating func appendFrame(data: Data, fileExtension: String) throws -> String {
        let number = try nextFrameNumber()
        let name = String(format: "frame-%04d.%@", number, fileExtension)
        try data.write(to: url(for: name), options: .withoutOverwriting)
        lastFrameNumber = number
        frames.append(name)
        try save()
        return name
    }

    /// Removes a frame from the sequence, moving its file into the "Deleted Frames"
    /// subfolder so it can be recovered.
    mutating func deleteFrame(_ frame: String) throws {
        guard let index = frames.firstIndex(of: frame) else { return }
        guard isContainedFrame(frame) else { throw ProjectError.invalidFrameName(frame) }
        let deletedFolder = folder.appendingPathComponent(Self.deletedFolderName)
        try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: true)

        var destination = deletedFolder.appendingPathComponent(frame)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stem = (frame as NSString).deletingPathExtension
            let ext = (frame as NSString).pathExtension
            destination = deletedFolder.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).\(ext)")
        }
        try FileManager.default.moveItem(at: url(for: frame), to: destination)
        frames.remove(at: index)
        try save()
    }

    /// Moves a frame by `offset` positions, clamped to the ends of the sequence.
    mutating func moveFrame(_ frame: String, by offset: Int) throws {
        guard let index = frames.firstIndex(of: frame) else { return }
        let target = min(max(index + offset, 0), frames.count - 1)
        guard target != index else { return }
        frames.remove(at: index)
        frames.insert(frame, at: target)
        try save()
    }

    mutating func setFPS(_ newValue: Int) throws {
        fps = Self.clampedFPS(newValue)
        try save()
    }

    /// Copies an image into the project as the green screen backdrop, replacing any
    /// previous one. The copy gets a unique name so cached renders are refreshed.
    mutating func setBackdrop(copying source: URL) throws {
        let ext = source.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { throw ProjectError.unsupportedImage(source.lastPathComponent) }
        let name = "\(Self.backdropPrefix)\(UUID().uuidString.prefix(8)).\(ext)"
        try FileManager.default.copyItem(at: source, to: url(for: name))
        try removeBackdropFile()
        greenScreen.backdrop = name
        try save()
    }

    mutating func removeBackdrop() throws {
        try removeBackdropFile()
        greenScreen.backdrop = nil
        try save()
    }

    private func removeBackdropFile() throws {
        guard let backdrop = greenScreen.backdrop, isContainedFrame(backdrop) else { return }
        let fileURL = url(for: backdrop)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: Validation

    static func clampedFPS(_ value: Int) -> Int {
        min(max(value, 1), 60)
    }

    /// A plain image filename, with no path components or hidden-file prefix.
    static func isValidFrameName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.hasPrefix(".")
            && imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// True if `name` is a valid frame name whose file, after resolving symlinks,
    /// sits directly inside the project folder.
    func isContainedFrame(_ name: String) -> Bool {
        guard Self.isValidFrameName(name) else { return false }
        let resolvedParent = url(for: name).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        return resolvedParent.path == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Helpers

    private struct Manifest: Codable {
        var version: Int
        var fps: Int
        var frames: [String]
        var greenScreen: GreenScreenSettings?
        var lastFrameNumber: Int?
    }

    private static func imageFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            imageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    /// One higher than any frame number used before: in the manifest, in the folder, or
    /// in "Deleted Frames". Reusing a deleted frame's name would show its cached image and
    /// clash if it were restored. New files also sort in capture order in Finder.
    private func nextFrameNumber() throws -> Int {
        let deletedFolder = folder.appendingPathComponent(Self.deletedFolderName)
        var names = try Self.imageFiles(in: folder)
        if FileManager.default.fileExists(atPath: deletedFolder.path) {
            names += try Self.imageFiles(in: deletedFolder)
        }
        let numbers = names.compactMap(Self.frameNumber(in:))
        return max(numbers.max() ?? 0, lastFrameNumber) + 1
    }

    /// The number in "frame-NNNN.jpg" or a deleted copy such as "frame-NNNN-1a2b3c4d.jpg".
    static func frameNumber(in name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension
        guard stem.hasPrefix("frame-") else { return nil }
        return Int(stem.dropFirst("frame-".count).prefix { $0.isNumber })
    }
}

enum ProjectError: LocalizedError {
    case invalidFrameName(String)
    case unsupportedImage(String)

    var errorDescription: String? {
        switch self {
        case .invalidFrameName(let name): "“\(name)” isn't a frame inside this project."
        case .unsupportedImage(let name): "“\(name)” isn't a supported image. Use JPEG, PNG or HEIC."
        }
    }
}
