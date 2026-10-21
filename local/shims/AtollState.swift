// Local-build shim (generated copy lives in local/.work; source of truth is
// local/shims/AtollState.swift). Compiled into every module whose sources
// contain `@State`.
//
// SDK 27 declares `State` as BOTH a struct (a normal @propertyWrapper) and a
// macro (SwiftUIMacros.StateMacro). Without Xcode the macro plugin is absent,
// so any `@State` fails to compile, and a same-named local type does not
// shadow the macro. `local/prepare.py` therefore rewrites `@State` to
// `@AtollState`, and this alias maps that to the real SwiftUI.State struct:
// semantics (storage in the view graph, persistence across body updates,
// `$x` projected Binding, init(initialValue:)) are SwiftUI's own.
import SwiftUI

typealias AtollState<Value> = SwiftUI.State<Value>
