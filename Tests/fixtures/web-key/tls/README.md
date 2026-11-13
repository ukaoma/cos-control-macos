# Signer audit TLS fixtures (0.5.390)

Public certificate chains from Let's Encrypt's own test sites, used by `Tests/WebKeyChecks.swift` (`signerTLSTrust`) to prove
that `SignerTLSCore.trusted` accepts real Let's Encrypt chains against the macOS system roots ALONE, offline, at a pinned date.
They hold certificates only. There is no private key here.

| File | Leaf | Chain | Leaf valid |
|---|---|---|---|
| `valid-isrgrootx1.letsencrypt.org.pem` | RSA, CN valid-isrgrootx1.letsencrypt.org | leaf, YR1, Root YR (cross-signed by ISRG Root X1) | 2026-11-04 to 2027-02-02 |
| `valid-isrgrootx2.letsencrypt.org.pem` | ECDSA P-256 (like Tailscale's), CN valid-isrgrootx2.letsencrypt.org | leaf, YE1, Root YE (cross-signed by ISRG Root X2) | 2026-10-29 to 2027-01-27 |

Fetched 2026-11-10 with:

    echo | /usr/bin/openssl s_client -connect <host>:443 -servername <host> -showcerts \
      | awk '/-----BEGIN CERTIFICATE-----/{p=1} p{print} /-----END CERTIFICATE-----/{p=0}'

The checks evaluate them at 2026-12-01T00:00:00Z, inside both leaves' validity, so they keep passing after the leaves
expire. If macOS ever drops ISRG Root X1 or X2 from its system roots, the "audit public chain" checks fail on purpose.
