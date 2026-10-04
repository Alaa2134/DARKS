import UIKit

/// Pictures for the demo library.
///
/// Demo items used to have no picture at all, so the library someone opens to
/// try the app was a grid of placeholders. These are real renders of the four
/// demo models, bundled in the asset catalog.
///
/// They are handed out as file URLs - written to Caches once - so they load
/// through exactly the same `AsyncImage` path as a picture served by the Pi,
/// and every screen that shows a model picture shows these without knowing
/// demo mode exists.
enum DemoPictures {
    static let prefix = "demo/"
    /// Bump when the pictures change, so a cached copy is never shown stale.
    private static let version = 1

    static func url(for relativePath: String) -> URL? {
        guard relativePath.hasPrefix(prefix) else { return nil }
        let name = String(relativePath.dropFirst(prefix.count))
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let file = caches
            .appendingPathComponent("demo-media", isDirectory: true)
            .appendingPathComponent("\(name)-v\(version).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }

        guard let image = UIImage(named: "DemoModel-\(name)"),
              let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
