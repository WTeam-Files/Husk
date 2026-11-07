// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

// MARK: - what can be downloaded

/// One Android system image the dependencies release offers.
struct GuestImageOption: Identifiable, Hashable {
    /// The asset's name, e.g. "vda-v12.qcow2".
    let file: String
    /// Its generation, e.g. "v12".
    let version: String
    let size: Int64
    /// SHA-256 when the release states one (the manifest, or GitHub's own asset digest); nil when nothing does.
    let sha256: String?
    /// The one the release's manifest points at.
    let recommended: Bool

    var id: String { file }
    var number: Int { GuestImageOption.number(version) }

    static func number(_ version: String) -> Int { Int(version.drop { !$0.isNumber }) ?? 0 }

    /// What each generation changed, for the picker. Unknown (newer) generations get a generic line.
    var summary: String {
        switch number {
        case 12: return "Latest. Ethernet is registered, so the command bridge stays connected after boot."
        case 11: return "Boot-menu fix over v10. Smaller download."
        case 10: return "First image with Husk's command bridge (the Library and APK installs need it). Smallest download."
        default: return recommended ? "The release's current image." : "An image published on the dependencies release."
        }
    }
}

/// Everything the picker offers: the images on the dependencies release, and the pre-booted snapshot.
struct GuestCatalog: Equatable {
    var images: [GuestImageOption]
    var snapshot: GuestManifest.Snapshot?
    /// The generation the snapshot was saved on (from its file name); images older than that cannot restore it.
    var snapshotVersion: Int

    /// Images older than this lack the command bridge the app talks to (see GuestImage.imageVersion), so they are not offered.
    static let minimumImageNumber = 10

    var recommended: GuestImageOption? { images.first { $0.recommended } ?? images.first }

    func snapshotFits(_ image: GuestImageOption) -> Bool { snapshot != nil && image.number >= snapshotVersion }

    /// The manifest says what is current; GitHub's release listing says what else is there. Either alone is enough to
    /// offer something: offline from the API (it allows 60 anonymous requests an hour) still leaves the manifest's image.
    static func load(manifest: GuestManifest?) async -> GuestCatalog {
        var options: [String: GuestImageOption] = [:]
        if let m = manifest {
            options[m.image.file] = GuestImageOption(file: m.image.file, version: version(of: m.image.file) ?? m.generation,
                                                     size: m.image.size, sha256: m.image.sha256, recommended: true)
        }
        for asset in await releaseAssets() {
            guard let v = version(of: asset.name), asset.name.hasPrefix("vda-"), asset.name.hasSuffix(".qcow2"),
                  GuestImageOption.number(v) >= minimumImageNumber, options[asset.name] == nil else { continue }
            let digest = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            options[asset.name] = GuestImageOption(file: asset.name, version: v, size: asset.size, sha256: digest,
                                                   recommended: false)
        }
        var images = options.values.sorted { $0.number > $1.number }
        if manifest == nil, let newest = images.first {
            images[0] = GuestImageOption(file: newest.file, version: newest.version, size: newest.size,
                                         sha256: newest.sha256, recommended: true)
        }
        let snapVersion = manifest?.snapshot.parts.first.flatMap(version(of:)).map(GuestImageOption.number) ?? 0
        return GuestCatalog(images: images, snapshot: manifest?.snapshot, snapshotVersion: snapVersion)
    }

    /// "vda-v12.qcow2" -> "v12", "vdb-snapshot-v10.qcow2.gz.00" -> "v10".
    static func version(of file: String) -> String? {
        guard let r = file.range(of: #"-v\d+"#, options: .regularExpression) else { return nil }
        return String(file[r].dropFirst())
    }

    private struct Asset: Decodable { let name: String; let size: Int64; let digest: String? }
    private struct Release: Decodable { let assets: [Asset] }

    private static func releaseAssets() async -> [Asset] {
        let url = URL(string: "https://api.github.com/repos/Leviidev/Husk/releases/tags/\(GuestImage.dependenciesTag)")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                HuskLog.log("guest", "release listing unavailable (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
                return []
            }
            return try JSONDecoder().decode(Release.self, from: data).assets
        } catch {
            HuskLog.log("guest", "release listing failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - a download that can stop and continue

/// What is being downloaded, remembered across launches so a paused (or interrupted) download continues from the bytes
/// already on disk instead of starting again.
struct GuestDownloadJob: Codable, Equatable {
    enum Stage: String, Codable { case image, snapshot }

    var stage: Stage
    /// The system image, when this job installs one.
    var imageFile: String?
    var imageVersion: String?
    var imageSize: Int64
    var imageSHA256: String?
    /// The snapshot's parts, in order, when this job installs it (after the image, or on its own).
    var snapshotParts: [String]
    var snapshotSize: Int64
    var snapshotSHA256: String?
    /// How many snapshot parts are complete on disk.
    var partsDone: Int = 0
    /// True when the snapshot follows a fresh image: failing it then only means Android boots from cold.
    var snapshotIsOptional: Bool
    var paused: Bool = false

    var includesSnapshot: Bool { !snapshotParts.isEmpty }

    /// Bytes this job downloads in all: the image (when it has one) and the snapshot (when it has one).
    var totalBytes: Int64 { (imageFile != nil ? imageSize : 0) + (includesSnapshot ? snapshotSize : 0) }

    /// Bytes of this job already behind the current stage: the installed image, and the snapshot parts already complete.
    var bytesBeforeCurrent: Int64 {
        guard stage == .snapshot else { return 0 }
        let image: Int64 = imageFile != nil ? imageSize : 0
        return image + snapshotParts.prefix(partsDone).reduce(0) { $0 + ResumableFetch.size(Self.partURL($1)) }
    }

    private static let key = "husk.guest.pendingDownload"

    static func load() -> GuestDownloadJob? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GuestDownloadJob.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// Where partial downloads live: Application Support, not tmp (which iOS empties when it likes, and a paused download
    /// has to survive that), and out of iCloud backups.
    static var folder: URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuestDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }

    static func partURL(_ file: String) -> URL { folder.appendingPathComponent(file + ".part") }

    /// Bytes already on disk for this job, for the progress bar of a paused download.
    var bytesOnDisk: Int64 {
        switch stage {
        case .image: return imageFile.map { ResumableFetch.size(Self.partURL($0)) } ?? 0
        case .snapshot:
            return bytesBeforeCurrent + (partsDone < snapshotParts.count
                                         ? ResumableFetch.size(Self.partURL(snapshotParts[partsDone])) : 0)
        }
    }

    static func removeAllParts() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Fetches one URL into a `.part` file with Range requests: `pause()` stops it with the bytes kept, and `start()` again
/// continues from them -- across launches too, since the bytes are all there is to remember.
///
/// A data task, not a download task: a download task's resume data names the CDN URL GitHub redirected to, which is signed
/// and expires within minutes, so resuming from it fails exactly when a pause has been long. Asking the release URL again
/// with a Range header gets a fresh redirect every time.
final class ResumableFetch: NSObject, URLSessionDataDelegate {
    let url: URL
    let part: URL
    private let onProgress: (_ received: Int64, _ total: Int64) -> Void
    private let onDone: (Result<URL, Error>) -> Void

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var session: URLSession?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var lastReport = Date.distantPast
    /// Bumped on every start and pause, so callbacks from a task that was stopped are ignored.
    private var generation = 0
    private var failure: String?
    private var alreadyComplete = false

    init(url: URL, part: URL,
         progress: @escaping (_ received: Int64, _ total: Int64) -> Void,
         completion: @escaping (Result<URL, Error>) -> Void) {
        self.url = url
        self.part = part
        self.onProgress = progress
        self.onDone = completion
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func start() {
        queue.addOperation { [self] in
            generation += 1
            failure = nil
            alreadyComplete = false
            if !FileManager.default.fileExists(atPath: part.path) {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            received = Self.size(part)
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            if received > 0 { req.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            let s = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            session = s
            let task = s.dataTask(with: req)
            task.taskDescription = String(generation)
            task.resume()
            HuskLog.log("guest", "fetching \(url.lastPathComponent)" + (received > 0 ? " from byte \(received)" : ""))
        }
    }

    /// Stop, keeping what has arrived. No completion is reported.
    func pause() {
        queue.addOperation { [self] in
            generation += 1
            session?.invalidateAndCancel()
            session = nil
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            HuskLog.log("guest", "paused \(url.lastPathComponent) at \(Self.size(part)) bytes")
        }
    }

    private func current(_ task: URLSessionTask) -> Bool { task.taskDescription == String(generation) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard current(dataTask), let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            switch http.statusCode {
            case 206:
                // Continuing: "Content-Range: bytes 1000-1999/2000".
                let h = try FileHandle(forWritingTo: part)
                try h.seekToEnd()
                handle = h
                total = Self.contentRangeTotal(http) ?? (received + max(0, http.expectedContentLength))
            case 200:
                // The whole file, from the start (the server ignored the Range, or nothing was there yet).
                FileManager.default.createFile(atPath: part.path, contents: nil)
                handle = try FileHandle(forWritingTo: part)
                received = 0
                total = max(0, http.expectedContentLength)
            case 416 where Self.contentRangeTotal(http) == received:
                // Asked for bytes past the end: the part is already whole.
                alreadyComplete = true
                total = received
                completionHandler(.cancel)
                return
            default:
                failure = "HTTP \(http.statusCode) fetching \(url.lastPathComponent)"
                if http.statusCode == 416 { try? FileManager.default.removeItem(at: part) }
                completionHandler(.cancel)
                return
            }
        } catch {
            failure = "could not write \(part.lastPathComponent): \(error.localizedDescription)"
            completionHandler(.cancel)
            return
        }
        onProgress(received, total)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard current(dataTask), let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = "could not write the download: \(error.localizedDescription)"
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        if Date().timeIntervalSince(lastReport) > 0.25 {
            lastReport = Date()
            onProgress(received, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard current(task) else { return }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        if alreadyComplete || (failure == nil && error == nil) {
            if total > 0, received < total {
                onDone(.failure(Self.error("the connection closed at \(received) of \(total) bytes")))
                return
            }
            onProgress(received, max(total, received))
            onDone(.success(part))
        } else {
            onDone(.failure(Self.error(failure ?? error?.localizedDescription ?? "download failed")))
        }
    }

    private static func contentRangeTotal(_ http: HTTPURLResponse) -> Int64? {
        guard let range = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = range.lastIndex(of: "/") else { return nil }
        return Int64(range[range.index(after: slash)...])
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "husk", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - reading parts as one stream

/// Several files read back to back as if they were one: the snapshot's parts are a byte-split gzip, so hashing and
/// unpacking them in order is the same as doing so to the joined archive -- without writing a two-gigabyte copy first.
final class ConcatReader {
    private var files: [URL]
    private var handle: FileHandle?

    init(_ files: [URL]) { self.files = files }

    func read(upToCount count: Int) throws -> Data? {
        var out = Data()
        while out.count < count {
            if handle == nil {
                guard !files.isEmpty else { break }
                handle = try FileHandle(forReadingFrom: files.removeFirst())
            }
            let chunk = try handle!.read(upToCount: count - out.count) ?? Data()
            if chunk.isEmpty {
                try? handle?.close()
                handle = nil
            } else {
                out.append(chunk)
            }
        }
        return out
    }

    func close() { try? handle?.close(); handle = nil; files = [] }

    /// SHA-256 of the files back to back.
    static func digest(_ files: [URL]) -> String? {
        let reader = ConcatReader(files)
        defer { reader.close() }
        let writer = DigestWriter()
        do {
            while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty { writer.update(chunk) }
        } catch { return nil }
        return writer.finish()
    }
}
