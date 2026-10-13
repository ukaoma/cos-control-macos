import Foundation

// Home city (server 6.71.13): the store against a stand-in helper. Pins the contract the Settings field relies on:
// a 404 hides the setting, a 400 shows the server's own sentence, Save sends PUT through `set-home-area` with
// homeCity on stdin, and a blank field sends "" (the server's clear). No server, helper binary or account.
@main struct HomeAreaChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name); count += 1 }
        func reply(_ status: Int, _ fields: [String: JSONValue] = [:], message: String = "Home city") -> HelperResponse {
            var details = fields; details["httpStatus"] = .number(Double(status))
            return HelperResponse(ok: true, message: message, details: details)
        }
        final class Calls { var log: [(args: [String], body: [String: String]?)] = [] }
        func fake(_ calls: Calls, _ answers: [HelperResponse]) -> HomeAreaStore.Run {
            var queue = answers
            return { args, input in
                let body = input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                calls.log.append((args, body))
                return queue.removeFirst()
            }
        }

        // 1. A server from before the route answers 404: the setting is hidden, never an error.
        let old = HomeAreaStore(); let oldCalls = Calls()
        await old.load(fake(oldCalls, [reply(404, message: "Needs server 6.71.13")]))
        check(oldCalls.log.first?.args == ["home-area"] && oldCalls.log.first?.body == nil, "load is a plain GET (`home-area`, no stdin)")
        check(old.availability == .unsupported && !old.visible, "404 hides the setting")
        check(old.error == nil, "404 is not shown as an error")
        old.draft = "Austin, TX"
        await old.save(fake(oldCalls, [reply(200)]))
        check(oldCalls.log.count == 1, "a hidden setting never sends a save")

        // 2. A current server: the field shows the saved city and the effective line.
        let store = HomeAreaStore(); let calls = Calls()
        await store.load(fake(calls, [reply(200, ["homeCity": .null, "effective": .object(["text": .string("Tulsa"), "source": .string("phone_area")])])]))
        check(store.visible && store.saved == nil && store.draft.isEmpty, "a current server shows the field, empty when no city is set")
        check(store.effectiveLine == "Fact checks use your phone's area: Tulsa", "phone area line")
        check(!store.changed, "an untouched empty field has nothing to save")

        // 3. Save sends PUT through set-home-area with homeCity, and the server's answer becomes the shown value.
        store.draft = "  Austin,   TX "
        check(store.changed, "an edited field can be saved")
        await store.save(fake(calls, [reply(200, ["homeCity": .string("Austin, TX"), "effective": .object(["text": .string("Austin, TX"), "source": .string("profile")])], message: "Home city saved")]))
        check(calls.log.last?.args == ["set-home-area"], "save is the PUT command (`set-home-area`)")
        check(calls.log.last?.body == ["homeCity": "Austin, TX"], "save sends homeCity, spaces collapsed")
        check(store.saved == "Austin, TX" && store.draft == "Austin, TX", "the saved city fills the field")
        check(store.effectiveLine == "Fact checks start from Austin, TX", "profile line after save")

        // 4. A 400 shows the server's sentence inline and keeps the saved value and the typed text.
        store.draft = "123 Main St"
        let refusal = "Use a city and state, like Austin, TX. Letters only, no street address."
        await store.save(fake(calls, [reply(400, ["error": .string(refusal)], message: refusal)]))
        check(calls.log.last?.body == ["homeCity": "123 Main St"], "the refused text was what was sent")
        check(store.error == refusal, "400 shows the server's message")
        check(store.visible && store.saved == "Austin, TX" && store.draft == "123 Main St", "a refusal changes neither the saved city nor the field")
        store.draft = "123 Main"
        check(store.error == nil, "the next edit clears the refusal")

        // 5. Blank sends "" (the clear), never nil and never an omitted key.
        store.draft = "   "
        check(store.changed, "clearing a saved city is a change")
        await store.save(fake(calls, [reply(200, ["homeCity": .null, "effective": .null])]))
        check(calls.log.last?.args == ["set-home-area"] && calls.log.last?.body == ["homeCity": ""], "blank sends homeCity \"\"")
        check(store.saved == nil && store.draft.isEmpty, "cleared")
        check(store.effectiveLine == "No starting point is set yet.", "nothing set line")

        // 6. A helper failure (server unreachable) is shown, not swallowed, once the setting is visible.
        store.draft = "Kansas City, MO"
        let failing: HomeAreaStore.Run = { _, _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not reach the glasses server."]) }
        await store.save(failing)
        check(store.error == "Could not reach the glasses server." && store.visible, "unreachable is a sentence under the field")
        check(HomeArea.payload("") == ["homeCity": ""], "payload of an empty field")
        check(!HomeArea.caption.contains("\u{2014}") && !HomeArea.caption.contains("\u{2192}"), "caption has no em dash or arrow")
        print("PASS Home city: \(count) checks")
    }
}
