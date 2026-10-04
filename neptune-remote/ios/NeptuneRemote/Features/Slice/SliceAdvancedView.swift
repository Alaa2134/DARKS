import SwiftUI

/// The settings a printer profile normally decides for you.
///
/// Every control here starts at a value that means **"leave the profile
/// alone"**, and only a value you move is sent. That is not a shortcut - it is
/// the difference between tuning one setting and quietly overriding a dozen
/// that were already right. A zero on this screen reads "profile decides", not
/// "none", and it is labelled that way rather than shown as a bare 0.
struct SliceAdvancedView: View {
    @EnvironmentObject private var slicing: SliceStore

    var body: some View {
        Form {
            Section {
                Picker(L.t("slicer.infill_pattern"), selection: $slicing.infillPattern) {
                    Text(localized: "slicer.profile_default").tag("")
                    Text("Grid").tag("grid")
                    Text("Gyroid").tag("gyroid")
                    Text("Honeycomb").tag("honeycomb")
                    Text("Cubic").tag("cubic")
                    Text("Triangles").tag("triangles")
                    Text("Lightning").tag("lightning")
                }
                stepper("slicer.top_layers", value: $slicing.topSolidLayers, range: 0...12)
                stepper("slicer.bottom_layers", value: $slicing.bottomSolidLayers, range: 0...12)
                Toggle(L.t("slicer.ironing"), isOn: $slicing.ironing)
            } header: {
                Text(localized: "slicer.section.shell")
            } footer: {
                Text(localized: "slicer.ironing.hint")
            }

            Section {
                Picker(L.t("slicer.seam"), selection: $slicing.seamPosition) {
                    Text(localized: "slicer.profile_default").tag("")
                    Text(localized: "slicer.seam.aligned").tag("aligned")
                    Text(localized: "slicer.seam.nearest").tag("nearest")
                    Text(localized: "slicer.seam.rear").tag("rear")
                    Text(localized: "slicer.seam.random").tag("random")
                }
                Toggle(L.t("slicer.avoid_crossing"), isOn: $slicing.avoidCrossingPerimeters)
            } header: {
                Text(localized: "slicer.section.surface")
            } footer: {
                Text(localized: "slicer.avoid_crossing.hint")
            }

            Section {
                slider(
                    "slicer.z_hop",
                    value: $slicing.retractionZHop,
                    range: 0...1,
                    step: 0.05,
                    unit: " mm"
                )
            } header: {
                Text(localized: "slicer.section.retraction")
            } footer: {
                Text(localized: "slicer.z_hop.hint")
            }

            Section {
                intSlider("slicer.fan_min", value: $slicing.fanMinPercent, range: 0...100, step: 5)
                intSlider("slicer.fan_max", value: $slicing.fanMaxPercent, range: 0...100, step: 5)
                stepper("slicer.fan_off_layers", value: $slicing.disableFanFirstLayers, range: 0...5)
            } header: {
                Text(localized: "slicer.section.cooling")
            } footer: {
                Text(localized: "slicer.fan_off_layers.hint")
            }

            // Only meaningful when support is actually on, so it is not offered
            // otherwise - a setting with nothing to attach to is noise.
            if slicing.supports {
                Section {
                    slider(
                        "slicer.support_gap",
                        value: $slicing.supportZDistance,
                        range: 0...0.4,
                        step: 0.05,
                        unit: " mm"
                    )
                    stepper(
                        "slicer.support_interface",
                        value: $slicing.supportInterfaceLayers,
                        range: 0...5
                    )
                } header: {
                    Text(localized: "slicer.section.support_detail")
                } footer: {
                    Text(localized: "slicer.support_gap.hint")
                }
            }

            Section {
                Toggle(L.t("slicer.spiral_vase"), isOn: $slicing.spiralVase)
            } header: {
                Text(localized: "slicer.section.vase")
            } footer: {
                Text(localized: "slicer.spiral_vase.hint")
            }

            Section {
                Button(role: .destructive) {
                    reset()
                } label: {
                    Text(localized: "slicer.reset_advanced")
                }
            } footer: {
                Text(localized: "slicer.reset_advanced.hint")
            }
        }
        .navigationTitle(L.t("slicer.advanced.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Controls

    private func stepper(_ key: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(localized: key)
                Spacer()
                Text(value.wrappedValue == 0
                        ? L.t("slicer.profile_default")
                        : "\(value.wrappedValue)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func slider(
        _ key: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localized: key)
                Spacer()
                Text(value.wrappedValue <= 0
                        ? L.t("slicer.profile_default")
                        : String(format: "%.2f%@", value.wrappedValue, unit))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func intSlider(
        _ key: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localized: key)
                Spacer()
                Text(value.wrappedValue == 0
                        ? L.t("slicer.profile_default")
                        : "\(value.wrappedValue)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }

    private func reset() {
        slicing.infillPattern = ""
        slicing.topSolidLayers = 0
        slicing.bottomSolidLayers = 0
        slicing.ironing = false
        slicing.seamPosition = ""
        slicing.spiralVase = false
        slicing.supportZDistance = 0
        slicing.supportInterfaceLayers = 0
        slicing.fanMinPercent = 0
        slicing.fanMaxPercent = 0
        slicing.disableFanFirstLayers = 0
        slicing.avoidCrossingPerimeters = false
        slicing.retractionZHop = 0
        Haptics.success()
    }
}
