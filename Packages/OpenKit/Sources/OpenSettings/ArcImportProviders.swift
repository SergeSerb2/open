import Foundation
import UniformTypeIdentifiers
import OpenModel

/// An extra data type in Import from Arc, supplied by another module (EZ: Easels; later others).
/// The wizard shows one Choose row, one Review line and one Report row per registered provider.
/// Agreed in IMC-questions.md "IMC 03:35" / "EZ 03:25".
@MainActor public protocol ArcImportDataProvider: AnyObject {
    /// Stable key, for example "easels".
    var id: String { get }
    /// Row title, for example "Easels". Also the Report row and the outcome count key.
    var title: String { get }
    var help: String { get }
    /// SF Symbol for the Review list.
    var symbol: String { get }
    /// Empty: the provider reads the Arc folder only. Otherwise the row shows "Choose…".
    /// `.folder` in the list lets the panel pick a folder.
    var fileTypes: [UTType] { get }
    /// Count only; no writes. `file` is the user's pick, if any. nil = nothing found.
    func count(arcDirectory: URL, file: URL?) async -> Int?
    /// Imports into the destination Profile. The result's undo removes exactly what was added; redo adds it again.
    func run(arcDirectory: URL, file: URL?, profileID: ProfileID) async -> ArcImportProviderResult
}

public struct ArcImportProviderResult: Sendable {
    public var imported: Int
    public var duplicates: Int
    /// Short report text, for example "Could not be read". nil = success.
    public var failure: String?
    public var undo: (@MainActor @Sendable () async throws -> Void)?
    public var redo: (@MainActor @Sendable () async throws -> Void)?
    public init(imported: Int = 0, duplicates: Int = 0, failure: String? = nil,
                undo: (@MainActor @Sendable () async throws -> Void)? = nil,
                redo: (@MainActor @Sendable () async throws -> Void)? = nil) {
        self.imported = imported; self.duplicates = duplicates; self.failure = failure; self.undo = undo; self.redo = redo
    }
}

/// The App registers providers once at launch.
@MainActor public enum ArcImportProviders {
    public static var all: [any ArcImportDataProvider] = []
    public static func provider(id: String) -> (any ArcImportDataProvider)? { all.first { $0.id == id } }
}
