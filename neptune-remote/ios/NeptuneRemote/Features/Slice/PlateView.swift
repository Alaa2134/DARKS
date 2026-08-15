import SwiftUI

/// The bed, from above, with the parts on it.
///
/// `extra_model_ids` and `copies` already existed, but the arrangement was left
/// entirely to the slicer: you could put four things on a plate and had no say
/// in where any of them went, and no way to see it. That is fine until two
/// parts touch, or one lands over a bed clip, or the plate is pushed off the
/// front edge - and the first sign of any of that was a failed print.
///
/// Drag a part and it moves. Everything is checked as it moves, against this
/// printer's own bed size, so the warning arrives while your finger is still
/// on the screen rather than four hours into a print.
struct PlateView: View {
    let modelIDs: [String]

    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var placement: PlacementStore

    @State private var arrangement: ArrangeResponse?
    @State private var isArranging = false
    @State private var error: APIError?
    /// The part being dragged, and where it started - so a drag that goes out
    /// of bounds can be put back rather than left there.
    @State private var dragging: String?
    @State private var dragStart: CGPoint = .zero

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { self.error = nil }
                    )
                }

                if isArranging && arrangement == nil {
                    BusyLine(textKey: "plate.arranging").card()
                } else if let arrangement {
                    bedCard(arrangement)
                    problemsCard(arrangement)
                    actionsCard
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
            .animation(.neptuneContent, value: arrangement)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("plate.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await arrange() }
    }

    // MARK: - The bed

    private func bedCard(_ result: ArrangeResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader("plate.bed", systemImage: "squareshape.split.2x2")
                Spacer()
                Text(String(format: "%.0f × %.0f mm", result.bedWidth, result.bedDepth))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                // One scale for both axes, so a non-square bed is drawn with
                // its real proportions rather than stretched to fill a square.
                let scale = side / max(result.bedWidth, result.bedDepth, 1)
                let bed = CGSize(
                    width: result.bedWidth * scale,
                    height: result.bedDepth * scale
                )
                let origin = CGPoint(
                    x: (geometry.size.width - bed.width) / 2,
                    y: (geometry.size.height - bed.height) / 2
                )

                ZStack(alignment: .topLeading) {
                    bedSurface(bed: bed, origin: origin)

                    ForEach(result.placements) { item in
                        partTile(item, bed: bed, origin: origin, scale: scale, result: result)
                    }
                }
            }
            .aspectRatio(max(result.bedWidth, 1) / max(result.bedDepth, 1), contentMode: .fit)
            .frame(maxWidth: .infinity)

            Text(localized: "plate.drag_hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func bedSurface(bed: CGSize, origin: CGPoint) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.previewBed)
            // A grid at roughly 50 mm, so a distance on screen means something.
            Path { path in
                let steps = 6
                for index in 1..<steps {
                    let fraction = CGFloat(index) / CGFloat(steps)
                    path.move(to: CGPoint(x: bed.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: bed.width * fraction, y: bed.height))
                    path.move(to: CGPoint(x: 0, y: bed.height * fraction))
                    path.addLine(to: CGPoint(x: bed.width, y: bed.height * fraction))
                }
            }
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .frame(width: bed.width, height: bed.height)
        .offset(x: origin.x, y: origin.y)
    }

    // MARK: - One part

    private func partTile(
        _ item: PlatePlacement,
        bed: CGSize,
        origin: CGPoint,
        scale: CGFloat,
        result: ArrangeResponse
    ) -> some View {
        let size = CGSize(width: item.width * scale, height: item.depth * scale)
        // Bed coordinates run from the centre, and Y grows away from the front
        // while the screen's Y grows downwards - so it is flipped here, or the
        // plate is a mirror of what comes off the printer.
        let centre = CGPoint(
            x: origin.x + bed.width / 2 + item.x * scale,
            y: origin.y + bed.height / 2 - item.y * scale
        )
        let trouble = result.problemsAr.contains { $0.contains(item.modelID) }

        return RoundedRectangle(cornerRadius: 4)
            .fill(trouble ? Theme.danger.opacity(0.35) : Theme.accent.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(trouble ? Theme.danger : Theme.accent, lineWidth: 1.5)
            )
            .overlay(
                Text(String(format: "%.0f×%.0f", item.width, item.depth))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(2)
                    .opacity(size.width > 44 ? 1 : 0)
            )
            .frame(width: max(size.width, 8), height: max(size.height, 8))
            .position(centre)
            .gesture(dragGesture(item, scale: scale))
            .animation(.neptune, value: trouble)
            .accessibilityLabel(
                L.t("plate.part.accessibility", item.modelID, Int(item.x), Int(item.y))
            )
    }

    private func dragGesture(_ item: PlatePlacement, scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragging != item.modelID {
                    dragging = item.modelID
                    dragStart = CGPoint(x: item.x, y: item.y)
                    Haptics.selection()
                }
                move(
                    item.modelID,
                    to: CGPoint(
                        x: dragStart.x + value.translation.width / scale,
                        y: dragStart.y - value.translation.height / scale
                    )
                )
            }
            .onEnded { _ in
                dragging = nil
                // Re-checked on release rather than on every frame of the
                // drag: the check is cheap but the round trip is not, and a
                // warning that flickers while you move is a warning you learn
                // to ignore.
                Task { await recheck() }
            }
    }

    // MARK: - Problems

    @ViewBuilder
    private func problemsCard(_ result: ArrangeResponse) -> some View {
        if !result.problemsAr.isEmpty || !result.unplaced.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L.t("plate.problems"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)

                ForEach(result.problemsAr, id: \.self) { problem in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Theme.danger).frame(width: 5, height: 5).padding(.top, 6)
                        Text(problem)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .card()
            .transition(.neptuneContent)
        } else {
            Label(L.t("plate.ready"), systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.printing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .transition(.neptuneContent)
        }
    }

    private var actionsCard: some View {
        HStack(spacing: 10) {
            Button {
                Task { await arrange(force: true) }
            } label: {
                Label(L.t("plate.auto"), systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isArranging)

            Button {
                for id in modelIDs { placement.setPosition(.zero, for: id) }
                Task { await arrange(force: true) }
            } label: {
                Label(L.t("plate.reset"), systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isArranging)
        }
        .card()
    }

    // MARK: - Work

    /// Move one part, and update what is on screen immediately.
    ///
    /// The drawing comes from local state during a drag rather than from the
    /// Pi, because a network round trip per frame is not a drag gesture.
    private func move(_ modelID: String, to point: CGPoint) {
        placement.setPosition(point, for: modelID)
        guard var current = arrangement,
              let index = current.placements.firstIndex(where: { $0.modelID == modelID })
        else { return }
        current.placements[index].x = point.x
        current.placements[index].y = point.y
        arrangement = current
    }

    private func arrange(force: Bool = false) async {
        guard !modelIDs.isEmpty else { return }
        guard force || arrangement == nil else { return }
        isArranging = true
        defer { isArranging = false }
        do {
            let result = try await printer.backend.arrangePlate(
                ArrangeRequestPayload(
                    modelIDs: modelIDs,
                    transforms: placement.platePayload(for: modelIDs)
                )
            )
            arrangement = result
            // Write the chosen positions back, so the slice carries them.
            for item in result.placements {
                placement.setPosition(CGPoint(x: item.x, y: item.y), for: item.modelID)
            }
            error = nil
        } catch {
            self.error = APIError.from(error, host: settings.host)
        }
    }

    /// Ask the Pi to judge the plate as it now stands.
    ///
    /// `checkOnly` matters here: the ordinary call rearranges, and adopting
    /// that answer would undo the drag that had just happened and report a
    /// verdict about a plate the user never built.
    private func recheck() async {
        do {
            let result = try await printer.backend.arrangePlate(
                ArrangeRequestPayload(
                    modelIDs: modelIDs,
                    transforms: placement.platePayload(for: modelIDs),
                    checkOnly: true
                )
            )
            var current = arrangement
            current?.problemsAr = result.problemsAr
            current?.unplaced = result.unplaced
            current?.ok = result.ok
            arrangement = current
            error = nil
        } catch {
            self.error = APIError.from(error, host: settings.host)
        }
    }
}
