import SwiftUI

/// Turn the model, size it, and stand it up before slicing it.
///
/// The library used to hand a model to the slicer exactly as it was exported,
/// which means a model exported lying on its side got sliced lying on its side.
/// Orientation is not a detail: it decides which faces need support, how tall
/// the print stands, which way the layer lines run, and therefore where the
/// part breaks.
///
/// Every number on this screen is measured on the Pi against the real mesh. The
/// height, the footprint, the area that would need support and whether it still
/// fits this machine all come back from turning the actual triangles - nothing
/// here is estimated from a bounding box.
struct PlacementView: View {
    let modelID: String
    let modelName: String
    /// Rendered live, so the picture matches the numbers.
    var mesh: LoadedMesh?

    @EnvironmentObject private var placement: PlacementStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var scalePercent: Double = 100
    @State private var showingReset = false

    private var current: ModelTransform { placement.transform(for: modelID) }
    private var report: OrientationReport? { placement.report(for: modelID) }
    private var suggestion: OrientationSuggestion? { placement.suggestion(for: modelID) }

    /// This machine's own volume, from its printer.cfg. Falls back only when
    /// discovery has not run.
    private var buildVolume: SIMD3<Float> {
        let limits = printer.capabilities.axisLimits
        func span(_ axis: String, _ fallback: Float) -> Float {
            guard let limit = limits[axis] else { return fallback }
            return Float(max(0, limit.max - Swift.max(limit.min, 0)))
        }
        return SIMD3(span("x", 320), span("y", 320), span("z", 400))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = placement.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { placement.lastError = nil }
                    )
                }

                preview
                measurements
                autoOrientCard
                rotationCard
                scaleCard
                mirrorCard
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("placement.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingReset = true
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(current.isIdentity)
                .accessibilityLabel(L.t("placement.reset"))
            }
        }
        .confirmationDialog(
            L.t("placement.reset.confirm"),
            isPresented: $showingReset,
            titleVisibility: .visible
        ) {
            Button(L.t("placement.reset"), role: .destructive) {
                placement.reset(modelID)
                scalePercent = 100
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
        .task {
            scalePercent = (current.uniformScale ?? 1) * 100
            await placement.measure(modelID)
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if let mesh {
            // The viewer draws the model as exported; the rotation applied here
            // is shown on top of it so the picture and the numbers agree.
            ModelViewer3D(mesh: mesh, buildVolume: buildVolume)
                .rotation3DEffect(.degrees(current.rotationDeg[safe: 2] ?? 0), axis: (0, 0, 1))
                .card()
        }
    }

    // MARK: - Measurements

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("placement.size", systemImage: "ruler")

            if let report {
                HStack(spacing: 12) {
                    StatTile(
                        titleKey: "machine.x",
                        value: Format.millimetres(report.width),
                        systemImage: "arrow.left.and.right"
                    )
                    StatTile(
                        titleKey: "machine.y",
                        value: Format.millimetres(report.depth),
                        systemImage: "arrow.up.and.down"
                    )
                    StatTile(
                        titleKey: "machine.z",
                        value: Format.millimetres(report.height),
                        systemImage: "arrow.up.to.line",
                        tint: report.fits ? Theme.accent : Theme.danger
                    )
                }

                if !report.fits {
                    ForEach(report.problemsAr, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Support area is the number that decides an orientation, so it
                // is stated in mm² rather than as "needs support" - the
                // difference between 20 mm² and 2000 mm² is the difference
                // between a scar you sand off and a second print.
                Label(
                    report.needsSupport
                        ? L.t("placement.support.needed", report.overhangArea)
                        : L.t("placement.support.none"),
                    systemImage: report.needsSupport ? "triangle.righthalf.filled" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(report.needsSupport ? Theme.paused : Theme.printing)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    L.t("placement.base_area", report.baseArea),
                    systemImage: "square.dashed.inset.filled"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if placement.isMeasuring {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(localized: "placement.measuring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    // MARK: - Auto-orient

    private var autoOrientCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("placement.auto.title", systemImage: "wand.and.stars")

            Text(localized: "placement.auto.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let suggestion {
                if suggestion.isWorthApplying {
                    comparison(suggestion)
                    Button {
                        placement.applySuggestion(for: modelID)
                        scalePercent = (placement.transform(for: modelID).uniformScale ?? 1) * 100
                    } label: {
                        Label(L.t("placement.auto.apply"), systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    // Saying "it is already the best way up" is the useful
                    // answer here. An auto-orient that always turns something
                    // is worse than one that knows when to leave it alone.
                    Label(L.t("placement.auto.already_best"), systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.printing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Prominent the first time, quiet afterwards: once there is an
            // answer on screen, asking again is a secondary action.
            if suggestion == nil {
                Button(action: runAutoOrient) { autoOrientLabel }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(placement.isSuggesting)
            } else {
                Button(action: runAutoOrient) { autoOrientLabel }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(placement.isSuggesting)
            }
        }
        .card()
    }

    private func runAutoOrient() {
        Task { await placement.suggestOrientation(for: modelID) }
    }

    private var autoOrientLabel: some View {
        HStack {
            if placement.isSuggesting { ProgressView().controlSize(.small) }
            Text(localized: suggestion == nil ? "placement.auto.run" : "placement.auto.again")
        }
        .frame(maxWidth: .infinity)
    }

    /// Before and after, side by side. The suggestion has to earn the tap.
    private func comparison(_ suggestion: OrientationSuggestion) -> some View {
        HStack(spacing: 0) {
            comparisonColumn(
                titleKey: "placement.compare.now",
                report: suggestion.current,
                tint: .secondary
            )
            Image(systemName: "arrow.left")
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
            comparisonColumn(
                titleKey: "placement.compare.suggested",
                report: suggestion.suggested,
                tint: Theme.printing
            )
        }
        .padding(12)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func comparisonColumn(
        titleKey: String,
        report: OrientationReport,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized: titleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(L.t("placement.support.area", report.overhangArea))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(L.t("placement.height.short", report.height))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rotation

    private var rotationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("placement.rotate", systemImage: "rotate.3d")

            ForEach(Array(["x", "y", "z"].enumerated()), id: \.offset) { index, axis in
                rotationRow(axis: axis, index: index)
            }
        }
        .card()
    }

    private func rotationRow(axis: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: axis.uppercased())
                    .font(.subheadline.weight(.bold))
                    .frame(width: 20)
                Spacer()
                Text(L.t("placement.degrees", current.rotationDeg[safe: index] ?? 0))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Ninety-degree steps rather than a free dial. Almost every useful
            // rotation is a right angle - it is how models are exported wrong -
            // and a slider makes 90.0 the one value that is hard to hit.
            HStack(spacing: 8) {
                ForEach([-90.0, -45.0, 45.0, 90.0], id: \.self) { step in
                    Button {
                        placement.rotate(modelID, byDegrees: step, axis: index)
                        Haptics.impact(.light)
                    } label: {
                        Text(step > 0 ? "+\(Int(step))°" : "\(Int(step))°")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Scale

    private var scaleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("placement.scale", systemImage: "arrow.up.left.and.arrow.down.right")

            HStack {
                Text(localized: "placement.scale.percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(Int(scalePercent))%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }

            Slider(value: $scalePercent, in: 10...400, step: 5) { editing in
                // Applied when the drag ends, not during it: each change costs
                // the Pi a full pass over the mesh.
                if !editing { placement.setUniformScale(scalePercent / 100, for: modelID) }
            }

            HStack(spacing: 8) {
                ForEach([50.0, 100.0, 150.0, 200.0], id: \.self) { preset in
                    Button {
                        scalePercent = preset
                        placement.setUniformScale(preset / 100, for: modelID)
                        Haptics.impact(.light)
                    } label: {
                        Text(verbatim: "\(Int(preset))%")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                (abs(scalePercent - preset) < 0.5 ? Theme.accent.opacity(0.25) : Theme.accent.opacity(0.10)),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    // MARK: - Mirror

    private var mirrorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("placement.mirror", systemImage: "flip.horizontal")

            Text(localized: "placement.mirror.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(Array(["x", "y", "z"].enumerated()), id: \.offset) { index, axis in
                    let on = current.mirror[safe: index] ?? false
                    Button {
                        placement.toggleMirror(modelID, axis: index)
                        Haptics.impact(.light)
                    } label: {
                        Text(verbatim: axis.uppercased())
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                on ? Theme.accent.opacity(0.28) : Theme.accent.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(on ? Theme.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card()
    }
}

extension Array {
    /// Bounds-checked access. The transform arrays come from the Pi, and a
    /// short one from an older backend must not crash the screen.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
