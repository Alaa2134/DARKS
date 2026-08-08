import SwiftUI

/// Filament spools with their real colours, and what is left on each.
struct FilamentView: View {
    @EnvironmentObject private var inventory: InventoryStore

    @State private var showingAdd = false
    @State private var adjusting: FilamentSpool?
    @State private var adjustGrams = ""

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = inventory.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        Task { await inventory.reloadFilament() }
                    } onDismiss: {
                        inventory.lastError = nil
                    }
                }

                summary

                if inventory.spools.isEmpty {
                    EmptyStateView(
                        titleKey: "filament.empty",
                        messageKey: "filament.summary",
                        systemImage: "circle.hexagongrid",
                        actionTitleKey: "filament.add"
                    ) {
                        showingAdd = true
                    }
                } else {
                    ForEach(inventory.spools) { spool in
                        spoolCard(spool)
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("filament.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack { AddSpoolView() }
        }
        .alert(L.t("filament.adjust"), isPresented: Binding(
            get: { adjusting != nil },
            set: { if !$0 { adjusting = nil } }
        )) {
            TextField(L.t("filament.initial"), text: $adjustGrams)
                .keyboardType(.decimalPad)
            Button(L.t("common.save")) {
                guard let spool = adjusting, let target = Double(adjustGrams) else { return }
                let delta = spool.remainingGrams - target
                if delta > 0 {
                    Task { await inventory.consume(spool, grams: delta) }
                }
                adjusting = nil
            }
            Button(L.t("common.cancel"), role: .cancel) { adjusting = nil }
        }
        .refreshable { await inventory.reloadFilament() }
        .task { await inventory.reloadFilament() }
    }

    private var summary: some View {
        HStack(spacing: Theme.spacing) {
            StatTile(
                titleKey: "filament.spools",
                value: "\(inventory.filament.spoolCount)",
                systemImage: "circle.hexagongrid"
            )
            StatTile(
                titleKey: "filament.remaining",
                value: Format.grams(inventory.filament.totalRemainingGrams),
                systemImage: "scalemass"
            )
        }
        .card()
    }

    private func spoolCard(_ spool: FilamentSpool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(spool.color)
                    .frame(width: 34, height: 34)
                    .overlay { Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(spool.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(Format.grams(spool.remainingGrams))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if spool.active {
                    StatusPill(text: L.t("filament.active"), color: Theme.printing, systemImage: "checkmark")
                }
            }

            ProgressView(value: spool.percentRemaining)
                .tint(spool.remainingGrams < 100 ? Theme.danger : spool.color)

            HStack(spacing: 12) {
                if !spool.active {
                    Button(L.t("filament.activate")) {
                        Task { await inventory.activate(spool) }
                    }
                    .font(.caption.weight(.medium))
                }
                Button(L.t("filament.adjust")) {
                    adjustGrams = String(Int(spool.remainingGrams.rounded()))
                    adjusting = spool
                }
                .font(.caption.weight(.medium))
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    Task { await inventory.deleteSpool(spool) }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
            .buttonStyle(.plain)
        }
        .card(tint: spool.active ? Theme.printing : .clear)
    }
}

/// New spool form.
struct AddSpoolView: View {
    @EnvironmentObject private var inventory: InventoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var payload = FilamentSpoolPayload()
    @State private var color = Color(red: 0.11, green: 0.11, blue: 0.12)
    @State private var priceText = ""

    private let materials = ["PLA", "PLA+", "PETG", "TPU", "ABS", "ASA", "Nylon"]

    var body: some View {
        Form {
            Section {
                TextField(L.t("filament.brand"), text: $payload.brand)
                Picker(L.t("filament.material"), selection: $payload.material) {
                    ForEach(materials, id: \.self) { Text($0).tag($0) }
                }
                TextField(L.t("filament.color.name"), text: $payload.colorName)
                ColorPicker(L.t("filament.color"), selection: $color, supportsOpacity: false)
            }

            Section {
                HStack {
                    Text(localized: "filament.initial")
                    Spacer()
                    TextField("1000", value: $payload.initialGrams, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                HStack {
                    Text(localized: "filament.price")
                    Spacer()
                    TextField("0", text: $priceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text(payload.currency).foregroundStyle(.secondary)
                }
                Toggle(L.t("filament.activate"), isOn: $payload.active)
            }

            Section {
                TextField(L.t("library.detail.notes"), text: $payload.notes, axis: .vertical)
            }
        }
        .navigationTitle(L.t("filament.add"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.save")) {
                    var body = payload
                    body.colorHex = color.hexString
                    body.price = Double(priceText) ?? 0
                    Task {
                        await inventory.addSpool(body)
                        dismiss()
                    }
                }
                .disabled(payload.initialGrams <= 0)
            }
        }
        .task {
            payload.currency = inventory.costSettings.currency
        }
    }
}
