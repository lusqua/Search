import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
    }

    /// The first Space's is the file there always was; every other Space
    /// has one of its own beside it.
    private static func file(for space: UUID) -> URL {
        space == Space.homeID ? Store.file("session.json") : Store.file("session-\(space.uuidString).json")
    }

    static func read(_ space: UUID = Space.homeID) -> Shape {
        let file = file(for: space)
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], active: 0) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], active: 0)
        }
        return shape
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
    static func write(now: Bool = false, _ shape: Shape, in space: UUID = Space.homeID) {
        let file = file(for: space)
        let put = {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
        if now {
            put()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: put)
        }
    }

    /// A deleted Space's tabs, gone with it.
    static func forget(_ space: UUID) {
        guard space != Space.homeID else { return }
        try? FileManager.default.removeItem(at: file(for: space))
    }
}
