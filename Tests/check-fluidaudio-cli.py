#!/usr/bin/env python3
"""0.5.317: the bundled FluidAudio CLI carries the version facts the glasses server proves it by.

fluidaudiocli 0.17.4 has no version command, so scripts/build-fluidaudio-cli.sh links an Info.plist into
__TEXT,__info_plist. This reads that section back out of the Mach-O (otool, never by running the tool) and checks it
against Resources/fluidaudio-cli.json. With --signed it also checks what the server checks after signing: codesign
--verify --strict, the identifier, the Info.plist bound to the signature, the hardened runtime and the team.

  check-fluidaudio-cli.py <pin.json> <binary> [--signed [--team TEAM]]
  check-fluidaudio-cli.py --selftest <pin.json> <scratch dir>
"""
import json, os, plistlib, re, subprocess, sys


def section_plist(binary):
    out = subprocess.run(['/usr/bin/otool', '-X', '-s', '__TEXT', '__info_plist', binary],
                         capture_output=True, text=True, check=True).stdout
    data = bytearray()
    for line in out.splitlines():
        # "0000000100004000\t3c 3f 78 6d ..." (bytes) or "... 6d783f3c ..." (words on some otool builds)
        parts = line.split('\t', 1)
        if len(parts) != 2:
            continue
        for token in parts[1].split():
            if not re.fullmatch(r'[0-9a-fA-F]+', token):
                continue
            if len(token) == 2:
                data.append(int(token, 16))
            elif len(token) == 8:
                data.extend(int(token, 16).to_bytes(4, 'little'))
    if not data:
        return None
    return plistlib.loads(bytes(data).rstrip(b'\x00'))


def check(pin, binary, signed, team):
    problems = []
    try:
        plist = section_plist(binary)
    except Exception as error:  # an unreadable section is a failure, never a pass
        plist, problems = None, [f'__info_plist unreadable: {error}']
    if plist is None:
        return problems or ['no __TEXT,__info_plist section']
    for key, want in [('CFBundleIdentifier', pin['identifier']), ('CFBundleShortVersionString', pin['version']),
                      ('FluidAudioSourceCommit', pin['sourceCommit'])]:
        if plist.get(key) != want:
            problems.append(f'{key} is {plist.get(key)!r}, expected {want!r}')
    if signed:
        verify = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=1', binary], capture_output=True, text=True)
        if verify.returncode != 0:
            problems.append('codesign --verify --strict failed: ' + verify.stderr.strip()[:200])
        info = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', binary], capture_output=True, text=True).stderr
        if f'Identifier={pin["identifier"]}' not in info:
            problems.append('signing identifier is not ' + pin['identifier'])
        if 'Info.plist entries=' not in info:
            problems.append('the Info.plist is not bound to the signature')
        if not re.search(r'flags=0x[0-9a-f]*\(.*runtime.*\)', info):
            problems.append('hardened runtime is off')
        if team and f'TeamIdentifier={team}' not in info:
            problems.append('TeamIdentifier is not ' + team)
    return problems


def selftest(pin_path, scratch):
    """A binary without the section, and one with a wrong version, must both fail; a right one must pass."""
    pin = json.load(open(pin_path))
    os.makedirs(scratch, exist_ok=True)
    src = os.path.join(scratch, 'main.c')
    open(src, 'w').write('int main(void){return 0;}\n')
    def build(name, version):
        out = os.path.join(scratch, name)
        args = ['/usr/bin/clang', '-o', out, src]
        if version is not None:
            plist = os.path.join(scratch, name + '.plist')
            plistlib.dump({'CFBundleIdentifier': pin['identifier'], 'CFBundleShortVersionString': version,
                           'FluidAudioSourceCommit': pin['sourceCommit']}, open(plist, 'wb'))
            args += ['-Wl,-sectcreate,__TEXT,__info_plist,' + plist]
        subprocess.run(args, check=True)
        return out
    bare, wrong, right = build('bare', None), build('wrong', '0.17.3'), build('right', pin['version'])
    assert check(pin, bare, False, None), 'a binary with no Info.plist section must fail'
    assert check(pin, wrong, False, None), 'a wrong version must fail'
    assert check(pin, right, False, None) == [], check(pin, right, False, None)
    # codesign takes the identifier from the embedded plist by default; a different one must fail.
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'com.example.other', right], check=True, capture_output=True)
    signed = check(pin, right, True, None)
    assert any('identifier' in p for p in signed) and any('runtime' in p for p in signed), signed
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', '--identifier', pin['identifier'], right], check=True, capture_output=True)
    assert check(pin, right, True, None) == [], check(pin, right, True, None)
    assert check(pin, right, True, 'NV3X46LLCR'), 'an ad hoc signature has no team, so a team check must fail'
    print('PASS check-fluidaudio-cli self-test: missing section, wrong version, unsigned identifier, no runtime and no team all fail; the plist survives signing')


if __name__ == '__main__':
    if sys.argv[1] == '--selftest':
        selftest(sys.argv[2], sys.argv[3])
        sys.exit(0)
    pin = json.load(open(sys.argv[1]))
    signed = '--signed' in sys.argv
    team = sys.argv[sys.argv.index('--team') + 1] if '--team' in sys.argv else None
    problems = check(pin, sys.argv[2], signed, team)
    if problems:
        print('FAIL fluidaudiocli: ' + '; '.join(problems), file=sys.stderr)
        sys.exit(1)
    print(f'PASS fluidaudiocli {pin["version"]} carries its Info.plist' + (' and signature' if signed else ''))
