import SwiftUI

/// Pick material / quality / infill / supports, and the app maps that onto
/// validated slicer profiles. No G-code jargon, no free-form numbers.
struct OneTapPrintView: View {
    let item: LibraryItem

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var slicing: SliceStore
    @EnvironmentObject private var inventory: InventoryStore
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var material = "PLA"
    @State private var quality = PrintQuality.normal
    @State private var infill = 20
    @State private var supports = false
    @State private var copies = 1

    @State private var filamentCheck: FilamentCheck?
    @State private var isStarting = false
    @State private var showingChecklist = false

    private var materials: [String] {
        let known = ["PLA", "PLA+", "PETG", "TPU", "ABS"]
        return known.contains(item.recommendedMaterial) || item.recommendedMaterial.isEmpty
            ? known
            : [item.recommendedMaterial] + known
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                summaryCard
                materialPicker
                qualityPicker
                infillPicker
                supportsToggle
                filamentStatus
                if let error = slicing.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { slicing.lastError = nil }
                    )
                }
                startButton
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("print.setup.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
        }
        .task {
            material = item.recommendedMaterial.isEmpty ? "PLA" : item.recommendedMaterial
            await slicing.loadProfiles()
            await refreshFilamentCheck()
        }
        .sheet(isPresented: $showingChecklist) {
            PrintChecklistView {
                Task { await startSlicing(andPrint: true) }
            }
        }
    }

    // MARK: - Cards

    private var summaryCard: some View {
        HStack(spacing: 12) {
            ModelImage(
                url: library.mediaURL(item.thumbnail),
                name: item.displayName,
                category: item.category,
                showsPlaceholderLabel: false
            )
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(2)
                if let dimensions = item.dimensionsDescription {
                    Text(dimensions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(estimateText)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    private var materialPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("print.setup.material", systemImage: "circle.hexagongrid")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(materials, id: \.self) { option in
                        selectableChip(title: option, selected: material == option) {
                            material = option
                            Task { await refreshFilamentCheck() }
                        }
                    }
                }
            }
        }
        .card()
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("print.setup.quality", systemImage: "square.stack.3d.up")
            Picker(L.t("print.setup.quality"), selection: $quality) {
                ForEach(PrintQuality.allCases) { option in
                    Text(localized: option.localizationKey).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Text(String(format: "%.2f mm", quality.layerHeight))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var infillPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("print.setup.infill", systemImage: "grid")
            HStack(spacing: 8) {
                ForEach([10, 15, 20, 40, 60, 100], id: \.self) { value in
                    selectableChip(title: "\(value)%", selected: infill == value) {
                        infill = value
                        Task { await refreshFilamentCheck() }
                    }
                }
            }
        }
        .card()
    }

    private var supportsToggle: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $supports) {
                Label(L.t("print.setup.supports"), systemImage: "square.3.layers.3d.middle.filled")
            }
            Divider()
            Stepper(value: $copies, in: 1...20) {
                HStack {
                    Label(L.t("print.setup.copies"), systemImage: "square.on.square")
                    Spacer()
                    Text("\(copies)").monospacedDigit()
                }
            }
        }
        .font(.subheadline)
        .card()
    }

    @ViewBuilder
    private var filamentStatus: some View {
        if let check = filamentCheck {
            HStack(spacing: 10) {
                Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(check.ok ? Theme.printing : Theme.paused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: check.messageKey)
                        .font(.subheadline)
                    if check.hasActiveSpool {
                        Text(L.t("filament.remaining", Format.grams(check.remainingGrams)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .card()
        }
    }

    private var startButton: some View {
        VStack(spacing: 10) {
            Button {
                if settings.requirePrintChecklist {
                    showingChecklist = true
                } else {
                    Task { await startSlicing(andPrint: true) }
                }
            } label: {
                HStack(spacing: 10) {
                    if isStarting || slicing.isSlicing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "printer.fill")
                    }
                    Text(localized: "print.setup.start")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(isStarting || slicing.isSlicing)

            Button {
                Task { await startSlicing(andPrint: false) }
            } label: {
                Text(localized: "print.setup.slice_only")
                    .font(.subheadline)
            }
            .disabled(isStarting || slicing.isSlicing)

            if slicing.isSlicing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: slicing.progress)
                        .tint(Theme.accent)
                    Text(slicing.stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var estimatedGrams: Double {
        let base = item.estimatedFilamentGrams ?? 0
        // The stored estimate assumes the library default; scale it roughly by
        // infill and copies so the filament check is not wildly optimistic.
        let infillFactor = 0.55 + Double(infill) / 100.0 * 0.45
        return base * infillFactor * Double(copies)
    }

    private var estimatedSeconds: Double {
        (item.estimatedSeconds ?? 0) * quality.timeFactor * Double(copies)
    }

    private var estimateText: String {
        L.t(
            "print.setup.estimate",
            Format.duration(estimatedSeconds),
            String(Int(estimatedGrams.rounded()))
        )
    }

    private func selectableChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? Theme.accent : Theme.pageFill, in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func refreshFilamentCheck() async {
        guard estimatedGrams > 0 else { return }
        filamentCheck = await inventory.checkFilament(grams: estimatedGrams, material: material)
    }

    /// Maps the four simple choices onto validated backend profiles and slices.
    private func startSlicing(andPrint: Bool) async {
        isStarting = true
        defer { isStarting = false }

        slicing.selectedModel = BackendModelFile(
            id: item.id,
            filename: item.modelFilename,
            size: item.modelSize,
            modified: item.updatedAt,
            fileExtension: (item.modelFilename as NSString).pathExtension.lowercased()
        )
        slicing.filamentProfile = SliceProfileMapper.filamentProfile(
            for: material, available: slicing.profiles.filaments
        )
        slicing.printProfile = SliceProfileMapper.printProfile(
            for: quality, available: slicing.profiles.prints
        )
        slicing.layerHeight = quality.layerHeight
        slicing.infill = infill
        slicing.supports = supports
        slicing.uploadToPrinter = true
        // Tag the job so the backend can attach the resulting G-code to this
        // model - that is what makes the printing screen show a picture.
        slicing.customOverrides["__library_item_id"] = item.id

        await slicing.startSlicing()

        guard andPrint else { return }
        // Wait for the slice to finish before offering to print it.
        while slicing.isSlicing {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        guard slicing.job?.status == "done" else { return }
        await slicing.printResult()
        dismiss()
    }
}

// MARK: - Simple choices -> slicer profiles

enum PrintQuality: String, CaseIterable, Identifiable {
    case draft, normal, fine, ultra

    var id: String { rawValue }
    var localizationKey: String { "print.quality.\(rawValue)" }

    var layerHeight: Double {
        switch self {
        case .draft: return 0.28
        case .normal: return 0.20
        case .fine: return 0.16
        case .ultra: return 0.12
        }
    }

    /// Rough print-time multiplier relative to the stored 0.2 mm estimate.
    var timeFactor: Double {
        switch self {
        case .draft: return 0.75
        case .normal: return 1.0
        case .fine: return 1.28
        case .ultra: return 1.7
        }
    }

    var profileHints: [String] {
        switch self {
        case .draft: return ["draft", "fast", "0.28", "0.3"]
        case .normal: return ["standard", "normal", "0.2"]
        case .fine: return ["fine", "quality", "0.16"]
        case .ultra: return ["ultra", "superfine", "0.12"]
        }
    }
}

/// Picks a real profile id from the ones the backend reports, so the app never
/// sends a profile name the slicer does not have.
enum SliceProfileMapper {
    static func filamentProfile(for material: String, available: [BackendProfile]) -> String {
        let needle = material.lowercased().replacingOccurrences(of: "+", with: "plus")
        if let exact = available.first(where: { $0.id.lowercased() == needle }) { return exact.id }
        if let partial = available.first(where: { $0.id.lowercased().contains(needle) }) { return partial.id }
        let base = material.lowercased().prefix(3)
        if let loose = available.first(where: { $0.id.lowercased().hasPrefix(base) }) { return loose.id }
        return available.first?.id ?? "pla"
    }

    static func printProfile(for quality: PrintQuality, available: [BackendProfile]) -> String {
        for hint in quality.profileHints {
            if let match = available.first(where: { $0.id.lowercased().contains(hint) }) {
                return match.id
            }
        }
        return available.first(where: { $0.id.lowercased().contains("standard") })?.id
            ?? available.first?.id
            ?? "standard"
    }
}
