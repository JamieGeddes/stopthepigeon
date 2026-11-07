import Foundation
import Testing

@Suite struct StopMotionProjectTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StopThePigeonTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func createWritesManifest() throws {
        let project = try StopMotionProject.create(at: folder, fps: 10)
        #expect(project.frames.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path))
    }

    @Test func appendNumbersFramesSequentially() throws {
        var project = try StopMotionProject.create(at: folder)
        try project.appendFrame(data: Data([1]), fileExtension: "jpg")
        try project.appendFrame(data: Data([2]), fileExtension: "jpg")
        #expect(project.frames == ["frame-0001.jpg", "frame-0002.jpg"])
        #expect(try Data(contentsOf: project.url(for: "frame-0002.jpg")) == Data([2]))
    }

    @Test func reopenPreservesOrderAndFPS() throws {
        var project = try StopMotionProject.create(at: folder)
        for byte in 1...3 { try project.appendFrame(data: Data([UInt8(byte)]), fileExtension: "jpg") }
        try project.moveFrame("frame-0003.jpg", by: -2)
        try project.setFPS(8)

        let reopened = try StopMotionProject.open(at: folder)
        #expect(reopened.frames == ["frame-0003.jpg", "frame-0001.jpg", "frame-0002.jpg"])
        #expect(reopened.fps == 8)
    }

    @Test func moveIsClampedToEnds() throws {
        var project = try StopMotionProject.create(at: folder)
        for byte in 1...3 { try project.appendFrame(data: Data([UInt8(byte)]), fileExtension: "jpg") }
        try project.moveFrame("frame-0001.jpg", by: 10)
        #expect(project.frames == ["frame-0002.jpg", "frame-0003.jpg", "frame-0001.jpg"])
        try project.moveFrame("frame-0001.jpg", by: -10)
        #expect(project.frames == ["frame-0001.jpg", "frame-0002.jpg", "frame-0003.jpg"])
    }

    @Test func deleteMovesFileToDeletedFolder() throws {
        var project = try StopMotionProject.create(at: folder)
        try project.appendFrame(data: Data([1]), fileExtension: "jpg")
        try project.appendFrame(data: Data([2]), fileExtension: "jpg")
        try project.deleteFrame("frame-0001.jpg")

        #expect(project.frames == ["frame-0002.jpg"])
        #expect(!FileManager.default.fileExists(atPath: project.url(for: "frame-0001.jpg").path))
        let deleted = folder.appendingPathComponent("Deleted Frames/frame-0001.jpg")
        #expect(FileManager.default.fileExists(atPath: deleted.path))
    }

    @Test func newFramesDoNotReuseNumbersOfRemainingFiles() throws {
        var project = try StopMotionProject.create(at: folder)
        try project.appendFrame(data: Data([1]), fileExtension: "jpg")
        try project.appendFrame(data: Data([2]), fileExtension: "jpg")
        try project.deleteFrame("frame-0001.jpg")
        let name = try project.appendFrame(data: Data([3]), fileExtension: "jpg")
        #expect(name == "frame-0003.jpg")
    }

    @Test func openAdoptsFolderOfImagesInNaturalOrder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["shot10.jpg", "shot2.jpg", "notes.txt", "shot1.JPG"] {
            try Data([0]).write(to: folder.appendingPathComponent(name))
        }
        let project = try StopMotionProject.open(at: folder)
        #expect(project.frames == ["shot1.JPG", "shot2.jpg", "shot10.jpg"])
        #expect(project.fps == 12)
    }

    @Test func openSkipsFramesMissingFromDisk() throws {
        var project = try StopMotionProject.create(at: folder)
        try project.appendFrame(data: Data([1]), fileExtension: "jpg")
        try project.appendFrame(data: Data([2]), fileExtension: "jpg")
        try FileManager.default.removeItem(at: project.url(for: "frame-0001.jpg"))
        #expect(try StopMotionProject.open(at: folder).frames == ["frame-0002.jpg"])
    }
}
