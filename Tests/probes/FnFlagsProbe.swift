import CoreGraphics
import Foundation

// By hand only (0.5.329 dictation lock): hold the real Fn (globe) key once while this runs. Every 100 ms for 10 s it
// prints the raw CGEventSource.flagsState(.hidSystemState) and whether .maskSecondaryFn is set, so the hidSystemState
// up read the lock fix relies on can be confirmed on real hardware. Reads flags only: posts no event, opens no window,
// needs no permission. Build: Tests/compile-guard.sh swiftc Tests/probes/FnFlagsProbe.swift -o fn-flags-probe
let start = Date()
for tick in 0..<100 {
    let flags = CGEventSource.flagsState(.hidSystemState)
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print(String(format: "%5d ms  tick %3d  raw 0x%016llx  fn %@", ms, tick, flags.rawValue, flags.contains(.maskSecondaryFn) ? "DOWN" : "up"))
    fflush(stdout)
    Thread.sleep(forTimeInterval: 0.1)
}
