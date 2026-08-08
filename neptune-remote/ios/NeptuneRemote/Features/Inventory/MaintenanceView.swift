import SwiftUI

/// Maintenance reminders driven by real print hours, print counts and dates.
struct MaintenanceView: View {
    @EnvironmentObject private var inventory: InventoryStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                totals

                if inventory.maintenance.tasks.isEmpty {
                    EmptyStateView(
                        titleKey: "maintenance.empty",
                        messageKey: "maintenance.title",
                        systemImage: "wrench.and.screwdriver"
                    )
                } else {
                    if !inventory.dueMaintenance.isEmpty {
                        SectionHeader("maintenance.due", systemImage: "exclamationmark.triangle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(inventory.dueMaintenance) { task in
                            taskCard(task)
                        }
                    }

                    let upcoming = inventory.maintenance.tasks.filter { !$0.due }
                    if !upcoming.isEmpty {
                        SectionHeader("maintenance.upcoming", systemImage: "clock")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        ForEach(upcoming) { task in
                            taskCard(task)
                        }
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("maintenance.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await inventory.loadMaintenance() }
        .task { await inventory.loadMaintenance() }
    }

    private var totals: some View {
        HStack(spacing: Theme.spacing) {
            StatTile(
                titleKey: "home.stats.prints",
                value: "\(inventory.maintenance.totalPrints)",
                systemImage: "printer"
            )
            StatTile(
                titleKey: "home.stats.hours",
                value: String(format: "%.0f", inventory.maintenance.totalPrintHours),
                systemImage: "clock"
            )
            StatTile(
                titleKey: "home.stats.filament",
                value: Format.grams(inventory.maintenance.totalFilamentGrams),
                systemImage: "scalemass"
            )
        }
        .card()
    }

    private func taskCard(_ task: MaintenanceTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: task.icon.isEmpty ? "wrench.and.screwdriver" : task.icon)
                    .foregroundStyle(task.due ? Theme.paused : Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(remainingText(task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if task.due {
                    StatusPill(text: L.t("maintenance.due"), color: Theme.paused, systemImage: "exclamationmark")
                }
            }

            ProgressView(value: min(1, max(0, task.progress)))
                .tint(task.due ? Theme.paused : Theme.accent)

            HStack {
                if let last = task.lastDoneAt {
                    Text(Format.relativeDate(last))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(L.t("maintenance.mark_done")) {
                    Task { await inventory.completeMaintenance(task) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .card(tint: task.due ? Theme.paused : .clear)
    }

    private func remainingText(_ task: MaintenanceTask) -> String {
        if task.due { return L.t("maintenance.due") }
        if let hours = task.remainingHours {
            return L.t("maintenance.remaining.hours", String(format: "%.0f", hours))
        }
        if let prints = task.remainingPrints {
            return L.t("maintenance.remaining.prints", prints)
        }
        if let days = task.remainingDays {
            return L.t("maintenance.remaining.days", days)
        }
        return ""
    }
}

/// Products made from library models, with margins.
struct ProductsView: View {
    @EnvironmentObject private var inventory: InventoryStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if inventory.products.isEmpty {
                    EmptyStateView(
                        titleKey: "products.empty",
                        messageKey: "products.title",
                        systemImage: "tag"
                    )
                } else {
                    ForEach(inventory.products) { product in
                        productCard(product)
                    }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("products.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await inventory.loadProducts() }
        .task { await inventory.loadProducts() }
    }

    private func productCard(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(.subheadline.weight(.medium))
                    if !product.sku.isEmpty {
                        Text(product.sku)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(product.colors, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex) ?? Theme.idle)
                            .frame(width: 14, height: 14)
                    }
                }
            }

            InfoRow(
                titleKey: "products.print_cost",
                value: Format.money(product.printCost, currency: product.currency)
            )
            InfoRow(
                titleKey: "products.selling_price",
                value: Format.money(product.sellingPrice, currency: product.currency)
            )
            InfoRow(
                titleKey: "products.margin",
                value: Format.money(product.margin, currency: product.currency),
                tint: product.margin > 0 ? Theme.printing : Theme.danger
            )

            if product.madeToOrder {
                StatusPill(text: L.t("products.made_to_order"), color: Theme.accent, systemImage: "hammer")
            } else {
                StatusPill(text: L.t("products.stock") + ": \(product.stock)", color: Theme.idle, systemImage: "shippingbox")
            }
        }
        .card()
    }
}
