import Foundation
struct CLIError: Error, CustomStringConvertible { var description: String }
enum RenderCLI {
    static let usage = """
    features-render split|peek|little|switcher --out FILE [--snapshot DIR] [--size WxH] [--scale 1|2]
        render-only: [--width W] [--page-color HOST=RRGGBB ...] [--seed-today-split URL=TITLE] [--keep-titles]
    features-render pip --out FILE [--size 384x216] [--scale 1|2] [--state playing|paused|ended]
        [--controls visible|hidden] [--meeting] [--site twitch|meet|youtube|none] [--drag-precision N]
        [--menu] [--document --top-bar-title TEXT] [--document-hover-options] [--document-pressed-options]
          [--screen WIDTHxHEIGHT [--screen-frame WIDTHxHEIGHT] --natural-size WIDTHxHEIGHT --first-open --geometry-report FILE.json] [--hover-skip-ahead]
    features-render compare --arc FILE --ours FILE --out DIR --state split|peek; check [--only auto-archive]; bench
    """
    static func value(_ args: [String], _ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
    /// Every value of a repeatable option.
    static func values(_ args: [String], _ key: String) -> [String] {
        args.indices.dropLast().filter { args[$0] == key }.map { args[$0 + 1] }
    }
}
