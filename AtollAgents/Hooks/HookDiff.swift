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

/// Minimal unified-diff generator for the install preview (common prefix/suffix trimmed, LCS on the middle).
enum HookDiff {
    static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private struct Op { var kind: Character; var text: String }

    /// Returns "" when the texts are equal.
    static func unified(old: String, new: String, oldLabel: String, newLabel: String, context: Int = 3) -> String {
        if old == new { return "" }
        let a = lines(old), b = lines(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let ma = Array(a[p..<(a.count - s)]), mb = Array(b[p..<(b.count - s)])

        var ops = [Op]()
        ops.reserveCapacity(a.count + mb.count)
        for i in 0..<p { ops.append(Op(kind: " ", text: a[i])) }
        if ma.count * mb.count > 4_000_000 {
            ma.forEach { ops.append(Op(kind: "-", text: $0)) }
            mb.forEach { ops.append(Op(kind: "+", text: $0)) }
        } else {
            let w = mb.count + 1
            var t = [Int32](repeating: 0, count: (ma.count + 1) * w)
            if !ma.isEmpty && !mb.isEmpty {
                for i in stride(from: ma.count - 1, through: 0, by: -1) {
                    for j in stride(from: mb.count - 1, through: 0, by: -1) {
                        t[i * w + j] = ma[i] == mb[j] ? t[(i + 1) * w + j + 1] + 1 : max(t[(i + 1) * w + j], t[i * w + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < ma.count || j < mb.count {
                if i < ma.count, j < mb.count, ma[i] == mb[j] { ops.append(Op(kind: " ", text: ma[i])); i += 1; j += 1 }
                else if i < ma.count, j == mb.count || t[(i + 1) * w + j] >= t[i * w + j + 1] { ops.append(Op(kind: "-", text: ma[i])); i += 1 }   // deletions before insertions, like diff(1)
                else { ops.append(Op(kind: "+", text: mb[j])); j += 1 }
            }
        }
        for i in (a.count - s)..<a.count { ops.append(Op(kind: " ", text: a[i])) }

        // line counters before each op
        var oldBefore = [Int](repeating: 0, count: ops.count + 1)
        var newBefore = [Int](repeating: 0, count: ops.count + 1)
        for (k, op) in ops.enumerated() {
            oldBefore[k + 1] = oldBefore[k] + (op.kind == "+" ? 0 : 1)
            newBefore[k + 1] = newBefore[k] + (op.kind == "-" ? 0 : 1)
        }
        let changed = ops.indices.filter { ops[$0].kind != " " }
        var out = "--- \(oldLabel)\n+++ \(newLabel)\n"
        var g = 0
        while g < changed.count {
            var last = changed[g]
            var h = g
            while h + 1 < changed.count, changed[h + 1] - last <= 2 * context + 1 { h += 1; last = changed[h] }
            let start = max(0, changed[g] - context)
            let end = min(ops.count - 1, last + context)
            let oc = oldBefore[end + 1] - oldBefore[start]
            let nc = newBefore[end + 1] - newBefore[start]
            let os = oc == 0 ? oldBefore[start] : oldBefore[start] + 1
            let ns = nc == 0 ? newBefore[start] : newBefore[start] + 1
            out += "@@ -\(os),\(oc) +\(ns),\(nc) @@\n"
            for k in start...end { out += "\(ops[k].kind)\(ops[k].text)\n" }
            g = h + 1
        }
        return out
    }
}
