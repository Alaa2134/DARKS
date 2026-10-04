import SwiftUI

/// "أطبع إيه؟" - a deterministic idea finder over the user's own library.
/// It ranks what they already own; it never invents models or calls a service.
struct IdeaFinderView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var room: String?
    @State private var maxSeconds: Double?
    @State private var material: String?
    @State private var surprise: LibraryItem?

    private let timeOptions: [(labelKey: String, seconds: Double?)] = [
        ("ideas.time.any", nil),
        ("ideas.time.30m", 1_800),
        ("ideas.time.2h", 7_200),
        ("ideas.time.6h", 21_600)
    ]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.spacing)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                surpriseCard
                filters
                results
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("ideas.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.close")) { dismiss() }
            }
        }
        .task { await reload() }
    }

    private var surpriseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let surprise {
                NavigationLink(value: surprise.id) {
                    HStack(spacing: 12) {
                        ModelImage(
                            url: library.mediaURL(surprise.thumbnail),
                            name: surprise.displayName,
                            category: surprise.category,
                            showsPlaceholderLabel: false
                        )
                        .frame(width: 90, height: 90)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(surprise.displayName)
                                .font(.headline)
                                .lineLimit(2)
                            if let seconds = surprise.estimatedSeconds {
                                Text(Format.duration(seconds))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                Task {
                    surprise = await library.surpriseMe()
                    Haptics.impact(.medium)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(localized: surprise == nil ? "ideas.surprise" : "ideas.again")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("ideas.room", systemImage: "map")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(titleKey: "ideas.room.any", icon: "square.grid.2x2", selected: room == nil) {
                        room = nil
                    }
                    ForEach(LibraryCategoryCatalog.ideaRooms, id: \.id) { entry in
                        chip(titleKey: entry.labelKey, icon: entry.icon, selected: room == entry.id) {
                            room = room == entry.id ? nil : entry.id
                        }
                    }
                }
            }

            SectionHeader("ideas.time", systemImage: "clock")
            HStack(spacing: 8) {
                ForEach(timeOptions, id: \.labelKey) { option in
                    chip(titleKey: option.labelKey, icon: "timer", selected: maxSeconds == option.seconds) {
                        maxSeconds = option.seconds
                    }
                }
            }

            SectionHeader("ideas.material", systemImage: "circle.hexagongrid")
            HStack(spacing: 8) {
                chip(titleKey: "ideas.material.any", icon: "square.grid.2x2", selected: material == nil) {
                    material = nil
                }
                ForEach(["PLA", "PETG", "TPU"], id: \.self) { option in
                    chip(title: option, icon: "circle.hexagongrid", selected: material == option) {
                        material = material == option ? nil : option
                    }
                }
            }
        }
        .card()
        .onChange(of: room) { _, _ in Task { await reload() } }
        .onChange(of: maxSeconds) { _, _ in Task { await reload() } }
        .onChange(of: material) { _, _ in Task { await reload() } }
    }

    @ViewBuilder
    private var results: some View {
        if library.isLoadingIdeas {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if library.ideas.isEmpty {
            EmptyStateView(
                titleKey: "ideas.empty",
                messageKey: "library.empty.hint",
                systemImage: "lightbulb"
            )
        } else {
            LazyVGrid(columns: columns, spacing: Theme.spacing) {
                ForEach(library.ideas) { item in
                    NavigationLink(value: item.id) {
                        LibraryCard(item: item, imageURL: library.mediaURL(item.thumbnail))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(
        titleKey: String? = nil,
        title: String = "",
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2)
                Text(titleKey.map { L.t($0) } ?? title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Theme.accent : Theme.pageFill, in: Capsule())
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func reload() async {
        await library.loadIdeas(room: room, maxSeconds: maxSeconds, material: material)
    }
}
