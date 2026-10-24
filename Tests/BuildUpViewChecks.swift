import AppKit
import SwiftUI

/// 0.5.343 Build-up, in place: the REAL COSBuildUp, live (no frozen frame), hosted off screen and driven by wall-clock time
/// while a stand-in loader flips its loading state, the way a call site's model does. COSBuildUpProbe reports every frame
/// the stage draws and every breadcrumb, so these checks watch the real view and state code run:
///   - a load that lands at 200 ms, 600 ms and 1.2 s draws a wire whose outline only grows, frame to frame, with no jump
///     (the 6.10.654 landing snap), lands, and then draws no more frames at all;
///   - a load inside the grace draws nothing; an empty answer hands off and stops; each logs one breadcrumb, counts only;
///   - a slow load draws, then stands still with no frames at all until its data lands;
///   - a view this session has seen reopens quietly: no frames, no breadcrumb.
/// No window is ordered in, no event is sent, nothing becomes active. Prints "build up view: N checks".
@main @MainActor struct BuildUpViewChecks {
    static var ran = 0
    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "") {
        ran += 1
        if !condition { print("check failed [\(behavior)]: \(detail())"); exit(1) }
    }

    final class Loader: ObservableObject {
        @Published var loading = true
        @Published var landed = false
    }

    struct Host: View {
        @ObservedObject var loader: Loader
        let label: String
        var body: some View {
            COSBuildUp(.rows(4), loading: loader.loading && !loader.landed, landed: loader.landed, label: label) {
                if loader.landed {
                    VStack(spacing: 6) { ForEach(0..<4, id: \.self) { Text("Row \($0)").cosRowCard() } }
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if loader.loading {
                    ProgressView("Loading rows…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No rows yet.").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    struct Run {
        var frames: [(t: Double, phase: COSBuildUpMachine.Phase, drawT: Double, outline: Double)] = []
        var crumbs: [String] = []
    }

    /// Opens the host, flips the loader at `at` seconds (landed with data, or ended empty), and keeps it on screen `for`.
    static func run(_ label: String, at: Double, landed: Bool, for seconds: Double) -> Run {
        var result = Run()
        let start = ProcessInfo.processInfo.systemUptime
        COSBuildUpProbe.frame = { _, phase, drawT, outline in
            result.frames.append((ProcessInfo.processInfo.systemUptime - start, phase, drawT, outline))
        }
        COSBuildUpProbe.breadcrumb = { result.crumbs.append($0) }
        defer { COSBuildUpProbe.frame = nil; COSBuildUpProbe.breadcrumb = nil }
        let loader = Loader()
        let host = NSHostingView(rootView: Host(loader: loader, label: label).frame(width: 520, height: 420).background(COSPalette.panel))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        defer { window.close() }
        var flipped = false
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            if !flipped, ProcessInfo.processInfo.systemUptime - start >= at {
                flipped = true
                if landed { loader.landed = true } else { loader.loading = false }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        return result
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        COSBuildUpSession.memory = COSBuildUpMemory()

        for (index, land) in [0.2, 0.6, 1.2].enumerated() {
            let label = "Loading rows \(index)"
            let at = COSBuildUpPlan.graceSeconds + land
            let seconds = at + COSBuildUpPlan.landDuration(count: 4) + 1.0
            let run = run(label, at: at, landed: true, for: seconds)
            let drawn = run.frames.filter { $0.phase == .building || $0.phase == .landing }
            check(drawn.count >= 6, "live frames", "land at \(land) s: the real stage drew \(drawn.count) frames")
            check(drawn.first.map { $0.outline < 0.35 } == true, "landing continuous", "land at \(land) s: the first frame starts the draw: \(drawn.first?.outline ?? -1)")
            check(drawn.contains { $0.phase == .landing } && drawn.contains { $0.phase == .building }, "live frames", "land at \(land) s: built, then landed")
            let raw = run.frames.map(\.drawT)
            check(zip(raw, raw.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 }, "landing continuous", "land at \(land) s: the draw clock never resets")
            for (a, b) in zip(drawn, drawn.dropFirst()) where b.phase == a.phase || b.phase == .landing {
                let grown = b.outline - a.outline
                // A frame can be late; the outline may only grow as fast as the draw itself allows over that gap.
                let room = COSBuildUpPlan.look(0, drawT: b.drawT, landT: nil).outline - COSBuildUpPlan.look(0, drawT: a.drawT, landT: nil).outline + 0.02
                check(grown <= room, "landing continuous", "land at \(land) s: the shown outline jumped \(a.outline) to \(b.outline) (room \(room))")
            }
            // The draw clock is the wall clock since the build began: never reset, never jumped ahead by a landing.
            if let first = drawn.first {
                let began = first.t - first.drawT
                for frame in drawn {
                    check(abs(frame.drawT - (frame.t - began)) < 0.06, "landing continuous",
                          "land at \(land) s: the draw clock read \(frame.drawT) at \(frame.t - began) s into the build (\(frame.phase))")
                    let allowed = COSBuildUpPlan.look(0, drawT: frame.t - began + 0.06, landT: nil).outline
                    check(frame.outline <= allowed + 1e-9, "landing continuous",
                          "land at \(land) s: the outline showed \(frame.outline), more than \(allowed) could have drawn by then")
                }
            }
            let last = run.frames.last?.t ?? 0
            check(last < seconds - 0.4, "frames stop", "land at \(land) s: frames still drawn at \(last) of \(seconds) s")
            check(run.crumbs.count == 1 && run.crumbs[0].hasPrefix("build-up rows outcome=landed rows="), "breadcrumb", "\(run.crumbs)")
            check(!run.crumbs[0].contains(label) && !run.crumbs[0].contains("Row"), "breadcrumb", "counts only: \(run.crumbs[0])")
        }

        let fast = run("Loading rows fast", at: 0.05, landed: true, for: 0.6)
        check(fast.frames.isEmpty, "grace skips build", "a fast load drew \(fast.frames.count) frames")
        check(fast.crumbs == ["build-up rows outcome=direct rows=4 ms=" + (fast.crumbs.first?.split(separator: "=").last.map(String.init) ?? "")],
              "breadcrumb", "\(fast.crumbs)")

        let empty = run("Loading rows empty", at: 0.6, landed: false, for: 1.6)
        check(empty.frames.contains { $0.phase == .handoff }, "error handoff", "the wire faded out")
        check((empty.frames.last?.t ?? 0) < 1.3, "frames stop", "frames still drawn at \(empty.frames.last?.t ?? 0)")
        check(empty.crumbs.count == 1 && empty.crumbs[0].hasPrefix("build-up rows outcome=empty"), "breadcrumb", "\(empty.crumbs)")

        // A slow load: the wire draws, stands still (no frames at all) until the data, then lands.
        let slow = run("Loading rows slow", at: 6.0, landed: true, for: 7.2)
        let still = slow.frames.filter { $0.t > COSBuildUpPlan.graceSeconds + COSBuildUpPlan.pulseSeconds + 0.3 && $0.t < 5.95 }
        check(!slow.frames.isEmpty && still.isEmpty, "frames stop", "\(still.count) frames while the wire stood still waiting")
        check(slow.frames.contains { $0.phase == .landing } && slow.crumbs.count == 1 && slow.crumbs[0].hasPrefix("build-up rows outcome=landed"),
              "live frames", "it still lands: \(slow.crumbs)")

        let again = run("Loading rows 0", at: 0.6, landed: true, for: 1.2)
        check(again.frames.isEmpty && again.crumbs.isEmpty, "reopen quiet", "a seen view built again: \(again.frames.count) frames, \(again.crumbs)")

        print("build up view: \(ran) checks; the real stage drew, landed with no jump and stopped; the grace, the hand-off and a quiet reopen")
    }
}
