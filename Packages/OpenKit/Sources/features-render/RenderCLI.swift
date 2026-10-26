import Foundation
struct CLIError: Error, CustomStringConvertible { var description: String }
enum RenderCLI {
    static let usage = """
    features-render split|peek|little --out FILE [--snapshot DIR] [--size WxH] [--scale 1|2]
        render-only: [--width W] [--page-color HOST=RRGGBB ...] [--seed-today-split URL=TITLE] [--keep-titles]
    features-render compare --arc FILE --ours FILE --out DIR --state split|peek; check; bench
    """
    static func value(_ args: [String], _ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
    /// Every value of a repeatable option.
    static func values(_ args: [String], _ key: String) -> [String] {
        args.indices.dropLast().filter { args[$0] == key }.map { args[$0 + 1] }
    }
}
