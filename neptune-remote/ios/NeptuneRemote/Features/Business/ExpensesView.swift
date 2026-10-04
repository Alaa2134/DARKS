import Charts
import SwiftUI

/// Money that went out, by what it was for.
struct ExpensesView: View {
    @EnvironmentObject private var business: BusinessStore

    @State private var showingNew = false

    private struct CategoryTotal: Identifiable {
        let category: ExpenseCategory
        let amount: Double
        var id: String { category.rawValue }
    }

    private var byCategory: [CategoryTotal] {
        var totals: [ExpenseCategory: Double] = [:]
        for expense in business.expenses { totals[expense.kind, default: 0] += expense.amount }
        return totals
            .map { CategoryTotal(category: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
    }

    var body: some View {
        List {
            Section {
                Picker(L.t("business.period"), selection: $business.period) {
                    ForEach(AccountsPeriod.allCases) { period in
                        Text(localized: period.localizationKey).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !byCategory.isEmpty {
                Section {
                    Chart(byCategory) { entry in
                        BarMark(x: .value("amount", entry.amount),
                                y: .value("category", L.t(entry.category.localizationKey)))
                            .foregroundStyle(entry.category.color.gradient)
                            .cornerRadius(6)
                            .annotation(position: .trailing) {
                                Text(business.money(entry.amount))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(byCategory.count) * 34 + 10)
                    .padding(.vertical, 6)
                } header: {
                    Text(L.t("business.expenses.total", business.money(business.expenses.reduce(0) { $0 + $1.amount })))
                }
            }

            Section {
                if business.expenses.isEmpty {
                    EmptyStateView(titleKey: "business.expenses.empty", messageKey: "business.expenses.empty.hint",
                                   systemImage: "arrow.down.circle", actionTitleKey: "business.expense.new",
                                   action: { showingNew = true })
                        .listRowBackground(Color.clear)
                }
                ForEach(business.expenses) { expense in
                    HStack(spacing: 12) {
                        Image(systemName: expense.kind.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(expense.kind.color, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expense.note.isEmpty ? L.t(expense.kind.localizationKey) : expense.note)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(verbatim: "\(L.t(expense.kind.localizationKey)) · \(Format.relativeDate(expense.spentAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(business.money(expense.amount))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { business.expenses[$0] }
                    Task { for expense in doomed { await business.deleteExpense(expense) } }
                }
            }
        }
        .navigationTitle(L.t("business.expenses.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L.t("business.expense.new"))
            }
        }
        .sheet(isPresented: $showingNew) { NavigationStack { NewExpenseView() } }
        .onChange(of: business.period) { _, _ in Task { await business.reloadAccounts() } }
        .task { await business.load() }
    }
}

struct NewExpenseView: View {
    @EnvironmentObject private var business: BusinessStore
    @Environment(\.dismiss) private var dismiss

    @State private var category: ExpenseCategory = .materials
    @State private var amount: Double = 0
    @State private var note = ""
    @State private var date = Date()

    var body: some View {
        Form {
            Section {
                Picker(L.t("business.expense.category"), selection: $category) {
                    ForEach(ExpenseCategory.allCases) { option in
                        Label(L.t(option.localizationKey), systemImage: option.systemImage).tag(option)
                    }
                }
                MoneyField(titleKey: "business.amount", value: $amount)
                TextField(L.t("business.note"), text: $note)
                DatePicker(L.t("business.expense.date"), selection: $date, in: ...Date(), displayedComponents: .date)
            } footer: {
                if category == .materials {
                    Text(localized: "business.expense.materials.hint")
                }
            }
        }
        .navigationTitle(L.t("business.expense.new"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.save")) {
                    Task {
                        await business.addExpense(ExpensePayload(category: category.rawValue, amount: amount,
                                                                 note: note, spentAt: date.timeIntervalSince1970))
                        dismiss()
                    }
                }
                .disabled(amount <= 0)
            }
        }
    }
}
