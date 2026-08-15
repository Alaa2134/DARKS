import SwiftUI

/// Help hub: troubleshooting, error explanations, bed mesh, system check, backups.
struct SupportView: View {
    @EnvironmentObject private var support: SupportStore

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TroubleshootingListView()
                } label: {
                    Label(L.t("troubleshooting.title"), systemImage: "stethoscope")
                }
                NavigationLink {
                    ErrorTranslatorView()
                } label: {
                    Label(L.t("error_translator.title"), systemImage: "character.book.closed")
                }
            } footer: {
                Text(localized: "troubleshooting.offline")
            }

            Section {
                NavigationLink {
                    BedMeshView()
                } label: {
                    Label(L.t("bedmesh.title"), systemImage: "grid")
                }
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    HStack {
                        Label(L.t("diagnostics.title"), systemImage: "checklist")
                        Spacer()
                        if !support.failedChecks.isEmpty {
                            Text("\(support.failedChecks.count)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.paused, in: Capsule())
                        }
                    }
                }
                NavigationLink {
                    BackupsView()
                } label: {
                    Label(L.t("backup.title"), systemImage: "archivebox")
                }
            }

            Section {
                NavigationLink {
                    MaintenanceView()
                } label: {
                    Label(L.t("maintenance.title"), systemImage: "wrench.and.screwdriver")
                }
                NavigationLink {
                    ProductsView()
                } label: {
                    Label(L.t("products.title"), systemImage: "tag")
                }
                NavigationLink {
                    CostView()
                } label: {
                    Label(L.t("cost.title"), systemImage: "banknote")
                }
            }
        }
        .navigationTitle(L.t("support.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await support.loadTopics() }
    }
}

// MARK: - Troubleshooting

struct TroubleshootingListView: View {
    @EnvironmentObject private var support: SupportStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if support.isLoadingTopics, support.topics.isEmpty {
                    ProgressView().padding(.vertical, 60)
                } else if support.topics.isEmpty {
                    EmptyStateView(
                        titleKey: "troubleshooting.title",
                        messageKey: "offline.body",
                        systemImage: "stethoscope"
                    )
                } else {
                    ForEach(support.topics) { topic in
                        NavigationLink {
                            TroubleshootingFlowView(topic: topic)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: topic.icon.isEmpty ? "questionmark.circle" : topic.icon)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.displayTitle)
                                        .font(.subheadline.weight(.medium))
                                    if !topic.summaryAR.isEmpty {
                                        Text(topic.summaryAR)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .card()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("troubleshooting.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await support.loadTopics() }
    }
}

/// Walks one decision tree, answering yes/no. Entirely offline.
struct TroubleshootingFlowView: View {
    let topic: TroubleshootingTopic

    @State private var currentStepID: String?
    @State private var advice: String?
    @State private var history: [String] = []

    private var step: TroubleshootingStep? {
        currentStepID.flatMap(topic.step)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if !topic.summaryAR.isEmpty {
                    Text(topic.summaryAR)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .card()
                }

                if let advice {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("troubleshooting.advice", systemImage: "lightbulb")
                        Text(advice)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L.t("troubleshooting.restart")) { restart() }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                    .card(tint: Theme.printing)
                } else if let step {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(step.questionAR.isEmpty ? step.questionEN : step.questionAR)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button(L.t("troubleshooting.yes")) { answer(yes: true, step: step) }
                                .buttonStyle(.borderedProminent)
                            Button(L.t("troubleshooting.no")) { answer(yes: false, step: step) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .card()
                } else {
                    Button {
                        currentStepID = topic.firstStep
                    } label: {
                        Text(localized: "troubleshooting.start")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                if !topic.quickFixesAR.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("troubleshooting.quick_fixes", systemImage: "bolt")
                        ForEach(topic.quickFixesAR, id: \.self) { fix in
                            Label(fix, systemImage: "checkmark.circle")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .card()
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(topic.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func answer(yes: Bool, step: TroubleshootingStep) {
        history.append(step.id)
        let next = yes ? step.yesNext : step.noNext
        if let next, topic.step(next) != nil {
            currentStepID = next
        } else {
            let text = step.adviceAR.isEmpty ? step.adviceEN : step.adviceAR
            advice = text.isEmpty ? L.t("troubleshooting.quick_fixes") : text
        }
    }

    private func restart() {
        advice = nil
        history = []
        currentStepID = topic.firstStep
    }
}

// MARK: - Error translator

struct ErrorTranslatorView: View {
    @EnvironmentObject private var support: SupportStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var input = ""
    @State private var result: TranslatedError?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(L.t("error_translator.placeholder"), text: $input, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.plain)
                    HStack(spacing: 12) {
                        Button(L.t("error_translator.translate")) {
                            Task { await translate(input) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                        if hasPrinterError {
                            Button(L.t("home.state.error")) {
                                Task {
                                    isWorking = true
                                    result = await support.translateCurrentPrinterError()
                                    input = result?.original ?? input
                                    isWorking = false
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                }
                .card()

                if let result {
                    resultCard(result)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("error_translator.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasPrinterError: Bool {
        !(printer.snapshot.errorMessage ?? "").isEmpty || printer.snapshot.klippy == .error
    }

    private func resultCard(_ translated: TranslatedError) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(translated.titleAR.isEmpty ? translated.titleEN : translated.titleAR)
                    .font(.headline)
                Text(translated.explanationAR.isEmpty ? translated.explanationEN : translated.explanationAR)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !translated.matched {
                Label(L.t("error_translator.unmatched"), systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !translated.causesAR.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized: "error_translator.causes")
                        .font(.subheadline.weight(.semibold))
                    ForEach(translated.causesAR, id: \.self) { cause in
                        Label(cause, systemImage: "circle.fill")
                            .font(.caption)
                            .labelStyle(BulletLabelStyle())
                    }
                }
            }

            if !translated.checksAR.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized: "error_translator.checks")
                        .font(.subheadline.weight(.semibold))
                    ForEach(translated.checksAR, id: \.self) { check in
                        Label(check, systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                }
            }

            // The original text is always kept - translations never replace it.
            VStack(alignment: .leading, spacing: 4) {
                Text(localized: "error_translator.original")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(translated.original)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .card(tint: translated.severity == "error" ? Theme.danger : .clear)
    }

    private func translate(_ text: String) async {
        isWorking = true
        defer { isWorking = false }
        result = await support.translate(text)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
