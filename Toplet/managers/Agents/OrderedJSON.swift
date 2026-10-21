/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

import Foundation

// A small, strict, ORDER-PRESERVING JSON reader/writer used only to edit the agents' own config files.
//
// Why not JSONSerialization: it returns unordered dictionaries (key order is lost), it turns numbers into
// NSNumber (1.0 -> 1, big integers lose precision) and re-escapes strings. This type keeps member order,
// keeps every number and string token byte-for-byte as it was written, and only normalises WHITESPACE.
//
// Strictness matches the agents: Claude Code documents its settings as strict JSON ("a // comment or a trailing
// comma is a syntax error", https://code.claude.com/docs/en/settings). Anything this parser rejects is
// refused by the installer instead of being "repaired".
//
// Output style replicates JavaScript's JSON.stringify(value, null, indent): that is how Claude Code itself writes
// settings.json, so a file written by Claude Code round-trips byte-for-byte (tested).

indirect enum JSONValue: Equatable {
    case object([JSONMember])
    case array([JSONValue])
    /// `raw` is the original token INCLUDING quotes, kept so unmodified strings are written back verbatim.
    case string(String, raw: String?)
    /// The original numeric token (validated against the JSON grammar), written back verbatim.
    case number(String)
    case bool(Bool)
    case null

    static func str(_ s: String) -> JSONValue { .string(s, raw: nil) }

    var stringValue: String? { if case .string(let s, _) = self { return s }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [JSONMember]? { if case .object(let o) = self { return o }; return nil }
    var isObject: Bool { if case .object = self { return true }; return false }
}

struct JSONMember: Equatable {
    var key: String
    var rawKey: String?
    var value: JSONValue
    init(_ key: String, _ value: JSONValue, rawKey: String? = nil) { self.key = key; self.value = value; self.rawKey = rawKey }
}

extension Array where Element == JSONMember {
    /// Indices of every member with this key (JSON allows duplicates; the installer refuses to guess between them).
    func indices(ofKey key: String) -> [Int] { enumerated().filter { $0.element.key == key }.map { $0.offset } }
    func first(key: String) -> JSONValue? { first(where: { $0.key == key })?.value }
}

struct JSONParseError: Error, CustomStringConvertible, Equatable {
    let message: String
    let offset: Int
    var description: String { "\(message) (at byte \(offset))" }
}

struct JSONWriteStyle: Equatable {
    var indent: String = "  "
    var newline: String = "\n"
    var trailingNewline: Bool = true
    var bom: Bool = false
}

enum OrderedJSON {
    static let maxDepth = 128

    /// Parses `data` (UTF-8, optional BOM). Zero bytes / whitespace only is NOT handled here (callers decide).
    static func parse(_ data: Data) throws -> (value: JSONValue, style: JSONWriteStyle) {
        var bytes = [UInt8](data)
        var style = JSONWriteStyle()
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            style.bom = true
            bytes.removeFirst(3)
        }
        // Reject invalid UTF-8 up front so token slicing below can never split a code point.
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw JSONParseError(message: "file is not valid UTF-8", offset: 0) }
        var p = Parser(bytes: bytes)
        p.skipWS()
        let v = try p.parseValue(depth: 0)
        p.skipWS()
        if p.i != bytes.count { throw JSONParseError(message: "unexpected data after the top-level value", offset: p.i + (style.bom ? 3 : 0)) }
        style.newline = bytes.contains(0x0D) && containsCRLF(bytes) ? "\r\n" : "\n"
        style.trailingNewline = bytes.last == 0x0A
        style.indent = detectIndent(bytes)
        return (v, style)
    }

    private static func containsCRLF(_ b: [UInt8]) -> Bool {
        var i = 0
        while i + 1 < b.count { if b[i] == 0x0D && b[i + 1] == 0x0A { return true }; i += 1 }
        return false
    }

    /// First indented line decides: a tab, or N spaces. Default two spaces (what Claude Code writes).
    private static func detectIndent(_ b: [UInt8]) -> String {
        var i = 0
        while i < b.count {
            if b[i] == 0x0A {
                var j = i + 1
                var n = 0
                var tab = false
                while j < b.count, b[j] == 0x20 || b[j] == 0x09 { if b[j] == 0x09 { tab = true }; n += 1; j += 1 }
                if n > 0, j < b.count, b[j] != 0x0A, b[j] != 0x0D {
                    return tab ? "\t" : String(repeating: " ", count: min(n, 8))
                }
            }
            i += 1
        }
        return "  "
    }

    static func serialize(_ v: JSONValue, style: JSONWriteStyle = JSONWriteStyle()) -> String {
        var out = ""
        out.reserveCapacity(1024)
        write(v, depth: 0, style: style, into: &out)
        if style.trailingNewline { out += style.newline }
        return (style.bom ? "\u{FEFF}" : "") + out
    }

    private static func write(_ v: JSONValue, depth: Int, style: JSONWriteStyle, into out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let raw): out += raw
        case .string(let s, let raw): out += raw ?? encodeString(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (n, item) in items.enumerated() {
                out += style.newline + String(repeating: style.indent, count: depth + 1)
                write(item, depth: depth + 1, style: style, into: &out)
                if n < items.count - 1 { out += "," }
            }
            out += style.newline + String(repeating: style.indent, count: depth) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (n, m) in members.enumerated() {
                out += style.newline + String(repeating: style.indent, count: depth + 1)
                out += m.rawKey ?? encodeString(m.key)
                out += ": "
                write(m.value, depth: depth + 1, style: style, into: &out)
                if n < members.count - 1 { out += "," }
            }
            out += style.newline + String(repeating: style.indent, count: depth) + "}"
        }
    }

    /// JSON.stringify-compatible string encoding (no escaping of "/" or non-ASCII).
    static func encodeString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
        }

        func err(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            if depth > OrderedJSON.maxDepth { throw err("nesting deeper than \(OrderedJSON.maxDepth) levels") }
            guard i < bytes.count else { throw err("unexpected end of file") }
            switch bytes[i] {
            case 0x7B: return try parseObject(depth: depth)
            case 0x5B: return try parseArray(depth: depth)
            case 0x22:
                let (s, raw) = try parseString()
                return .string(s, raw: raw)
            case 0x2D, 0x30...0x39: return .number(try parseNumber())
            case 0x74: try literal("true"); return .bool(true)
            case 0x66: try literal("false"); return .bool(false)
            case 0x6E: try literal("null"); return .null
            default: throw err("unexpected character (comments, trailing commas and unquoted keys are not valid JSON)")
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw err("invalid literal") }
            i += w.count
            // a literal must not run into identifier characters ("nullx")
            if i < bytes.count, (bytes[i] >= 0x61 && bytes[i] <= 0x7A) || (bytes[i] >= 0x41 && bytes[i] <= 0x5A) || (bytes[i] >= 0x30 && bytes[i] <= 0x39) {
                throw err("invalid literal")
            }
        }

        mutating func parseNumber() throws -> String {
            let start = i
            if bytes[i] == 0x2D { i += 1 }
            guard i < bytes.count else { throw err("invalid number") }
            if bytes[i] == 0x30 { i += 1 }
            else if bytes[i] >= 0x31 && bytes[i] <= 0x39 { while i < bytes.count, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 } }
            else { throw err("invalid number") }
            if i < bytes.count, bytes[i] == 0x2E {
                i += 1
                let d = i
                while i < bytes.count, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
                if i == d { throw err("invalid number") }
            }
            if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                i += 1
                if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
                let d = i
                while i < bytes.count, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
                if i == d { throw err("invalid number") }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        static func hexVal(_ b: UInt8) -> UInt32? {
            switch b {
            case 0x30...0x39: return UInt32(b - 0x30)
            case 0x41...0x46: return UInt32(b - 0x41 + 10)
            case 0x61...0x66: return UInt32(b - 0x61 + 10)
            default: return nil
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw err("bad \\u escape") }
            var v: UInt32 = 0
            for k in 0..<4 {
                guard let h = Parser.hexVal(bytes[i + k]) else { throw err("bad \\u escape") }
                v = v * 16 + h
            }
            i += 4
            return v
        }

        mutating func parseString() throws -> (String, String) {
            let start = i
            i += 1 // opening quote
            var buf = [UInt8]()
            while true {
                guard i < bytes.count else { throw err("unterminated string") }
                let b = bytes[i]
                if b == 0x22 { i += 1; break }
                if b < 0x20 { throw err("raw control character inside a string") }
                if b == 0x5C {
                    i += 1
                    guard i < bytes.count else { throw err("unterminated string") }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case 0x22: buf.append(0x22)
                    case 0x5C: buf.append(0x5C)
                    case 0x2F: buf.append(0x2F)
                    case 0x62: buf.append(0x08)
                    case 0x66: buf.append(0x0C)
                    case 0x6E: buf.append(0x0A)
                    case 0x72: buf.append(0x0D)
                    case 0x74: buf.append(0x09)
                    case 0x75:
                        var cp = try hex4()
                        if cp >= 0xD800 && cp <= 0xDBFF {
                            if i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 {
                                let save = i
                                i += 2
                                let lo = try hex4()
                                if lo >= 0xDC00 && lo <= 0xDFFF { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) }
                                else { i = save; cp = 0xFFFD }
                            } else { cp = 0xFFFD }
                        } else if cp >= 0xDC00 && cp <= 0xDFFF { cp = 0xFFFD } // lone surrogate: decoded copy only; raw token is preserved on write
                        buf.append(contentsOf: Array(String(Character(Unicode.Scalar(cp) ?? "\u{FFFD}")).utf8))
                    default: throw err("invalid escape sequence")
                    }
                } else {
                    buf.append(b)
                    i += 1
                }
            }
            return (String(decoding: buf, as: UTF8.self), String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            i += 1
            var items = [JSONValue]()
            skipWS()
            if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try parseValue(depth: depth + 1))
                skipWS()
                guard i < bytes.count else { throw err("unterminated array") }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x5D { i += 1; break }
                throw err("expected , or ] in array")
            }
            return .array(items)
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            i += 1
            var members = [JSONMember]()
            skipWS()
            if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(members) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == 0x22 else { throw err("expected a string key") }
                let (k, rawK) = try parseString()
                skipWS()
                guard i < bytes.count, bytes[i] == 0x3A else { throw err("expected : after key") }
                i += 1
                skipWS()
                let v = try parseValue(depth: depth + 1)
                members.append(JSONMember(k, v, rawKey: rawK))
                skipWS()
                guard i < bytes.count else { throw err("unterminated object") }
                if bytes[i] == 0x2C { i += 1; continue }
                if bytes[i] == 0x7D { i += 1; break }
                throw err("expected , or } in object")
            }
            return .object(members)
        }
    }
}
