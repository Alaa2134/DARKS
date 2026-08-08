import SwiftUI
import UIKit

// MARK: - Section header

struct SectionHeader: View {
    let titleKey: String
    var systemImage: String?
    var trailing: AnyView?

    init(_ titleKey: String, systemImage: String? = nil, trailing: AnyView? = nil) {
        self.titleKey = titleKey
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.accent)
            }
            Text(localized: titleKey)
                .font(.headline)
            Spacer(minLength: 0)
            trailing
        }
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let titleKey: String
    let value: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(tint)
                }
                Text(localized: titleKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Key/value row

struct InfoRow: View {
    let titleKey: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack {
            Text(localized: titleKey)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let text: String
    let color: Color
    var systemImage: String?
    var pulsing = false

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .opacity(pulsing && isPulsing ? 0.35 : 1)
                    .animation(
                        pulsing ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default,
                        value: isPulsing
                    )
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.16), in: Capsule())
        .foregroundStyle(color)
        .onAppear { if pulsing { isPulsing = true } }
    }
}

// MARK: - Big action button

struct BigActionButton: View {
    let titleKey: String
    let systemImage: String
    var tint: Color = Theme.accent
    var isDestructive = false
    var isEnabled = true
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title2)
                    }
                }
                .frame(height: 26)

                Text(localized: titleKey)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    .fill((isDestructive ? Theme.danger : tint).opacity(isEnabled ? 0.15 : 0.06))
            }
            .foregroundStyle(isEnabled ? (isDestructive ? Theme.danger : tint) : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
    }
}

// MARK: - Emergency stop

struct EmergencyStopButton: View {
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Button {
            Haptics.warning()
            isConfirming = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized: "action.emergency_stop")
                        .font(.headline)
                    Text(localized: "action.emergency_stop.subtitle")
                        .font(.caption2)
                        .opacity(0.85)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.danger)
            }
            .foregroundStyle(.white)
            .shadow(color: Theme.danger.opacity(0.35), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            L.t("action.emergency_stop.confirm"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L.t("action.emergency_stop"), role: .destructive, action: action)
            Button(L.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(localized: "action.emergency_stop.message")
        }
    }
}

// MARK: - Progress ring

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 12
    var tint: Color = Theme.printing
    var label: String?
    var caption: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.65), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)

            VStack(spacing: 2) {
                Text(label ?? Format.percent(progress))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Temperature gauge

struct TemperatureBadge: View {
    let titleKey: String
    let actual: Double
    let target: Double
    let tint: Color
    var systemImage: String

    private var isHeating: Bool { target > 0 && actual < target - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(localized: titleKey)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isHeating {
                    Image(systemName: "flame.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.nozzle)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.temperature(actual))
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ \(Format.temperatureShort(target))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: min(1, max(0, target > 0 ? actual / target : actual / 300)))
                .tint(tint)
        }
    }
}

// MARK: - Error banner

struct ErrorBanner: View {
    let message: String
    var retryTitleKey = "common.retry"
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let onRetry {
                    Button(L.t(retryTitleKey), action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                .fill(Theme.danger.opacity(0.12))
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let titleKey: String
    let messageKey: String
    var systemImage: String = "tray"
    var actionTitleKey: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(localized: titleKey)
                .font(.headline)
            Text(localized: messageKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitleKey, let action {
                Button(L.t(actionTitleKey), action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

// MARK: - Labelled slider

struct LabelledSlider: View {
    let titleKey: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var tint: Color = Theme.accent
    var onCommit: ((Double) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localized: titleKey)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(value))\(unit)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onCommit?(value) }
            }
            .tint(tint)
        }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
