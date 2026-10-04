import SwiftUI

/// An order's state, as the same chip everywhere it appears.
struct OrderStatusChip: View {
    let status: OrderStatus

    var body: some View {
        Label(L.t(status.localizationKey), systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.14), in: Capsule())
    }
}

/// A thin progress bar, tide-coloured, for "12 of 20 made".
struct MadeBar: View {
    let progress: Double
    var tint: Color = Theme.tide

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, proxy.size.width * CGFloat(min(max(progress, 0), 1))))
            }
        }
        .frame(height: 6)
        .environment(\.layoutDirection, .leftToRight)
        .flipsForRightToLeftLayoutDirection(true)
    }
}

/// One order in a list: who, what state, how much, how far along.
struct OrderRow: View {
    let order: Order
    let currency: String

    private func money(_ value: Double) -> String { Format.money(value, currency: currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(order.title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.tideDeep)
                    .monospacedDigit()
                Text(order.displayCustomer)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                OrderStatusChip(status: order.status)
            }
            HStack(spacing: 10) {
                Text(money(order.total))
                    .font(.headline)
                    .monospacedDigit()
                if order.balance > 0.005 {
                    Text(L.t("business.balance.short", money(order.balance)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.emberHot)
                } else if order.isPaid {
                    Label(L.t("business.paid.full"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.printing)
                }
                Spacer(minLength: 0)
                if let due = order.dueDate, order.status.isOpen {
                    Label(Format.relativeDate(due), systemImage: order.overdue ? "exclamationmark.triangle.fill" : "calendar")
                        .font(.caption)
                        .foregroundStyle(order.overdue ? Theme.danger : .secondary)
                }
            }
            if order.status.isOpen, order.units > 0 {
                HStack(spacing: 8) {
                    MadeBar(progress: order.progress)
                    Text(verbatim: "\(order.printed)/\(order.units)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small figure with its label, for the hero cards.
struct HeroFigure: View {
    let titleKey: String
    let value: String
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized: titleKey)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A square shortcut on the factory screen.
struct BusinessShortcut: View {
    let titleKey: String
    let systemImage: String
    var tint: Color = Theme.tideDeep

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .shadow(color: tint.opacity(0.35), radius: 8, y: 4)
            Text(localized: titleKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .card(padding: 0)
    }
}

/// A money field that edits a Double and shows nothing for zero.
struct MoneyField: View {
    let titleKey: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(localized: titleKey)
            Spacer()
            TextField("0", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 140)
        }
    }
}

/// Typed amounts, whichever digits the keyboard produced.
///
/// An Arabic keyboard types ٣٤٫٥ - perfectly good money that `Double(_:)`
/// reads as nothing at all.
enum Amount {
    static func parse(_ text: String) -> Double? {
        var ascii = ""
        for character in text {
            switch character {
            case "٠"..."٩":
                ascii.append(String(character.unicodeScalars.first!.value - 0x0660))
            case "۰"..."۹":
                ascii.append(String(character.unicodeScalars.first!.value - 0x06F0))
            case "٫", ",":
                ascii.append(".")
            case "0"..."9", ".":
                ascii.append(character)
            default:
                continue
            }
        }
        guard !ascii.isEmpty, let value = Double(ascii), value.isFinite else { return nil }
        return value
    }

    static func text(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}
