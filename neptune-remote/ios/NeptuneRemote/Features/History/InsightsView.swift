import SwiftUI

/// What this printer's own results say about what works on it.
///
/// The screen's job is to not overclaim. A success rate from two prints is
/// noise wearing a percentage sign, so combinations below the minimum render
/// their counts and no percentage at all - the backend returns nil for exactly
/// that reason, and the UI has to respect it rather than compute one itself.
struct InsightsView: View {
    @EnvironmentObject private var calibration: CalibrationStore

    var body: some View {
        List {
            if calibration.learning.insights.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }

            Section {
                ForEach(calibration.learning.insights) { insight in
                    insightRow(insight)
                }
            } header: {
                Text(localized: "insights.section.findings")
            } footer: {
                Text(L.t("insights.section.findings.footer", calibration.learning.minSamples))
            }

            if !calibration.learning.combinations.isEmpty {
                Section {
                    ForEach(calibration.learning.combinations) { combination in
                        combinationRow(combination)
                    }
                } header: {
                    Text(localized: "insights.section.combinations")
                }
            }

            if let accuracy = calibration.learning.durationAccuracy, !accuracy.isEmpty {
                Section {
                    ForEach(accuracy.sorted(by: { $0.key < $1.key }), id: \.key) { material, ratio in
                        LabeledContent(material) {
                            Text(L.t("insights.duration.ratio", Int((ratio - 1) * 100)))
                                .foregroundStyle(ratio > 1.15 ? Theme.paused : .secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text(localized: "insights.section.duration")
                } footer: {
                    Text(localized: "insights.section.duration.footer")
                }
            }
        }
        .navigationTitle(L.t("insights.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await calibration.loadLearning() }
        .refreshable { await calibration.loadLearning() }
    }

    private func insightRow(_ insight: LearnedInsight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(insight.titleAR, systemImage: insight.isWarning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(insight.isWarning ? Theme.paused : Theme.accent)

            Text(insight.detailAR)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            if !insight.suggestionAR.isEmpty {
                Text(insight.suggestionAR)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func combinationRow(_ combination: LearnedCombination) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(combination.labelAR)
                    .font(.subheadline)
                Spacer()
                // No percentage below the minimum. The backend returns nil and
                // the UI must not invent one - a rate from two prints reads as
                // authoritative and is not.
                if let rate = combination.successRate {
                    Text("\(Int(rate * 100))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(rate >= 0.9 ? Theme.printing
                                         : rate >= 0.7 ? Theme.paused : Theme.danger)
                        .monospacedDigit()
                } else {
                    Text(localized: "insights.not_enough")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 10) {
                Text(L.t("insights.counts", combination.succeeded, combination.total))
                if combination.earlyFailures > 0 {
                    Text(L.t("insights.early", combination.earlyFailures))
                        .foregroundStyle(Theme.paused)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
