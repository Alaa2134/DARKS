import SwiftUI

/// Paste a link, get a model.
///
/// Until now everything in the library had to be uploaded from the phone,
/// which means finding the model on a desktop, downloading it, moving it
/// across, and uploading it again. Most of that work is the phone not being
/// where the file is - so the Pi fetches it instead, and the phone only
/// carries the link.
struct ImportLinkView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var nameAR = ""
    @State private var isImporting = false
    @State private var result: ImportResult?

    /// Kept separate from `library.lastError`: a failure here belongs on this
    /// screen, not on the list behind it.
    @State private var failure: String?

    private var trimmed: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canImport: Bool {
        !isImporting && trimmed.count > 8 && trimmed.lowercased().hasPrefix("http")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                linkCard

                if isImporting {
                    BusyLine(textKey: "import.working").card()
                }

                if let failure {
                    ErrorBanner(message: failure, onDismiss: { self.failure = nil })
                }

                if let result {
                    resultCard(result)
                }

                whatWorksCard
            }
            .padding(Theme.spacing)
            .animation(.neptuneContent, value: isImporting)
            .animation(.neptuneContent, value: result)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("import.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The link

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("import.link", systemImage: "link")

            TextField(L.t("import.link.placeholder"), text: $url, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                // Links are Latin text in any language - forcing LTR stops a
                // pasted URL from being reordered on screen and read wrong.
                .environment(\.layoutDirection, .leftToRight)
                .multilineTextAlignment(.leading)
                .lineLimit(1...3)

            TextField(L.t("import.name"), text: $nameAR)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await run() }
            } label: {
                Label(L.t("import.start"), systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canImport)
        }
        .card()
    }

    // MARK: - What came back

    @ViewBuilder
    private func resultCard(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.needsKey.isEmpty {
                Label(
                    L.t("import.done", result.items.count),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.printing)

                if !result.collectionName.isEmpty {
                    Text(L.t("import.collection", result.collectionName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(result.items) { item in
                    HStack(spacing: 10) {
                        ModelImage(
                            url: library.mediaURL(item.thumbnail),
                            name: item.displayName,
                            category: item.category,
                            showsPlaceholderLabel: false
                        )
                        .frame(width: 44, height: 44)

                        Text(item.displayName)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                    }
                }

                Button(L.t("import.back_to_library")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            } else {
                Label(L.t("import.needs_key"), systemImage: "key")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.paused)
            }

            ForEach(result.notesAr, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        .transition(.neptuneContent)
    }

    /// Which links actually work, said before it fails rather than after.
    private var whatWorksCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("import.what_works", systemImage: "info.circle")
            ForEach(
                ["import.works.direct", "import.works.zip", "import.works.pages"],
                id: \.self
            ) { key in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(localized: key)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card()
    }

    // MARK: - Work

    private func run() async {
        isImporting = true
        failure = nil
        result = nil
        defer { isImporting = false }

        let outcome = await library.importFromURL(trimmed, nameAR: nameAR)
        if let outcome {
            result = outcome
        } else {
            failure = library.lastError?.localizedDescription ?? L.t("import.failed")
            library.lastError = nil
        }
    }
}
