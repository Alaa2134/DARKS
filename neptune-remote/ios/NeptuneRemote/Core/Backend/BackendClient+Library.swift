import Foundation

/// Endpoints added by the library / media / vision / inventory / support routers.
extension BackendClient {

    // MARK: - Summary

    func summary() async throws -> BackendSummary {
        try await decode(BackendSummary.self, path: "summary", timeout: 20)
    }

    // MARK: - Library

    func libraryItems(
        category: String? = nil,
        favouritesOnly: Bool = false,
        collection: String? = nil,
        limit: Int = 200
    ) async throws -> [LibraryItem] {
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let category { query.append(URLQueryItem(name: "category", value: category)) }
        if favouritesOnly { query.append(URLQueryItem(name: "favourites", value: "true")) }
        if let collection { query.append(URLQueryItem(name: "collection", value: collection)) }
        return try await decode([LibraryItem].self, path: "library", query: query, timeout: 40)
    }

    func libraryItem(id: String) async throws -> LibraryItem {
        try await decode(LibraryItem.self, path: "library/\(id)")
    }

    func uploadLibraryModel(
        filename: String,
        data: Data,
        nameAR: String = "",
        nameEN: String = "",
        category: String = "other",
        tags: [String] = []
    ) async throws -> LibraryItem {
        guard let base = try baseURL() else { throw APIError.notConfigured }
        let (responseData, _) = try await http.upload(
            url: base.appendingPathComponent("api/library/upload"),
            fieldName: "file",
            filename: filename,
            fileData: data,
            fields: [
                "name_ar": nameAR,
                "name_en": nameEN,
                "category": category,
                "tags": tags.joined(separator: ",")
            ],
            headers: authHeaders()
        )
        do {
            return try JSONDecoder().decode(LibraryItem.self, from: responseData)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func updateLibraryItem(id: String, payload: LibraryItemUpdatePayload) async throws -> LibraryItem {
        try await decode(
            LibraryItem.self, path: "library/\(id)", method: "PATCH",
            body: try await http.encodeBody(payload)
        )
    }

    func deleteLibraryItem(id: String) async throws {
        _ = try await raw(path: "library/\(id)", method: "DELETE", timeout: 30)
    }

    // MARK: - Backup

    func libraryBackups() async throws -> [LibraryBackupInfo] {
        try await decode([LibraryBackupInfo].self, path: "library/backups", timeout: 30)
    }

    /// Write an archive and prune the old ones.
    func createLibraryBackup(keep: Int = 5) async throws -> LibraryBackupResult {
        try await decode(
            LibraryBackupResult.self,
            path: "library/backups",
            method: "POST",
            query: [URLQueryItem(name: "keep", value: "\(keep)")],
            // A library of a few hundred models is a real amount of copying.
            timeout: 900
        )
    }

    func restoreLibraryBackup(_ payload: LibraryRestorePayload) async throws -> LibraryRestoreResult {
        try await decode(
            LibraryRestoreResult.self,
            path: "library/backups/restore",
            method: "POST",
            body: try await http.encodeBody(payload),
            timeout: 900
        )
    }

    func deleteLibraryBackup(filename: String) async throws {
        _ = try await raw(
            path: "library/backups/\(filename)", method: "DELETE", timeout: 30
        )
    }

    /// The archive itself, for saving off the Pi - which is the entire point:
    /// a backup that only exists on the card it protects is not a backup.
    func downloadLibraryBackup(filename: String) async throws -> Data {
        try await raw(path: "library/backups/\(filename)/download", timeout: 900)
    }

    // MARK: - Plate arrangement

    /// Work out where a set of models goes on this printer's bed.
    ///
    /// Footprints are measured after each model's rotation and scale, because
    /// a rotated part casts a different shadow on the plate than the file did.
    func arrangePlate(_ payload: ArrangeRequestPayload) async throws -> ArrangeResponse {
        try await decode(
            ArrangeResponse.self,
            path: "library/arrange",
            method: "POST",
            body: try await http.encodeBody(payload),
            timeout: 120
        )
    }

    // MARK: - Mesh health

    /// Check a model before slicing it.
    func meshHealth(id: String) async throws -> MeshHealth {
        try await decode(MeshHealth.self, path: "library/\(id)/health", timeout: 120)
    }

    /// Fix what has one right answer, into a new library item.
    func repairMesh(id: String) async throws -> MeshRepairResult {
        try await decode(
            MeshRepairResult.self,
            path: "library/\(id)/repair",
            method: "POST",
            timeout: 180
        )
    }

    // MARK: - Resuming

    /// What resuming at this layer would involve. Nothing is written.
    func resumePlan(name: String, layer: Int) async throws -> ResumePlan {
        try await decode(
            ResumePlan.self,
            path: "gcodes/local/\(name)/resume/\(layer)",
            timeout: 120
        )
    }

    /// Write the resumed file and hand it to the printer.
    ///
    /// Never starts the print. Resuming onto a part that is still on the bed is
    /// something to press Print on deliberately, after looking at the machine.
    func buildResume(
        name: String,
        payload: ResumeRequestPayload
    ) async throws -> ResumeResult {
        try await decode(
            ResumeResult.self,
            path: "gcodes/local/\(name)/resume",
            method: "POST",
            body: try await http.encodeBody(payload),
            timeout: 300
        )
    }

    // MARK: - Toolpath preview

    /// How many layers a sliced file has, how high each one is, and how wide
    /// the print is. Asked for once, before any layer is drawn.
    func previewSummary(name: String) async throws -> PreviewSummary {
        try await decode(
            PreviewSummary.self,
            // The first call scans the whole file to build its layer index.
            path: "gcodes/local/\(name)/preview",
            timeout: 120
        )
    }

    /// One layer's toolpath.
    ///
    /// One at a time on purpose: a 50 MB file holds millions of coordinates and
    /// no phone wants them all. The Pi seeks straight to the layer, so this
    /// costs the size of a single layer rather than of the file.
    func previewLayer(
        name: String,
        layer: Int,
        includeTravel: Bool = false
    ) async throws -> PreviewLayer {
        try await decode(
            PreviewLayer.self,
            path: "gcodes/local/\(name)/preview/\(layer)",
            query: includeTravel ? [URLQueryItem(name: "travel", value: "true")] : [],
            timeout: 60
        )
    }

    // MARK: - Placement

    /// Ask the Pi which way up this model should go.
    ///
    /// Measured against the real mesh, not guessed: every candidate orientation
    /// is actually turned and scored. `transform` is where the model stands
    /// now, so the answer composes with a resize the user has already made
    /// rather than throwing it away.
    ///
    /// Nothing is saved. Applying the suggestion is the caller's decision.
    func suggestOrientation(
        id: String,
        transform: ModelTransform = .identity
    ) async throws -> OrientationSuggestion {
        try await decode(
            OrientationSuggestion.self,
            path: "library/\(id)/orient",
            method: "POST",
            body: try await http.encodeBody(transform),
            // A big mesh is a lot of triangles to turn twenty-four ways.
            timeout: 90
        )
    }

    /// Measure a transform without saving or slicing anything.
    ///
    /// What the app calls while a rotation dial is being dragged: how tall is
    /// it now, does it still fit, does it still need support.
    func measureTransform(
        id: String,
        transform: ModelTransform
    ) async throws -> OrientationReport {
        try await decode(
            OrientationReport.self,
            path: "library/\(id)/transform",
            method: "POST",
            body: try await http.encodeBody(transform),
            timeout: 60
        )
    }

    func regenerateThumbnail(id: String) async throws -> LibraryItem {
        try await decode(
            LibraryItem.self, path: "library/\(id)/regenerate-thumbnail",
            method: "POST", timeout: 120
        )
    }

    func replaceThumbnail(id: String, imageData: Data, filename: String = "photo.jpg") async throws -> LibraryItem {
        guard let base = try baseURL() else { throw APIError.notConfigured }
        let (responseData, _) = try await http.upload(
            url: base.appendingPathComponent("api/library/\(id)/thumbnail"),
            fieldName: "file",
            filename: filename,
            fileData: imageData,
            mimeType: "image/jpeg",
            headers: authHeaders()
        )
        do {
            return try JSONDecoder().decode(LibraryItem.self, from: responseData)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    func addPhoto(itemID: String, imageData: Data, caption: String = "") async throws {
        guard let base = try baseURL() else { throw APIError.notConfigured }
        _ = try await http.upload(
            url: base.appendingPathComponent("api/library/\(itemID)/photos"),
            fieldName: "file",
            filename: "photo.jpg",
            fileData: imageData,
            mimeType: "image/jpeg",
            fields: ["caption": caption],
            headers: authHeaders()
        )
    }

    func categories() async throws -> [LibraryCategory] {
        try await decode([LibraryCategory].self, path: "library/categories")
    }

    func downloadLibraryModel(id: String) async throws -> Data {
        try await raw(path: "library/\(id)/download", timeout: 600)
    }

    // MARK: - Search

    func search(query: String, category: String? = nil, favouritesOnly: Bool = false) async throws -> SearchResponse {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "60")
        ]
        if let category { items.append(URLQueryItem(name: "category", value: category)) }
        if favouritesOnly { items.append(URLQueryItem(name: "favourites", value: "true")) }
        return try await decode(SearchResponse.self, path: "search", query: items, timeout: 20)
    }

    func suggestions(prefix: String) async throws -> [String] {
        try await decode(
            [String].self, path: "search/suggest",
            query: [URLQueryItem(name: "q", value: prefix)], timeout: 10
        )
    }

    func ideas(room: String?, maxSeconds: Double?, material: String?) async throws -> [LibraryItem] {
        let payload = IdeaRequestPayload(room: room, maxSeconds: maxSeconds, material: material, limit: 15)
        return try await decode(
            [LibraryItem].self, path: "ideas", method: "POST",
            body: try await http.encodeBody(payload), timeout: 20
        )
    }

    // MARK: - Collections

    func collections() async throws -> [LibraryCollection] {
        try await decode([LibraryCollection].self, path: "collections")
    }

    func addToCollection(collectionID: String, itemID: String) async throws {
        _ = try await raw(path: "collections/\(collectionID)/items/\(itemID)", method: "POST")
    }

    func removeFromCollection(collectionID: String, itemID: String) async throws {
        _ = try await raw(path: "collections/\(collectionID)/items/\(itemID)", method: "DELETE")
    }

    // MARK: - Ratings

    func ratePrint(_ payload: PrintRatingPayload) async throws {
        _ = try await raw(
            path: "library/ratings", method: "POST", body: try await http.encodeBody(payload)
        )
    }

    // MARK: - Camera

    func cameraStatus(probe: Bool = false) async throws -> CameraStatus {
        try await decode(
            CameraStatus.self, path: "camera/status",
            query: [URLQueryItem(name: "probe", value: probe ? "true" : "false")],
            timeout: probe ? 30 : 12
        )
    }

    func cameraDevices() async throws -> [CameraDeviceInfo] {
        struct Payload: Decodable { let devices: [CameraDeviceInfo] }
        return try await decode(Payload.self, path: "camera/devices", timeout: 40).devices
    }

    func snapshot() async throws -> Data {
        try await raw(path: "camera/snapshot", timeout: 25)
    }

    func saveSnapshot() async throws -> String {
        struct Payload: Decodable { let path: String }
        return try await decode(Payload.self, path: "camera/snapshot/save", method: "POST", timeout: 30).path
    }

    func setROI(_ roi: [Double]?) async throws {
        struct Payload: Encodable { let roi: [Double]? }
        _ = try await raw(
            path: "camera/roi", method: "POST", body: try await http.encodeBody(Payload(roi: roi))
        )
    }

    // MARK: - Recording

    func recordingStatus() async throws -> RecordingStatus {
        try await decode(RecordingStatus.self, path: "camera/record/status")
    }

    func startRecording() async throws -> VideoRecord {
        try await decode(VideoRecord.self, path: "camera/record/start", method: "POST", timeout: 30)
    }

    func stopRecording() async throws -> VideoRecord {
        try await decode(VideoRecord.self, path: "camera/record/stop", method: "POST", timeout: 40)
    }

    // MARK: - Timelapse

    func timelapseStatus() async throws -> TimelapseStatus {
        try await decode(TimelapseStatus.self, path: "timelapse/status")
    }

    func startTimelapse() async throws {
        _ = try await raw(path: "timelapse/start", method: "POST", timeout: 20)
    }

    func finishTimelapse() async throws -> VideoRecord {
        try await decode(VideoRecord.self, path: "timelapse/finish", method: "POST", timeout: 600)
    }

    func timelapseMacro() async throws -> String {
        struct Payload: Decodable { let macro: String }
        return try await decode(Payload.self, path: "timelapse/macro").macro
    }

    // MARK: - Videos

    func videos(kind: String? = nil) async throws -> [VideoRecord] {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: "200")]
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        return try await decode([VideoRecord].self, path: "videos", query: query, timeout: 30)
    }

    func videoStorage() async throws -> VideoStorageSummary {
        try await decode(VideoStorageSummary.self, path: "videos/storage", timeout: 30)
    }

    func deleteVideo(id: String) async throws {
        _ = try await raw(path: "videos/\(id)", method: "DELETE", timeout: 30)
    }

    func downloadVideo(id: String) async throws -> Data {
        try await raw(path: "videos/\(id)/download", timeout: 900)
    }

    func cleanupVideos() async throws -> Int {
        struct Payload: Decodable { let count: Int }
        return try await decode(Payload.self, path: "videos/cleanup", method: "POST", timeout: 60).count
    }

    // MARK: - Vision

    func visionStatus() async throws -> VisionStatus {
        try await decode(VisionStatus.self, path: "vision/status")
    }

    func updateVisionSettings(_ payload: VisionSettingsPayload) async throws -> VisionStatus {
        try await decode(
            VisionStatus.self, path: "vision/settings", method: "POST",
            body: try await http.encodeBody(payload), timeout: 30
        )
    }

    func visionEvents(confirmedOnly: Bool = false) async throws -> [VisionEvent] {
        struct Payload: Decodable { let events: [VisionEvent] }
        return try await decode(
            Payload.self, path: "vision/events",
            query: [
                URLQueryItem(name: "limit", value: "150"),
                URLQueryItem(name: "confirmed_only", value: confirmedOnly ? "true" : "false")
            ]
        ).events
    }

    func acknowledgeVisionEvent(id: String) async throws {
        _ = try await raw(path: "vision/events/\(id)/acknowledge", method: "POST")
    }

    func clearVisionEvents() async throws {
        _ = try await raw(path: "vision/events", method: "DELETE")
    }

    func confirmFirstLayerOK() async throws {
        _ = try await raw(path: "vision/first-layer-ok", method: "POST")
    }

    // MARK: - Filament

    func spools() async throws -> [FilamentSpool] {
        try await decode([FilamentSpool].self, path: "filament")
    }

    func filamentSummary() async throws -> FilamentSummary {
        try await decode(FilamentSummary.self, path: "filament/summary")
    }

    func createSpool(_ payload: FilamentSpoolPayload) async throws -> FilamentSpool {
        try await decode(
            FilamentSpool.self, path: "filament", method: "POST",
            body: try await http.encodeBody(payload)
        )
    }

    func activateSpool(id: String) async throws -> FilamentSpool {
        try await decode(FilamentSpool.self, path: "filament/\(id)/active", method: "POST")
    }

    func consumeFilament(id: String, grams: Double) async throws -> FilamentSpool {
        struct Payload: Encodable { let grams: Double; let reason: String }
        return try await decode(
            FilamentSpool.self, path: "filament/\(id)/consume", method: "POST",
            body: try await http.encodeBody(Payload(grams: grams, reason: "manual"))
        )
    }

    func deleteSpool(id: String) async throws {
        _ = try await raw(path: "filament/\(id)", method: "DELETE")
    }

    func checkFilament(grams: Double, material: String? = nil) async throws -> FilamentCheck {
        var query = [URLQueryItem(name: "grams", value: String(grams))]
        if let material { query.append(URLQueryItem(name: "material", value: material)) }
        return try await decode(FilamentCheck.self, path: "filament/check/estimate", query: query)
    }

    // MARK: - Cost

    func costSettings() async throws -> CostSettings {
        try await decode(CostSettings.self, path: "cost/settings")
    }

    func saveCostSettings(_ settings: CostSettings) async throws -> CostSettings {
        try await decode(
            CostSettings.self, path: "cost/settings", method: "PUT",
            body: try await http.encodeBody(settings)
        )
    }

    func calculateCost(_ payload: CostRequestPayload) async throws -> CostBreakdown {
        try await decode(
            CostBreakdown.self, path: "cost/calculate", method: "POST",
            body: try await http.encodeBody(payload)
        )
    }

    // MARK: - Products

    func products() async throws -> [Product] {
        try await decode([Product].self, path: "products")
    }

    func createProduct(_ payload: ProductPayload) async throws -> Product {
        try await decode(
            Product.self, path: "products", method: "POST",
            body: try await http.encodeBody(payload)
        )
    }

    func deleteProduct(id: String) async throws {
        _ = try await raw(path: "products/\(id)", method: "DELETE")
    }

    // MARK: - Maintenance

    func maintenance() async throws -> MaintenanceStatus {
        try await decode(MaintenanceStatus.self, path: "maintenance")
    }

    func completeMaintenance(id: String, note: String = "") async throws {
        struct Payload: Encodable { let note: String }
        _ = try await raw(
            path: "maintenance/\(id)/complete", method: "POST",
            body: try await http.encodeBody(Payload(note: note))
        )
    }

    // MARK: - Queue

    func queueState() async throws -> QueueState {
        try await decode(QueueState.self, path: "queue")
    }

    func addToQueue(_ payload: QueueJobPayload) async throws -> QueueJob {
        try await decode(
            QueueJob.self, path: "queue", method: "POST", body: try await http.encodeBody(payload)
        )
    }

    func removeFromQueue(id: String) async throws {
        _ = try await raw(path: "queue/\(id)", method: "DELETE")
    }

    func setBedClear(_ clear: Bool) async throws -> QueueState {
        struct Payload: Encodable { let clear: Bool }
        return try await decode(
            QueueState.self, path: "queue/bed-clear", method: "POST",
            body: try await http.encodeBody(Payload(clear: clear))
        )
    }

    func startNextQueuedJob() async throws {
        _ = try await raw(path: "queue/start-next", method: "POST", timeout: 60)
    }

    // MARK: - Support

    func diagnostics() async throws -> DiagnosticsReport {
        try await decode(DiagnosticsReport.self, path: "diagnostics", timeout: 45)
    }

    func diagnosticsReport() async throws -> String {
        struct Payload: Decodable { let report: String }
        return try await decode(Payload.self, path: "diagnostics/report", timeout: 45).report
    }

    func translateError(_ message: String) async throws -> TranslatedError {
        struct Payload: Encodable { let message: String }
        return try await decode(
            TranslatedError.self, path: "support/translate-error", method: "POST",
            body: try await http.encodeBody(Payload(message: message))
        )
    }

    func troubleshootingTopics() async throws -> [TroubleshootingTopic] {
        try await decode([TroubleshootingTopic].self, path: "support/topics")
    }

    func bedMesh() async throws -> BedMeshReport {
        try await decode(BedMeshReport.self, path: "printer/bed-mesh", timeout: 25)
    }

    func backups() async throws -> [BackupInfo] {
        try await decode([BackupInfo].self, path: "backups", timeout: 25)
    }

    func createBackup() async throws -> BackupInfo {
        struct Payload: Encodable { let include_profiles: Bool }
        return try await decode(
            BackupInfo.self, path: "backups", method: "POST",
            body: try await http.encodeBody(Payload(include_profiles: true)), timeout: 120
        )
    }

    func deleteBackup(filename: String) async throws {
        _ = try await raw(path: "backups/\(filename)", method: "DELETE")
    }
}
