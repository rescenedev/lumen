import SwiftUI

/// Launches the app. All real code lives in this (testable) library module;
/// the thin `Lumen` executable target just imports it and calls this. Splitting
/// the app into a library + a 2-line executable is what lets the test runner
/// link against the code (executable targets aren't linkable).
public func runLumenApp() {
    LumenApp.main()
}
