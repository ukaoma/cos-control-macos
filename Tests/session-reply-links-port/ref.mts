// 0.5.380 (Tests/session-reply-links-port/harness.py). Reference: the REAL server functions (session-links.ts imported; imageTokens lifted verbatim from
// agent-session-output-images.ts and transpiled, since it is not exported and importing that module runs it).
import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const SERVER = process.argv[2]
const [input, output] = [process.argv[3], process.argv[4]]
const { transformSync } = createRequire(SERVER + '/package.json')('esbuild')
const links = await import(SERVER + '/server/lib/session-links.ts')
const imgSrc = readFileSync(SERVER + '/server/lib/agent-session-output-images.ts', 'utf8')
const fn = /\nfunction imageTokens\([\s\S]*?\n}\n/.exec(imgSrc)![0]
const scan = Number(eval(/export const OUTPUT_IMAGE_SCAN_CHARS = ([0-9 *]+)\n/.exec(imgSrc)![1]))
const js = transformSync('type Candidate = { source: string; label: string }\n' + fn, { loader: 'ts' }).code
const imageTokens = new Function('OUTPUT_IMAGE_SCAN_CHARS', js + '\nreturn imageTokens')(scan)

const roots = { workspace: null, extra: [], home: '/nonexistent-cos-reader-links-home' }
const isSp = (c: string | undefined) => c === ' ' || c === '\t'

// The Mac-only assembly (removal whitespace and empty-line collapse), written independently of the Swift and Python.
function collapse(text: string, removals: number[], whole: boolean): string {
  if (!removals.length) return text
  const lines = text.split('\n')
  const starts: number[] = []; let acc = 0
  for (const l of lines) { starts.push(acc); acc += l.length + 1 }
  const touched = new Set<number>()
  for (const r of [...removals].sort((a, b) => a - b)) { let li = 0; for (let k = 0; k < starts.length; k++) if (starts[k] <= r) li = k; touched.add(li) }
  const blank = (l: string) => /^[ \t\r]*$/.test(l)
  const emptied = (l: string) => { const c = l.replace(/^[ \t\r]+|[ \t\r]+$/g, ''); return c === '' || /^[-*+]$/.test(c) || /^[0-9]{1,9}[.)]$/.test(c) }
  const kept: string[] = []; let dropped = false
  for (let k = 0; k < lines.length; k++) {
    if (k === lines.length - 1 && !whole) { kept.push(lines[k]); break }
    if (touched.has(k) && emptied(lines[k])) { dropped = true; continue }
    if (dropped && blank(lines[k]) && (kept.length ? blank(kept[kept.length - 1]) : true)) continue
    if (!blank(lines[k])) dropped = false
    kept.push(lines[k])
  }
  if (dropped && whole) while (kept.length && blank(kept[kept.length - 1])) kept.pop()
  return kept.join('\n')
}

function reader(raw: string) {
  const shortened = raw.length > scan
  const scanned = shortened ? raw.slice(0, raw.lastIndexOf('\n', scan - 1) + 1) : raw
  const candidates = imageTokens(scanned)
  const all = links.linkTokens(scanned)
  const linked = all.filter((l: any) => links.isLocalTarget(l.target) && !candidates.some((c: any) => l.start < c.end && c.start < l.end))
  const tokens = {
    images: candidates.map((c: any) => [c.start, c.end, c.source]),
    links: all.map((l: any) => [l.start, l.end, l.label, l.target, links.isLocalTarget(l.target)]),
    words: linked.map((l: any) => links.linkCardWords(l.label, links.resolveLinkTarget(l.target, [], roots).name, l.target)),
  }
  if (!candidates.length && !linked.length) return { tokens, text: null }
  const edits = [
    ...candidates.map((c: any) => ({ start: c.start, end: c.end, words: null as string | null })),
    ...linked.map((l: any, k: number) => ({ start: l.start, end: l.end, words: tokens.words[k] as string })),
  ].sort((a, b) => a.start - b.start)
  let out = ''; let end = 0; let removals: number[] = []
  for (const e of edits) {
    out += scanned.slice(end, e.start); end = e.end
    if (e.words !== null) { out += e.words; continue }
    const prev = out.length ? out[out.length - 1] : undefined
    const next = end < scanned.length ? scanned[end] : undefined
    if (isSp(next) && (prev === undefined || prev === '\n' || isSp(prev))) end++
    else if (next === undefined || next === '\n' || next === '\r') { out = out.replace(/[ \t]+$/, ''); removals = removals.map(r => Math.min(r, out.length)) }
    removals.push(out.length)
  }
  out += scanned.slice(end)
  return { tokens, text: collapse(out, removals, !shortened) + raw.slice(scanned.length) }
}

const cases: string[] = JSON.parse(readFileSync(input, 'utf8'))
writeFileSync(output, JSON.stringify(cases.map(reader)))
