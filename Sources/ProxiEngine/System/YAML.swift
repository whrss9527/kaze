import Foundation

/// YAML 里的一个值：空、标量、列表或映射（映射保留键的顺序）。
/// 只实现代理配置里用得到的部分：块状和流式的映射与列表、各种引号、块标量（| 和 >）、锚点、别名和合并键（<<）。
indirect enum YAMLNode: Equatable {
    case null
    /// 标量；quoted 表示原文加了引号（"123" 是字符串，写回时照样加引号）。
    case scalar(String, quoted: Bool)
    case sequence([YAMLNode])
    case mapping([YAMLPair])

    /// 字符串标量（写回时加引号）。
    static func string(_ text: String) -> YAMLNode { .scalar(text, quoted: true) }

    /// 数字、布尔这类不加引号的标量。
    static func plain(_ text: String) -> YAMLNode { .scalar(text, quoted: false) }

    static func int(_ value: Int) -> YAMLNode { .scalar(String(value), quoted: false) }

    static func bool(_ value: Bool) -> YAMLNode { .scalar(value ? "true" : "false", quoted: false) }

    static func strings(_ values: [String]) -> YAMLNode { .sequence(values.map { .string($0) }) }

    var string: String? {
        if case .scalar(let text, _) = self { return text }
        return nil
    }

    var int: Int? {
        guard let text = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Int(text)
    }

    var bool: Bool? {
        guard let text = string?.lowercased() else { return nil }
        switch text {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }

    var array: [YAMLNode]? {
        if case .sequence(let items) = self { return items }
        return nil
    }

    var pairs: [YAMLPair]? {
        if case .mapping(let pairs) = self { return pairs }
        return nil
    }

    var isNull: Bool { self == .null }

    /// 映射里的值；不是映射或没有这个键时是 nil。
    subscript(key: String) -> YAMLNode? {
        pairs?.last { $0.key == key }?.value
    }

    var keys: [String] { pairs?.map(\.key) ?? [] }

    /// 字符串列表；单个标量也当成只有一项的列表。
    var stringArray: [String]? {
        switch self {
        case .sequence(let items): return items.compactMap(\.string)
        case .scalar(let text, _): return [text]
        default: return nil
        }
    }

    /// 在映射里设置一个键（有就替换，没有就加在最后）。
    mutating func set(_ key: String, _ value: YAMLNode) {
        guard case .mapping(var pairs) = self else { return }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index].value = value
        } else {
            pairs.append(YAMLPair(key: key, value: value))
        }
        self = .mapping(pairs)
    }

    /// 从映射里去掉一个键。
    mutating func remove(_ key: String) {
        guard case .mapping(let pairs) = self else { return }
        self = .mapping(pairs.filter { $0.key != key })
    }
}

struct YAMLPair: Equatable {
    var key: String
    var value: YAMLNode
}

struct YAMLError: LocalizedError, Equatable {
    var line: Int
    var message: String

    var errorDescription: String? { line > 0 ? L("第 %@ 行：%@", line, message) : message }
}

// MARK: - 解析

enum YAMLParser {
    /// 解析第一个文档。空文档是 .null。
    static func parse(_ text: String) throws -> YAMLNode {
        let parser = Parser(text)
        return try parser.parseDocument()
    }

    private struct Line {
        var number: Int
        var indent: Int
        var content: String
    }

    private final class Parser {
        private var raw: [String] = []
        private var index = 0
        private var override: Line?
        private var anchors: [String: YAMLNode] = [:]

        init(_ text: String) {
            var body = text
            if body.hasPrefix("\u{FEFF}") {
                body.removeFirst()
            }
            var lines: [String] = []
            var started = false
            for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = String(rawLine)
                if line.hasSuffix("\r") {
                    line.removeLast()
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !started {
                    if trimmed.hasPrefix("%") { lines.append(""); continue }
                    if trimmed == "---" || trimmed.hasPrefix("--- ") {
                        started = true
                        let rest = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        lines.append(rest)
                        continue
                    }
                    if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                        started = true
                    }
                } else if line.hasPrefix("---") || line == "..." {
                    // 只取第一个文档。
                    break
                }
                lines.append(line)
            }
            raw = lines
        }

        func parseDocument() throws -> YAMLNode {
            guard let first = try peek() else { return .null }
            let node = try parseNode(indent: first.indent)
            if let extra = try peek() {
                throw YAMLError(line: extra.number, message: L("缩进不对，或者多了内容"))
            }
            return node
        }

        // MARK: 行

        /// 下一行有内容的行（跳过空行和整行注释）。
        private func peek() throws -> Line? {
            if let override { return override }
            while index < raw.count {
                let line = raw[index]
                var indent = 0
                for character in line {
                    if character == " " {
                        indent += 1
                    } else if character == "\t" {
                        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
                        if rest.isEmpty || rest.hasPrefix("#") { break }
                        throw YAMLError(line: index + 1, message: L("缩进里不能用 Tab，请换成空格"))
                    } else {
                        break
                    }
                }
                let content = Parser.stripComment(String(line.dropFirst(indent)))
                if content.isEmpty {
                    index += 1
                    continue
                }
                return Line(number: index + 1, indent: indent, content: content)
            }
            return nil
        }

        private func consume() {
            if override != nil {
                override = nil
            } else {
                index += 1
            }
        }

        /// 把当前行换成它的一部分（「- 键: 值」里 - 后面的内容），原来那一行算读过了。
        private func replaceCurrent(with line: Line) {
            if override == nil {
                index += 1
            }
            override = line
        }

        /// 去掉行尾注释：不在引号里、前面是空白（或者在行首）的 # 开始的部分。
        static func stripComment(_ text: String) -> String {
            var result = ""
            var quote: Character?
            var atScalarStart = true
            var previous: Character = " "
            let iterator = Array(text)
            var position = 0
            while position < iterator.count {
                let character = iterator[position]
                if let open = quote {
                    result.append(character)
                    if open == "\"" && character == "\\" && position + 1 < iterator.count {
                        result.append(iterator[position + 1])
                        position += 2
                        continue
                    }
                    if character == open {
                        if open == "'" && position + 1 < iterator.count && iterator[position + 1] == "'" {
                            result.append("'")
                            position += 2
                            continue
                        }
                        quote = nil
                    }
                    previous = character
                    position += 1
                    continue
                }
                if character == "#" && (previous == " " || previous == "\t" || result.isEmpty) {
                    break
                }
                if (character == "\"" || character == "'") && atScalarStart {
                    quote = character
                    result.append(character)
                    previous = character
                    position += 1
                    atScalarStart = false
                    continue
                }
                if character == " " || character == "\t" {
                    // 空白不改变「是不是在值的开头」。
                } else if character == "[" || character == "{" || character == "," {
                    atScalarStart = true
                } else if (character == "-" || character == ":" || character == "?") && (position + 1 == iterator.count || iterator[position + 1] == " ") {
                    atScalarStart = true
                } else {
                    atScalarStart = false
                }
                result.append(character)
                previous = character
                position += 1
            }
            while let last = result.last, last == " " || last == "\t" {
                result.removeLast()
            }
            return result
        }

        private static func isSequenceItem(_ content: String) -> Bool {
            content == "-" || content.hasPrefix("- ")
        }

        /// 「键: 值」拆开；不是这种行返回 nil。
        static func splitKey(_ content: String) -> (key: String, rest: String)? {
            guard let first = content.first, first != "[", first != "{", !isSequenceItem(content) else { return nil }
            let characters = Array(content)
            var position = 0
            var key: String
            if first == "\"" || first == "'" {
                guard let quoted = try? readQuoted(characters, from: 0) else { return nil }
                key = quoted.0
                position = quoted.1
                while position < characters.count && characters[position] == " " { position += 1 }
                guard position < characters.count, characters[position] == ":" else { return nil }
                guard position + 1 == characters.count || characters[position + 1] == " " else { return nil }
                return (key, String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces))
            }
            while position < characters.count {
                if characters[position] == ":" && (position + 1 == characters.count || characters[position + 1] == " ") {
                    key = String(characters[..<position]).trimmingCharacters(in: .whitespaces)
                    if key.isEmpty { return nil }
                    return (key, String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces))
                }
                position += 1
            }
            return nil
        }

        // MARK: 块

        private func parseNode(indent: Int) throws -> YAMLNode {
            guard let line = try peek() else { return .null }
            if Parser.isSequenceItem(line.content) {
                return try parseSequence(indent: line.indent)
            }
            if Parser.splitKey(line.content) != nil {
                return try parseMapping(indent: line.indent)
            }
            consume()
            return try inlineValue(line.content, line: line)
        }

        private func parseMapping(indent: Int) throws -> YAMLNode {
            var pairs: [YAMLPair] = []
            var merged: [YAMLPair] = []
            while let line = try peek(), line.indent == indent {
                if Parser.isSequenceItem(line.content) { break }
                guard let split = Parser.splitKey(line.content) else {
                    throw YAMLError(line: line.number, message: L("这里应该是「键: 值」"))
                }
                let key = split.key
                consume()
                var text = split.rest
                var anchor: String?
                (text, anchor) = Parser.takeProperties(text)
                let value: YAMLNode
                if text.isEmpty {
                    if let next = try peek() {
                        if next.indent > indent {
                            value = try parseNode(indent: next.indent)
                        } else if next.indent == indent && Parser.isSequenceItem(next.content) {
                            value = try parseSequence(indent: indent)
                        } else {
                            value = .null
                        }
                    } else {
                        value = .null
                    }
                } else if text.hasPrefix("|") || text.hasPrefix(">") {
                    value = try blockScalar(header: text, parentIndent: indent, line: line)
                } else {
                    value = try inlineValue(text, line: line)
                }
                if let anchor {
                    anchors[anchor] = value
                }
                if key == "<<" {
                    switch value {
                    case .mapping(let items):
                        merged += items
                    case .sequence(let items):
                        for case .mapping(let items) in items {
                            merged += items
                        }
                    default:
                        throw YAMLError(line: line.number, message: L("<< 后面要是映射或别名"))
                    }
                    continue
                }
                if let existing = pairs.firstIndex(where: { $0.key == key }) {
                    pairs[existing].value = value
                } else {
                    pairs.append(YAMLPair(key: key, value: value))
                }
            }
            // 合并键：自己写了的键优先，先合并进来的优先。
            for pair in merged where !pairs.contains(where: { $0.key == pair.key }) {
                pairs.append(pair)
            }
            return .mapping(pairs)
        }

        private func parseSequence(indent: Int) throws -> YAMLNode {
            var items: [YAMLNode] = []
            while let line = try peek(), line.indent == indent, Parser.isSequenceItem(line.content) {
                let afterDash = String(line.content.dropFirst())
                let itemText = afterDash.trimmingCharacters(in: .whitespaces)
                var text = itemText
                var anchor: String?
                (text, anchor) = Parser.takeProperties(text)
                let node: YAMLNode
                if text.isEmpty {
                    consume()
                    if let next = try peek(), next.indent > indent {
                        node = try parseNode(indent: next.indent)
                    } else {
                        node = .null
                    }
                } else if Parser.isSequenceItem(text) || (Parser.splitKey(text) != nil) {
                    // 「- 键: 值」：同一项里的后续键和这个键对齐。
                    let column = indent + (line.content.count - text.count)
                    replaceCurrent(with: Line(number: line.number, indent: column, content: text))
                    node = try parseNode(indent: column)
                } else if text.hasPrefix("|") || text.hasPrefix(">") {
                    consume()
                    node = try blockScalar(header: text, parentIndent: indent, line: line)
                } else {
                    consume()
                    node = try inlineValue(text, line: line)
                }
                if let anchor {
                    anchors[anchor] = node
                }
                items.append(node)
            }
            return .sequence(items)
        }

        /// 值前面的锚点（&名字）和标签（!!str 之类，忽略）。
        static func takeProperties(_ text: String) -> (String, String?) {
            var rest = text
            var anchor: String?
            for _ in 0..<2 {
                if rest.hasPrefix("&") {
                    let name = rest.dropFirst().prefix { !$0.isWhitespace }
                    anchor = String(name)
                    rest = String(rest.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                } else if rest.hasPrefix("!") {
                    let tag = rest.prefix { !$0.isWhitespace }
                    rest = String(rest.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            return (rest, anchor)
        }

        /// | 和 > 开头的多行文字。
        private func blockScalar(header: String, parentIndent: Int, line: Line) throws -> YAMLNode {
            let folded = header.hasPrefix(">")
            var chomp: Character = " "
            var explicitIndent: Int?
            for character in header.dropFirst() {
                if character == "-" || character == "+" {
                    chomp = character
                } else if let digit = character.wholeNumberValue {
                    explicitIndent = digit
                } else if character == " " {
                    break
                }
            }
            var collected: [String] = []
            var blockIndent: Int? = explicitIndent.map { parentIndent + $0 }
            while index < raw.count {
                let text = raw[index]
                let indent = text.prefix { $0 == " " }.count
                let blank = text.trimmingCharacters(in: .whitespaces).isEmpty
                if blank {
                    collected.append("")
                    index += 1
                    continue
                }
                if blockIndent == nil {
                    guard indent > parentIndent else { break }
                    blockIndent = indent
                }
                guard let required = blockIndent, indent >= required else { break }
                collected.append(String(text.dropFirst(required)))
                index += 1
            }
            // 末尾的空行按保留方式处理。
            var trailing = 0
            while let last = collected.last, last.isEmpty {
                collected.removeLast()
                trailing += 1
            }
            var body: String
            if folded {
                body = ""
                for (offset, item) in collected.enumerated() {
                    if offset > 0 {
                        body += item.isEmpty || collected[offset - 1].isEmpty ? "\n" : " "
                    }
                    body += item
                }
            } else {
                body = collected.joined(separator: "\n")
            }
            switch chomp {
            case "-": break
            case "+": body += String(repeating: "\n", count: trailing + (collected.isEmpty ? 0 : 1))
            default: if !collected.isEmpty { body += "\n" }
            }
            return .scalar(body, quoted: true)
        }

        // MARK: 行内的值

        private func inlineValue(_ text: String, line: Line) throws -> YAMLNode {
            var value = text
            if value.hasPrefix("[") || value.hasPrefix("{") {
                // 流式写法可以跨行：一直读到括号配对为止。
                while !Parser.balanced(value) {
                    guard index < raw.count else {
                        throw YAMLError(line: line.number, message: L("括号没有闭合"))
                    }
                    let next = Parser.stripComment(raw[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                    value += " " + next
                }
            }
            var scanner = FlowScanner(characters: Array(value), line: line.number, anchors: anchors)
            let node = try scanner.parseBlockValue()
            anchors = scanner.anchors
            return node
        }

        static func balanced(_ text: String) -> Bool {
            var depth = 0
            var quote: Character?
            var previous: Character = " "
            for character in text {
                if let open = quote {
                    if character == open && !(open == "\"" && previous == "\\") {
                        quote = nil
                    }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "[" || character == "{" {
                    depth += 1
                } else if character == "]" || character == "}" {
                    depth -= 1
                }
                previous = character
            }
            return depth <= 0
        }

        /// 读一个带引号的标量，返回内容和结束后的位置。
        static func readQuoted(_ characters: [Character], from start: Int) throws -> (String, Int) {
            let open = characters[start]
            var position = start + 1
            var text = ""
            while position < characters.count {
                let character = characters[position]
                if open == "'" {
                    if character == "'" {
                        if position + 1 < characters.count && characters[position + 1] == "'" {
                            text.append("'")
                            position += 2
                            continue
                        }
                        return (text, position + 1)
                    }
                    text.append(character)
                    position += 1
                    continue
                }
                if character == "\"" {
                    return (text, position + 1)
                }
                if character == "\\" && position + 1 < characters.count {
                    let escaped = characters[position + 1]
                    position += 2
                    switch escaped {
                    case "n": text.append("\n")
                    case "t", "\t": text.append("\t")
                    case "r": text.append("\r")
                    case "0": text.append("\0")
                    case "b": text.append("\u{08}")
                    case "f": text.append("\u{0C}")
                    case "a": text.append("\u{07}")
                    case "e": text.append("\u{1B}")
                    case " ": text.append(" ")
                    case "_": text.append("\u{A0}")
                    case "N": text.append("\u{85}")
                    case "L": text.append("\u{2028}")
                    case "P": text.append("\u{2029}")
                    case "x", "u", "U":
                        let length = escaped == "x" ? 2 : (escaped == "u" ? 4 : 8)
                        guard position + length <= characters.count,
                              let code = UInt32(String(characters[position..<(position + length)]), radix: 16),
                              let scalar = Unicode.Scalar(code) else {
                            throw YAMLError(line: 0, message: L("转义写错了"))
                        }
                        text.unicodeScalars.append(scalar)
                        position += length
                    default:
                        text.append(escaped)
                    }
                    continue
                }
                text.append(character)
                position += 1
            }
            throw YAMLError(line: 0, message: L("引号没有闭合"))
        }
    }

    /// 行内的值：流式列表 / 映射、带引号的字符串、别名、普通标量。
    private struct FlowScanner {
        var characters: [Character]
        var position = 0
        var line: Int
        var anchors: [String: YAMLNode]

        init(characters: [Character], line: Int, anchors: [String: YAMLNode]) {
            self.characters = characters
            self.line = line
            self.anchors = anchors
        }

        private var atEnd: Bool { position >= characters.count }

        private mutating func skipSpaces() {
            while !atEnd && (characters[position] == " " || characters[position] == "\t") {
                position += 1
            }
        }

        private func error(_ message: String) -> YAMLError {
            YAMLError(line: line, message: message)
        }

        /// 块里一个键后面的整个值：普通标量一直到行尾。
        mutating func parseBlockValue() throws -> YAMLNode {
            skipSpaces()
            guard !atEnd else { return .null }
            let first = characters[position]
            if first == "[" || first == "{" || first == "\"" || first == "'" || first == "*" || first == "&" || first == "!" {
                let node = try parseValue()
                skipSpaces()
                if !atEnd {
                    throw error(L("值的后面多了内容：%@", String(characters[position...])))
                }
                return node
            }
            let text = String(characters[position...]).trimmingCharacters(in: .whitespaces)
            position = characters.count
            return FlowScanner.plainScalar(text)
        }

        static func plainScalar(_ text: String) -> YAMLNode {
            switch text {
            case "", "~", "null", "Null", "NULL": return .null
            default: return .scalar(text, quoted: false)
            }
        }

        mutating func parseValue() throws -> YAMLNode {
            skipSpaces()
            guard !atEnd else { return .null }
            switch characters[position] {
            case "[":
                return try parseSequence()
            case "{":
                return try parseMapping()
            case "\"", "'":
                let (text, end) = try quoted()
                position = end
                return .scalar(text, quoted: true)
            case "*":
                position += 1
                let name = readName()
                guard let node = anchors[name] else { throw error(L("找不到锚点 &%@", name)) }
                return node
            case "&":
                position += 1
                let name = readName()
                let node = try parseValue()
                anchors[name] = node
                return node
            case "!":
                while !atEnd && characters[position] != " " { position += 1 }
                return try parseValue()
            default:
                var text = ""
                while !atEnd {
                    let character = characters[position]
                    if character == "," || character == "]" || character == "}" { break }
                    text.append(character)
                    position += 1
                }
                return FlowScanner.plainScalar(text.trimmingCharacters(in: .whitespaces))
            }
        }

        private mutating func quoted() throws -> (String, Int) {
            do {
                return try Parser.readQuoted(characters, from: position)
            } catch let problem as YAMLError {
                throw error(problem.message)
            }
        }

        private mutating func readName() -> String {
            var name = ""
            while !atEnd {
                let character = characters[position]
                if character == " " || character == "," || character == "]" || character == "}" { break }
                name.append(character)
                position += 1
            }
            return name
        }

        private mutating func parseSequence() throws -> YAMLNode {
            position += 1
            var items: [YAMLNode] = []
            while true {
                skipSpaces()
                guard !atEnd else { throw error(L("[ 没有闭合")) }
                if characters[position] == "]" {
                    position += 1
                    return .sequence(items)
                }
                items.append(try parseValue())
                skipSpaces()
                guard !atEnd else { throw error(L("[ 没有闭合")) }
                if characters[position] == "," {
                    position += 1
                } else if characters[position] != "]" {
                    throw error(L("列表里的项目要用逗号分开"))
                }
            }
        }

        private mutating func parseMapping() throws -> YAMLNode {
            position += 1
            var pairs: [YAMLPair] = []
            while true {
                skipSpaces()
                guard !atEnd else { throw error(L("{ 没有闭合")) }
                if characters[position] == "}" {
                    position += 1
                    return .mapping(pairs)
                }
                var key: String
                if characters[position] == "\"" || characters[position] == "'" {
                    let (text, end) = try quoted()
                    key = text
                    position = end
                } else {
                    key = ""
                    while !atEnd {
                        let character = characters[position]
                        if character == "," || character == "}" { break }
                        if character == ":" && (position + 1 >= characters.count || [" ", ",", "}", "]"].contains(characters[position + 1])) { break }
                        key.append(character)
                        position += 1
                    }
                    key = key.trimmingCharacters(in: .whitespaces)
                }
                skipSpaces()
                var value: YAMLNode = .null
                if !atEnd && characters[position] == ":" {
                    position += 1
                    skipSpaces()
                    if !atEnd && characters[position] != "," && characters[position] != "}" {
                        value = try parseValue()
                    }
                }
                if key == "<<", case .mapping(let merged) = value {
                    for pair in merged where !pairs.contains(where: { $0.key == pair.key }) {
                        pairs.append(pair)
                    }
                } else if let existing = pairs.firstIndex(where: { $0.key == key }) {
                    pairs[existing].value = value
                } else {
                    pairs.append(YAMLPair(key: key, value: value))
                }
                skipSpaces()
                guard !atEnd else { throw error(L("{ 没有闭合")) }
                if characters[position] == "," {
                    position += 1
                } else if characters[position] != "}" {
                    throw error(L("映射里的项目要用逗号分开"))
                }
            }
        }
    }
}

// MARK: - 写出

enum YAMLWriter {
    /// 块状的 YAML 文本，缩进两格，以换行结尾。
    static func write(_ node: YAMLNode) -> String {
        switch node {
        case .mapping(let pairs) where !pairs.isEmpty:
            return mappingLines(pairs, indent: 0).joined(separator: "\n") + "\n"
        case .sequence(let items) where !items.isEmpty:
            return sequenceLines(items, indent: 0).joined(separator: "\n") + "\n"
        default:
            return inline(node) + "\n"
        }
    }

    private static func mappingLines(_ pairs: [YAMLPair], indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        for pair in pairs {
            let key = self.key(pair.key)
            switch pair.value {
            case .mapping(let children) where !children.isEmpty:
                lines.append("\(pad)\(key):")
                lines += mappingLines(children, indent: indent + 2)
            case .sequence(let items) where !items.isEmpty:
                lines.append("\(pad)\(key):")
                lines += sequenceLines(items, indent: indent + 2)
            default:
                lines.append("\(pad)\(key): \(inline(pair.value))")
            }
        }
        return lines
    }

    private static func sequenceLines(_ items: [YAMLNode], indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        for item in items {
            var nested: [String]
            switch item {
            case .mapping(let pairs) where !pairs.isEmpty:
                nested = mappingLines(pairs, indent: indent + 2)
            case .sequence(let children) where !children.isEmpty:
                nested = sequenceLines(children, indent: indent + 2)
            default:
                lines.append("\(pad)- \(inline(item))")
                continue
            }
            // 第一行和「- 」放在一起。
            nested[0] = pad + "- " + String(nested[0].dropFirst(indent + 2))
            lines += nested
        }
        return lines
    }

    /// 放在一行里的值：标量、空列表、空映射。
    static func inline(_ node: YAMLNode) -> String {
        switch node {
        case .null: return "null"
        case .scalar(let text, let quoted):
            return quoted || !isSafePlain(text) ? quote(text) : text
        case .sequence(let items):
            return "[" + items.map(inline).joined(separator: ", ") + "]"
        case .mapping(let pairs):
            return "{" + pairs.map { "\(key($0.key)): \(inline($0.value))" }.joined(separator: ", ") + "}"
        }
    }

    private static func key(_ text: String) -> String {
        isSafePlain(text) && !["null", "~", "true", "false"].contains(text.lowercased()) ? text : quote(text)
    }

    /// 不加引号也不会被误读的标量。
    static func isSafePlain(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        if first == " " || last == " " { return false }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) {
            // 负数这类以 - 开头的数字可以。
            if first == "-", text.count > 1, Double(text) != nil { return true }
            return false
        }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") { return false }
        if text.contains(where: { $0.isNewline || $0 == "\t" || ($0.asciiValue.map { $0 < 0x20 } ?? false) }) { return false }
        return true
    }

    /// 双引号字符串（JSON 兼容的转义）。
    static func quote(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"" + escaped + "\""
    }
}
