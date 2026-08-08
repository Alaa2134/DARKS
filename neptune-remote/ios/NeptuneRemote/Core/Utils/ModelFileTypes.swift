import Foundation
import UniformTypeIdentifiers

/// The file types the app accepts, resolved once.
///
/// iOS declares no system type for STL, OBJ or 3MF. The app declares them in
/// its Info.plist (`UTImportedTypeDeclarations`), and this is where those
/// declarations are turned back into `UTType` values for the document pickers.
///
/// The failure this prevents: asking for `UTType(filenameExtension: "stl")`
/// without a declaration returns a *dynamic* type such as
/// `dyn.ah62d4rv4ge80c8x1gq`. Dynamic types are minted per-process from the
/// extension and never unify with the type the Files app has already assigned
/// to a real document, so the picker shows every .stl greyed out and
/// unselectable.
enum ModelFileTypes {

    /// Declared in Info.plist, in the same order.
    static let stl = UTType("public.standard-tesselated-geometry-format")
    static let threeMF = UTType("org.3mf.3dmanufacturing")
    static let obj = UTType("public.geometry-definition-format")
    static let gcode = UTType("com.neptune.remote.gcode")

    static let modelExtensions = ["stl", "3mf", "obj"]
    static let gcodeExtensions = ["gcode", "gco", "g"]

    /// Types for the model picker: the declared ones first, then any type the
    /// system already knows for these extensions, then `.data` as a catch-all.
    ///
    /// The catch-all matters because some storage providers hand back files
    /// typed only as `public.data`; without it those become unselectable, which
    /// is the same bug in a different disguise.
    static let pickerTypes: [UTType] = types(
        declared: [stl, threeMF, obj], extensions: modelExtensions
    )

    static let gcodePickerTypes: [UTType] = types(
        declared: [gcode], extensions: gcodeExtensions
    )

    /// Everything the app will accept from a picker or the Share sheet.
    static let allPickerTypes: [UTType] = types(
        declared: [stl, threeMF, obj, gcode],
        extensions: modelExtensions + gcodeExtensions
    )

    private static func types(declared: [UTType?], extensions: [String]) -> [UTType] {
        var result: [UTType] = declared.compactMap { $0 }
        for suffix in extensions {
            guard let type = UTType(filenameExtension: suffix) else { continue }
            // A dynamic type is worthless for matching, but harmless to include
            // and occasionally the only thing a provider reports.
            if !result.contains(type) { result.append(type) }
        }
        result.append(.data)
        return result
    }

    /// Whether a filename is one the app can do something with. Used where a
    /// type is unavailable and only the name is known - the Share extension
    /// receiving an opaque item, for instance.
    static func isSupported(filename: String) -> Bool {
        let suffix = (filename as NSString).pathExtension.lowercased()
        return modelExtensions.contains(suffix) || gcodeExtensions.contains(suffix)
    }

    static func isModel(filename: String) -> Bool {
        modelExtensions.contains((filename as NSString).pathExtension.lowercased())
    }
}
