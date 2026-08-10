import SwiftUI
import UniformTypeIdentifiers

struct SliceView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var slicing: SliceStore

    @State private var showingImporter = false
    @State private var showingResult = false
    @State private var showingChecklist = false
    @State private var modelData: Data?
    @State private var isLoadingPreview = false

    private var modelTypes: [UTType] { ModelFileTypes.pickerTypes }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if !slicing.isSlicerAvailable && !settings.demoMode { slicerMissingCard }
                if let error = slicing.lastError { errorBanner(error) }
                // Picking a model uploads through FilesStore, so a failure lands
                // in *its* error slot. Showing only the slicing store's error
                // made a failed import completely silent: the picker closed and
                // nothing whatsoever appeared on screen.
                if let error = files.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onRetry: nil,
                        onDismiss: { files.lastError = nil }
                    )
                }

                modelCard
                if slicing.selectedModel != nil {
                    previewCard
                    profilesCard
                    parametersCard
                    outputCard
                    sliceButton
                }
                if slicing.isSlicing || slicing.job != nil { progressCard }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("tab.slice"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(settings.slicePresets) { preset in
                        Button(preset.name) { slicing.apply(preset: preset) }
                    }
                    Divider()
                    Button {
                        saveCurrentAsPreset()
                    } label: {
                        Label(L.t("slicer.save_preset"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.below.rectangle")
                }
            }
        }
        .task {
            await slicing.loadProfiles()
            await files.loadModels()
        }
        // A UIKit picker in a sheet, not .fileImporter - the same fix the
        // library screen already carries, which this screen never got.
        //
        // .fileImporter binds its completion to the view that presented it,
        // and this view is rebuilt every second by the printer status refresh.
        // When the rebuild happens while the picker is open the callback goes
        // with it: the file is selected, Open does nothing, and there is no
        // error anywhere. DocumentPicker keeps its delegate on a coordinator
        // UIKit retains, so a redraw behind the picker cannot detach it.
        .sheet(isPresented: $showingImporter) {
            DocumentPicker(
                contentTypes: modelTypes,
                allowsMultipleSelection: false,
                onPick: { urls in
                    showingImporter = false
                    handleImport(.success(urls))
                },
                onCancel: { showingImporter = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingResult) {
            if let job = slicing.job {
                SliceResultView(job: job)
            }
        }
        .sheet(isPresented: $showingChecklist) {
            PrintChecklistView {
                Task {
                    await slicing.printResult()
                    showingChecklist = false
                }
            }
            .presentationDetents([.medium])
        }
        .onChange(of: slicing.job?.status) { _, status in
            if status == "done" { showingResult = true }
        }
    }

    // MARK: - Cards

    private var slicerMissingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.t("slicer.not_installed"), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.paused)
            Text(localized: "slicer.not_installed.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(tint: Theme.paused)
    }

    private func errorBanner(_ error: APIError) -> some View {
        ErrorBanner(message: error.localizedDescription, onDismiss: { slicing.lastError = nil })
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("slicer.model", systemImage: "cube")

            Button {
                showingImporter = true
            } label: {
                Label(L.t("slicer.import"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if let label = files.uploadProgressLabel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }

            if files.models.isEmpty {
                Text(localized: "slicer.no_models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files.models) { model in
                    Button {
                        select(model)
                    } label: {
                        HStack {
                            // Filled for the model being sliced, a plus for the
                            // others sharing its plate: two different roles, and
                            // one tick for both would hide which is which.
                            Image(systemName: symbol(for: model))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.filename)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(Format.fileSize(model.size)) · \(Format.relativeDate(model.modified))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            togglePlate(model)
                        } label: {
                            Label(
                                L.t(onPlate(model) ? "slicer.plate.remove" : "slicer.plate.add"),
                                systemImage: onPlate(model) ? "minus.square" : "plus.square.on.square"
                            )
                        }
                        Button(role: .destructive) {
                            Task { await files.deleteModel(model) }
                        } label: {
                            Label(L.t("common.delete"), systemImage: "trash")
                        }
                    }
                    if model.id != files.models.last?.id { Divider() }
                }
            }

            if slicing.selectedModel != nil { plateSummary }
        }
        .card()
    }

    /// One plate, one file. Shown only once there is something to say about it.
    private var plateSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Stepper(value: $slicing.copies, in: 1...24) {
                HStack {
                    Text(localized: "slicer.copies")
                    Spacer()
                    Text("\(slicing.copies)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            if !slicing.plateModels.isEmpty {
                Text(L.t("slicer.plate.count", slicing.plateModels.count + 1))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Said once, plainly. A full plate is one print job - which is the
            // point, and also the risk.
            if slicing.plateModels.count > 0 || slicing.copies > 1 {
                Label(L.t("slicer.plate.warning"), systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(Theme.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(localized: "slicer.plate.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func onPlate(_ model: BackendModelFile) -> Bool {
        slicing.plateModels.contains { $0.id == model.id }
    }

    private func symbol(for model: BackendModelFile) -> String {
        if slicing.selectedModel?.id == model.id { return "checkmark.circle.fill" }
        if onPlate(model) { return "plus.circle.fill" }
        return "circle"
    }

    private func togglePlate(_ model: BackendModelFile) {
        guard slicing.selectedModel?.id != model.id else { return }
        if let index = slicing.plateModels.firstIndex(where: { $0.id == model.id }) {
            slicing.plateModels.remove(at: index)
        } else {
            slicing.plateModels.append(model)
        }
        Haptics.selection()
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("preview.title", systemImage: "rotate.3d")
            if isLoadingPreview {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized: "preview.loading").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ModelPreviewView(
                    data: modelData,
                    filename: slicing.selectedModel?.filename ?? "",
                    buildVolume: buildVolume
                )
            }
        }
        .card()
    }

    /// The build volume to draw the model against.
    ///
    /// The slicing profile wins when one is selected, because that is what the
    /// G-code will actually be sliced for. Otherwise it falls back to the axis
    /// travel discovered from the connected printer's printer.cfg - never to a
    /// hardcoded size.
    private var buildVolume: SIMD3<Float> {
        let discovered = printer.capabilities.buildVolume
        guard let profile = slicing.profiles.printers.first(where: { $0.id == slicing.printerProfile })
        else { return discovered ?? SIMD3(200, 200, 200) }

        let fallback = discovered ?? SIMD3(200, 200, 200)
        let height = profile.values["max_print_height"].flatMap(Float.init) ?? fallback.z
        let shape = profile.values["bed_shape"] ?? ""
        var width = fallback.x
        var depth = fallback.y
        let points = shape.split(separator: ",").compactMap { token -> (Float, Float)? in
            let parts = token.split(separator: "x")
            guard parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]) else { return nil }
            return (x, y)
        }
        if let maxX = points.map(\.0).max(), let maxY = points.map(\.1).max() {
            width = maxX
            depth = maxY
        }
        return SIMD3(width, depth, height)
    }

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("slicer.profiles", systemImage: "list.bullet.rectangle")

            picker(titleKey: "slicer.printer_profile", selection: $slicing.printerProfile,
                   options: slicing.profiles.printers)
            picker(titleKey: "slicer.filament", selection: $slicing.filamentProfile,
                   options: slicing.profiles.filaments)
            picker(titleKey: "slicer.print_profile", selection: $slicing.printProfile,
                   options: slicing.profiles.prints)

            // A mode is a shortcut for the eleven fields below, resolved
            // against this nozzle and this material. Placed with the profiles
            // because it overrides them.
            NavigationLink {
                PrintModeView(selection: $slicing.mode)
            } label: {
                HStack {
                    Text(localized: "slicer.mode")
                    Spacer()
                    Text(slicing.mode.map { L.t("mode.\($0)") } ?? L.t("slicer.mode.none"))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.tertiary)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)

            Button(L.t("slicer.load_profile_defaults")) {
                slicing.applyProfileDefaults()
                Haptics.selection()
            }
            .font(.caption)
        }
        .card()
    }

    private func picker(titleKey: String, selection: Binding<String>, options: [BackendProfile]) -> some View {
        HStack {
            Text(localized: titleKey)
                .font(.subheadline)
            Spacer()
            Picker("", selection: selection) {
                if options.isEmpty {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
                ForEach(options) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var parametersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("slicer.parameters", systemImage: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized: "slicer.layer_height")
                        .font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f mm", slicing.layerHeight))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Slider(value: $slicing.layerHeight, in: 0.06...0.4, step: 0.02)
            }

            LabelledSlider(
                titleKey: "slicer.infill",
                value: Binding(
                    get: { Double(slicing.infill) },
                    set: { slicing.infill = Int($0) }
                ),
                range: 0...100,
                step: 5,
                unit: "%"
            )

            Stepper(value: $slicing.perimeters, in: 1...8) {
                HStack {
                    Text(localized: "slicer.perimeters")
                    Spacer()
                    Text("\(slicing.perimeters)").monospacedDigit()
                }
                .font(.subheadline)
            }

            Toggle(isOn: $slicing.supports) {
                Text(localized: "slicer.supports").font(.subheadline)
            }

            if slicing.supports {
                // Where support may start from. This is the choice that
                // decides how the part comes out - support growing off the
                // model marks the surface it stood on, and no style fixes
                // that. It used to be missing entirely, so the app quietly
                // used the slicer's default of "everywhere".
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized: "slicer.support_placement").font(.subheadline)
                    Picker("", selection: $slicing.supportPlacement) {
                        Text(localized: "slicer.support_placement.everywhere").tag("everywhere")
                        Text(localized: "slicer.support_placement.plate").tag("build_plate_only")
                    }
                    .pickerStyle(.segmented)
                    Text(localized: slicing.supportPlacement == "build_plate_only"
                            ? "slicer.support_placement.plate.hint"
                            : "slicer.support_placement.everywhere.hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(localized: "slicer.support_style").font(.subheadline)
                    Picker("", selection: $slicing.supportStyle) {
                        Text("Grid").tag("grid")
                        Text("Snug").tag("snug")
                        Text("Organic").tag("organic")
                    }
                    .pickerStyle(.segmented)
                }

                // 0 means "leave the slicer's own threshold alone", which is
                // not the same as "no support" - so it is labelled, not left
                // as a bare zero.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(localized: "slicer.support_angle").font(.subheadline)
                        Spacer()
                        Text(slicing.supportThresholdAngle == 0
                                ? L.t("slicer.support_angle.auto")
                                : "\(slicing.supportThresholdAngle)°")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(slicing.supportThresholdAngle) },
                            set: { slicing.supportThresholdAngle = Int($0) }
                        ),
                        in: 0...80,
                        step: 5
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(localized: "slicer.adhesion").font(.subheadline)
                Picker("", selection: $slicing.adhesion) {
                    Text(localized: "slicer.adhesion.none").tag("none")
                    Text(localized: "slicer.adhesion.skirt").tag("skirt")
                    Text(localized: "slicer.adhesion.brim").tag("brim")
                    Text(localized: "slicer.adhesion.raft").tag("raft")
                }
                .pickerStyle(.segmented)
            }

            Toggle(isOn: $slicing.overrideTemperatures) {
                Text(localized: "slicer.override_temperatures").font(.subheadline)
            }

            if slicing.overrideTemperatures {
                Stepper(value: $slicing.nozzleTemperature, in: 150...300, step: 5) {
                    HStack {
                        Text(localized: "temperature.nozzle")
                        Spacer()
                        Text("\(slicing.nozzleTemperature)°").monospacedDigit()
                    }
                    .font(.subheadline)
                }
                Stepper(value: $slicing.bedTemperature, in: 0...120, step: 5) {
                    HStack {
                        Text(localized: "temperature.bed")
                        Spacer()
                        Text("\(slicing.bedTemperature)°").monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }

            if settings.advancedMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized: "slicer.retraction").font(.subheadline)
                    Slider(value: $slicing.retractionLength, in: 0...6, step: 0.1)
                    Text(String(format: "%.1f mm", slicing.retractionLength))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // Everything the profile normally decides. On its own screen
            // rather than stacked here, because a slicing card with thirty
            // controls is one nobody reads.
            NavigationLink {
                SliceAdvancedView()
            } label: {
                HStack {
                    Label(L.t("slicer.advanced.title"), systemImage: "slider.horizontal.below.rectangle")
                        .font(.subheadline)
                    Spacer()
                    if slicing.hasAdvancedOverrides {
                        Text("\(slicing.advancedOverrideCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.accent.opacity(0.2), in: Capsule())
                    }
                    Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("slicer.output", systemImage: "arrow.down.doc")
            Toggle(isOn: $slicing.uploadToPrinter) {
                Text(localized: "slicer.upload_to_printer").font(.subheadline)
            }
            Text(localized: "slicer.no_autostart_note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var sliceButton: some View {
        Button {
            Task { await slicing.startSlicing() }
        } label: {
            HStack {
                if slicing.isSlicing {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "wand.and.rays")
                }
                Text(localized: "slicer.start")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(slicing.isSlicing || slicing.selectedModel == nil)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("slicer.progress", systemImage: "gearshape.arrow.triangle.2.circlepath")

            ProgressView(value: slicing.progress) {
                Text(slicing.stage.isEmpty ? L.t("slicer.stage.queued") : slicing.stage)
                    .font(.caption)
            }
            .tint(Theme.accent)

            if let job = slicing.job, job.didSucceed {
                Divider()
                SliceSummary(stats: job.stats, outputFilename: job.outputFilename)

                HStack(spacing: 10) {
                    Button {
                        showingResult = true
                    } label: {
                        Label(L.t("slicer.summary"), systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if settings.requirePrintChecklist {
                            showingChecklist = true
                        } else {
                            Task { await slicing.printResult() }
                        }
                    } label: {
                        Label(L.t("slicer.print_now"), systemImage: "printer.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if slicing.isSlicing {
                Button(L.t("common.cancel"), role: .destructive) {
                    Task { await slicing.cancelSlicing() }
                }
                .font(.caption)
            }

            if !slicing.logs.isEmpty {
                DisclosureGroup(L.t("slicer.logs")) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(slicing.logs.suffix(60).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .card()
    }

    // MARK: - Actions

    private func select(_ model: BackendModelFile) {
        slicing.selectedModel = model
        Haptics.selection()
        Task {
            isLoadingPreview = true
            modelData = await files.modelData(model)
            isLoadingPreview = false
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        // A failure used to be discarded by the pattern match, so a picker
        // that errored looked exactly like one that was cancelled.
        if case .failure(let error) = result {
            files.lastError = APIError.from(error, host: settings.host)
            return
        }
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task {
            if let model = await files.upload(modelURL: url) {
                slicing.selectedModel = model
                isLoadingPreview = true
                // Read locally so the preview appears instantly. The upload
                // already succeeded, so a failure here costs only the preview.
                modelData = try? await ImportedFile.read(url)
                isLoadingPreview = false
                Haptics.success()
            }
        }
    }

    private func saveCurrentAsPreset() {
        let preset = SlicePreset(
            name: "\(slicing.filamentProfile.uppercased()) · \(slicing.printProfile)",
            printerProfile: slicing.printerProfile,
            filamentProfile: slicing.filamentProfile,
            printProfile: slicing.printProfile,
            layerHeight: slicing.layerHeight,
            infill: slicing.infill,
            supports: slicing.supports,
            adhesion: slicing.adhesion
        )
        settings.slicePresets.append(preset)
        Haptics.success()
    }
}

// MARK: - Summary

struct SliceSummary: View {
    let stats: SliceStats
    let outputFilename: String

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(outputFilename)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(titleKey: "slicer.estimated_time",
                         value: Format.duration(stats.estimatedTimeSeconds),
                         systemImage: "clock")
                StatTile(titleKey: "slicer.filament_grams",
                         value: Format.grams(stats.filamentGrams),
                         systemImage: "scalemass")
                StatTile(titleKey: "slicer.filament_meters",
                         value: Format.meters(stats.filamentMeters),
                         systemImage: "ruler")
                StatTile(titleKey: "slicer.layers",
                         value: stats.layerCount.map(String.init) ?? "--",
                         systemImage: "square.3.layers.3d")
            }
        }
    }
}

// MARK: - Result sheet

struct SliceResultView: View {
    let job: SliceJob

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var slicing: SliceStore
    @Environment(\.dismiss) private var dismiss

    @State private var shareURL: URL?
    @State private var showingShare = false
    @State private var showingChecklist = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    SliceSummary(stats: job.stats, outputFilename: job.outputFilename)
                        .card()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader("slicer.details", systemImage: "info.circle")
                        InfoRow(titleKey: "slicer.engine", value: job.engine)
                        InfoRow(titleKey: "slicer.model", value: job.modelFilename)
                        if let height = job.stats.layerHeight {
                            InfoRow(titleKey: "slicer.layer_height", value: String(format: "%.2f mm", height))
                        }
                        if let size = job.stats.gcodeSize {
                            InfoRow(titleKey: "files.size", value: Format.fileSize(size))
                        }
                        if let path = job.moonrakerPath {
                            InfoRow(titleKey: "slicer.uploaded_as", value: path)
                        }
                    }
                    .card()

                    VStack(spacing: 10) {
                        Button {
                            if settings.requirePrintChecklist {
                                showingChecklist = true
                            } else {
                                Task {
                                    await slicing.printResult()
                                    dismiss()
                                }
                            }
                        } label: {
                            Label(L.t("slicer.print_now"), systemImage: "printer.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            Task {
                                shareURL = await slicing.downloadResult()
                                showingShare = shareURL != nil
                            }
                        } label: {
                            Label(L.t("slicer.save_gcode"), systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding()
            }
            .background(Theme.pageFill)
            .navigationTitle(L.t("slicer.completed"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common.done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showingShare) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
            .sheet(isPresented: $showingChecklist) {
                PrintChecklistView {
                    Task {
                        await slicing.printResult()
                        showingChecklist = false
                        dismiss()
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}
