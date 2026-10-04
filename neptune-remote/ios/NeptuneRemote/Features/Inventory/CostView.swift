import SwiftUI

/// What a print actually costs, and what to charge for it.
struct CostView: View {
    var prefill: LibraryItem?

    @EnvironmentObject private var inventory: InventoryStore

    @State private var grams: Double = 25
    @State private var hours: Double = 2
    @State private var quantity = 1
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                inputs
                if let breakdown = inventory.lastCost {
                    result(breakdown)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("cost.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { CostSettingsView() }
        }
        .task {
            if let prefill {
                grams = prefill.estimatedFilamentGrams ?? grams
                hours = (prefill.estimatedSeconds ?? hours * 3_600) / 3_600
            }
            await inventory.load()
            await calculate()
        }
    }

    private var inputs: some View {
        VStack(spacing: 14) {
            LabelledSlider(
                titleKey: "filament.material", value: $grams, range: 1...2_000,
                step: 1, unit: " g"
            ) { _ in Task { await calculate() } }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized: "printing.elapsed").font(.subheadline)
                    Spacer()
                    Text(Format.duration(hours * 3_600))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Slider(value: $hours, in: 0.1...80, step: 0.1) { editing in
                    if !editing { Task { await calculate() } }
                }
                .tint(Theme.accent)
            }

            Stepper(value: $quantity, in: 1...500) {
                HStack {
                    Text(localized: "print.setup.copies")
                    Spacer()
                    Text("\(quantity)").monospacedDigit()
                }
                .font(.subheadline)
            }
            .onChange(of: quantity) { _, _ in Task { await calculate() } }
        }
        .card()
    }

    private func result(_ breakdown: CostBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(breakdown.lines) { line in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(localized: line.key)
                            .font(.subheadline)
                        if !line.detail.isEmpty {
                            Text(line.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(Format.money(line.amount, currency: breakdown.currency))
                        .font(.subheadline.monospacedDigit())
                }
            }

            Divider()

            InfoRow(
                titleKey: "cost.per_unit",
                value: Format.money(breakdown.costPerUnit, currency: breakdown.currency)
            )
            InfoRow(
                titleKey: "cost.total",
                value: Format.money(breakdown.totalCost, currency: breakdown.currency)
            )
            InfoRow(
                titleKey: "cost.suggested",
                value: Format.money(breakdown.suggestedPricePerUnit, currency: breakdown.currency),
                tint: Theme.printing
            )
            InfoRow(
                titleKey: "cost.profit_amount",
                value: Format.money(breakdown.profitPerUnit, currency: breakdown.currency),
                tint: Theme.printing
            )
        }
        .card()
    }

    private func calculate() async {
        await inventory.calculateCost(
            CostRequestPayload(
                filamentGrams: grams,
                printSeconds: hours * 3_600,
                quantity: quantity,
                spoolID: inventory.activeSpool?.id
            )
        )
    }
}

/// Editable cost model.
struct CostSettingsView: View {
    @EnvironmentObject private var inventory: InventoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CostSettings.default

    var body: some View {
        Form {
            Section {
                TextField(L.t("cost.currency"), text: $draft.currency)
                numberRow("cost.filament_price", value: $draft.filamentPricePerKg)
                numberRow("cost.electricity", value: $draft.electricityPricePerKwh)
                numberRow("cost.watts", value: $draft.printerWatts)
                numberRow("cost.machine_rate", value: $draft.machineHourlyRate)
            }
            Section {
                numberRow("cost.failure_rate", value: $draft.failureRatePercent, unit: "%")
                numberRow("cost.labour", value: $draft.labourPerPrint)
                numberRow("cost.packaging", value: $draft.packagingPerPrint)
                numberRow("cost.other", value: $draft.otherPerPrint)
            }
            Section {
                numberRow("cost.profit", value: $draft.profitPercent, unit: "%")
                numberRow("cost.rounding", value: $draft.roundSellingPriceTo)
            }
        }
        .navigationTitle(L.t("cost.settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.save")) {
                    Task {
                        await inventory.saveCostSettings(draft)
                        dismiss()
                    }
                }
            }
        }
        .task { draft = inventory.costSettings }
    }

    private func numberRow(_ titleKey: String, value: Binding<Double>, unit: String = "") -> some View {
        HStack {
            Text(localized: titleKey)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            if !unit.isEmpty {
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
