import SwiftUI

/// Notifications that arrive when the app is closed - and the honest statement
/// of whether any will.
///
/// The screen leads with `reachableWhenAppIsClosed` on purpose. Everything else
/// here is a preference; that one line is a fact, and getting it wrong is how
/// someone finds out about a nine-hour failed print by walking into the room.
struct AlertSettingsView: View {
    @EnvironmentObject private var alerts: AlertStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var notifications: NotificationManager

    @State private var showingSetupGuide = false

    var body: some View {
        List {
            reachabilitySection
            if let record = alerts.unacknowledgedOutage {
                outageSection(record)
            }
            channelsSection
            eventsSection
            quietHoursSection
            heartbeatSection
            localSection
            powerHistorySection
        }
        .navigationTitle(L.t("alerts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await alerts.load(force: true) }
        .task {
            await alerts.load()
            await notifications.refreshAuthorizationStatus()
        }
        .sheet(isPresented: $showingSetupGuide) {
            NavigationStack { AlertSetupGuideView() }
        }
    }

    // MARK: - Will anything reach me?

    private var reachabilitySection: some View {
        Section {
            // An unreachable backend must not be drawn as "no channels
            // configured" - that is a claim about the Pi's settings, and we do
            // not know them. Say what actually happened instead.
            if let error = alerts.lastError, !alerts.status.notifications.configured {
                Label(error.localizedDescription, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Theme.paused)
                Button(L.t("common.retry")) {
                    Task { await alerts.load(force: true) }
                }
            } else {
                reachabilitySummary
            }

            ForEach(alerts.status.notifications.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
            }

            if !alerts.isReachableWhenClosed, alerts.lastError == nil {
                Button {
                    showingSetupGuide = true
                } label: {
                    Label(L.t("alerts.setup.open"), systemImage: "wrench.and.screwdriver")
                }
            }
        } header: {
            Text(localized: "alerts.section.reachability")
        } footer: {
            Text(localized: "alerts.section.reachability.footer")
        }
    }

    private var reachabilitySummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alerts.isReachableWhenClosed ? "bell.badge.fill" : "bell.slash.fill")
                .font(.title2)
                .foregroundStyle(alerts.isReachableWhenClosed ? Theme.printing : Theme.danger)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(localized: alerts.isReachableWhenClosed
                     ? "alerts.reachable.yes"
                     : "alerts.reachable.no")
                    .font(.subheadline.weight(.semibold))
                if !alerts.status.advice.text.isEmpty {
                    Text(alerts.status.advice.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Outage

    private func outageSection(_ record: OutageRecord) -> some View {
        Section {
            OutageCard(record: record) {
                Task { await alerts.acknowledge(record) }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Channels

    private var channelsSection: some View {
        Section {
            if alerts.status.notifications.channels.isEmpty {
                Text(localized: "alerts.channels.none")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alerts.status.notifications.channels) { channel in
                    HStack {
                        Label(channel.name, systemImage: channelIcon(channel.name))
                        Spacer()
                        if channel.isHealthy {
                            Text(L.t("alerts.channel.sent", channel.sent))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(channel.lastError)
                                .font(.caption2)
                                .foregroundStyle(Theme.danger)
                                .lineLimit(2)
                        }
                    }
                }
            }

            Button {
                Task { await alerts.sendTest() }
            } label: {
                HStack {
                    if alerts.isTesting { ProgressView().controlSize(.small) }
                    Label(L.t("alerts.test.send"), systemImage: "paperplane")
                }
            }
            .disabled(alerts.isTesting || alerts.status.notifications.channels.isEmpty)

            if let result = alerts.lastTest {
                Label(
                    L.t(result.sent ? "alerts.test.sent" : "alerts.test.failed"),
                    systemImage: result.sent ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(result.sent ? Theme.printing : Theme.danger)
            }
        } header: {
            Text(localized: "alerts.section.channels")
        } footer: {
            Text(localized: "alerts.section.channels.footer")
        }
    }

    private func channelIcon(_ name: String) -> String {
        switch name {
        case "ntfy": return "bell.badge"
        case "telegram": return "paperplane.fill"
        default: return "link"
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        Section {
            Toggle(L.t("alerts.enabled"), isOn: Binding(
                get: { alerts.preferences.enabled },
                set: { newValue in
                    var updated = alerts.preferences
                    updated.enabled = newValue
                    Task { await alerts.save(updated) }
                }
            ))

            if alerts.preferences.enabled {
                ForEach(alerts.status.notifications.availableEvents, id: \.self) { kind in
                    eventToggle(kind)
                }
            }
        } header: {
            Text(localized: "alerts.section.events")
        } footer: {
            Text(localized: "alerts.section.events.footer")
        }
    }

    private func eventToggle(_ kind: String) -> some View {
        let isCritical = alerts.criticalEvents.contains(kind)
        return Toggle(isOn: Binding(
            get: { alerts.preferences.events.contains(kind) },
            set: { newValue in Task { await alerts.setEvent(kind, enabled: newValue) } }
        )) {
            HStack(spacing: 6) {
                Text(L.t("notification.\(kind).title"))
                if isCritical {
                    // Marked because these ignore quiet hours and the rate
                    // limit: the user should know which switches are the ones
                    // that will wake them at 3am, and that it is deliberate.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.paused)
                }
            }
        }
    }

    // MARK: - Quiet hours

    private var quietHoursSection: some View {
        Section {
            Toggle(L.t("alerts.quiet_hours"), isOn: Binding(
                get: { alerts.preferences.quietHoursEnabled },
                set: { newValue in
                    var updated = alerts.preferences
                    updated.quietHoursEnabled = newValue
                    Task { await alerts.save(updated) }
                }
            ))

            if alerts.preferences.quietHoursEnabled {
                hourPicker("alerts.quiet_hours.start", value: alerts.preferences.quietStartHour) {
                    var updated = alerts.preferences
                    updated.quietStartHour = $0
                    Task { await alerts.save(updated) }
                }
                hourPicker("alerts.quiet_hours.end", value: alerts.preferences.quietEndHour) {
                    var updated = alerts.preferences
                    updated.quietEndHour = $0
                    Task { await alerts.save(updated) }
                }
            }
        } header: {
            Text(localized: "alerts.section.quiet_hours")
        } footer: {
            Text(localized: "alerts.section.quiet_hours.footer")
        }
    }

    private func hourPicker(
        _ titleKey: String,
        value: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        Picker(L.t(titleKey), selection: Binding(get: { value }, set: onChange)) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
            }
        }
    }

    // MARK: - Heartbeat

    private var heartbeatSection: some View {
        Section {
            HStack {
                Label(
                    L.t(alerts.status.heartbeat.enabled ? "alerts.heartbeat.on" : "alerts.heartbeat.off"),
                    systemImage: "waveform.path.ecg"
                )
                Spacer()
                if alerts.status.heartbeat.enabled,
                   let since = alerts.status.heartbeat.secondsSinceLastPing {
                    Text(Format.duration(since))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if alerts.status.heartbeat.enabled {
                Button(L.t("alerts.heartbeat.test")) {
                    Task { await alerts.testHeartbeat() }
                }
                if !alerts.status.heartbeat.lastError.isEmpty {
                    Text(alerts.status.heartbeat.lastError)
                        .font(.caption2)
                        .foregroundStyle(Theme.danger)
                }
            }
        } header: {
            Text(localized: "alerts.section.heartbeat")
        } footer: {
            Text(localized: "alerts.section.heartbeat.footer")
        }
    }

    // MARK: - Local notifications

    private var localSection: some View {
        Section {
            Toggle(L.t("settings.notifications"), isOn: $settings.notificationsEnabled)
            if settings.notificationsEnabled {
                Toggle(L.t("alerts.local.power"), isOn: $settings.notifyPowerAndRunout)
                Toggle(L.t("alerts.local.progress"), isOn: $settings.notifyProgressMilestones)

                if notifications.authorizationStatus == .denied {
                    Label(L.t("settings.notifications.denied"), systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(Theme.paused)
                } else if notifications.authorizationStatus != .authorized {
                    Button(L.t("settings.notifications.request")) {
                        Task { await notifications.requestAuthorization() }
                    }
                }
            }
        } header: {
            Text(localized: "alerts.section.local")
        } footer: {
            Text(localized: "alerts.section.local.footer")
        }
    }

    // MARK: - History

    private var powerHistorySection: some View {
        Section {
            if alerts.outage.records.isEmpty {
                Text(localized: "alerts.outage.none")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(alerts.outage.records.prefix(10)) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(record.causeAr, systemImage: record.systemImage)
                            .font(.subheadline.weight(.medium))
                        Text(Format.date(record.detectedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let snapshot = record.snapshot, !snapshot.layerText.isEmpty {
                            Text(L.t("alerts.outage.reached", snapshot.layerText))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let present = alerts.outage.serialPresent {
                LabeledContent(L.t("alerts.outage.mcu")) {
                    Text(L.t(present ? "alerts.outage.mcu.present" : "alerts.outage.mcu.absent"))
                        .foregroundStyle(present ? Theme.printing : Theme.danger)
                }
            } else if alerts.outage.enabled {
                // Stated rather than hidden: with no device to watch, the
                // backend cannot tell a power cut from a Klipper crash, and it
                // refuses to guess.
                Text(localized: "alerts.outage.no_serial")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
            }
        } header: {
            Text(localized: "alerts.section.outages")
        } footer: {
            Text(localized: "alerts.section.outages.footer")
        }
    }
}
