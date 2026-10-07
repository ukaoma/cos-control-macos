#!/usr/bin/env python3
"""Build-time only: stage the pinned Node/npm distribution inside the app.

End users need neither Python, Homebrew nor a system Node installation.
The committed SHA, not a checksum downloaded alongside an archive, is trusted.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def stage(destination):
    pin = json.loads((ROOT / "Resources/node-runtime.json").read_text())
    archive_name = pin["archive"]
    prefix = archive_name.removesuffix(".tar.gz")
    with tempfile.TemporaryDirectory(prefix="cos-node-") as tmp:
        archive = Path(tmp) / archive_name
        url = f'https://nodejs.org/dist/v{pin["version"]}/{archive_name}'
        with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
            raise RuntimeError("Node runtime checksum mismatch; refusing to package")
        # Exact pinned bytes. Additionally reject escaping paths, devices and links.
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                path = Path(member.name)
                if path.is_absolute() or ".." in path.parts or path.parts[0] != prefix:
                    raise RuntimeError("Unsafe Node archive path")
                if member.isdev() or member.islnk():
                    raise RuntimeError("Unsupported Node archive member")
                if member.issym():
                    target = (Path(tmp) / member.name).parent / member.linkname
                    if not target.resolve().is_relative_to((Path(tmp) / prefix).resolve()):
                        raise RuntimeError("Escaping Node archive link")
            tar.extractall(tmp)
        source = Path(tmp) / prefix
        if destination.exists():
            raise RuntimeError("Runtime destination already exists")
        # Preserve npm/npx's relative symlinks and all upstream licences.
        shutil.copytree(source, destination, symlinks=True)
        shutil.rmtree(destination / "include")
        shutil.rmtree(destination / "share")
        (destination / "runtime.json").write_text(json.dumps(pin) + "\n")
        actual = subprocess.check_output([str(destination / "bin/node"), "--version"], text=True).strip()
        if actual != "v" + pin["version"]:
            raise RuntimeError("Packaged Node version mismatch")
        subprocess.run([str(destination / "bin/node"), str(destination / "lib/node_modules/npm/bin/npm-cli.js"), "--version"], check=True)
        print(f'Bundled Node {pin["version"]}; verified {pin["sha256"]}')


if __name__ == "__main__":
    stage(Path(sys.argv[1]))
