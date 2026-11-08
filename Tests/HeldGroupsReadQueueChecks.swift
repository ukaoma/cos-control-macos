import Foundation

/// Fictional inventory and controllable suspensions only. No helper, EventKit, disk or network reads.
@main @MainActor struct HeldGroupsReadQueueChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ behavior: String, line: UInt = #line) {
        checks += 1
        if !condition { fatalError("Held groups read check failed at \(line): \(behavior)") }
    }

    @MainActor final class Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let ready = waiters; waiters = []
            ready.forEach { $0.resume() }
        }
    }

    static func main() async {
        snapshotChecks()
        await coalescedAndForcedChecks()
        await concurrentForceChecks()
        await cancelledWaiterChecks()
        await cancelledOwnerChecks()
        print("PASS: Held voice reads: \(checks) checks (inventory, compatibility, coalescing, force barrier and cancellation)")
    }

    static func snapshotChecks() {
        let sample: JSONValue = .object(["sessionId": .string("fixture"), "chunkIndex": .number(0)])
        let group: JSONValue = .object(["id": .string("group"), "members": .array([sample])])
        let inventory: [String: JSONValue] = ["state": .string("ready"), "groups": .array([group]), "loose": .array([sample])]
        let decoded = HeldGroupsReadSnapshot(inventory)
        check(decoded?.groups.first?.id == "group" && decoded?.loose.first?.sessionId == "fixture", "valid existing DTO identities are retained")
        check(decoded?.groups.first?.sampleCount == 1 && decoded?.groups.first?.seed.id == "fixture#0", "optional old-helper fields retain DTO defaults")
        var legacy = inventory; legacy["state"] = nil
        check(HeldGroupsReadSnapshot(legacy)?.state == "ready", "older successful helper without state is supported")
        let absent = HeldGroupsReadSnapshot(["state": .string("route_absent"), "groups": .array([]), "loose": .array([]), "pending": .number(0)])
        check(absent?.state == "route_absent" && absent?.groups.isEmpty == true, "older server route_absent payload remains supported")
        check(HeldGroupsReadSnapshot(["state": .string("ready"), "groups": .array([]), "loose": .array([])]) != nil, "empty successful inventory is a real answer")
        for key in ["groups", "loose"] {
            var missing = inventory; missing[key] = nil
            check(HeldGroupsReadSnapshot(missing) == nil, "missing \(key) inventory is refused")
            var wrong = inventory; wrong[key] = .object([:])
            check(HeldGroupsReadSnapshot(wrong) == nil, "malformed \(key) inventory is refused")
        }
        var badGroup = inventory; badGroup["groups"] = .array([.object(["id": .string("no-members")])])
        check(HeldGroupsReadSnapshot(badGroup) == nil, "an unidentifiable group is not silently dropped")
        var badLoose = inventory; badLoose["loose"] = .array([.object(["sessionId": .string("no-index")])])
        check(HeldGroupsReadSnapshot(badLoose) == nil, "an unidentifiable sample is not silently dropped")
        var refused = inventory; refused["state"] = .string("error")
        check(HeldGroupsReadSnapshot(refused) == nil, "an error payload cannot become ready")
    }

    static func coalescedAndForcedChecks() async {
        let queue = HeldGroupsReadQueue()
        let entered = Gate(), release = Gate()
        var reads = 0
        var events: [String] = []
        let first = Task { @MainActor in
            await queue.run(force: false) {
                reads += 1
                if reads == 1 {
                    events.append("active")
                    entered.open(); await release.wait()
                    events.append("active done")
                } else { events.append("coalesced") }
            }
        }
        await entered.wait()
        await queue.run(force: false) { events.append("wrong background closure") }
        await queue.run(force: false) { events.append("wrong second background closure") }
        check(reads == 1, "background calls return without starting concurrent reads")
        let forced = Task { @MainActor in await queue.run(force: true) { events.append("fresh forced") } }
        await Task.yield()
        check(events == ["active"], "force does not return or start while the old read is suspended")
        release.open()
        await first.value; await forced.value
        check(reads == 2, "multiple background requests coalesce into one follow-up")
        check(events == ["active", "active done", "coalesced", "fresh forced"], "force waits for the old cycle and then completes its own fresh read")
        await queue.run(force: false) { events.append("later") }
        check(events.last == "later", "queue releases after completion")
    }

    static func concurrentForceChecks() async {
        let queue = HeldGroupsReadQueue()
        let entered = Gate(), release = Gate()
        var active = 0, peak = 0
        var owners: [String] = []
        let first = Task { @MainActor in
            await queue.run(force: true) {
                active += 1; peak = max(peak, active); owners.append("first")
                entered.open(); await release.wait(); active -= 1
            }
        }
        await entered.wait()
        let second = Task { @MainActor in await queue.run(force: true) { active += 1; peak = max(peak, active); owners.append("second"); await Task.yield(); active -= 1 } }
        let third = Task { @MainActor in await queue.run(force: true) { active += 1; peak = max(peak, active); owners.append("third"); await Task.yield(); active -= 1 } }
        release.open()
        await first.value; await second.value; await third.value
        check(peak == 1, "concurrent force callers never overlap reads")
        check(owners.count == 3 && Set(owners) == ["first", "second", "third"], "every explicit force caller gets one fresh read")
    }

    static func cancelledWaiterChecks() async {
        let queue = HeldGroupsReadQueue()
        let entered = Gate(), release = Gate()
        var forcedReads = 0
        let first = Task { @MainActor in await queue.run(force: false) { entered.open(); await release.wait() } }
        await entered.wait()
        let cancelled = Task { @MainActor in await queue.run(force: true) { forcedReads += 1 } }
        cancelled.cancel()
        release.open()
        await first.value; await cancelled.value
        check(forcedReads == 0, "a cancelled waiter never starts a new read")
    }

    static func cancelledOwnerChecks() async {
        let queue = HeldGroupsReadQueue()
        let entered = Gate(), release = Gate()
        var reads = 0
        var sawCancellation = false
        let owner = Task { @MainActor in
            await queue.run(force: false) {
                reads += 1; entered.open(); await release.wait()
                sawCancellation = Task.isCancelled
            }
        }
        await entered.wait()
        await queue.run(force: false) { reads += 100 }
        owner.cancel(); release.open(); await owner.value
        check(sawCancellation, "cancelling the owner reaches the active read")
        check(reads == 1, "a cancelled cycle does not start its queued follow-up")
        await queue.run(force: true) { reads += 1 }
        check(reads == 2, "cancelled cycle releases the queue for a later force read")
    }
}
