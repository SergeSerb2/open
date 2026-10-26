import Foundation
struct CLIError: Error, CustomStringConvertible { var description: String }
enum RenderCLI {
    static let usage = "features-render split|peek|little --out FILE [--snapshot DIR] [--size WxH] [--scale 1|2]; compare --arc FILE --ours FILE --out DIR --state split|peek; check; bench"
    static func value(_ args: [String], _ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
}
