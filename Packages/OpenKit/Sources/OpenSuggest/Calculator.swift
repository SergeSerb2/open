import Foundation

/// Safe arithmetic evaluator: a small recursive-descent parser over a fixed token set. It never hands
/// input to `NSExpression` or any other dynamic evaluator.
///
/// ```
/// expr    := term (("+" | "-") term)*          // "x + y%" means x + x·y/100
/// term    := unary (("*" | "/" | "%") unary)*  // infix "%" is modulo
/// unary   := ("-" | "+") unary | power         // so -2^2 = -4
/// power   := postfix ("^" unary)?              // right-associative
/// postfix := primary ("%")*                    // "%" before an operator, ")" or the end is percent
/// primary := number | "(" expr ")"
/// ```
/// Operators: `+ - − * × · / ÷ ^ ** %` and parentheses. Numbers: `3`, `3.14`, `.5`, `5.`.
/// Input must contain at least one binary operator, so a lone `42` or `-5` is not a calculation.
public enum Calculator {
    public static let maxInputLength = 256
    static let maxDepth = 64

    public static func evaluate(_ raw: String) -> Double? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= maxInputLength,
              input.contains(where: { $0.isASCII && $0.isNumber }),
              let tokens = tokenize(input) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseExpression(), parser.atEnd, parser.binaryOperators > 0,
              value.isFinite else { return nil }
        return value == 0 ? 0 : value // no "-0"
    }

    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var s = String(format: "%.12g", value)
        if !s.contains("e"), s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    enum Token: Equatable {
        case number(Double)
        case plus, minus, times, divide, power, percent, open, close
    }

    static func tokenize(_ input: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case " ", "\t": break
            case "+": tokens.append(.plus)
            case "-", "\u{2212}": tokens.append(.minus)
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" { tokens.append(.power); i += 1 } else { tokens.append(.times) }
            case "\u{00D7}", "\u{00B7}": tokens.append(.times)
            case "/", "\u{00F7}": tokens.append(.divide)
            case "^": tokens.append(.power)
            case "%": tokens.append(.percent)
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default:
                guard (ch.isASCII && ch.isNumber) || ch == "." else { return nil }
                var j = i
                var text = ""
                var sawDot = false
                while j < chars.count {
                    let c = chars[j]
                    if c.isASCII && c.isNumber { text.append(c) }
                    else if c == "." && !sawDot { sawDot = true; text.append(c) }
                    else { break }
                    j += 1
                }
                guard text != ".", let n = Double(text) else { return nil }
                tokens.append(.number(n))
                i = j
                continue
            }
            i += 1
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var pos = 0
        var depth = 0
        var binaryOperators = 0

        var atEnd: Bool { pos >= tokens.count }
        func peek(_ offset: Int = 0) -> Token? { pos + offset < tokens.count ? tokens[pos + offset] : nil }
        mutating func advance() { pos += 1 }

        mutating func parseExpression() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Calculator.maxDepth, var lhs = parseTerm()?.value else { return nil }
            while let t = peek(), t == .plus || t == .minus {
                advance()
                binaryOperators += 1
                guard let rhs = parseTerm() else { return nil }
                let amount = rhs.isPercent ? lhs * rhs.value : rhs.value
                lhs = t == .plus ? lhs + amount : lhs - amount
            }
            return lhs
        }

        /// `isPercent` is true when the term is one percentage ("10%"), for the "x + y%" rule.
        mutating func parseTerm() -> (value: Double, isPercent: Bool)? {
            let startPos = pos
            guard var lhs = parseUnary() else { return nil }
            var isPercent = pos - startPos >= 2 && tokens[pos - 1] == .percent
            while let t = peek(), t == .times || t == .divide || t == .percent {
                advance()
                binaryOperators += 1
                isPercent = false
                guard let rhs = parseUnary() else { return nil }
                switch t {
                case .times: lhs *= rhs
                case .divide:
                    guard rhs != 0 else { return nil }
                    lhs /= rhs
                default:
                    guard rhs != 0 else { return nil }
                    lhs = lhs.truncatingRemainder(dividingBy: rhs)
                }
            }
            return (lhs, isPercent)
        }

        mutating func parseUnary() -> Double? {
            if peek() == .minus { advance(); return parseUnary().map { -$0 } }
            if peek() == .plus { advance(); return parseUnary() }
            return parsePower()
        }

        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            guard peek() == .power else { return base }
            advance()
            binaryOperators += 1
            guard let exponent = parseUnary() else { return nil }
            let v = pow(base, exponent)
            return v.isFinite ? v : nil
        }

        mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            // "%" followed by a number or "(" is modulo; parseTerm handles it.
            while peek() == .percent {
                switch peek(1) {
                case .number?, .open?: return value
                default:
                    advance()
                    value /= 100
                }
            }
            return value
        }

        mutating func parsePrimary() -> Double? {
            switch peek() {
            case .number(let n)?:
                advance()
                return n
            case .open?:
                advance()
                guard let v = parseExpression(), peek() == .close else { return nil }
                advance()
                return v
            default:
                return nil
            }
        }
    }
}
