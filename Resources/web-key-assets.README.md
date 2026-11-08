# Phone signer asset pins

`web-key-assets.json` is copied into the signed Control bundle. The release owner fills it only after freezing the exact matched server package:

```json
{"v":1,"releases":{"7.0.0":{"webControlManifestSha256":"<sha256 of server/web-control/.manifest.json bytes>","webSignerManifestSha256":"<sha256 of server/web-signer/.manifest.json bytes>"}}}
```

The version is the exact managed server package version. Hash the manifest file bytes, including their final newline. No wildcard, fallback, runtime learning, environment override, or writable on-disk trust cache is supported. Missing pins and unsupported versions disable enrollment. The checked-in empty map is intentionally unusable until the release owner pins the frozen server.

The helper locates this resource only beside its actual executable inside COS Control.app, refuses symlinks, and verifies the complete app's Developer ID signature, team NV3X46LLCR and bundle identity before reading it. It then validates managed generation identity, both installed manifest hashes and every installed asset hash, the server's reported integrity hashes, and all five signer assets fetched over certificate-verified HTTPS pinned to the owned loopback listener. No pairing token is sent to signer assets. Audit receipts include booleans and stable reasons, not private paths or server response text.

Pure fixture tests may parse synthetic pins and compare synthetic bytes. They cannot override the production bundle lookup or grant authority to an unsigned test helper. Physical phone enrollment, Touch ID, the protected-state Keychain canary, committed anchor maturity, and receiver consumption remain separate acceptance checks.
