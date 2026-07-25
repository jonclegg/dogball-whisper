import Foundation

/// Downloads the Parakeet V3 model from our own CloudFront mirror straight into
/// the directory FluidAudio loads from, so FluidAudio never touches HuggingFace.
///
/// FluidAudio's own downloader enumerates a repo via HuggingFace's listing API
/// and can't be pointed at a plain file host. Instead we ship a fixed manifest,
/// pull each file from CloudFront into FluidAudio's cache directory, and then let
/// FluidAudio load from cache (it skips the network when every required file is
/// already present). Bonus: because we own the transfer, we get a byte-accurate
/// progress fraction, which FluidAudio's file-count progress can't give us.
enum ModelMirror {
    /// CloudFront distribution fronting the S3 model bucket.
    static let baseURL = URL(string: "https://d36t08oi3ecji2.cloudfront.net")!

    struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int
        }
        let prefix: String
        let totalBytes: Int
        let files: [File]
    }

    enum MirrorError: LocalizedError, Equatable {
        case manifestMissing
        case sizeMismatch(path: String, expected: Int, got: Int)
        case rangeNotHonored(path: String)

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "The bundled model manifest is missing."
            case .sizeMismatch(let path, let expected, let got):
                return "Downloaded \(path) was \(got) bytes, expected \(expected). Please retry."
            case .rangeNotHonored(let path):
                return "The server sent the wrong byte range for \(path). Please retry."
            }
        }
    }

    static func loadManifest() throws -> Manifest {
        guard let url = Bundle.main.url(forResource: "parakeet-manifest", withExtension: "json") else {
            throw MirrorError.manifestMissing
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    /// FluidAudio's default cache directory for the Parakeet V3 repo.
    /// Mirrors `MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV3)`.
    static func modelsDirectory(prefix: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
    }

    /// True when every manifest file is already present at the right size.
    static func isComplete() -> Bool {
        guard let manifest = try? loadManifest() else { return false }
        let dir = modelsDirectory(prefix: manifest.prefix)
        return manifest.files.allSatisfy { file in
            let path = dir.appendingPathComponent(file.path)
            guard let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int else {
                return false
            }
            return size == file.size
        }
    }

    /// What a fetch should do about the bytes already sitting in a `.partial`
    /// file. Pure, so the resume decision is unit-testable without a network:
    /// the transfer itself is the only part that needs one.
    enum ResumePlan: Equatable {
        /// Nothing usable on disk: request the whole file, write from zero.
        case fresh
        /// Ask for `bytes=<offset>-` and append to what is already there.
        case resume(offset: Int)
        /// Every byte is already in the partial; no request needed.
        case complete
    }

    static func resumePlan(partialBytes: Int?, expectedBytes: Int) -> ResumePlan {
        guard let partialBytes, partialBytes > 0 else { return .fresh }
        if partialBytes == expectedBytes { return .complete }
        // More bytes than the file has means what is on disk is not a prefix
        // of what we are fetching, so there is nothing to resume from.
        guard partialBytes < expectedBytes else { return .fresh }
        return .resume(offset: partialBytes)
    }

    /// Whether a `206` response is really the continuation we asked for.
    /// Appending a body that starts anywhere else would silently corrupt the
    /// file, and the size check at the end would not catch it.
    /// Expected header shape: `bytes <start>-<end>/<total>`.
    static func rangeIsHonored(contentRange: String?, offset: Int, expectedBytes: Int) -> Bool {
        guard let contentRange else { return false }
        let spec = contentRange.trimmingCharacters(in: .whitespaces)
        guard spec.hasPrefix("bytes ") else { return false }
        let parts = spec.dropFirst("bytes ".count).split(separator: "/")
        guard parts.count == 2, Int(parts[1]) == expectedBytes else { return false }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2,
              Int(bounds[0]) == offset,
              Int(bounds[1]) == expectedBytes - 1
        else { return false }
        return true
    }

    private static func partialByteCount(at url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
    }

    /// Downloads any missing/incomplete files from the mirror.
    /// `onProgress` receives a 0...1 fraction of total bytes.
    ///
    /// Resumable at byte granularity: an interrupted transfer leaves its
    /// `.partial` file on disk and the next call asks the server for the rest
    /// with a `Range` header, which matters because one file in the manifest
    /// is 92% of the payload. A partial is only thrown away when its bytes
    /// can no longer be trusted (see `fetch`).
    static func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let manifest = try loadManifest()
        let dir = modelsDirectory(prefix: manifest.prefix)
        let total = manifest.totalBytes

        // Count bytes already on disk so a resumed download reports true progress.
        var completedBytes = 0
        var pending: [Manifest.File] = []
        for file in manifest.files {
            let dest = dir.appendingPathComponent(file.path)
            if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int, size == file.size {
                completedBytes += file.size
            } else {
                pending.append(file)
            }
        }
        onProgress(Double(completedBytes) / Double(total))

        let baseCompleted = completedBytes
        var priorFilesBytes = 0
        for file in pending {
            let dest = dir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            let remoteURL = baseURL
                .appendingPathComponent(manifest.prefix)
                .appendingPathComponent(file.path)
            let tmp = dest.appendingPathExtension("partial")

            // Bytes already on disk for this file are only folded into the
            // reported fraction once the response has been accepted, so a
            // server that ignores our Range header (and forces a restart from
            // zero) cannot make progress run backwards.
            let priorBytes = baseCompleted + priorFilesBytes
            let fileBytes = try await fetch(
                file: file, from: remoteURL, into: tmp,
                onBytes: { done in
                    onProgress(min(1.0, Double(priorBytes + done) / Double(total)))
                })

            guard fileBytes == file.size else {
                try? FileManager.default.removeItem(at: tmp)
                throw MirrorError.sizeMismatch(path: file.path, expected: file.size, got: fileBytes)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)

            priorFilesBytes += file.size
            onProgress(min(1.0, Double(baseCompleted + priorFilesBytes) / Double(total)))
        }
        onProgress(1.0)
    }

    /// Brings `tmp` up to `file.size` bytes, resuming from whatever is already
    /// there, and returns how many bytes it now holds.
    ///
    /// The partial survives a transport failure on purpose: those bytes are a
    /// verified prefix and re-fetching them is the whole point of resume. It
    /// is deleted whenever it stops being trustworthy — a non-2xx response, a
    /// `206` whose `Content-Range` is not what we asked for, or a failed write.
    private static func fetch(
        file: Manifest.File,
        from remoteURL: URL,
        into tmp: URL,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        let plan = resumePlan(partialBytes: partialByteCount(at: tmp), expectedBytes: file.size)
        if case .complete = plan { return file.size }

        var request = URLRequest(url: remoteURL)
        var resumeOffset = 0
        if case let .resume(offset) = plan {
            resumeOffset = offset
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else {
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: tmp)
        if resumeOffset > 0 { try handle.seek(toOffset: UInt64(resumeOffset)) }

        do {
            let written = try await PartialFileDownload.run(
                request: request, handle: handle, resumeOffset: resumeOffset,
                expectedBytes: file.size, path: file.path, onBytes: onBytes)
            try handle.close()
            return written
        } catch let failure as PartialFileDownload.Failure {
            try? handle.close()
            if !failure.partialIsResumable {
                try? FileManager.default.removeItem(at: tmp)
            }
            throw failure.underlying
        }
    }

    /// Removes every mirrored file so the model can be reinstalled.
    static func deleteModel() throws {
        let manifest = try loadManifest()
        let dir = modelsDirectory(prefix: manifest.prefix)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

/// Streams one HTTP response body straight into an open file.
///
/// `URLSession.bytes` only offers a byte-at-a-time `AsyncSequence`, which costs
/// an async resumption per byte — real CPU over a 445MB file. This drops to the
/// delegate API, which hands over whole chunks, and writes them from the
/// delegate queue so the transfer is paced by the disk instead of piling up in
/// memory behind a slower consumer.
///
/// Every mutable field is touched only from that one serial delegate queue (and
/// the continuation is resumed exactly once, under a lock), which is what the
/// `@unchecked Sendable` records.
private final class PartialFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Wraps whatever went wrong with the one thing the caller has to decide
    /// afterwards: whether the bytes already on disk are still a usable prefix.
    struct Failure: Error {
        let underlying: Error
        let partialIsResumable: Bool
    }

    /// Report progress about this often, so a 445MB file emits a few hundred
    /// updates rather than one per chunk.
    private static let reportInterval = 2 << 20

    private let handle: FileHandle
    private let resumeOffset: Int
    private let expectedBytes: Int
    private let path: String
    private let onBytes: @Sendable (Int) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var isFinished = false
    /// Set when the transfer finishes before anyone was waiting on it, which
    /// `withTaskCancellationHandler` makes reachable: its `onCancel` can run
    /// (and cancel the task, completing it) before the continuation body has
    /// handed us the continuation. Without this, that call would never resume.
    private var earlyResult: Result<Int, Error>?

    private var bytesOnDisk: Int
    private var lastReport: Int
    private var failure: Failure?

    private init(
        handle: FileHandle, resumeOffset: Int, expectedBytes: Int, path: String,
        onBytes: @escaping @Sendable (Int) -> Void
    ) {
        self.handle = handle
        self.resumeOffset = resumeOffset
        self.expectedBytes = expectedBytes
        self.path = path
        self.onBytes = onBytes
        self.bytesOnDisk = resumeOffset
        self.lastReport = resumeOffset
    }

    /// Runs `request`, appending its body to `handle`, and returns how many
    /// bytes the file holds afterwards. Throws `Failure`.
    static func run(
        request: URLRequest,
        handle: FileHandle,
        resumeOffset: Int,
        expectedBytes: Int,
        path: String,
        onBytes: @escaping @Sendable (Int) -> Void
    ) async throws -> Int {
        let delegate = PartialFileDownload(
            handle: handle, resumeOffset: resumeOffset, expectedBytes: expectedBytes,
            path: path, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.attach(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func attach(_ continuation: CheckedContinuation<Int, Error>) {
        lock.lock()
        if let earlyResult {
            self.earlyResult = nil
            lock.unlock()
            continuation.resume(with: earlyResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Int, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let pending = continuation
        continuation = nil
        if pending == nil { earlyResult = result }
        lock.unlock()
        pending?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            failure = Failure(underlying: URLError(.badServerResponse), partialIsResumable: false)
            completionHandler(.cancel)
            return
        }
        guard resumeOffset > 0 else {
            completionHandler(.allow)
            return
        }
        if http.statusCode == 200 {
            // The server ignored our Range header, so this body is the whole
            // file: throw away what we had and rewrite from byte zero.
            do {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
            } catch {
                failure = Failure(underlying: error, partialIsResumable: false)
                completionHandler(.cancel)
                return
            }
            bytesOnDisk = 0
            lastReport = 0
        } else if !ModelMirror.rangeIsHonored(
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            offset: resumeOffset, expectedBytes: expectedBytes)
        {
            failure = Failure(
                underlying: ModelMirror.MirrorError.rangeNotHonored(path: path),
                partialIsResumable: false)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A half-written chunk means the file is no longer a clean prefix.
            failure = Failure(underlying: error, partialIsResumable: false)
            dataTask.cancel()
            return
        }
        bytesOnDisk += data.count
        if bytesOnDisk - lastReport >= Self.reportInterval {
            lastReport = bytesOnDisk
            onBytes(bytesOnDisk)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Breaks the session's strong reference to this delegate.
        session.finishTasksAndInvalidate()
        if let failure {
            finish(.failure(failure))
        } else if let error {
            // A dropped connection leaves a verified prefix on disk; that is
            // exactly what the next call resumes from.
            finish(.failure(Failure(underlying: error, partialIsResumable: true)))
        } else {
            finish(.success(bytesOnDisk))
        }
    }
}
