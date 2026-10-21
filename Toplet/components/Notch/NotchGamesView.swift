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

import SwiftUI

/// The Games tab: a game list on the left, the board on the right. ContentView keeps this tab open
/// when the pointer leaves the notch (click outside to close), so a game is never lost to a stray move.
struct NotchGamesView: View {
    @ObservedObject private var store = NotchGamesStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sidebar
                .frame(width: 136)
            VStack(spacing: 8) {
                header
                ZStack {
                    board
                        .id(store.selected)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    if store.isFinished {
                        resultBanner
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(spring, value: store.selected)
                .animation(spring, value: store.isFinished)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 4) {
                ForEach(NotchGameKind.allCases) { kind in gameButton(kind) }
            }
            Spacer(minLength: 4)
            Text(record)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(spring) { store.newGame() }
            } label: {
                Label("New game", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .notchSurfaceCapsule(tint: .accentColor, interactive: true)
            .keyboardShortcut("n", modifiers: .command)
            .help("Start a new game (⌘N)")
        }
    }

    private func gameButton(_ kind: NotchGameKind) -> some View {
        let isSelected = store.selected == kind
        return Button {
            withAnimation(spring) { store.selected = kind }
        } label: {
            let row = HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text(kind.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            // Glass goes on the row itself: as a background layer it is drawn over the label.
            if isSelected {
                row.notchSurface(cornerRadius: 9, tint: .accentColor)
            } else {
                row
            }
        }
        .buttonStyle(.plain)
        .help(kind.howToPlay)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var record: String {
        switch store.selected {
        case .pairs:
            guard let best = store.bestPairs(store.pairsSize) else { return "No best yet on \(store.pairsSize.title)." }
            return "Best on \(store.pairsSize.title): \(best.moves) moves · \(clock(best.seconds))"
        case .ticTacToe:
            let r = store.ticTacToeRecord
            return "You \(r.wins) · Mac \(r.losses) · Draws \(r.draws)"
        case .lightsOut:
            return store.bestLightsOut.map { "Best: \($0) moves" } ?? "No best yet."
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            // Ticks only while a Pairs game is being timed; every other status changes with the board.
            TimelineView(.animation(minimumInterval: 1, paused: !isTiming)) { context in
                Text(status(now: context.date))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            switch store.selected {
            case .pairs:
                Picker("Board size", selection: $store.pairsSize) {
                    ForEach(PairsBoard.Size.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 132)
            case .ticTacToe:
                Picker("Difficulty", selection: $store.difficulty) {
                    ForEach(TicTacToeBoard.Difficulty.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 132)
            case .lightsOut:
                EmptyView()
            }
        }
        .frame(height: 18)
    }

    private var isTiming: Bool {
        store.selected == .pairs && store.pairs.startedAt != nil && !store.pairs.isWon
    }

    private func status(now: Date) -> String {
        switch store.selected {
        case .pairs:
            let p = store.pairs
            return "\(p.matched.count / 2) of \(p.cards.count / 2) pairs · \(moves(p.moves)) · \(clock(Int(p.elapsed(now: now))))"
        case .ticTacToe:
            switch store.ticTacToe.outcome {
            case .win(.x, _): return "You win"
            case .win(.o, _): return "The Mac wins"
            case .draw: return "Draw"
            case nil: return store.computerThinking ? "Mac is thinking…" : "Your move · you are ✕"
            }
        case .lightsOut:
            return "\(store.lightsOut.litCount) lights on · \(moves(store.lightsOut.moves))"
        }
    }

    // MARK: Boards

    @ViewBuilder
    private var board: some View {
        switch store.selected {
        case .pairs: pairsBoard
        case .ticTacToe: ticTacToeBoard
        case .lightsOut: lightsOutBoard
        }
    }

    private var pairsBoard: some View {
        let p = store.pairs
        let side: CGFloat = p.size == .large ? 32 : 36
        return grid(columns: p.size.columns, count: p.cards.count, side: side, spacing: 6) { index in
            let revealed = p.isRevealed(index)
            let matched = p.matched.contains(index)
            Button { withAnimation(spring) { store.flipPair(index) } } label: {
                ZStack {
                    Image(systemName: PairsBoard.symbols[p.cards[index]])
                        .font(.system(size: side * 0.42, weight: .semibold))
                        .foregroundStyle(matched ? Color.green : Color.white)
                        .opacity(revealed ? 1 : 0)
                    Image(systemName: "questionmark")
                        .font(.system(size: side * 0.32, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .opacity(revealed ? 0 : 1)
                }
                // The card turns 180° face down; mirror its face back so the "?" reads correctly.
                .scaleEffect(x: reduceMotion || revealed ? 1 : -1, y: 1)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .notchSurface(cornerRadius: 8, tint: matched ? .green : (revealed ? .accentColor : nil), interactive: !revealed)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : (revealed ? 0 : 180)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(matched && !reduceMotion ? 0.94 : 1)
            .disabled(matched)
            .accessibilityLabel(revealed ? "Card \(index + 1), \(PairsBoard.symbols[p.cards[index]])" : "Card \(index + 1), face down")
        }
    }

    private var ticTacToeBoard: some View {
        let t = store.ticTacToe
        var winning: Set<Int> = []
        if case .win(_, let line) = t.outcome { winning = Set(line) }
        return grid(columns: 3, count: 9, side: 46, spacing: 6) { index in
            let mark = t.cells[index]
            Button { withAnimation(spring) { store.playTicTacToe(index) } } label: {
                Group {
                    switch mark {
                    case .x: Image(systemName: "xmark").foregroundStyle(Color.accentColor)
                    case .o: Image(systemName: "circle").foregroundStyle(Color.orange)
                    case nil: Color.clear
                    }
                }
                .font(.system(size: 20, weight: .bold))
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .notchSurface(cornerRadius: 10, tint: winning.contains(index) ? .green : nil,
                          interactive: mark == nil && t.outcome == nil)
            .disabled(mark != nil || t.outcome != nil || store.computerThinking)
            .accessibilityLabel("Square \(index + 1), " + (mark == .x ? "yours" : mark == .o ? "Mac" : "empty"))
        }
    }

    private var lightsOutBoard: some View {
        let l = store.lightsOut
        return grid(columns: LightsOutBoard.side, count: l.lights.count, side: 27, spacing: 5) { index in
            let on = l.lights[index]
            Button { withAnimation(spring) { store.pressLight(index) } } label: {
                Circle()
                    .fill(on ? Color.yellow : Color.white.opacity(0.06))
                    .shadow(color: on ? .yellow.opacity(0.7) : .clear, radius: on ? 6 : 0)
                    .padding(5)
                    .frame(width: 27, height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .notchSurface(cornerRadius: 7, interactive: true)
            .accessibilityLabel("Light \(index + 1), \(on ? "on" : "off")")
        }
    }

    private func grid<Cell: View>(columns: Int, count: Int, side: CGFloat, spacing: CGFloat,
                                  @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        // Deliberately no glass container: it blends a revealed card's tint into every neighbour.
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0..<(count / columns), id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in cell(row * columns + col) }
                }
            }
        }
    }

    // MARK: Result

    private var resultBanner: some View {
        VStack(spacing: 6) {
            Text(resultTitle).font(.system(size: 15, weight: .bold))
            if store.isNewBest {
                Label("New best", systemImage: "trophy.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.yellow)
            }
            Button("Play again") { withAnimation(spring) { store.newGame() } }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .notchSurfaceCapsule(tint: .accentColor, interactive: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        // Dark underlay so the result stays readable over a busy board.
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .notchSurface(cornerRadius: 16)
        .shadow(color: .black.opacity(0.5), radius: 16)
    }

    private var resultTitle: String {
        switch store.selected {
        case .pairs: return "All pairs in \(store.pairs.moves) moves"
        case .ticTacToe:
            switch store.ticTacToe.outcome {
            case .win(.x, _): return "You win!"
            case .win(.o, _): return "The Mac wins"
            default: return "It's a draw"
            }
        case .lightsOut: return "Lights out in \(store.lightsOut.moves) moves"
        }
    }

    private func moves(_ n: Int) -> String { n == 1 ? "1 move" : "\(n) moves" }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
