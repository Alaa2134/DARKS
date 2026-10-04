import UIKit
import UniformTypeIdentifiers

/// Share Extension: accepts STL / 3MF / OBJ files from Files, Safari, Mail and
/// anything else that vends a file URL, and stages them for the main app.
///
/// It deliberately does not talk to the Raspberry Pi itself. The backend token
/// lives in the app's Keychain and is never copied into the shared container,
/// so the extension only copies the file into the App Group and records it.
/// The app performs the real upload with its own credentials.
final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let openButton = UIButton(type: .system)

    /// Extensions the backend's mesh parser supports.
    private static let acceptedExtensions: Set<String> = ["stl", "3mf", "obj"]

    private var stagedCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        Task { await handleInput() }
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = .systemBackground

        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 16
        container.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.text = localized("share.working")

        spinner.startAnimating()

        openButton.setTitle(localized("share.open_app"), for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle(localized("common.close"), for: .normal)
        closeButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        container.addArrangedSubview(spinner)
        container.addArrangedSubview(statusLabel)
        container.addArrangedSubview(openButton)
        container.addArrangedSubview(closeButton)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    // MARK: - Work

    private func handleInput() async {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        guard SharedStore.inboxDirectory != nil else {
            await finishWithMessage(localized("share.no_app_group"), success: false)
            return
        }

        for provider in attachments {
            guard let url = await loadFileURL(from: provider) else { continue }
            if stage(url) { stagedCount += 1 }
        }

        if stagedCount == 0 {
            await finishWithMessage(localized("share.unsupported"), success: false)
        } else {
            await finishWithMessage(
                String(format: localized("share.staged"), stagedCount),
                success: true
            )
        }
    }

    /// Resolves a provider to an on-disk file URL, trying the file-URL
    /// representation first and falling back to the generic data type.
    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        for identifier in [UTType.fileURL.identifier, UTType.data.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            let loaded: URL? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let data = item as? Data,
                              let url = Self.writeTemporary(data: data) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            if let loaded { return loaded }
        }
        return nil
    }

    private nonisolated static func writeTemporary(data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("stl")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Copies the file into the App Group inbox and records it for the app.
    private func stage(_ url: URL) -> Bool {
        let suffix = url.pathExtension.lowercased()
        guard Self.acceptedExtensions.contains(suffix) else { return false }
        guard let inbox = SharedStore.inboxDirectory else { return false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let identifier = UUID().uuidString
        let relative = "\(identifier).\(suffix)"
        let destination = inbox.appendingPathComponent(relative)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            // Some providers hand back a URL that cannot be copied directly;
            // reading it into memory is the documented fallback.
            guard let data = try? Data(contentsOf: url),
                  (try? data.write(to: destination, options: .atomic)) != nil
            else { return false }
        }

        SharedStore.enqueue(
            PendingImport(
                id: identifier,
                filename: url.lastPathComponent,
                relativePath: relative,
                receivedAt: Date()
            )
        )
        return true
    }

    @MainActor
    private func finishWithMessage(_ message: String, success: Bool) async {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        openButton.isHidden = !success
    }

    @objc private func openApp() {
        guard let url = URL(string: "neptuneremote://library") else { return }
        // Share extensions may open their host app; if the system refuses, the
        // file is still staged and the app imports it on next launch.
        extensionContext?.open(url) { [weak self] _ in
            self?.finish()
        }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func localized(_ key: String) -> String {
        let value = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        return value
    }
}
