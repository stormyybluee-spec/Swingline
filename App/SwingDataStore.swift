//
//  SwingDataStore.swift
//  Swingline
//
//  On device persistence for swings. File based, not SwiftData, and the reasons
//  are worth stating because the choice is deliberate.
//
//  SwingRecord, and every engine type it carries, is already a Codable value
//  type. SwiftData would mean turning SwingRecord into an @Model reference type
//  and threading a ModelContext through the app, which ripples into AppStore,
//  the timeline, and every view that holds a swing by value today. A JSON file
//  per swing is the smaller, lower risk change, it mirrors how the web build
//  already stores records in IndexedDB (serialised records, blobs kept beside
//  them), and it keeps the record a plain value that is trivial to pass around
//  and test. If a real need for relational queries shows up later, this is a
//  clean thing to replace.
//
//  Layout, under Application Support/Swingline:
//
//    swings/<id>.json          the SwingRecord itself
//    swings/<id>.frames.json   the pose frames, for playback and overlays later
//    swings/<id>.mov           the video clip, when one exists
//    swings/<id>.jpg           the thumbnail, when one exists
//
//  Frames, video and thumbnail are kept beside the record rather than inside it,
//  exactly as the web build keeps full frame data separate, so the timeline can
//  list hundreds of swings without deserialising every landmark.
//
//  A note on what does not exist yet. The capture pipeline produces pose frames
//  but does not yet write a video file or a thumbnail. The store accepts both so
//  the seam is ready, but today they are nil. That is honest state, not an
//  oversight: video recording (AVAssetWriter) and thumbnailing are their own
//  step and are not part of this pass.
//
//  House rule: no em dashes anywhere.
//

import Foundation

// MARK: - Frame persistence DTOs

/*
  Frame, Landmark and Vec3 are not Codable, and adding Codable to them across
  files cannot rely on synthesis. Rather than edit the engine types, frames are
  mapped to these small DTOs for storage and back on load. Short keys because
  there are dozens of landmarks per frame and hundreds of frames per swing.
*/
private struct StoredLandmark: Codable {
    var x: Double
    var y: Double
    var z: Double?
    var v: Double?  // visibility (MediaPipe)
    var s: Double?  // score (Vision)

    init(_ l: Landmark) {
        x = l.x
        y = l.y
        z = l.z
        v = l.visibility
        s = l.score
    }

    var landmark: Landmark {
        Landmark(x: x, y: y, z: z, visibility: v, score: s)
    }
}

private struct StoredFrame: Codable {
    var t: Double
    var conf: Double
    var world: [StoredLandmark]
    var norm: [StoredLandmark]

    init(_ f: Frame) {
        t = f.t
        conf = f.conf
        world = f.world.map(StoredLandmark.init)
        norm = f.norm.map(StoredLandmark.init)
    }

    var frame: Frame {
        Frame(t: t, world: world.map(\.landmark), norm: norm.map(\.landmark), conf: conf)
    }
}

// MARK: - Store

public struct SwingDataStore {

    public enum StoreError: Error {
        case noDirectory
    }

    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        // Application Support is the right home: not user facing, backed up, and
        // survives restarts. The directory is created on demand.
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        self.root = base.appendingPathComponent("Swingline/swings", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Paths

    private func recordURL(_ id: String) -> URL { root.appendingPathComponent("\(id).json") }
    private func framesURL(_ id: String) -> URL { root.appendingPathComponent("\(id).frames.json") }
    public func videoURL(_ id: String) -> URL { root.appendingPathComponent("\(id).mov") }
    public func thumbnailURL(_ id: String) -> URL { root.appendingPathComponent("\(id).jpg") }

    // MARK: Saving

    /*
      Persist a record and, when present, its frames. Video and thumbnail are
      passed as file URLs the caller already wrote, and are moved into place
      beside the record. All three are optional so a failed swing with no frames
      still saves its record.

      Writes are atomic so a crash mid save never leaves a half written record
      that fails to decode on next launch.
    */
    public func save(_ record: SwingRecord, frames: [Frame]? = nil, video: URL? = nil, thumbnail: URL? = nil) throws {
        let recordData = try encoder.encode(record)
        try recordData.write(to: recordURL(record.id), options: .atomic)

        if let frames {
            let dto = frames.map(StoredFrame.init)
            let frameData = try encoder.encode(dto)
            try frameData.write(to: framesURL(record.id), options: .atomic)
        }

        if let video {
            let dest = videoURL(record.id)
            try? fileManager.removeItem(at: dest)
            try fileManager.moveItem(at: video, to: dest)
        }

        // Replacement is already the behaviour: the old tile is removed before
        // the new one is moved in, so regenerating a thumbnail for an existing
        // swing overwrites rather than failing on a name that exists.
        if let thumbnail {
            let dest = thumbnailURL(record.id)
            try? fileManager.removeItem(at: dest)
            try fileManager.moveItem(at: thumbnail, to: dest)
        }
    }

    // MARK: Loading

    /*
      Every stored record, newest first. A single record that fails to decode is
      skipped rather than taking the whole history down with it, and its id is
      returned so the caller can decide whether to warn. One bad file must never
      cost a golfer the rest of their swings.
    */
    public func loadAllRecords() -> (records: [SwingRecord], skipped: [String]) {
        guard let names = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return ([], [])
        }

        var records: [SwingRecord] = []
        var skipped: [String] = []

        for url in names where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".frames.json") {
            guard let data = try? Data(contentsOf: url) else {
                skipped.append(url.lastPathComponent)
                continue
            }
            if let record = try? decoder.decode(SwingRecord.self, from: data) {
                records.append(record)
            } else {
                skipped.append(url.lastPathComponent)
            }
        }

        records.sort { $0.createdAt > $1.createdAt }
        return (records, skipped)
    }

    // Frames for one swing, decoded back into engine Frames. Nil when a swing
    // has no stored frames (a failed capture) or the file is unreadable.
    public func loadFrames(_ id: String) -> [Frame]? {
        guard
            let data = try? Data(contentsOf: framesURL(id)),
            let dto = try? decoder.decode([StoredFrame].self, from: data)
        else { return nil }
        return dto.map(\.frame)
    }

    public func hasVideo(_ id: String) -> Bool { fileManager.fileExists(atPath: videoURL(id).path) }
    public func hasThumbnail(_ id: String) -> Bool { fileManager.fileExists(atPath: thumbnailURL(id).path) }

    // MARK: Deleting

    /*
      Remove a swing and everything stored beside it. Missing files are not an
      error, since a failed swing legitimately has no frames or video.

      The annotation sidecar is deleted here too. It was added in Phase 5 after
      this method was written and was never added to the list, so a deleted swing
      left its drawing on disk for good: dead bytes that nothing could ever load
      again, since the record that named them was gone. Bulk delete would have
      multiplied that, which is what surfaced it.
    */
    public func delete(_ id: String) {
        for url in [recordURL(id), framesURL(id), videoURL(id), thumbnailURL(id), annotationURL(id)] {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Phase 5 additions (annotation sidecar + video replacement)

    // The annotation sidecar, kept beside the record like frames and video, so
    // the timeline never deserialises drawing data it does not need.
    public func annotationURL(_ id: String) -> URL {
        root.appendingPathComponent("\(id).drawing")
    }

    public func hasAnnotation(_ id: String) -> Bool {
        fileManager.fileExists(atPath: annotationURL(id).path)
    }

    public func loadAnnotation(_ id: String) -> Data? {
        try? Data(contentsOf: annotationURL(id))
    }

    // Nil data removes the sidecar, so clearing a drawing does not leave a stale
    // one on disk to reappear when the swing is reopened.
    public func saveAnnotation(_ id: String, data: Data?) {
        let url = annotationURL(id)
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    // Swap in an edited clip. The caller has already written the new file to a
    // temporary URL; this moves it into place over the old one. Frames, record,
    // thumbnail and annotation are untouched, because a trim or a rotate changes
    // only the picture.
    public func replaceVideo(_ id: String, with newVideo: URL) throws {
        let dest = videoURL(id)
        try? fileManager.removeItem(at: dest)
        try fileManager.moveItem(at: newVideo, to: dest)
    }
}