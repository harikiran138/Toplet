/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import OSLog
import SwiftUI
import Defaults

enum LogCategory: String {
    case lifecycle = "🔄"
    case memory = "💾"
    case performance = "⚡️"
    case ui = "🎨"
    case network = "🌐"
    case error = "❌"
    case warning = "⚠️"
    case success = "✅"
    case debug = "🔍"
    case extensions = "🧩"

    var osCategoryName: String {
        switch self {
        case .lifecycle: return "lifecycle"
        case .memory: return "memory"
        case .performance: return "performance"
        case .ui: return "ui"
        case .network: return "network"
        case .error: return "error"
        case .warning: return "warning"
        case .success: return "success"
        case .debug: return "debug"
        case .extensions: return "extensions"
        }
    }

    var defaultLevel: LogLevel {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .success, .ui, .network, .lifecycle, .memory, .performance, .extensions: return .info
        case .debug: return .debug
        }
    }
}

struct Logger {
    private static let subsystem = "app.toplet.Toplet"
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static var osLoggerCache: [LogCategory: OSLog] = [:]
    // `log` may be called from any thread; guard the cache.
    private static let osLoggerCacheLock = NSLock()

    private static func osLogger(for category: LogCategory) -> OSLog {
        osLoggerCacheLock.lock()
        defer { osLoggerCacheLock.unlock() }
        if let cached = osLoggerCache[category] {
            return cached
        }
        let logger = OSLog(subsystem: subsystem, category: category.osCategoryName)
        osLoggerCache[category] = logger
        return logger
    }

    /// `message` is an autoclosure so the (often interpolated) string is only built
    /// when the configured level lets the entry through.
    static func log(
        _ message: @autoclosure () -> String,
        category: LogCategory,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let configuredLevel = Defaults[.logLevel]
        if configuredLevel == .none || category.defaultLevel.rawValue > configuredLevel.rawValue {
            return
        }

        let fileName = (file as NSString).lastPathComponent
        let timestamp = dateFormatter.string(from: Date())
        let entry = "\(category.rawValue) [\(timestamp)] [\(fileName):\(line)] \(function) - \(message())"
        let logger = osLogger(for: category)
        os_log("%{public}@", log: logger, type: .default, entry)

#if DEBUG
        Swift.print(entry)
#endif
    }
    
}

// Global overrides to filter scattered print and NSLog statements throughout the app

public func NSLog(_ format: String, _ args: CVarArg...) {
    let configuredLevel = Defaults[.logLevel]
    if configuredLevel == .none { return }
    
    let message = String(format: format, arguments: args)
    let lowerMessage = message.lowercased()
    
    let isError = message.contains("❌") || lowerMessage.contains("error") || lowerMessage.contains("failed")
    let isWarning = message.contains("⚠️") || lowerMessage.contains("warning")
    
    let simulatedLevel: LogLevel = isError ? .error : (isWarning ? .warning : .debug)
    
    if simulatedLevel.rawValue > configuredLevel.rawValue { return }
    
    Foundation.NSLog("%@", message)
} 