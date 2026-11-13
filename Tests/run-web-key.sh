#!/bin/zsh
# Phone approvals (server 6.99.31, COS_WEB_KEY_AUTHORITY, default off). Sources/WebKeyCore.swift and HelperSources/PairingCore.swift
# compiled alone with Tests/WebKeyChecks.swift (ONE compile, through Tests/compile-guard.sh), run against vectors the server's
# own code made (Tests/fixtures/web-key/golden.json), then the pins (Tests/web-key-pins.py). No keychain, no Secure Enclave, no
# Touch ID, no helper, no server: every effect is a stand-in, and state files go to a temporary folder.
set -euo pipefail
ROOT="${0:A:h:h}"
DIR="$(mktemp -d /tmp/cos-web-key.XXXXXX)"
trap 'rm -rf "$DIR"' EXIT
# 0.5.390, the signer audit's TLS trust (SignerTLSCore): a throwaway root, a second root and a ts.net leaf, minted for this run
# with /usr/bin/openssl like Tailscale's pair (P-256, SHA-256, SAN only, serverAuth). Nothing here is trusted by the Mac and no
# key is committed; the folder goes with $DIR.
TLS="$DIR/tls"
mkdir -m 700 "$TLS"
print -r -- $'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:example-mac.tail00000a.ts.net' > "$TLS/leaf.cnf"
# Two roots with different names and keys (with prompt=no the config's CN wins over -subj, so each gets its own config).
for NAME in root other; do
  print -r -- "[req]"$'\n'"distinguished_name=dn"$'\n'"prompt=no"$'\n'"[dn]"$'\n'"CN=COS web key check $NAME"$'\n'"[v3]"$'\n'"basicConstraints=critical,CA:true"$'\n'"keyUsage=critical,keyCertSign,cRLSign"$'\n'"subjectKeyIdentifier=hash" > "$TLS/$NAME.cnf"
  /usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$TLS/$NAME-key.pem" 2>/dev/null
  /usr/bin/openssl req -new -x509 -sha256 -days 30 -key "$TLS/$NAME-key.pem" -config "$TLS/$NAME.cnf" -extensions v3 -out "$TLS/$NAME.pem" 2>/dev/null
done
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$TLS/leaf-key.pem" 2>/dev/null
/usr/bin/openssl req -new -sha256 -key "$TLS/leaf-key.pem" -subj "/CN=example-mac.tail00000a.ts.net" -out "$TLS/leaf.csr" 2>/dev/null
/usr/bin/openssl x509 -req -sha256 -days 20 -in "$TLS/leaf.csr" -CA "$TLS/root.pem" -CAkey "$TLS/root-key.pem" -CAcreateserial -extfile "$TLS/leaf.cnf" -out "$TLS/leaf.pem" 2>/dev/null
cat "$TLS/leaf.pem" "$TLS/root.pem" > "$TLS/leaf-chain.pem"
/usr/bin/python3 "$ROOT/Tests/kit-compile.py" "$ROOT/Tests/compile-guard.sh" swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete -parse-as-library \
  "$ROOT/Sources/WebKeyCore.swift" "$ROOT/HelperSources/PairingCore.swift" "$ROOT/Tests/WebKeyChecks.swift" -o "$DIR/web-key-checks"
OUT="$(TMPDIR="$DIR/" COS_WEB_KEY_TLS_DIR="$TLS" "$DIR/web-key-checks" "$ROOT/Tests/fixtures/web-key/golden.json")" || { print -r -- "$OUT"; exit 1; }
print -r -- "$OUT"
# A machine-dependent check that could not run says SKIP; it is counted and reported, never passed silently (0.5.390).
SKIPPED="$(print -r -- "$OUT" | grep -c '^SKIP ' || true)"
print -r -- "web key checks skipped: $SKIPPED"
COUNT="${${OUT##*checks: }%% passed*}"
# A floor on the count: a check that silently stops running must fail this, not pass it. 0.5.390: 292 on a Mac with mkcert;
# the floor leaves out only the 4 machine-dependent mkcert checks, which SKIP (counted above) where mkcert is absent.
(( COUNT >= 288 )) || { print -u2 "web key checks ran only $COUNT (expected at least 288)"; exit 1; }
/usr/bin/python3 "$ROOT/Tests/web-key-pins.py" "$ROOT"
