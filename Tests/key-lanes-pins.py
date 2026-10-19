#!/usr/bin/env python3
"""K1 P10 key lanes: the wiring pins and the copy parity, over source. What each pin protects is in its name.

- Copy parity: every key-lane string Control shows that the lens also shows comes from P8's catalog
  (server/lib/key-notices.ts at 8385336, vendored at Tests/fixtures/key-lanes/key-notices-8385336.ts with its SHA-256
  pinned here). When the P8 worktree is on this Mac, the vendored copy is also compared with the commit itself.
- Hooks: exactly one Settings row in the panel, exactly one optional step (in the Ready stage) and one install latch in
  the setup window, and the keyed-session guard at the top of each Continue and Fork entry point.
- The key: never drawn, never in argv (the helper reads it from stdin only), no sheet or dialog.
Prints "key lanes pins: N passed". Usage: key-lanes-pins.py <repo root>"""
import hashlib, pathlib, re, subprocess, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
read = lambda rel: (root / rel).read_text(encoding='utf-8')
passed = 0
def check(value, name):
    global passed
    if not value:
        print(f'key lanes pin FAILED: {name}'); sys.exit(1)
    passed += 1

core, views, panel, setup = read('Sources/KeyLanes.swift'), read('Sources/KeyLanesViews.swift'), read('Sources/Views.swift'), read('Sources/ControlSetup.swift')
model, work, helper, status = read('Sources/ControllerModel.swift'), read('Sources/WorkHandoffStore.swift'), read('HelperSources/main.swift'), read('HelperSources/ProviderStatusCore.swift')
guide = read('Sources/ProviderConnectModel.swift')

# ── Copy parity with P8.
FIXTURE = 'Tests/fixtures/key-lanes/key-notices-8385336.ts'
ts = read(FIXTURE)
check(hashlib.sha256(ts.encode()).hexdigest() == 'f4ffe178361e2cb463bcd0f6f0f1593fe7e8152e3094b4dbec4d685f091e35fb', 'the vendored P8 catalog is the 8385336 blob')
p8 = pathlib.Path.home() / 'cos-worktrees/kl-k1-p8'
if p8.exists():
    live = subprocess.run(['git', '-C', str(p8), 'show', '8385336:server/lib/key-notices.ts'], capture_output=True, text=True)
    if live.returncode == 0:
        check(live.stdout == ts, 'the vendored P8 catalog equals P8 at 8385336')

def swift_string(name):
    m = re.search(r'static let ' + re.escape(name) + r' = "((?:[^"\\]|\\.)*)"', core)
    check(m is not None, f'KeyLanes.{name} is a literal')
    return m.group(1)

for name, ts_text in (('keyedSessionRefusal', "keyed_session: () => 'This session ran on your key. Continue it from COS.'"),
                      ('downgradeLine', "downgrade: () => 'Remove your keys first. Older COS cannot see them.'"),
                      ('noCreditLimitLine', "no_credit_limit: () => 'Set a credit limit on this key at openrouter.ai first.'")):
    check(ts_text in ts, f'P8 still says {name}')
    check(f"'{swift_string(name)}'" in ts_text, f'{name} matches P8 byte for byte')
# The breaker line is a template in P8 over BREAKER_LIMITS (3 failures, 1 hour in the frozen P1 contract).
check("breaker_open: () => `Key paused ${hours} hour${hours === 1 ? '' : 's'} after ${BREAKER_LIMITS.failures} failures.`" in ts, 'P8 breaker template')
check(swift_string('breakerLine') == 'Key paused 1 hour after 3 failures.', 'the breaker line is P8 at 3 failures, 1 hour')
check("key_rejected: p => put('Your {f} was rejected. Fix it in COS Control.', providerCopy(p.keyKind).key)" in ts, 'P8 key rejected template')
check('"Your \\(keyName(kind)) was rejected. Fix it in COS Control."' in core, 'the key rejected line is P8 with the provider key name')
for kind, key in (('openrouter', 'OpenRouter key'), ('anthropic', 'Anthropic key'), ('openai', 'OpenAI key'), ("'openai-compatible'", 'endpoint key')):
    check(re.search(re.escape(kind) + r": \{ key: '" + re.escape(key) + "'", ts) is not None, f'P8 names the {kind} key "{key}"')
    check(f'"{kind.strip(chr(39))}": "{key}"' in core, f'Control names the {kind} key "{key}"')

# ── Setup guide keys the install decision reads.
for key in ('cos.setupGuide.journeyFinished', 'cos.setupGuide.glassesHandled', 'cos.setupGuide.hidden'):
    check(f'"{key}"' in guide and f'"{key}"' in core, f'the install decision reads SetupGuideState key {key}')

# ── Hooks.
check(panel.count('KeyLanesSettingsRow(model: model)') == 1, 'one Settings row in the panel')
check(panel.index('TranscriptionSettingsCard(store: model.transcriptionSettings, model: model)') < panel.index('KeyLanesSettingsRow(model: model)')
      < panel.index('                utilities\n'), 'the Settings row sits after Transcription, before Utilities')
check(setup.count('KeyLanesSetupStep(model: model)') == 1, 'one optional step in setup')
ready = setup[setup.index('        case .ready:'):setup.index('        case .guide:')]
check('KeyLanesSetupStep(model: model)' in ready, 'the optional step is in the Ready stage only (after local setup)')
check(setup.count('.background(KeyLanesInstallLatch(model: model))') == 1, 'one install latch, in a background (no layout place)')
for name, src in (('Views.swift', panel), ('ControlSetup.swift', setup)):
    code_lines = [l for l in src.splitlines() if 'KeyLanes' in l and not l.strip().startswith('//')]
    check(len(code_lines) == (1 if name == 'Views.swift' else 2), f'{name} carries only the hook')

def body(src, signature):
    start = src.index(signature)
    return src[start:start + 1600]
for signature, src, guard in (
        ('    func sendChatMessage() {', model, 'if let line = KeyLanes.refusal(sessionID: session.sessionId) { chatRefusal = line; return }'),
        ('    func forkChatThread() {', model, 'if let line = KeyLanes.refusal(sessionID: session.sessionId) { chatRefusal = line; return }'),
        ('    func submit(source: WorkSource, mode: WorkHandoffMode,', work, 'if mode != .newSession, let line = KeyLanes.refusal(sessionID: session?.nativeID) { error = line; return }'),
        ('    func forkToPlatform(source: WorkSource,', work, 'if let line = KeyLanes.refusal(sessionID: session.nativeID) { error = line; return }')):
    b = body(src, signature)
    check(guard in b, f'the keyed-session refusal is displayed by {signature.strip()}')
    head = b[b.index(') async {\n') if ') async {\n' in b[:600] else b.index('() {\n'):]
    check(guard in '\n'.join(head.splitlines()[:4]), f'the refusal comes before anything runs in {signature.strip()}')
check(model.count('KeyLanes.refusal(') == 2 and work.count('KeyLanes.refusal(') == 2, 'four guards, no more')

# ── The helper verb.
check(helper.count('case "key-lanes": try emitKeyLanes(args: args)') == 1, 'one key-lanes verb in the helper')
fn = helper[helper.index('    private func emitKeyLanes(args: [String]) throws {'):]
fn = fn[:fn.index('\n    }\n') + 6]
check('readBoundedStdin(KeyLanesHelperCore.stdinLimit)' in fn, 'the helper reads a key from bounded stdin')
check('option(' not in fn and 'environment' not in fn.lower(), 'the helper never takes a key from argv or the environment')
check('log(' not in fn.lower().replace('catalog', '') and 'print(' not in fn and fn.count('secret') == 5,
      'the helper never logs or prints the key (it is only held for the answer check)')
check('enum KeyLanesHelperCore' in status, 'the grammar and whitelist live in ProviderStatusCore.swift')

# ── The app: the key is pasted, held only until Save, never drawn and never put in arguments.
check('static func keyInput(' in core and '["save-key"], input, run: run' in core, 'the app sends the key as stdin input, not arguments')
check(re.search(r'\["key-lanes"[^\]]*secret', core) is None and re.search(r'\[[^\]]*"save-key"[^\]]*secret', core) is None, 'the key is never put in argv')
check('NSPasteboard.general.string(forType: .string)' in views and 'SecureField' not in views, 'the key comes by paste only')
check(re.search(r'Text\(\s*(pending|secret)\s*[)?!]', views) is None and '\\(pending' not in views and '\\(secret' not in views
      and '$pending' not in views and 'Text(pending.map { KeyLanes.pendingLine(kind: kind, secret: $0) }' in views,
      'the pasted key is drawn only as its kind and last four')
check('pending = nil' in views.split('Button(KeyLanes.saveLabel)')[1].split('Task {')[0], 'Save key drops the view\'s copy before it sends')
for name, src in (('KeyLanes.swift', core), ('KeyLanesViews.swift', views)):
    check('.sheet(' not in src and '.confirmationDialog(' not in src and '.alert(' not in src, f'{name}: inline confirmations only (COSConfirm)')
    check(not any(ch in src for ch in '—–→'), f'{name}: no em dash, en dash or arrow')
check(views.count('.cosConfirm(') == 2, 'Remove and Remove all keys each confirm first')
for action, button in (('store.removeAll(', 'Button(KeyLanes.removeAllLabel) { removingAll = true }'), ('store.removeKey(', 'Button(KeyLanes.removeLabel) { removing = key.ref }')):
    runs = [l for l in views.splitlines() if action in l]
    check(len(runs) == 1 and '.destructive(' in runs[0], f'{action} runs only from its confirmation')
    check(button in views, f'the button only opens the confirmation ({button.split("{")[0].strip()})')

# ── Build lists.
run_sh, release = read('Tests/run.sh'), read('scripts/build-release.sh')
check(run_sh.count('"$ROOT/Sources/KeyLanes.swift" "$ROOT/Sources/KeyLanesViews.swift"') == 3, 'the suite compiles the key-lane files with the app (3 lists)')
check(release.count('"$ROOT/Sources/KeyLanes.swift" "$ROOT/Sources/KeyLanesViews.swift"') == 1, 'the release build compiles them')
check('Tests/key-lanes-helper-checks.py' in run_sh and 'Tests/run-key-lanes.sh' in run_sh, 'the full suite runs the key-lane lanes')
print(f'key lanes pins: {passed} passed')
