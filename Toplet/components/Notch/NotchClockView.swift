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

import Defaults
import MapKit
import SwiftUI

enum ClockPanel: String, CaseIterable, Identifiable {
    case world = "World", alarms = "Alarms", here = "Here"
    var id: String { rawValue }
}

/// Shared with ContentView: the Clock tab stays open while an alarm is being edited or is ringing.
@MainActor
final class ClockUIState: ObservableObject {
    static let shared = ClockUIState()
    @Published var isEditing = false
}

/// The Clock tab: the time on the left (in the 12/24-hour format chosen in Settings), and World
/// clocks, Alarms and a "Here" map on the right.
struct NotchClockView: View {
    @ObservedObject private var alarms = AlarmManager.shared
    @ObservedObject private var location = NotchLocation.shared
    @ObservedObject private var ui = ClockUIState.shared
    @Default(.clockHourFormat) private var hourFormat
    @Default(.worldClockZones) private var zones
    @Default(.notchAlarms) private var alarmList
    @AppStorage("clock.panel") private var panelRaw = ClockPanel.world.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var zoneQuery = ""
    @State private var isAddingZone = false
    @State private var draft: NotchAlarm?

    private var panel: ClockPanel { ClockPanel(rawValue: panelRaw) ?? .world }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            clockColumn.frame(width: 178)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Clock view", selection: Binding(get: { panel }, set: { p in withAnimation(spring) { panelRaw = p.rawValue } })) {
                    ForEach(ClockPanel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Group {
                    switch panel {
                    case .world: worldPanel
                    case .alarms: alarmsPanel
                    case .here: herePanel
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .onChange(of: draft != nil || isAddingZone) { _, editing in ui.isEditing = editing }
        .onDisappear { ui.isEditing = false }
    }

    // MARK: Clock

    private var clockColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let ringing = alarms.ringing {
                ringingCard(ringing)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            } else {
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hourFormat.string(from: context.date))
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                nextAlarmLine
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .animation(spring, value: alarms.ringing?.id)
    }

    @ViewBuilder
    private var nextAlarmLine: some View {
        if let next = alarms.next {
            Label {
                Text("\(next.date.formatted(.dateTime.weekday(.abbreviated))) \(hourFormat.string(from: next.date))")
                    + Text(next.alarm.label.isEmpty ? "" : " · \(next.alarm.label)").foregroundColor(.secondary)
            } icon: {
                Image(systemName: "alarm.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
        } else {
            Label("No alarms set", systemImage: "alarm")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func ringingCard(_ alarm: NotchAlarm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(alarm.label.isEmpty ? "Alarm" : alarm.label, systemImage: "alarm.waves.left.and.right.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, isActive: !reduceMotion)
            Text(hourFormat.string(hour: alarm.hour, minute: alarm.minute))
                .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            HStack(spacing: 6) {
                capsuleButton("Stop", tint: .orange) { alarms.stop() }
                capsuleButton(alarms.snoozeLabel, tint: nil) { alarms.snooze() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notchSurface(cornerRadius: 14, tint: .orange)
    }

    // MARK: World

    private var worldPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    if zones.isEmpty && !isAddingZone {
                        Text("Add a city to see its time next to yours.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    TimelineView(.periodic(from: Date(), by: 30)) { context in
                        VStack(spacing: 4) {
                            ForEach(zones, id: \.self) { id in worldRow(id, now: context.date) }
                        }
                    }
                }
            }
            .hidingScrollEdgeBlur()
            if isAddingZone { zonePicker } else {
                smallButton("Add city", symbol: "plus") { withAnimation(spring) { isAddingZone = true } }
            }
        }
    }

    @ViewBuilder
    private func worldRow(_ id: String, now: Date) -> some View {
        if let zone = TimeZone(identifier: id) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(WorldClockLabel.city(id)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(WorldClockLabel.relative(zone, now: now)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(hourFormat.string(from: now, timeZone: zone))
                    .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                removeButton { withAnimation(spring) { zones.removeAll { $0 == id } } }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .notchSurface(cornerRadius: 10)
        }
    }

    private var zoneMatches: [String] {
        let q = zoneQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return TimeZone.knownTimeZoneIdentifiers
            .filter { !zones.contains($0) && WorldClockLabel.city($0).lowercased().contains(q) }
            .sorted { WorldClockLabel.city($0).lowercased().hasPrefix(q) && !WorldClockLabel.city($1).lowercased().hasPrefix(q) }
            .prefix(3).map { $0 }
    }

    private var zonePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("City, e.g. Tokyo", text: $zoneQuery)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { if let first = zoneMatches.first { addZone(first) } }
                smallButton("Done", symbol: nil) { withAnimation(spring) { isAddingZone = false; zoneQuery = "" } }
            }
            HStack(spacing: 4) {
                ForEach(zoneMatches, id: \.self) { id in
                    Button(WorldClockLabel.city(id)) { addZone(id) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .notchSurfaceCapsule(interactive: true)
                }
            }
        }
    }

    private func addZone(_ id: String) {
        withAnimation(spring) {
            zones.append(id)
            zoneQuery = ""
            isAddingZone = false
        }
    }

    // MARK: Alarms

    private var alarmsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let draft {
                AlarmEditor(alarm: draft, hourFormat: hourFormat,
                            onSave: { alarm in alarms.save(alarm); withAnimation(spring) { self.draft = nil } },
                            onCancel: { withAnimation(spring) { self.draft = nil } })
                    .id(draft.id)
                    .transition(.opacity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        if alarmList.isEmpty {
                            Text("No alarms yet. They ring here with the timer sound, even when the notch is closed.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }
                        ForEach(alarmList) { alarm in alarmRow(alarm) }
                    }
                }
                .hidingScrollEdgeBlur()
                smallButton("New alarm", symbol: "plus") {
                    let now = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(3600))
                    withAnimation(spring) { draft = NotchAlarm(hour: now.hour ?? 7, minute: 0) }
                }
            }
        }
    }

    private func alarmRow(_ alarm: NotchAlarm) -> some View {
        HStack(spacing: 8) {
            Button { withAnimation(spring) { draft = alarm } } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hourFormat.string(hour: alarm.hour, minute: alarm.minute))
                        .font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
                    Text([alarm.label, alarm.repeatSummary].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit alarm")
            Toggle("", isOn: Binding(get: { alarm.isEnabled }, set: { alarms.setEnabled($0, for: alarm.id) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            removeButton { withAnimation(spring) { alarms.delete(alarm.id) } }
        }
        .opacity(alarm.isEnabled ? 1 : 0.55)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .notchSurface(cornerRadius: 10)
    }

    // MARK: Here

    @ViewBuilder
    private var herePanel: some View {
        if let loc = location.location {
            ZStack(alignment: .bottomLeading) {
                Map(initialPosition: .region(MKCoordinateRegion(center: loc.coordinate,
                                                                 latitudinalMeters: 4000, longitudinalMeters: 4000))) {
                    Marker(location.place ?? "You", systemImage: "laptopcomputer", coordinate: loc.coordinate)
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 6) {
                    Text(location.place ?? "Your location").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    smallButton("Open in Maps", symbol: "map") { location.openInMaps() }
                }
                .padding(6)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(6)
            }
            .onAppear { location.locate() }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(location.isDenied
                     ? "Location is turned off for Toplet. Turn it on in System Settings to see where you are."
                     : "See where this Mac is on a small map. Toplet asks for your location once and keeps it on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if location.isDenied {
                    smallButton("Open Location Settings", symbol: "gear") { location.openPrivacySettings() }
                } else {
                    smallButton(location.isLocating ? "Locating…" : "Show my location", symbol: "location.fill") { location.locate() }
                        .disabled(location.isLocating)
                }
            }
        }
    }

    // MARK: Small controls

    private func smallButton(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchSurfaceCapsule(interactive: true)
    }

    private func capsuleButton(_ title: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchSurfaceCapsule(tint: tint, interactive: true)
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

/// Inline alarm editor: time, label and the weekdays it repeats on.
private struct AlarmEditor: View {
    @State var alarm: NotchAlarm
    let hourFormat: ClockHourFormat
    let onSave: (NotchAlarm) -> Void
    let onCancel: () -> Void

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: alarm.hour, minute: alarm.minute)) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                alarm.hour = parts.hour ?? 0
                alarm.minute = parts.minute ?? 0
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField).labelsHidden()
                    .environment(\.locale, hourFormat.pickerLocale)
                TextField("Label", text: $alarm.label)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
            }
            HStack(spacing: 3) {
                // Monday-first, as in the Clock app.
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    let on = alarm.repeatDays.contains(day)
                    Button(String(Calendar.current.veryShortWeekdaySymbols[day - 1])) {
                        if on { alarm.repeatDays.remove(day) } else { alarm.repeatDays.insert(day) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.5))
                    .notchSurface(cornerRadius: 10, tint: on ? .accentColor : nil, interactive: true)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1] + (on ? ", repeats" : ""))
                }
                Text(alarm.repeatSummary).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 4)
                Spacer(minLength: 4)
                Button("Cancel", action: onCancel).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    var saved = alarm
                    saved.isEnabled = true
                    onSave(saved)
                } label: {
                    Text("Save").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .notchSurfaceCapsule(tint: .accentColor, interactive: true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .notchSurface(cornerRadius: 12)
    }
}

private extension ClockHourFormat {
    /// NSDatePicker follows its locale's clock; pick one that shows the chosen format.
    var pickerLocale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .twelveHour: return Locale(identifier: "en_US")
        case .twentyFourHour: return Locale(identifier: "en_GB")
        }
    }
}
