// Golden vectors for COS Control's web-key half (every key here is a throwaway made at generation time), made by the SERVER's own code (cos-glasses-server 6.99.31 worktree,
// read only). Run: <server>/node_modules/.bin/tsx gen_control_golden.mts <server root> > web-key-golden.json
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createHash, randomBytes } from 'node:crypto'
const root = process.argv[2]
const reg = await import(join(root, 'server/lib/web-key-registry.ts'))
const kit = await import(join(root, 'server/lib/__fixtures__/web-key-kit.ts'))
const env = await import(join(root, 'server/lib/web-key-envelope.ts'))
const shared = await import(join(root, 'shared/web-turn-envelope.ts'))
const { WebKeyRegistry, WebKeyEnrollments, audOf, sasOf } = reg
const { p256, signB64, signJcs, SELF_DNS, ORIGIN, passkeyOf, credentialIdOf, passkeyAssertion, coseOf, anchorRegistrationBody, anchoredEntry, seedRegistry } = kit
const dir = mkdtempSync(join(tmpdir(), 'ctl-golden-'))
let clock = 1_786_000_000_000
const file = join(dir, 'web-keys.json')
const anchor = p256()
const registry0 = new WebKeyRegistry(file, join(dir, 'audit.jsonl'), () => clock)
// 1. The anchor statement, accepted by registerAnchor.
const body = anchorRegistrationBody(anchor, clock)
const registered = registry0.registerAnchor(body, 'control')
if (!registered.ok) throw new Error('anchor refused ' + registered.reason)
const anchorD = (anchor.privateKey.export({ format: 'jwk' }) as { d: string }).d
// 2. A proven enrollment, pendingView as Control reads it.
const DEVICE = '100.64.0.9'
const registry = new WebKeyRegistry(file, join(dir, 'audit.jsonl'), () => clock)
const enroll = new WebKeyEnrollments(registry, { now: () => clock, deviceAllowed: (r: string) => r === DEVICE })
const phone = p256()
const r = randomBytes(32)
const label = 'Miles’s iPhone "Duo" \\ é'
const userAgent = 'Mozilla/5.0 (iPhone) Safari tab\u0009end'
const s = enroll.start({ spki: phone.spki, label, userAgent, remote: '::ffff:' + DEVICE, sasCommit: env.sha256Hex(r) }, { selfDnsName: SELF_DNS, origin: ORIGIN })
if (!s.ok) throw new Error('start ' + s.reason)
const passkey = passkeyOf(phone)
const msg = WebKeyEnrollments.proofMessage({ ...s, phoneNonce: r.toString('base64url'), passkeyCredentialId: credentialIdOf(phone), passkeySpkiSha256: env.sha256Hex(passkey.der) })
const challenge = createHash('sha256').update(env.canonicalBytes(msg)!).digest()
const assertion = passkeyAssertion(passkey, challenge, { credentialId: credentialIdOf(phone) })
const p = enroll.prove({ enrollId: s.enrollId, signature: signJcs(phone, msg), phoneNonce: r.toString('base64url'), passkey: { credentialId: credentialIdOf(phone), publicKey: coseOf(passkey), assertion } })
if (!p.ok) throw new Error('prove ' + p.reason)
const view = enroll.pendingView()!
const nodeSig = signB64(anchor, Buffer.from(view.approvalJcs as string, 'base64url'))
// 3. The server's revocation digest for a list with two revoked keys, and its key list.
const k1 = p256(), k2 = p256(), k3 = p256()
const file2 = join(dir, 'web-keys-2.json')
seedRegistry(file2, anchor, [anchoredEntry(anchor, k1), anchoredEntry(anchor, k2), anchoredEntry(anchor, k3)], 0)
const registry2 = new WebKeyRegistry(file2, join(dir, 'audit2.jsonl'), () => clock)
clock += 1000; registry2.revoke(k2.kid, 'lost', 'token')
clock += 1000; registry2.revoke(k1.kid, 'lost', 'web')
const out = {
  generatedBy: 'gen_control_golden.mts (cos-glasses-server 6.99.31 worktree code)',
  selfDns: SELF_DNS,
  anchor: { spki: anchor.spki, d: anchorD, spkiSha256: env.sha256Hex(anchor.der), fingerprint: env.fingerprintOfSpki(anchor.der), kid: env.kidOfSpki(anchor.der),
            aud: audOf(anchor.der, SELF_DNS), statement: body.statement, createdAt: 1_786_000_000_000, registered: registered.ok },
  pending: view,
  pendingJson: JSON.stringify(view),
  expect: { sas: p.sas, fingerprint: p.fingerprint, kid: phone.kid, label, userAgent: userAgent.replace(/[\u0000-\u001f\u007f]/g, ' '), remote: DEVICE, epoch: registry.epoch(), nodeAnchorSig: nodeSig,
            approveAccepted: enroll.approve(s.enrollId, nodeSig, SELF_DNS).ok },
  sasVector: { challenge: randomBytes(32).toString('base64url'), spki: phone.spki, r: randomBytes(32).toString('base64url') } as Record<string, string>,
  revocation: { epoch: registry2.epoch(), list: registry2.list(SELF_DNS), revocations: registry2.revocations(), digest: registry2.revocationDigest() },
  jcs: [
    { value: { b: 1, a: [true, false, null, 'x y'], 'é': 'q"\\\n\u0001\u007f', A: 0 }, text: '' },
    { value: { z: { y: [1, 2, { b: 'c', a: 'd' }] }, aa: -5 }, text: '' },
    { value: { ctl: '\b\f\t\r\u001f\u0000 end', 'Z': 'upper', '_': 'under', '~': 'tilde', '\u00e9t\u00e9': '\ud83d\ude00' }, text: '' },
  ],
}
out.sasVector.sas = sasOf(Buffer.from(out.sasVector.challenge, 'base64url'), Buffer.from(out.sasVector.spki, 'base64url'), Buffer.from(out.sasVector.r, 'base64url'))
for (const j of out.jcs) j.text = shared.canonicalJson(j.value)
process.stdout.write(JSON.stringify(out, null, 2) + '\n')
rmSync(dir, { recursive: true, force: true })
