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

// Wire protocol of the private `atoll-notify` socket (docs/NOTIFICATIONS-SOURCES.md).
//
//   one JSON object per connection, terminated by EOF (`nc -U` half-closes when stdin ends), at most 1 MiB:
//   {"v":1,"title":"Build done","body":"...","subtitle":"...","app":"make","bundleID":"com.apple.Terminal","symbol":"hammer.fill",
//    "url":"https://...","openApp":"com.apple.Terminal","tab":"agents","priority":"low|normal|high|critical","ttl":6,
//    "dedupe":"build","thread":"ci","sensitive":true}
//   reply, one line:  {"ok":true,"id":"<uuid>"}   or   {"ok":false,"error":"<fixed text>"}
//
// Error texts are fixed strings: nothing the client sent is ever echoed back.

enum IngressReply: Equatable {
    case ok(id: UUID)
    case error(String)

    /// Single-line JSON plus newline.
    var line: Data {
        let obj: [String: Any]
        switch self {
        case .ok(let id): obj = ["ok": true, "id": id.uuidString]
        case .error(let m): obj = ["ok": false, "error": m]
        }
        var d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{\"ok\":false,\"error\":\"internal\"}".utf8)
        d.append(0x0A)
        return d
    }
}

enum NotificationIngressDecoder {
    enum Failure: Error, Equatable {
        case malformed
        case unsupportedVersion
        case missingTitle
        case wrongType(String)
        case invalid(String)
        case multipleActions

        /// Fixed, client-safe text.
        var message: String {
            switch self {
            case .malformed: return "malformed JSON"
            case .unsupportedVersion: return "unsupported protocol version (expected v:1)"
            case .missingTitle: return "title is required"
            case .wrongType(let f): return "field '\(f)' has the wrong type"
            case .invalid(let f): return "invalid \(f)"
            case .multipleActions: return "only one of url, openApp and tab may be given"
            }
        }
    }

    static let knownStringFields = ["title", "body", "subtitle", "app", "bundleID", "symbol", "url", "openApp", "tab", "priority", "dedupe", "thread"]
    static let cliSuffix = " (via CLI)"

    /// Decodes one request. The result's `source` is always `.cli`; the app name always carries provenance.
    static func decode(_ data: Data, now: Date = Date(), fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result<NotchNotification, Failure> {
        guard !data.isEmpty else { return .failure(.malformed) }
        // Tolerate invalid UTF-8 from shell arguments: replace instead of rejecting.
        let text = String(decoding: data, as: UTF8.self)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [])) as? [String: Any] else { return .failure(.malformed) }

        guard let v = obj["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.intValue == 1, v.doubleValue == 1 else {
            return .failure(.unsupportedVersion)
        }
        var strings: [String: String] = [:]
        for k in knownStringFields {
            guard let raw = obj[k] else { continue }
            if raw is NSNull { continue }
            guard let s = raw as? String else { return .failure(.wrongType(k)) }
            strings[k] = s
        }
        guard let rawTitle = strings["title"] else { return .failure(.missingTitle) }
        let title = NotificationText.clean(rawTitle, max: NotificationText.maxTitle)
        guard !title.isEmpty else { return .failure(.missingTitle) }

        var priority = NotificationPriority.normal
        if let p = strings["priority"] {
            switch p.lowercased() {
            case "low": priority = .low
            case "normal": priority = .normal
            case "high": priority = .high
            case "critical": priority = .critical
            default: return .failure(.invalid("priority"))
            }
        }

        var ttl: TimeInterval?
        if let raw = obj["ttl"], !(raw is NSNull) {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return .failure(.wrongType("ttl")) }
            let d = n.doubleValue
            guard d.isFinite, d > 0, d <= 3600 else { return .failure(.invalid("ttl")) }
            ttl = d
        }

        var sensitive = false
        if let raw = obj["sensitive"], !(raw is NSNull) {
            guard let b = raw as? Bool, CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() else { return .failure(.wrongType("sensitive")) }
            sensitive = b
        }

        var symbol: String?
        if let s = strings["symbol"], !s.isEmpty {
            guard let ok = NotificationText.symbol(s) else { return .failure(.invalid("symbol")) }
            symbol = ok
        }
        var bundle: String?
        if let s = strings["bundleID"], !s.isEmpty {
            guard let ok = NotificationText.bundleID(s) else { return .failure(.invalid("bundleID")) }
            bundle = ok
        }

        // At most one action. Empty strings count as absent.
        let url = strings["url"].flatMap { $0.isEmpty ? nil : $0 }
        let openApp = strings["openApp"].flatMap { $0.isEmpty ? nil : $0 }
        let tab = strings["tab"].flatMap { $0.isEmpty ? nil : $0 }
        if [url != nil, openApp != nil, tab != nil].filter({ $0 }).count > 1 { return .failure(.multipleActions) }
        var action = NotificationAction.none
        if let u = url {
            guard let ok = NotificationURLPolicy.validate(u, fileExists: fileExists) else { return .failure(.invalid("url")) }
            action = .openURL(ok)
        } else if let a = openApp {
            guard let ok = NotificationText.bundleID(a) else { return .failure(.invalid("openApp")) }
            action = .activateApp(bundleID: ok)
        } else if let t = tab {
            guard let ok = NotificationText.tab(t) else { return .failure(.invalid("tab")) }
            action = .openNotchTab(ok)
        }

        // Provenance: the sender chooses the app name, so the notch always says it came from the command line.
        let rawApp = NotificationText.clean(strings["app"] ?? "", max: 40)
        let appName = (rawApp.isEmpty ? NotificationSource.cli.defaultAppName : rawApp + cliSuffix)

        let n = NotchNotification(id: UUID(), source: .cli, appName: appName, bundleID: bundle, iconSymbol: symbol, title: title,
                                  subtitle: NotificationText.cleanOptional(strings["subtitle"], max: NotificationText.maxSubtitle),
                                  body: NotificationText.cleanOptional(strings["body"], max: NotificationText.maxBody, multiline: true),
                                  receivedAt: now, priority: priority, ttl: ttl,
                                  dedupeKey: NotificationText.cleanOptional(strings["dedupe"], max: NotificationText.maxKey),
                                  threadID: NotificationText.cleanOptional(strings["thread"], max: NotificationText.maxKey),
                                  action: action, isSensitive: sensitive)
        return .success(n)
    }
}
