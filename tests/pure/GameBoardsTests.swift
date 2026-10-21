// Tests for the GameBoards rules (run by tests/pure/run.sh).
import Foundation
var failures = 0
func check(_ c: Bool, _ msg: String, _ line: Int = #line) { if !c { failures += 1; print("FAIL \(line): \(msg)") } }
struct Seeded: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
var rng = Seeded(s: 42)
let t0 = Date(timeIntervalSince1970: 1000)
// Pairs
for size in PairsBoard.Size.allCases {
    var b = PairsBoard(size: size, using: &rng)
    check(b.cards.count == size.columns * size.rows, "grid \(size.title)")
    check(Dictionary(grouping: b.cards, by: { $0 }).values.allSatisfy { $0.count == 2 }, "two of each")
    // solve perfectly
    var byValue: [Int: [Int]] = [:]; for (i, v) in b.cards.enumerated() { byValue[v, default: []].append(i) }
    for (_, idx) in byValue.sorted(by: { $0.key < $1.key }) { b.flip(idx[0], now: t0); b.flip(idx[1], now: t0.addingTimeInterval(30)) }
    check(b.isWon && b.moves == size.rawValue, "perfect solve in \(size.rawValue) moves, got \(b.moves)")
    check(b.elapsed(now: t0.addingTimeInterval(999)) == 30, "elapsed freezes at finish")
    check(!b.flip(0, now: t0), "no flips after win")
}
var p = PairsBoard(size: .small, using: &rng)
let a = 0, other = p.cards.indices.first { $0 != 0 && p.cards[$0] != p.cards[0] }!
p.flip(a, now: t0); check(!p.flip(a, now: t0), "same card twice ignored")
p.flip(other, now: t0); check(p.showsMismatch && p.moves == 1, "mismatch shows")
let third = p.cards.indices.first { $0 != a && $0 != other }!
p.flip(third, now: t0); check(p.faceUp == [third], "third tap hides mismatch immediately")
// Tic-tac-toe: perfect never loses against every human line of play
func explore(_ board: TicTacToeBoard) -> Int {  // returns number of human wins found
    if let o = board.outcome { if case .win(.x, _) = o { return 1 }; return 0 }
    var wins = 0
    for i in board.emptyCells {
        var b = board; b.play(i, as: .x)
        if b.outcome == nil, let m = b.bestMove(for: .o, difficulty: .perfect, using: &rng) { b.play(m, as: .o) }
        wins += explore(b)
    }
    return wins
}
let start = Date(); check(explore(TicTacToeBoard()) == 0, "perfect AI never loses"); print("full game tree in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
var t = TicTacToeBoard(cells: [.o, .o, nil, .x, .x, nil, nil, nil, nil])
check(t.bestMove(for: .o, difficulty: .perfect, using: &rng) == 2, "takes the win")
t = TicTacToeBoard(cells: [.x, .x, nil, .o, nil, nil, nil, nil, nil])
check(t.bestMove(for: .o, difficulty: .perfect, using: &rng) == 2, "blocks")
check(TicTacToeBoard.outcome(of: [.x, .o, .x, .x, .o, .o, .o, .x, .x]) == .draw, "draw")
// Lights out
for _ in 0..<50 { let l = LightsOutBoard(using: &rng); check(!l.isSolved, "scrambled") }
var l = LightsOutBoard(lights: Array(repeating: false, count: 25)); 
var l2 = l; l2 = LightsOutBoard(lights: { var v = Array(repeating: false, count: 25); for i in [0, 1, 5] { v[i] = true }; return v }())
check(l2.press(0) && l2.isSolved && l2.moves == 1, "corner press clears its cross")
check(!l.press(3), "solved board ignores presses")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
