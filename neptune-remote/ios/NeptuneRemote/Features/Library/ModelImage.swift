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
        // A model with no picture yet is still drawn as an object worth
        // printing: deep water, lit from above, its category glyph in light -
        // and a hue of its own per category, so a shelf of models without
        // thumbnails is not a row of identical tiles.
        let hue = Self.hue(for: category)
        return ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.42),
                    Color(hue: hue, saturation: 0.70, brightness: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(hue: hue, saturation: 0.45, brightness: 1).opacity(0.45), .clear],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 2,
                endRadius: 120
            )
            LayerWaves(count: 3)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
            VStack(spacing: 8) {
                Image(systemName: LibraryCategoryCatalog.icon(for: category))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: Color(hue: hue, saturation: 0.6, brightness: 1).opacity(0.8), radius: 12)
                if showsPlaceholderLabel, !name.isEmpty {
                    Text(name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    /// A stable hue per category, kept inside the cool half of the wheel so the
    /// library stays in the app's water palette rather than becoming a rainbow.
    static func hue(for category: String) -> Double {
        var hash: UInt64 = 1469598103934665603
        for byte in category.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let palette: [Double] = [0.52, 0.55, 0.58, 0.62, 0.66, 0.72, 0.47, 0.08]
        return palette[Int(hash % UInt64(palette.count))]
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
        .navigationDestination(for: ProjectRoute.self) { route in
            ProjectView(projectID: route.id)
        }
    }
}

/// A project pushed by id.
///
/// Its own type rather than another `String` route: a bare string already means
/// "a model", and two destinations reading the same type is how a tap on a
/// project ends up opening a model that does not exist.
struct ProjectRoute: Hashable {
    let id: String
}
