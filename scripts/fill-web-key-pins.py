#!/usr/bin/env python3
"""Fill releases[<version>] in Resources/web-key-assets.json from a FROZEN server tarball's own manifest bytes.

Usage: python3 -I scripts/fill-web-key-pins.py <server tarball> <web-key-assets.json> <version>

The two hashes are derived here from the tarball members package/server/web-control/.manifest.json and
package/server/web-signer/.manifest.json (bytes as packed, final newline included), never typed by hand. Nothing is
extracted to disk. The tarball must say it is <version>, both manifests must be regular files in Control's shape
(v 1, sha256, the five signer paths), and the result must pass the rules WebKeyAssetsCore.pins enforces. Anything
else refuses with exit 1 and writes nothing. See Resources/web-key-assets.README.md.
"""
import hashlib, json, re, sys, tarfile

SIGNER_PATHS = {"/index.html", "/signer-proof.js", "/signer-store.js", "/signer.js", "/signer.css"}


def refuse(why):
    sys.exit("fill-web-key-pins: " + why)


if len(sys.argv) != 4:
    refuse("usage: fill-web-key-pins.py <server tarball> <web-key-assets.json> <version>")
tgz, out, version = sys.argv[1:4]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    refuse("version must be exactly major.minor.patch")

with tarfile.open(tgz, "r:gz") as t:
    members = {m.name: m for m in t.getmembers()}

    def read(name):
        m = members.get(name)
        if m is None or not m.isfile() or m.issym() or m.islnk():
            refuse(name + " is missing or not a regular file")
        return t.extractfile(m).read()

    if json.loads(read("package/package.json")).get("version") != version:
        refuse("the tarball is not " + version)
    digests = {}
    for key, name in (("webControlManifestSha256", "package/server/web-control/.manifest.json"),
                      ("webSignerManifestSha256", "package/server/web-signer/.manifest.json")):
        data = read(name)
        body = json.loads(data)
        files = body.get("files") if isinstance(body, dict) else None
        if not isinstance(body, dict) or set(body) != {"v", "algorithm", "files"} or type(body["v"]) is not int or body["v"] != 1 or body["algorithm"] != "sha256" \
                or not isinstance(files, dict) or not files \
                or not all(isinstance(v, str) and re.fullmatch(r"[0-9a-f]{64}", v) for v in files.values()):
            refuse(name + " is not a v1 sha256 manifest")
        if key == "webSignerManifestSha256" and set(files) != SIGNER_PATHS:
            refuse(name + " does not list exactly the five signer files")
        digests[key] = hashlib.sha256(data).hexdigest()

with open(out) as f:
    pins = json.load(f)
if not isinstance(pins, dict) or set(pins) != {"v", "releases"} or type(pins["v"]) is not int or pins["v"] != 1 or not isinstance(pins["releases"], dict):
    refuse(out + " is not a v1 pin file")
pins["releases"][version] = digests
if len(pins["releases"]) > 32:
    refuse("more than 32 releases")
with open(out, "w") as f:
    f.write(json.dumps(pins, separators=(",", ":")) + "\n")
print(json.dumps(pins, separators=(",", ":")))
