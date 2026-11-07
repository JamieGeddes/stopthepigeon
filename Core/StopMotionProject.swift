import Foundation

/// A stop-motion project is a folder of image files plus a `project.json`
/// recording the frame order and playback rate.
struct StopMotionProject: Equatable {
    static let manifestName = "project.json"
    static let deletedFolderName = "Deleted Frames"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "png"]

    let folder: URL
    var fps: Int
    var frames: [String]

    var name: String { folder.lastPathComponent }
    var frameURLs: [URL] { frames.map(url(for:)) }

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
            let existing = manifest.frames.filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            return StopMotionProject(folder: folder, fps: manifest.fps, frames: existing)
        }

        let images = try imageFiles(in: folder).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let project = StopMotionProject(folder: folder, fps: 12, frames: images)
        try project.save()
        return project
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Manifest(version: 1, fps: fps, frames: frames))
        try data.write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: Editing

    /// Writes image data as a new frame at the end of the sequence and saves the manifest.
    @discardableResult
    mutating func appendFrame(data: Data, fileExtension: String) throws -> String {
        let name = String(format: "frame-%04d.%@", try nextFrameNumber(), fileExtension)
        try data.write(to: url(for: name), options: .withoutOverwriting)
        frames.append(name)
        try save()
        return name
    }

    /// Removes a frame from the sequence, moving its file into the "Deleted Frames"
    /// subfolder so it can be recovered.
    mutating func deleteFrame(_ frame: String) throws {
        guard let index = frames.firstIndex(of: frame) else { return }
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
        fps = min(max(newValue, 1), 60)
        try save()
    }

    // MARK: Helpers

    private struct Manifest: Codable {
        var version: Int
        var fps: Int
        var frames: [String]
    }

    private static func imageFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            imageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    /// One higher than any "frame-NNNN" file in the folder, so new files never collide
    /// and sort in capture order in Finder.
    private func nextFrameNumber() throws -> Int {
        let numbers = try Self.imageFiles(in: folder).compactMap { name -> Int? in
            let stem = (name as NSString).deletingPathExtension
            guard stem.hasPrefix("frame-") else { return nil }
            return Int(stem.dropFirst("frame-".count))
        }
        return (numbers.max() ?? 0) + 1
    }
}
