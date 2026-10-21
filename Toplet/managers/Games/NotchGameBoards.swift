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

// Pure game rules for the Games tab: no SwiftUI, no timers, no storage, so every rule is testable
// on its own. NotchGamesStore owns the boards and adds timing (mismatch hide, computer move delay).

enum NotchGameKind: String, CaseIterable, Identifiable {
    case pairs, ticTacToe, lightsOut
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pairs: return "Pairs"
        case .ticTacToe: return "Tic-Tac-Toe"
        case .lightsOut: return "Lights Out"
        }
    }

    var symbol: String {
        switch self {
        case .pairs: return "square.grid.2x2.fill"
        case .ticTacToe: return "number"
        case .lightsOut: return "lightbulb.fill"
        }
    }

    var howToPlay: String {
        switch self {
        case .pairs: return "Flip two cards at a time and match every pair."
        case .ticTacToe: return "Get three in a row before the Mac does."
        case .lightsOut: return "A tap flips a light and its neighbours. Turn them all off."
        }
    }
}

// MARK: - Pairs

struct PairsBoard: Equatable {
    enum Size: Int, CaseIterable, Identifiable {
        case small = 6, medium = 8, large = 12 // number of pairs
        var id: Int { rawValue }
        var columns: Int { self == .large ? 6 : 4 }
        var rows: Int { rawValue * 2 / columns }
        var title: String { "\(columns)×\(rows)" }
    }

    static let symbols = ["star.fill", "heart.fill", "bolt.fill", "leaf.fill", "moon.fill", "flame.fill",
                          "drop.fill", "cloud.fill", "bell.fill", "music.note", "paperplane.fill", "sun.max.fill"]

    let size: Size
    private(set) var cards: [Int]
    /// Cards turned up and not yet matched; at most two.
    private(set) var faceUp: [Int] = []
    private(set) var matched: Set<Int> = []
    private(set) var moves = 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?

    init<R: RandomNumberGenerator>(size: Size, using rng: inout R) {
        self.size = size
        cards = (0..<size.rawValue).flatMap { [$0, $0] }.shuffled(using: &rng)
    }

    init(size: Size) {
        var rng = SystemRandomNumberGenerator()
        self.init(size: size, using: &rng)
    }

    var isWon: Bool { matched.count == cards.count }
    /// Two different cards are showing and will be turned back.
    var showsMismatch: Bool { faceUp.count == 2 }
    func isRevealed(_ index: Int) -> Bool { faceUp.contains(index) || matched.contains(index) }

    /// Turns a card up. Tapping a third card while a mismatch shows hides the mismatch at once,
    /// so a fast player never waits for the animation. Returns false when the tap does nothing.
    @discardableResult
    mutating func flip(_ index: Int, now: Date) -> Bool {
        guard cards.indices.contains(index), !isWon, !isRevealed(index) else { return false }
        if faceUp.count == 2 { faceUp.removeAll() }
        if startedAt == nil { startedAt = now }
        faceUp.append(index)
        if faceUp.count == 2 {
            moves += 1
            if cards[faceUp[0]] == cards[faceUp[1]] {
                matched.formUnion(faceUp)
                faceUp.removeAll()
                if isWon { finishedAt = now }
            }
        }
        return true
    }

    mutating func hideMismatch() {
        if faceUp.count == 2 { faceUp.removeAll() }
    }

    func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

// MARK: - Tic-Tac-Toe

struct TicTacToeBoard: Equatable {
    enum Mark: Equatable {
        case x, o
        var other: Mark { self == .x ? .o : .x }
    }

    enum Outcome: Equatable {
        case win(Mark, line: [Int])
        case draw
    }

    enum Difficulty: String, CaseIterable, Identifiable {
        case relaxed, perfect
        var id: String { rawValue }
        var title: String { self == .relaxed ? "Relaxed" : "Perfect" }
    }

    static let lines = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]]

    private(set) var cells: [Mark?] = Array(repeating: nil, count: 9)

    init() {}
    init(cells: [Mark?]) { self.cells = cells }

    var outcome: Outcome? { Self.outcome(of: cells) }
    var emptyCells: [Int] { cells.indices.filter { cells[$0] == nil } }

    @discardableResult
    mutating func play(_ index: Int, as mark: Mark) -> Bool {
        guard cells.indices.contains(index), cells[index] == nil, outcome == nil else { return false }
        cells[index] = mark
        return true
    }

    /// The computer's reply. Perfect never loses (full minimax over at most 9! positions, instant at
    /// this size); Relaxed plays a random empty square about a third of the time, so it can be beaten.
    func bestMove<R: RandomNumberGenerator>(for mark: Mark, difficulty: Difficulty, using rng: inout R) -> Int? {
        let empty = emptyCells
        guard !empty.isEmpty, outcome == nil else { return nil }
        if difficulty == .relaxed, Double.random(in: 0..<1, using: &rng) < 0.35 {
            return empty.randomElement(using: &rng)
        }
        var best: (index: Int, score: Int)?
        for index in empty {
            var next = cells
            next[index] = mark
            let score = -Self.negamax(next, toMove: mark.other, depth: 1)
            if best == nil || score > best!.score { best = (index, score) }
        }
        return best?.index
    }

    /// Score from the point of view of `toMove`: +10 for a win, sooner wins score higher.
    private static func negamax(_ cells: [Mark?], toMove: Mark, depth: Int) -> Int {
        switch outcome(of: cells) {
        case .win(let winner, _): return winner == toMove ? 10 - depth : depth - 10
        case .draw: return 0
        case nil: break
        }
        var best = Int.min
        for index in cells.indices where cells[index] == nil {
            var next = cells
            next[index] = toMove
            best = max(best, -negamax(next, toMove: toMove.other, depth: depth + 1))
        }
        return best
    }

    static func outcome(of cells: [Mark?]) -> Outcome? {
        for line in lines {
            if let mark = cells[line[0]], cells[line[1]] == mark, cells[line[2]] == mark {
                return .win(mark, line: line)
            }
        }
        return cells.contains(where: { $0 == nil }) ? nil : .draw
    }
}

// MARK: - Lights Out

struct LightsOutBoard: Equatable {
    static let side = 5
    private(set) var lights: [Bool]
    private(set) var moves = 0

    /// Starts from the solved board and applies random presses, so every puzzle can be solved.
    init<R: RandomNumberGenerator>(presses: Int = 8, using rng: inout R) {
        lights = Array(repeating: false, count: Self.side * Self.side)
        repeat {
            for index in Array(lights.indices).shuffled(using: &rng).prefix(presses) {
                toggleCross(index)
            }
        } while isSolved
    }

    init(presses: Int = 8) {
        var rng = SystemRandomNumberGenerator()
        self.init(presses: presses, using: &rng)
    }

    init(lights: [Bool]) { self.lights = lights }

    var isSolved: Bool { !lights.contains(true) }
    var litCount: Int { lights.filter { $0 }.count }

    @discardableResult
    mutating func press(_ index: Int) -> Bool {
        guard lights.indices.contains(index), !isSolved else { return false }
        toggleCross(index)
        moves += 1
        return true
    }

    private mutating func toggleCross(_ index: Int) {
        let row = index / Self.side, col = index % Self.side
        for (r, c) in [(row, col), (row - 1, col), (row + 1, col), (row, col - 1), (row, col + 1)]
        where (0..<Self.side).contains(r) && (0..<Self.side).contains(c) {
            lights[r * Self.side + c].toggle()
        }
    }
}
