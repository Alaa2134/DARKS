import SwiftUI
import UniformTypeIdentifiers

/// A document picker whose result actually comes back.
///
/// This replaces SwiftUI's `.fileImporter`, which failed on the library screen
/// in a way that produced no error and no callback at all: the picker opened,
/// the file could be selected, Open did nothing, and the completion handler was
/// never invoked. The app refreshes printer state every few seconds, so the
/// hosting view is re-evaluated constantly, and `.fileImporter` binds its
/// completion to that view - when the view is rebuilt while the picker is on
/// screen, the callback goes with it.
///
/// Here the delegate lives on the Coordinator, which UIKit retains for the
/// lifetime of the picker, so a redraw of the SwiftUI view behind it cannot
/// detach the result.
///
/// `asCopy: true` is deliberate. iOS materialises the document - downloading it
/// from iCloud if it is only a placeholder - and hands back a plain file in the
/// app's own container. That removes security-scoped access, file coordination
/// and iCloud placeholder handling from the caller's problem entirely, at the
/// cost of one temporary copy.
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    var allowsMultipleSelection = true
    let onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        // Keep the coordinator's closures current without replacing the
        // delegate, so a redraw never severs the connection.
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
