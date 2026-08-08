import SwiftUI

/// The local print-failure monitor.
///
/// Two promises are stated on screen, because they are the ones a user needs to
/// trust: nothing leaves the Raspberry Pi, and the monitor can pause a print but
/// never cuts mains power.
struct VisionView: View {
    @EnvironmentObject private var media: MediaStore

    @State private var showingROI = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = media.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        Task { await media.load(force: true) }
                    } onDismiss: {
                        media.lastError = nil
                    }
                }

                promiseCard
                modePicker
                statusCard
                if !media.vision.available { unavailableCard }
                tuning
                events
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("vision.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingROI) {
            NavigationStack { ROIPickerView() }
        }
        .refreshable {
            await media.load(force: true)
            await media.loadVisionEvents()
        }
        .task {
            await media.load()
            await media.loadVisionEvents()
        }
    }

    private var promiseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.t("vision.subtitle"), systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if media.vision.neverCutsPower {
                Label(L.t("vision.never_cuts_power"), systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(VisionMode.allCases) { mode in
                Button {
                    Task { await media.setVisionMode(mode) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.systemImage)
                            .foregroundStyle(media.visionMode == mode ? Theme.accent : .secondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localized: mode.localizationKey)
                                .font(.subheadline.weight(.medium))
                            Text(localized: "\(mode.localizationKey).detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if media.visionMode == mode {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                if mode != VisionMode.allCases.last { Divider() }
            }
        }
        .card()
    }

    private var statusCard: some View {
        VStack(spacing: 10) {
            InfoRow(
                titleKey: "vision.provider.\(media.vision.provider)",
                value: media.vision.running ? L.t("common.on") : L.t("common.off"),
                tint: media.vision.running ? Theme.printing : .secondary
            )
            InfoRow(
                titleKey: "vision.frames_analysed",
                value: "\(media.vision.framesAnalysed)"
            )
            InfoRow(
                titleKey: "vision.interval",
                value: String(format: "%.0f s", media.vision.intervalSeconds)
            )
            InfoRow(
                titleKey: "vision.confirmations",
                value: "\(media.vision.confirmationsRequired)"
            )
            if media.vision.isHeuristic {
                Text(localized: "vision.provider.heuristic.note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !media.vision.lastError.isEmpty {
                Text(media.vision.lastError)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private var unavailableCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.paused)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized: media.visionBlockedKey)
                    .font(.subheadline)
                if !media.vision.reason.isEmpty {
                    Text(media.vision.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .card(tint: Theme.paused)
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showingROI = true
            } label: {
                HStack {
                    Label(L.t("camera.roi"), systemImage: "viewfinder.rectangular")
                    Spacer()
                    Text(media.vision.roi == nil ? L.t("camera.roi.clear") : "✓")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)

            Divider()

            Button {
                Task { await media.confirmFirstLayerOK() }
            } label: {
                Label(L.t("vision.first_layer"), systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    @ViewBuilder
    private var events: some View {
        SectionHeader(
            "vision.events",
            systemImage: "list.bullet.rectangle",
            trailing: clearEventsButton
        )
        .frame(maxWidth: .infinity, alignment: .leading)

        if media.visionEvents.isEmpty {
            EmptyStateView(
                titleKey: "vision.events.empty",
                messageKey: "vision.subtitle",
                systemImage: "eye"
            )
        } else {
            ForEach(media.visionEvents) { event in
                eventCard(event)
            }
        }
    }

    private var clearEventsButton: AnyView? {
        guard !media.visionEvents.isEmpty else { return nil }
        return AnyView(
            Button(L.t("vision.events.clear")) {
                Task { await media.clearVisionEvents() }
            }
            .font(.caption)
        )
    }

    private func eventCard(_ event: VisionEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = media.eventImageURL(event) {
                ModelImage(
                    url: url, name: "", category: "other",
                    cornerRadius: Theme.smallCornerRadius, showsPlaceholderLabel: false
                )
                .aspectRatio(4 / 3, contentMode: .fit)
            }

            HStack(spacing: 8) {
                Image(systemName: event.confirmed ? "exclamationmark.triangle.fill" : "eye")
                    .foregroundStyle(event.confirmed ? Theme.paused : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: event.localizationKey)
                        .font(.subheadline.weight(.medium))
                    Text(Format.date(event.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(Format.percentValue(event.confidence * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                StatusPill(
                    text: L.t("vision.action.\(event.action.isEmpty ? "none" : event.action)"),
                    color: event.action == "paused" ? Theme.danger : Theme.idle,
                    systemImage: event.action == "paused" ? "pause.circle" : "bell"
                )
                Spacer(minLength: 0)
                if !event.acknowledged {
                    Button(L.t("vision.acknowledge")) {
                        Task { await media.acknowledge(event) }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .card(tint: event.confirmed && !event.acknowledged ? Theme.paused : .clear)
    }
}

/// Drag a box over the live view to tell the monitor where the print is.
struct ROIPickerView: View {
    @EnvironmentObject private var media: MediaStore
    @Environment(\.dismiss) private var dismiss

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    var body: some View {
        VStack(spacing: Theme.spacing) {
            Text(localized: "camera.roi.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GeometryReader { geometry in
                ZStack {
                    if let url = media.streamURL {
                        MJPEGView(url: url)
                    } else if let url = media.snapshotURL {
                        TimedSnapshotView(url: url)
                    } else {
                        Color.black.opacity(0.1).overlay {
                            Text(localized: "camera.status.no_camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let rect = selectionRect(in: geometry.size) {
                        Rectangle()
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .background(Theme.accent.opacity(0.12))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if start == nil { start = value.startLocation }
                            current = value.location
                        }
                        .onEnded { value in
                            current = value.location
                            commit(in: geometry.size)
                        }
                )
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .padding(.horizontal)

            HStack(spacing: 12) {
                Button(L.t("camera.roi.clear")) {
                    start = nil
                    current = nil
                    Task { await media.clearROI() }
                }
                .buttonStyle(.bordered)

                Button(L.t("camera.roi.save")) {
                    Task {
                        await media.commitROI()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(media.pendingROI == nil)
            }

            Spacer()
        }
        .padding(.top, Theme.spacing)
        .background(Theme.pageFill)
        .navigationTitle(L.t("camera.roi"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
        }
        .task { await media.refreshCamera() }
    }

    private func selectionRect(in size: CGSize) -> CGRect? {
        if let start, let current {
            return CGRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y)
            )
        }
        // Show the region already stored on the backend.
        guard let roi = media.pendingROI, roi.count == 4, size.width > 0, size.height > 0 else {
            return nil
        }
        return CGRect(
            x: roi[0] * size.width, y: roi[1] * size.height,
            width: (roi[2] - roi[0]) * size.width, height: (roi[3] - roi[1]) * size.height
        )
    }

    private func commit(in size: CGSize) {
        guard let start, let current, size.width > 0, size.height > 0 else { return }
        let x0 = min(start.x, current.x) / size.width
        let y0 = min(start.y, current.y) / size.height
        let x1 = max(start.x, current.x) / size.width
        let y1 = max(start.y, current.y) / size.height
        guard x1 - x0 > 0.05, y1 - y0 > 0.05 else { return }
        media.pendingROI = [
            min(max(x0, 0), 1), min(max(y0, 0), 1),
            min(max(x1, 0), 1), min(max(y1, 0), 1)
        ]
    }
}
