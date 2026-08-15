import Foundation

/// G-code files (from Moonraker) and uploaded models (on the Raspberry Pi).
@MainActor
final class FilesStore: ObservableObject {

    @Published private(set) var gcodes: [BackendGCodeFile] = []
    @Published private(set) var models: [BackendModelFile] = []
    @Published private(set) var isLoadingGCodes = false
    @Published private(set) var isLoadingModels = false
    @Published var uploadProgressLabel: String?
    @Published var lastError: APIError?

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - G-code

    func loadGCodes() async {
        guard !isLoadingGCodes else { return }
        isLoadingGCodes = true
        defer { isLoadingGCodes = false }

        if settings.demoMode {
            gcodes = DemoSimulator.demoGCodes
            return
        }

        // Prefer the backend (it merges Moonraker + locally sliced files);
        // fall back to talking to Moonraker directly if the backend is down.
        do {
            gcodes = try await printer.backend.gcodes()
            lastError = nil
            return
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }

        do {
            let files = try await printer.moonraker.listGCodes()
            gcodes = files.map(Self.convert)
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    static func convert(_ file: MoonrakerFile) -> BackendGCodeFile {
        BackendGCodeFile(
            path: file.path,
            filename: file.filename,
            size: file.size ?? 0,
            modified: file.modified ?? 0,
            estimatedTime: file.estimatedTime,
            filamentTotalMM: file.filamentTotal,
            filamentWeightG: file.filamentWeightTotal,
            layerHeight: file.layerHeight,
            firstLayerHeight: file.firstLayerHeight,
            objectHeight: file.objectHeight,
            filamentType: file.filamentType,
            filamentName: file.filamentName,
            slicer: file.slicer,
            thumbnailPath: file.thumbnailPath,
            layerCount: nil,
            // Moonraker's own metadata knows nothing about colour changes -
            // they are our header, and reading it means opening the file. The
            // detail screen fetches them for one file at a time instead.
            storedColorChanges: nil,
            source: "moonraker"
        )
    }

    func delete(_ file: BackendGCodeFile) async {
        guard !settings.demoMode else {
            gcodes.removeAll { $0.id == file.id }
            return
        }
        do {
            if file.source == "backend" {
                try await printer.backend.deleteLocalGCode(name: file.filename)
            } else {
                try await printer.moonraker.deleteGCode(path: file.path)
            }
            gcodes.removeAll { $0.id == file.id }
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    /// Starts a print and reports whether it actually started.
    ///
    /// The Moonraker path runs through `PrinterStore`, which records its own
    /// failures on its own `lastError` - and no file screen displays that one.
    /// So a refused print produced a dismissed sheet, a screen that popped
    /// back, and not one word anywhere: "I press print and nothing happens".
    /// The error is carried across here so the screen the user is looking at is
    /// the screen that shows it.
    @discardableResult
    func startPrint(_ file: BackendGCodeFile) async -> Bool {
        if settings.demoMode {
            printer.demoStartPrint(
                filename: file.filename,
                estimatedSeconds: file.estimatedTime ?? 2_700,
                layers: file.layerCount ?? 240
            )
            return true
        }
        if file.source == "backend" {
            do {
                _ = try await printer.backend.sendLocalGCodeToPrinter(name: file.filename, startPrint: true)
                Haptics.success()
                return true
            } catch {
                lastError = APIError.from(error, host: settings.host)
                Haptics.error()
                return false
            }
        }
        let started = await printer.startPrint(filename: file.path)
        if !started {
            lastError = printer.lastError ?? .unknown(L.t("print.failed_to_start"))
            // Handed over, not copied: the root now shows printer errors too,
            // and the same sentence twice on one screen reads like two faults.
            printer.lastError = nil
        }
        return started
    }

    func download(_ file: BackendGCodeFile) async -> URL? {
        guard !settings.demoMode else { return nil }
        do {
            let data: Data
            if file.source == "backend" {
                data = try await printer.backend.downloadLocalGCode(name: file.filename)
            } else {
                data = try await printer.moonraker.downloadGCode(path: file.path)
            }
            return try writeTemporary(data: data, filename: file.filename)
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    func metadata(for file: BackendGCodeFile) async -> MoonrakerFile? {
        guard !settings.demoMode, file.source == "moonraker" else { return nil }
        return try? await printer.moonraker.metadata(filename: file.path)
    }

    /// The colour changes a file will stop for.
    ///
    /// Fetched per file rather than carried in the listing, because reading the
    /// plan means opening the G-code. Failure is silent and returns nothing:
    /// this decorates a screen, and an old backend that does not know the
    /// endpoint must not put an error banner over a file that opens fine.
    func colorChanges(for file: BackendGCodeFile) async -> [ColorChange] {
        if !file.colorChanges.isEmpty { return file.colorChanges }
        guard !settings.demoMode else { return [] }
        return (try? await printer.backend.gcodeMetadata(path: file.path))?.colorChanges ?? []
    }

    func upload(gcodeURL url: URL) async -> Bool {
        await withSecurityScope(url) { data, filename in
            if self.settings.demoMode { return true }
            _ = try await self.printer.moonraker.uploadGCode(filename: filename, data: data)
            return true
        }
    }

    // MARK: - Models

    func loadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        if settings.demoMode {
            models = DemoSimulator.demoModels
            return
        }
        do {
            models = try await printer.backend.models()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func upload(modelURL url: URL) async -> BackendModelFile? {
        guard !settings.demoMode else { return DemoSimulator.demoModels.first }

        var uploaded: BackendModelFile?
        _ = await withSecurityScope(url) { data, filename in
            self.uploadProgressLabel = L.t("slicer.uploading", filename)
            let result = try await self.printer.backend.uploadModel(filename: filename, data: data)
            uploaded = BackendModelFile(
                id: result.id,
                filename: result.filename,
                size: result.size,
                modified: Date().timeIntervalSince1970,
                fileExtension: (filename as NSString).pathExtension.lowercased()
            )
            return true
        }
        uploadProgressLabel = nil
        if uploaded != nil { await loadModels() }
        return uploaded
    }

    func deleteModel(_ model: BackendModelFile) async {
        guard !settings.demoMode else {
            models.removeAll { $0.id == model.id }
            return
        }
        do {
            try await printer.backend.deleteModel(id: model.id)
            models.removeAll { $0.id == model.id }
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }

    func modelData(_ model: BackendModelFile) async -> Data? {
        guard !settings.demoMode else { return nil }
        do {
            return try await printer.backend.downloadModel(id: model.id)
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    // MARK: - Helpers

    private func withSecurityScope(
        _ url: URL,
        _ body: @escaping (Data, String) async throws -> Bool
    ) async -> Bool {
        // ImportedFile owns the security scope, the iCloud download and the
        // coordinated read - a picked G-code file is as likely to be an
        // undownloaded iCloud placeholder as a model is.
        //
        // The label is set *before* the read, not after. Reading a large file,
        // or one iOS has to fetch from iCloud first, takes long enough that
        // leaving the screen untouched until afterwards looked like the app had
        // ignored the file entirely.
        uploadProgressLabel = L.t("slicer.reading", url.lastPathComponent)
        defer { uploadProgressLabel = nil }

        do {
            let data = try await ImportedFile.read(url)
            let ok = try await body(data, url.lastPathComponent)
            if ok { lastError = nil }
            return ok
        } catch let error as ImportedFile.ReadError {
            lastError = .unknown(error.localizedDescription)
            Haptics.error()
            return false
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return false
        }
    }

    private func writeTemporary(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neptune-share", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
