// Verifies that `AtollState` (typealias of the real SwiftUI.State, see local/shims/AtollState.swift)
// keeps state across body re-evaluations, supports $binding, init(initialValue:) and optionals.
import SwiftUI
import AppKit
typealias AtollState<Value> = SwiftUI.State<Value>

var bodyCount = 0
var observed: [String] = []
final class Probe { var bump: (() -> Void)?; var setViaBinding: ((Int) -> Void)?; var read: (() -> Int)? }
let probe = Probe()

struct Child: View {
    @Binding var v: Int
    var body: some View { Text("child \(v)").onAppear { probe.setViaBinding = { v = $0 } } }
}
struct V: View {
    @AtollState private var count = 0
    @AtollState private var opt: String?
    @AtollState var seeded: Int = 1
    @AtollState private var inited: Int
    @AtollState private var tick = 0   // forces parent re-evaluation
    init(n: Int) { _inited = AtollState(initialValue: n) }
    var body: some View {
        bodyCount += 1
        return VStack {
            Text("count=\(count) opt=\(opt ?? "nil") inited=\(inited) tick=\(tick)")
            Child(v: $count)
        }.onAppear {
            probe.bump = { count += 1 }
            probe.read = { count }
        }
    }
}
struct Host: View { @AtollState var parentTick = 0
    var body: some View { VStack { V(n: parentTick == 0 ? 7 : 99); Text("\(parentTick)") }.onAppear { DispatchQueue.main.asyncAfter(deadline: .now()+0.3){ parentTick += 1 } } } }

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let hv = NSHostingView(rootView: Host())
let win = NSWindow(contentRect: NSRect(x:0,y:0,width:300,height:200), styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = hv
win.orderBack(nil)
func spin(_ t: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: t)) }
var failures = 0
func expect(_ cond: Bool, _ what: String) { print(cond ? "PASS" : "FAIL", what); if !cond { failures += 1 } }
spin(0.2)
let bodyCountAfterMount = bodyCount
expect(probe.read?() == 0, "initial value 0 after mount")
probe.bump?(); probe.bump?(); spin(0.1)
expect(probe.read?() == 2, "mutation through @AtollState setter persists (2 bumps)")
probe.setViaBinding?(10); spin(0.1)
expect(probe.read?() == 10, "mutation through child @Binding ($count) lands in parent state")
spin(0.6) // parent re-evaluates V with a different init argument
expect(bodyCount > bodyCountAfterMount + 2, "parent body re-evaluated")
expect(probe.read?() == 10, "state survives parent re-evaluation (not reset to initial)")
exit(failures == 0 ? 0 : 1)
