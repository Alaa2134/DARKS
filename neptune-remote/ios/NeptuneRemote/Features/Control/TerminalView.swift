import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var command = ""
    @State private var showingHistory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            shortcutStrip
            consoleList
            inputBar
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("terminal.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingHistory = true
                    } label: {
                        Label(L.t("terminal.history"), systemImage: "clock")
                    }
                    Button(role: .destructive) {
                        printer.clearConsole()
                    } label: {
                        Label(L.t("terminal.clear"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            CommandHistorySheet { selected in
                command = selected
                showingHistory = false
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(settings.gcodeFavourites) { shortcut in
                    shortcutChip(shortcut.command, isFavourite: true)
                }
                // Only the ones this machine actually has. QUAD_GANTRY_LEVEL
                // does not exist on a bed-slinger and SCREWS_TILT_CALCULATE
                // does not exist without [screws_tilt_adjust]; both answered
                // "Unknown command" from a button that looked like every other
                // button on the strip.
                ForEach(GCodeShortcut.predefined) { shortcut in
                    if !settings.isFavourite(shortcut.command), supported(shortcut) {
                        shortcutChip(shortcut.command, isFavourite: false)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// A command with no required object is always offered; one with a
    /// requirement is offered only once the printer has reported it.
    ///
    /// Unknown capabilities mean "show it": before discovery finishes the
    /// object list is empty, and hiding the whole strip until then would be a
    /// worse lie than showing one button that might not apply.
    private func supported(_ shortcut: GCodeShortcut) -> Bool {
        guard let required = shortcut.requiredObject else { return true }
        guard !printer.capabilities.objects.isEmpty else { return true }
        return printer.capabilities.has(required)
    }

    private func shortcutChip(_ text: String, isFavourite: Bool) -> some View {
        Button {
            Task { await printer.send(gcode: text) }
            Haptics.selection()
        } label: {
            HStack(spacing: 4) {
                if isFavourite {
                    Image(systemName: "star.fill").font(.system(size: 9))
                }
                Text(text)
                    .font(.caption.monospaced())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                settings.toggleFavourite(text)
            } label: {
                Label(
                    L.t(isFavourite ? "terminal.unfavourite" : "terminal.favourite"),
                    systemImage: isFavourite ? "star.slash" : "star"
                )
            }
            Button {
                command = text
            } label: {
                Label(L.t("terminal.edit"), systemImage: "pencil")
            }
        }
    }

    // MARK: - Console

    private var consoleList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if printer.console.isEmpty {
                        Text(localized: "terminal.empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(printer.console) { line in
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Theme.cardFill)
            .onChange(of: printer.console.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func color(for kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .command: return Theme.accent
        case .response: return .primary
        case .error: return Theme.danger
        case .info: return .secondary
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(L.t("terminal.placeholder"), text: $command)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(sendCommand)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: sendCommand) {
                Image(systemName: "paperplane.fill")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent, in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sendCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        command = ""
        Task { await printer.send(gcode: text) }
    }
}

// MARK: - History sheet

struct CommandHistorySheet: View {
    let onSelect: (String) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if settings.gcodeHistory.isEmpty {
                    Text(localized: "terminal.history.empty")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.gcodeHistory, id: \.self) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        HStack {
                            Text(command)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                settings.toggleFavourite(command)
                            } label: {
                                Image(systemName: settings.isFavourite(command) ? "star.fill" : "star")
                                    .foregroundStyle(Theme.paused)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(L.t("terminal.history"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(L.t("terminal.clear")) { settings.gcodeHistory = [] }
                }
            }
        }
    }
}
