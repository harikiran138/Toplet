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

/// Owns the Games tab's boards. A single shared instance, so a game in progress survives the
/// notch closing and reopening; best results and preferences persist in UserDefaults.
@MainActor
final class NotchGamesStore: ObservableObject {
    static let shared = NotchGamesStore()

    private let defaults: UserDefaults
    private var hideMismatchTask: Task<Void, Never>?
    private var computerTask: Task<Void, Never>?

    @Published var selected: NotchGameKind {
        didSet { defaults.set(selected.rawValue, forKey: Keys.selected) }
    }

    // Pairs
    @Published private(set) var pairs: PairsBoard
    @Published var pairsSize: PairsBoard.Size {
        didSet {
            defaults.set(pairsSize.rawValue, forKey: Keys.pairsSize)
            if oldValue != pairsSize { newPairs() }
        }
    }

    // Tic-Tac-Toe: the human is X; who opens alternates every game.
    @Published private(set) var ticTacToe = TicTacToeBoard()
    @Published private(set) var humanStarts = true
    @Published private(set) var computerThinking = false
    @Published var difficulty: TicTacToeBoard.Difficulty {
        didSet { defaults.set(difficulty.rawValue, forKey: Keys.difficulty) }
    }

    // Lights Out
    @Published private(set) var lightsOut = LightsOutBoard()

    /// True for the finished game that beat the stored best; drives the "New best" badge.
    @Published private(set) var isNewBest = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = NotchGameKind(rawValue: defaults.string(forKey: Keys.selected) ?? "") ?? .pairs
        let size = PairsBoard.Size(rawValue: defaults.integer(forKey: Keys.pairsSize)) ?? .medium
        pairsSize = size
        pairs = PairsBoard(size: size)
        difficulty = TicTacToeBoard.Difficulty(rawValue: defaults.string(forKey: Keys.difficulty) ?? "") ?? .relaxed
    }

    func newGame() {
        isNewBest = false
        switch selected {
        case .pairs: newPairs()
        case .ticTacToe: newTicTacToe()
        case .lightsOut: lightsOut = LightsOutBoard()
        }
    }

    var isFinished: Bool {
        switch selected {
        case .pairs: return pairs.isWon
        case .ticTacToe: return ticTacToe.outcome != nil
        case .lightsOut: return lightsOut.isSolved
        }
    }

    // MARK: Pairs

    func flipPair(_ index: Int) {
        hideMismatchTask?.cancel()
        guard pairs.flip(index, now: Date()) else { return }
        if pairs.showsMismatch {
            // Long enough to memorise both cards; a tap on a third card hides them sooner.
            hideMismatchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                self?.pairs.hideMismatch()
            }
        } else if pairs.isWon {
            recordPairs()
        }
    }

    func bestPairs(_ size: PairsBoard.Size) -> (moves: Int, seconds: Int)? {
        let moves = defaults.integer(forKey: Keys.pairsBestMoves(size))
        guard moves > 0 else { return nil }
        return (moves, defaults.integer(forKey: Keys.pairsBestSeconds(size)))
    }

    private func newPairs() {
        hideMismatchTask?.cancel()
        isNewBest = false
        pairs = PairsBoard(size: pairsSize)
    }

    private func recordPairs() {
        let seconds = Int(pairs.elapsed(now: Date()).rounded())
        let best = bestPairs(pairs.size)
        // Fewer moves wins; the time breaks a tie.
        if best == nil || pairs.moves < best!.moves || (pairs.moves == best!.moves && seconds < best!.seconds) {
            defaults.set(pairs.moves, forKey: Keys.pairsBestMoves(pairs.size))
            defaults.set(seconds, forKey: Keys.pairsBestSeconds(pairs.size))
            isNewBest = true
        }
    }

    // MARK: Tic-Tac-Toe

    var ticTacToeRecord: (wins: Int, losses: Int, draws: Int) {
        (defaults.integer(forKey: Keys.tttWins), defaults.integer(forKey: Keys.tttLosses), defaults.integer(forKey: Keys.tttDraws))
    }

    func playTicTacToe(_ index: Int) {
        guard !computerThinking, ticTacToe.play(index, as: .x) else { return }
        if ticTacToe.outcome != nil { recordTicTacToe(); return }
        scheduleComputerMove()
    }

    private func newTicTacToe() {
        computerTask?.cancel()
        computerThinking = false
        ticTacToe = TicTacToeBoard()
        humanStarts.toggle()
        if !humanStarts { scheduleComputerMove() }
    }

    private func scheduleComputerMove() {
        computerThinking = true
        computerTask = Task { [weak self] in
            // A short pause reads as the Mac "thinking" instead of an instant snap.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            var rng = SystemRandomNumberGenerator()
            if let move = self.ticTacToe.bestMove(for: .o, difficulty: self.difficulty, using: &rng) {
                self.ticTacToe.play(move, as: .o)
            }
            self.computerThinking = false
            if self.ticTacToe.outcome != nil { self.recordTicTacToe() }
        }
    }

    private func recordTicTacToe() {
        switch ticTacToe.outcome {
        case .win(.x, _): defaults.set(ticTacToeRecord.wins + 1, forKey: Keys.tttWins)
        case .win(.o, _): defaults.set(ticTacToeRecord.losses + 1, forKey: Keys.tttLosses)
        case .draw: defaults.set(ticTacToeRecord.draws + 1, forKey: Keys.tttDraws)
        case nil: return
        }
        objectWillChange.send()
    }

    // MARK: Lights Out

    var bestLightsOut: Int? {
        let moves = defaults.integer(forKey: Keys.lightsBest)
        return moves > 0 ? moves : nil
    }

    func pressLight(_ index: Int) {
        guard lightsOut.press(index), lightsOut.isSolved else { return }
        if bestLightsOut.map({ lightsOut.moves < $0 }) ?? true {
            defaults.set(lightsOut.moves, forKey: Keys.lightsBest)
            isNewBest = true
        }
    }

    private enum Keys {
        static let selected = "notchGames.selected"
        static let pairsSize = "notchGames.pairs.size"
        static let difficulty = "notchGames.ticTacToe.difficulty"
        static let tttWins = "notchGames.ticTacToe.wins"
        static let tttLosses = "notchGames.ticTacToe.losses"
        static let tttDraws = "notchGames.ticTacToe.draws"
        static let lightsBest = "notchGames.lightsOut.bestMoves"
        static func pairsBestMoves(_ size: PairsBoard.Size) -> String { "notchGames.pairs.\(size.title).bestMoves" }
        static func pairsBestSeconds(_ size: PairsBoard.Size) -> String { "notchGames.pairs.\(size.title).bestSeconds" }
    }
}
