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

    enum MirrorError: LocalizedError {
        case manifestMissing
        case sizeMismatch(path: String, expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "The bundled model manifest is missing."
            case .sizeMismatch(let path, let expected, let got):
                return "Downloaded \(path) was \(got) bytes, expected \(expected). Please retry."
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

    /// Downloads any missing/incomplete files from the mirror.
    /// `onProgress` receives a 0...1 fraction of total bytes.
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
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }

            let (bytes, response) = try await URLSession.shared.bytes(from: remoteURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            var fileBytes = 0
            var lastReport = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= (1 << 20) {
                    try handle.write(contentsOf: buffer)
                    fileBytes += buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    if fileBytes - lastReport >= (2 << 20) {
                        lastReport = fileBytes
                        let done = baseCompleted + priorFilesBytes + fileBytes
                        onProgress(min(1.0, Double(done) / Double(total)))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                fileBytes += buffer.count
            }
            try handle.close()

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

    /// Removes every mirrored file so the model can be reinstalled.
    static func deleteModel() throws {
        let manifest = try loadManifest()
        let dir = modelsDirectory(prefix: manifest.prefix)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
