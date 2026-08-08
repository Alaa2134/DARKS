import Foundation

/// Reads a file the user picked from the Files app.
///
/// `Data(contentsOf:)` is not enough for a document picker URL, and the two
/// ways it fails are both things people hit constantly:
///
/// * **iCloud placeholders.** A file shown in Files may not be on the device at
///   all - only a stub. Reading it returns an error, and the app reports
///   "unreadable" for a file the user can plainly see.
/// * **Uncoordinated reads.** Provider-backed files (iCloud Drive, Dropbox,
///   Google Drive) need `NSFileCoordinator`, or the read races the provider
///   materialising the file.
///
/// This type downloads the file first when it needs downloading, then reads it
/// under coordination, and reports which of those failed so the message can say
/// something useful.
enum ImportedFile {

    enum ReadError: LocalizedError, Equatable {
        case accessDenied
        case notDownloaded
        case downloadFailed(String)
        case unreadable(String)
        case empty
        case tooLarge(bytes: Int64, limit: Int64)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return L.t("library.import.access_denied")
            case .notDownloaded:
                return L.t("library.import.not_downloaded")
            case .downloadFailed(let detail):
                return L.t("library.import.download_failed") + (detail.isEmpty ? "" : ": \(detail)")
            case .unreadable(let detail):
                return L.t("library.import.unreadable") + (detail.isEmpty ? "" : ": \(detail)")
            case .empty:
                return L.t("library.import.empty")
            case .tooLarge(let bytes, let limit):
                return L.t(
                    "library.import.too_large",
                    Format.fileSize(bytes),
                    Format.fileSize(limit)
                )
            }
        }
    }

    /// Uploading happens from memory, so a genuinely enormous mesh is refused up
    /// front with a clear reason rather than by being killed for memory.
    static let sizeLimit: Int64 = 512 * 1024 * 1024

    /// Reads a security-scoped URL, materialising it from iCloud if necessary.
    static func read(_ url: URL, sizeLimit: Int64 = ImportedFile.sizeLimit) async throws -> Data {
        // A URL from the document picker is security-scoped; a URL the Share
        // Extension already copied into the App Group is not, and calling stop
        // on a scope that never started is wrong. Track which happened.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let status = downloadStatus(of: url), status != .current {
            try await download(url)
        }

        if let size = fileSize(of: url), size > sizeLimit {
            throw ReadError.tooLarge(bytes: size, limit: sizeLimit)
        }

        let data = try coordinatedRead(url)
        guard !data.isEmpty else { throw ReadError.empty }
        return data
    }

    // MARK: - iCloud

    private static func downloadStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
    }

    private static func fileSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
    }

    /// Asks the system to bring the file down, then waits for it.
    ///
    /// `startDownloadingUbiquitousItem` is asynchronous with no completion
    /// handler, so the status is polled. The timeout keeps a stalled download
    /// from hanging the import forever.
    private static func download(_ url: URL, timeout: TimeInterval = 120) async throws {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw ReadError.downloadFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            let status = downloadStatus(of: url)
            // nil means it is not an iCloud item after all, so there is nothing
            // to wait for; .current means the local copy is up to date.
            if status == nil || status == .current { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ReadError.notDownloaded
    }

    // MARK: - Reading

    private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinatorError: NSError?
        var readError: Error?
        var data: Data?

        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [.withoutChanges], error: &coordinatorError
        ) { readableURL in
            do {
                data = try Data(contentsOf: readableURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }

        if let coordinatorError {
            throw ReadError.unreadable(coordinatorError.localizedDescription)
        }
        if let readError {
            throw ReadError.unreadable(readError.localizedDescription)
        }
        guard let data else { throw ReadError.accessDenied }
        return data
    }
}
