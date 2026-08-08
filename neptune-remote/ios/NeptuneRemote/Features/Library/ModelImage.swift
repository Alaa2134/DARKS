import SwiftUI

/// The picture of a model - the single most important thing in the app.
///
/// Rules this view enforces everywhere it is used:
/// * a real rendered preview when the Pi produced one,
/// * otherwise a clearly-labelled placeholder built from the model's own name,
/// * never a raw G-code filename standing in for a picture.
struct ModelImage: View {
    let url: URL?
    var name: String = ""
    var category: String = ""
    var cornerRadius: CGFloat = Theme.smallCornerRadius
    var contentMode: ContentMode = .fill
    var showsPlaceholderLabel = true

    var body: some View {
        ZStack {
            placeholder
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case .failure:
                        // The preview did not load; the placeholder underneath stays visible.
                        Color.clear
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityLabel(name.isEmpty ? L.t("printing.no_image") : name)
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            VStack(spacing: 8) {
                Image(systemName: LibraryCategoryCatalog.icon(for: category))
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent.opacity(0.75))
                if showsPlaceholderLabel, !name.isEmpty {
                    Text(name)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

/// Square grid cell used by the library and idea finder.
struct LibraryCard: View {
    let item: LibraryItem
    let imageURL: URL?
    var onFavourite: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModelImage(
                url: imageURL,
                name: item.displayName,
                category: item.category,
                showsPlaceholderLabel: false
            )
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if let onFavourite {
                    Button(action: onFavourite) {
                        Image(systemName: item.favourite ? "star.fill" : "star")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(item.favourite ? Theme.paused : .white)
                            .padding(7)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.printCount > 0 {
                    Label("\(item.printCount)", systemImage: "printer.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(6)
                }
            }

            Text(item.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let seconds = item.estimatedSeconds {
                    Label(Format.duration(seconds), systemImage: "clock")
                }
                if let grams = item.estimatedFilamentGrams {
                    Label("\(Int(grams.rounded())) g", systemImage: "scalemass")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

// MARK: - Navigation

extension View {
    /// Library items are pushed by id from several screens (home, library,
    /// ideas, search), so the destination is registered once here and applied
    /// to the root of every navigation stack that can reach a model.
    func withLibraryDestinations() -> some View {
        navigationDestination(for: String.self) { identifier in
            ModelDetailView(itemID: identifier)
        }
    }
}
