import AppKit
import Foundation

/// Reply in the message reader (D4; Miles 2026-11-11 13:59). The words against Control Web's (server 6.99.12, cos-chat.js
/// replyHtml), the session rule, the model pick, the effort gate, and the reply store's run (DropItStore.reply) against a
/// stand-in Ask job. Compiled with Sources/DropIt.swift and Sources/Models.swift alone (Tests/run-message-reply.sh).
@main struct MessageReplyChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ label: String) { if !ok { failures += 1; print("FAIL: \(label)") } }

    static func checkWords() {
        // The web's own strings, character for character (cos-chat.js:1548-1551, composerHtml's hint without Drop).
        check(MessageReply.title == "Reply", "[words] the block is titled Reply")
        check(MessageReply.label(no: 486) == "Reply to Message #486" && MessageReply.label(no: nil) == "Reply", "[words] the box is Reply to Message #N, or Reply")
        check(MessageReply.continuesLine == "Continues this conversation. The answer lands in Messages with its own number.", "[words] the continue line is the web's")
        check(MessageReply.startsLine == "Starts a conversation. The answer lands in Messages with its own number.", "[words] the start line is the web's")
        let all = [MessageReply.title, MessageReply.label(no: 1), MessageReply.continuesLine, MessageReply.startsLine]
        check(all.allSatisfy { !$0.contains("Miles") && !$0.contains("\u{2014}") && !$0.contains("\u{2192}") }, "[copy] no name, em dash or arrow")
    }

    static func checkSession() {
        check(MessageReply.session("a1b2c3d4-0000-4000-8000-123456789abc") == "a1b2c3d4-0000-4000-8000-123456789abc", "[session] a server session id is continued")
        check(MessageReply.subline(sessionId: "a1b2c3d4-0000-4000-8000-123456789abc") == MessageReply.continuesLine, "[session] with one it says it continues")
        check(MessageReply.session("") == nil && MessageReply.subline(sessionId: "") == MessageReply.startsLine, "[session] none: it starts a conversation, and says so")
        check(MessageReply.session("../x") == nil && MessageReply.session("short") == nil && MessageReply.session(String(repeating: "a", count: 81)) == nil,
              "[session] an id the helper would refuse is never sent; the reply starts fresh and says so")
        let a = MessageReply.target(turnID: "t-486", replyID: "r1"), b = MessageReply.target(turnID: "t-486", replyID: "r2")
        check(a.hasPrefix("cos:reply:t-486:") && a != b, "[target] one run target per reply, so two replies to one turn are two runs")
    }

    static func checkModelAndEffort() {
        // The web's menu (cos-chat.js modelsFrom): Claude Opus, Fable, Sonnet, then the engines by the model each runs; no Haiku.
        let catalog: [(id: String, available: Bool, resolved: String?)] = [
            ("sonnet", true, nil), ("opus", true, nil), ("fable", true, nil), ("haiku", true, nil),
            ("codex-frontier", true, "gpt-5.5-codex"), ("codex-balanced", true, nil), ("cursor-grok", false, "grok-4"),
            ("cursor-composer", false, nil), ("ollama", true, "  ")]
        let menu = MessageReply.menu(catalog)
        check(menu.map(\.id) == ["opus", "fable", "sonnet", "codex-frontier", "codex-balanced", "ollama"], "[menu] the web's order; Haiku is not on it; Cursor only when ready")
        check(menu.map(\.label) == ["Claude Opus", "Claude Fable", "Claude Sonnet", "Codex gpt-5.5-codex", "Codex Balanced", "Ollama"],
              "[menu] the web's names: a Claude tier by name, an engine by the model it runs, else the web's fallback word")
        check(MessageReply.menu([("opus", false, nil), ("sonnet", true, nil)]).map(\.id) == ["sonnet"], "[menu] a model this Mac cannot run is not offered")
        check(MessageReply.menu([("codex-frontier", true, String(repeating: "m", count: 80))]).first?.label.count == 48, "[menu] a label is at most 48 characters, as on the web")
        check(MessageReply.model(picked: nil, menu: menu) == "sonnet", "[model] nothing picked: Sonnet, as on the web")
        check(MessageReply.model(picked: "opus", menu: menu) == "opus", "[model] a pick on the menu is used, Opus included")
        check(MessageReply.model(picked: "haiku", menu: menu) == "sonnet" && MessageReply.model(picked: "gone", menu: menu) == "sonnet",
              "[model] a pick that is off the menu falls back to Sonnet")
        check(MessageReply.model(picked: nil, menu: [MessageReply.Choice(id: "codex-frontier", label: "Codex")]) == "codex-frontier", "[model] no Sonnet: the menu's first")
        check(MessageReply.available(catalog) && !MessageReply.available([("sonnet", false, nil), ("haiku", true, nil)]) && !MessageReply.available([]),
              "[shown] Reply shows only where the menu has a model to run it")
        check(MessageReply.modelGoneLine.hasPrefix("The model you picked is not available"), "[model] a pick that went away refuses with a line, never a substitute")
        let served: [String: [WorkEffortChoice]] = ["claude": [WorkEffortChoice(value: "high", label: "High"), WorkEffortChoice(value: "xhigh", label: "Extra High")]]
        check(MessageReply.effortChoices(provider: "claude", efforts: served).map(\.value) == ["high", "xhigh"], "[effort] the server's efforts for the model's agent")
        check(MessageReply.effortChoices(provider: "codex", efforts: served).isEmpty && MessageReply.effortChoices(provider: "claude", efforts: [:]).isEmpty,
              "[effort] none served (7.0.18) or none for this agent: no Effort, never an invented list")
        check(MessageReply.effortOffered("xhigh", provider: "claude", efforts: served) && !MessageReply.effortOffered("max", provider: "claude", efforts: served)
              && !MessageReply.effortOffered("high", provider: "codex", efforts: served), "[effort] an effort goes only with a model whose agent was offered it")
        check(MessageReply.modelKey == "cos.messageReply.model" && MessageReply.effortKey == "cos.messageReply.effort", "[keep] per-Mac picks under new keys")
    }

    @MainActor static func checkStore() async {
        let store = DropItStore()
        var calls: [(target: String, prompt: String, session: String?)] = []
        store.askJob = { target, prompt, _, session, _ in calls.append((target, prompt, session)); return .started("1a1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b") }
        let session = "a1b2c3d4-0000-4000-8000-123456789abc"
        check(await store.reply("  which slide moved? ", to: "turn-486", session: session), "[reply] a reply starts")
        check(calls.count == 1 && calls[0].prompt == "which slide moved?" && calls[0].session == session && calls[0].target.hasPrefix("cos:reply:turn-486:"),
              "[reply] it sends the words, trimmed, with the turn's session, on its own target")
        check(store.asks.count == 1 && store.asks[0].replyTo == "turn-486" && !store.asks[0].threaded, "[reply] it is kept as this turn's reply, never a COS thread Ask")
        // A session the server refuses: once more, fresh, so the reply is never lost.
        calls = []
        var answers: [DropItStore.AskStart] = [.refused("That conversation has ended."), .started("2a1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b")]
        store.askJob = { target, prompt, _, session, _ in calls.append((target, prompt, session)); return answers.removeFirst() }
        check(await store.reply("and the appendix?", to: "turn-486", session: session), "[retry] a refused session starts fresh")
        check(calls.count == 2 && calls[0].session == session && calls[1].session == nil && calls[0].target != calls[1].target,
              "[retry] the second try carries no session and its own target")
        // No session: no retry, and a refusal says why.
        calls = []
        store.askJob = { target, prompt, _, session, _ in calls.append((target, prompt, session)); return .refused("Work is busy. Try again in a minute.") }
        check(await store.reply("fresh one", to: "turn-12", session: nil) == false && calls.count == 1 && calls[0].session == nil
              && store.line == "Work is busy. Try again in a minute.", "[refused] a reply with no session that did not start says why, once")
        check(await store.reply("   ", to: "turn-12", session: nil) == false && calls.count == 1, "[empty] an empty box sends nothing")
        store.askJob = nil
        check(await store.reply("held", to: "turn-12", session: nil) == false && store.line == DropIt.askHeldLine, "[unwired] no run: the held line")
    }

    @MainActor static func main() async {
        checkWords()
        checkSession()
        checkModelAndEffort()
        await checkStore()
        if failures > 0 { print("MessageReplyChecks: \(failures) failed"); exit(1) }
        print("MessageReplyChecks: words, session, model and effort, reply store PASS")
    }
}
