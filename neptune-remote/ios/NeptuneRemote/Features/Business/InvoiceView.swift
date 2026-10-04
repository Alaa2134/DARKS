import SwiftUI
import UIKit

/// An order as an invoice the customer can be sent - a picture for WhatsApp,
/// and the same thing as plain text for anything that will not take one.
struct InvoiceView: View {
    let order: Order

    @EnvironmentObject private var business: BusinessStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction

    @State private var rendered: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                InvoiceCard(order: order, shopName: shopName, currency: business.currency)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

                if let rendered {
                    ShareLink(
                        item: Image(uiImage: rendered),
                        preview: SharePreview(L.t("business.invoice.title", order.number), image: Image(uiImage: rendered))
                    ) {
                        Label(L.t("business.invoice.share.image"), systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.tideDeep)
                    .controlSize(.large)
                }
                ShareLink(item: plainText) {
                    Label(L.t("business.invoice.share.text"), systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("business.invoice.title", order.number))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.done")) { dismiss() }
            }
        }
        .task { render() }
    }

    private var shopName: String {
        settings.printerName.isEmpty ? "Neptune Remote" : settings.printerName
    }

    @MainActor
    private func render() {
        let renderer = ImageRenderer(
            content: InvoiceCard(order: order, shopName: shopName, currency: business.currency)
                .frame(width: 390)
                .environment(\.layoutDirection, direction)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 3
        rendered = renderer.uiImage
    }

    /// The invoice as text, line by line, for a chat that strips images.
    private var plainText: String {
        var lines = [
            "\(shopName) — \(L.t("business.invoice.title", order.number))",
            "\(L.t("business.customer")): \(order.displayCustomer)",
            Format.date(order.createdAt),
            "",
        ]
        for item in order.items {
            lines.append("• \(item.name) × \(item.quantity) = \(business.money(item.lineTotal))")
        }
        lines.append("")
        if order.discount > 0 { lines.append("\(L.t("business.discount")): − \(business.money(order.discount))") }
        if order.shipping > 0 { lines.append("\(L.t("business.shipping")): \(business.money(order.shipping))") }
        lines.append("\(L.t("business.total")): \(business.money(order.total))")
        lines.append("\(L.t("business.paid")): \(business.money(order.paid))")
        if order.balance > 0.005 {
            lines.append("\(L.t("business.balance")): \(business.money(order.balance))")
        }
        return lines.joined(separator: "\n")
    }
}

/// The invoice itself. Light, printable, branded - the one thing in the app
/// a customer sees.
struct InvoiceCard: View {
    let order: Order
    let shopName: String
    let currency: String

    private func money(_ value: Double) -> String { Format.money(value, currency: currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header band: the brand's deep water, the shop's name.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "printer.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.tide)
                    Text(shopName)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(order.title)
                        .font(.title3.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Theme.emberWarm)
                }
                Text(L.t("business.invoice.heading"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(20)
            .background(Theme.abyss)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized: "business.invoice.to")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(order.displayCustomer)
                            .font(.subheadline.weight(.bold))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(localized: "business.invoice.date")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Format.date(order.createdAt))
                            .font(.caption.weight(.medium))
                    }
                }

                VStack(spacing: 8) {
                    ForEach(order.items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.subheadline.weight(.medium))
                                Text(verbatim: "\(item.quantity) × \(money(item.unitPrice))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(item.lineTotal))
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 6) {
                    if order.discount > 0 { row("business.discount", "− " + money(order.discount)) }
                    if order.shipping > 0 { row("business.shipping", money(order.shipping)) }
                    row("business.total", money(order.total), bold: true)
                    row("business.paid", money(order.paid))
                    if order.balance > 0.005 {
                        row("business.balance", money(order.balance), tint: Theme.emberHot, bold: true)
                    } else {
                        HStack {
                            Spacer()
                            Label(L.t("business.paid.full"), systemImage: "checkmark.seal.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Theme.printing)
                        }
                    }
                }

                Text(localized: "business.invoice.thanks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
            .padding(20)
            .background(Color.white)
        }
        .foregroundStyle(Color(rgb: 0x0B1B2B))
        .environment(\.colorScheme, .light)
    }

    private func row(_ key: String, _ value: String, tint: Color? = nil, bold: Bool = false) -> some View {
        HStack {
            Text(localized: key)
                .font(bold ? .subheadline.weight(.bold) : .subheadline)
            Spacer()
            Text(value)
                .font((bold ? Font.subheadline.weight(.heavy) : .subheadline).monospacedDigit())
                .foregroundStyle(tint ?? Color(rgb: 0x0B1B2B))
        }
    }
}
