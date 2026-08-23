#!/usr/bin/env python3
"""Every toggle in the menu-bar panel must be bound from `status`.

The panel refreshes `model.status` on its own and nothing else. A toggle seeded
from any other source renders whatever that source was initialised to, forever,
unless something the user may never do happens to load it.

"Show Claude sessions" was seeded from `model.claudeSessionsEnabled`, which only
`loadClaudeSessions()` sets -- and every caller of that lives in ActivityWindow,
never in the panel. The box rendered false while the setting was true; Miles
enabled it four times against a control that could not show him anything else.
The comment above it named the hazard ("only accurate once that has loaded") and
it shipped anyway.

TWO WEAKER VERSIONS OF THIS CHECK BOTH PASSED THE MUTATION that reverted the
toggle to its broken source, which is why the matching below is as specific as it
is:

  whole-line matching   satisfied by a `model.status.x == nil` guard that assigned
                        from somewhere else entirely.
  4-line window         satisfied by the NEIGHBOURING toggle's status read: every
                        seed in `onAppear` sits within four lines of another one.

So the value itself must come from status -- either assigned directly, or bound by
an `if let <token> = model.status...` that governs the assignment.
"""
import io
import re
import sys

path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
# Comments explain this rule in prose in the file being checked; matching them
# would let the explanation satisfy the assertion.
lines = [l for l in src.split('\n') if not l.strip().startswith('//')]
code = '\n'.join(lines)

declared = sorted(set(re.findall(r'@State private var (selected\w+)', code)))
if not declared:
    raise SystemExit('no selected* toggle state found - did the panel move?')

WINDOW = 4
failures = []

for name in declared:
    idx = [i for i, l in enumerate(lines) if re.search(r'\b' + name + r'\s*=[^=]', l)]
    if not idx:
        failures.append(f'{name} is declared but never assigned')
        continue

    bound = False
    for i in idx:
        m = re.search(r'\b' + name + r'\s*=\s*([^\n{}]+)', lines[i])
        rhs = m.group(1).strip().rstrip('}').strip() if m else ''
        if 'model.status.' in rhs:
            bound = True
            break
        token = re.match(r'^(\w+)$', rhs)
        if token:
            window = '\n'.join(lines[max(0, i - WINDOW):i + 1])
            if re.search(r'if let ' + token.group(1) + r'\s*=\s*model\.status\.', window):
                bound = True
                break
    if not bound:
        failures.append(
            f'{name} is never bound from model.status. The panel only refreshes '
            f'status, so this toggle renders its initial value regardless of the '
            f'real setting. Publish the flag in health -> status and read it here.'
        )

if failures:
    for f in failures:
        print(f'  FAIL: {f}', file=sys.stderr)
    raise SystemExit(1)

print(f'  panel toggles bound from status: {len(declared)} checked')
