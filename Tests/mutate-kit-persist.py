#!/usr/bin/env python3
"""Mutation lane for the persistent kit store (kit-compile.py) and the persistent compile reuse (reuse-compile.py).

Usage: mutate-kit-persist.py [<mutant name> ...]   (no names: every mutant)

Runs against a scratch copy of the four scripts and their two test files, never the real ones, and never Swift (the tests
use a stand-in compiler). A GREEN BASELINE of both test files comes first; each mutant must land EXACTLY ONCE, and the
test file that owns the mutated script must go red. The killing tests are printed. Exit 1 if any mutant survives.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
KIT, REUSE = 'kit-compile.py', 'reuse-compile.py'
TESTS = {KIT: 'test-kit-compile.py', REUSE: 'test-reuse-compile.py'}

# (name, script, original, mutant, tests to run, e.g. 'PersistentKitTests.test_x' space separated)
MUTANTS = [
    ('persist flag no longer required', KIT,
     "    if os.environ.get('COS_TEST_KIT_PERSIST') != '1' or not raw:\n", "    if not raw:\n",
     'PersistentKitTests.test_off_switch_is_the_per_run_layout_exactly'),
    ('store not required to be absolute', KIT,
     "    if not os.path.isabs(raw):\n", "    if False:\n",
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused'),
    ('iCloud-synced store accepted', KIT,
     "    if 'Mobile Documents' in real.parts or any(real == s or s in real.parents for s in synced):\n", "    if False:\n",
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused'),
    ('only Documents refused, not Desktop or Mobile Documents', KIT,
     "    synced = [home / 'Documents', home / 'Desktop', home / 'Library' / 'Mobile Documents']\n",
     "    synced = [home / 'Documents']\n    real = Path(str(real).replace('Mobile Documents', 'MD'))\n",
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused'),
    ('kit-compile.py digest out of the key', KIT,
     "    return {'kit-compile': digest_file(__file__),\n", "    return {'kit-compile': None,\n",
     'PersistentKitTests.test_the_key_carries_this_script_the_guard_scripts_and_the_sdk_build'),
    ('compile-guard.sh digest out of the key', KIT,
     "            'compile-guard': digest_file(guard) if guard.is_file() else None,\n", "            'compile-guard': None,\n",
     'PersistentKitTests.test_the_key_carries_this_script_the_guard_scripts_and_the_sdk_build'),
    ('compile-bounded.py digest out of the key', KIT,
     "            'compile-bounded': digest_file(bounded) if bounded.is_file() else None}\n", "            'compile-bounded': None}\n",
     'PersistentKitTests.test_the_key_carries_this_script_the_guard_scripts_and_the_sdk_build'),
    ('SDK build version out of the key', KIT,
     "[(k, os.environ.get(k)) for k in ENV_KEYS], sdk_build, sorted(tool_digests(prefix).items())]",
     "[(k, os.environ.get(k)) for k in ENV_KEYS], sorted(tool_digests(prefix).items())]",
     'PersistentKitTests.test_the_key_carries_this_script_the_guard_scripts_and_the_sdk_build'),
    ('eviction keeps three per name', KIT,
     "KEEP_PER_NAME = 2 ", "KEEP_PER_NAME = 3 ",
     'PersistentKitTests.test_eviction_keeps_the_newest_two_keys_per_kit_name'),
    ('eviction counts across all names, not per name', KIT,
     "                groups.setdefault(m.group(1), []).append(p)\n", "                groups.setdefault('all', []).append(p)\n",
     'PersistentKitTests.test_eviction_keeps_the_newest_two_keys_per_kit_name'),
    ('eviction ignores the idle-age floor', KIT,
     "                if time.time() - old.stat().st_mtime >= min_age:\n", "                if True:\n",
     'PersistentKitTests.test_a_kit_used_within_the_eviction_age_is_never_evicted'),
    ('eviction ignores a lane still linking (no use-lock check)', KIT,
     "            try:\n                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n            except OSError:\n                os.close(fd)  # still in use by a lane that is linking against it\n                return\n",
     "            pass\n",
     'PersistentKitTests.test_a_kit_a_lane_is_still_linking_against_is_not_evicted_from_under_it'),
    ('lane never takes its use lock', KIT,
     "        fd = os.open(self.use_lock(kit_name), os.O_CREAT | os.O_RDWR, 0o600)\n        fcntl.flock(fd, fcntl.LOCK_SH)\n",
     "        fd = os.open(self.use_lock(kit_name), os.O_CREAT | os.O_RDWR, 0o600)\n",
     'PersistentKitTests.test_a_kit_a_lane_is_still_linking_against_is_not_evicted_from_under_it'),
    ('rebuild of a tampered kit does not wait for linking lanes', KIT,
     "    if use is not None:\n        fcntl.flock(use, fcntl.LOCK_EX)  # wait for lanes still linking against a stale copy of this very kit\n",
     "    if False:\n        pass\n",
     'PersistentKitTests.test_rebuilding_a_tampered_kit_waits_for_lanes_linking_against_it'),
    ('use lock stays exclusive after the build', KIT,
     "        if use is not None:\n            fcntl.flock(use, fcntl.LOCK_SH)  # building is over (or failed): from here this lane only reads the kit\n",
     "        if use is not None:\n            pass\n",
     'PersistentKitTests.test_lanes_on_one_kit_link_at_the_same_time'),
    ('exclusive build lock dropped to shared', KIT,
     "        root.lock(exclusive=True)\n        try:\n            kit_dir, receipt, code, how = build_kit(",
     "        root.lock(exclusive=False)\n        try:\n            kit_dir, receipt, code, how = build_kit(",
     'PersistentKitTests.test_racing_processes_cannot_corrupt_the_store'),
    ('dead build directories not swept', KIT,
     "        for dead in root.path.glob('.*-building.*'):  # we hold the build lock, so no live build owns these\n            shutil.rmtree(dead, ignore_errors=True)\n",
     "        pass\n",
     'PersistentKitTests.test_a_dead_build_directory_is_swept_by_the_next_build'),
    ('stale use locks not swept', KIT,
     "            if not (self.path / stale.name[:-len('.lock')]).exists():\n                self.drop_if_unused(stale)\n",
     "            pass\n",
     'PersistentKitTests.test_a_stale_use_lock_for_an_evicted_kit_is_removed'),
    ('reuse does not refresh recency', KIT,
     "    if receipt:\n        os.utime(kit_dir)\n", "    if receipt:\n",
     'PersistentKitTests.test_reusing_a_kit_refreshes_its_recency_for_eviction'),
    ('persistent store removed as if private', KIT,
     "        self.private = not self.persistent and not configured\n", "        self.private = not configured\n",
     'PersistentKitTests.test_a_run_without_a_per_run_kit_dir_still_keeps_the_store'),
    ('store directory not private', KIT,
     "mode=0o700 if self.persistent else 0o777", "mode=0o777",
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused'),
    ('exact reuse not available from the store alone', KIT,
     "not (persistent_store() or os.environ.get('COS_TEST_KIT_DIR'))", "not os.environ.get('COS_TEST_KIT_DIR')",
     'PersistentKitTests.test_a_run_without_a_per_run_kit_dir_still_keeps_the_store'),
    ('out/ count cap removed', KIT,
     "if count and (count + 1 > limit_entries or total + size > limit_bytes):", "if count and (total + size > limit_bytes):",
     'PersistentKitTests.test_out_store_keeps_the_newest_entries_within_the_count_cap'),
    ('out/ byte cap removed', KIT,
     "if count and (count + 1 > limit_entries or total + size > limit_bytes):", "if count and (count + 1 > limit_entries):",
     'PersistentKitTests.test_out_store_byte_cap_always_keeps_the_newest'),
    ('out/ never trimmed', KIT,
     "                if root.persistent:\n                    evict_out(store)\n", "                pass\n",
     'PersistentKitTests.test_out_store_keeps_the_newest_entries_within_the_count_cap'),
    ('out/ half-written pairs kept', KIT,
     "        else:\n            for f in files:\n                f.unlink(missing_ok=True)\n", "        else:\n            pass\n",
     'PersistentKitTests.test_out_store_sweeps_a_half_written_pair'),
    ('scratch directory not masked in output keys', KIT,
     "    return RUN_TMP.sub('<tmp>', text)\n", "    return text\n",
     'KitTests.test_the_per_run_scratch_directory_is_not_part_of_an_output_key'),
    ('no single-file MacDictationCore kit', KIT,
     "        'mac-dictation-core': ['MacDictationCore.swift'],\n", "",
     'KitTests.test_mac_dictation_core_alone_is_one_kit_for_every_lane'),
    ('per-run layout evicts per name too', KIT,
     "        if not self.persistent:\n            kits = sorted(", "        if False:\n            kits = sorted(",
     'PersistentKitTests.test_off_switch_keeps_the_four_kit_eviction_and_no_out_cap'),
    # ---- reuse-compile.py
    ('reuse: persist flag no longer required', REUSE,
     "    if os.environ.get('COS_TEST_KIT_PERSIST') != '1' or not raw:\n", "    if not raw:\n",
     'PersistentReuseTests.test_off_switch_means_nothing_is_kept_between_runs'),
    ('reuse: store not required to be absolute', REUSE,
     "    if not os.path.isabs(raw):\n", "    if False:\n",
     'PersistentReuseTests.test_an_icloud_or_relative_store_is_refused'),
    ('reuse: iCloud-synced store accepted', REUSE,
     "    if 'Mobile Documents' in real.parts or any(real == s or s in real.parents for s in synced):\n", "    if False:\n",
     'PersistentReuseTests.test_an_icloud_or_relative_store_is_refused'),
    ('reuse: whole environment hashed again', REUSE,
     "    env = [(key, os.environ.get(key)) for key in ENV_ALLOW]\n", "    env = sorted(os.environ.items())\n",
     'ReuseTests.test_exact_reuse_and_each_input_invalidation'),
    ('reuse: SDKROOT left off the allowlist', REUSE,
     "ENV_ALLOW = ('SDKROOT', ", "ENV_ALLOW = (",
     'ReuseTests.test_exact_reuse_and_each_input_invalidation'),
    ('reuse: Tests/ is an input again', REUSE,
     "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')", "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources', 'Tests')",
     'ReuseTests.test_exact_reuse_and_each_input_invalidation'),
    ('reuse: Resources not an input', REUSE,
     "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')", "INPUT_DIRS = ('Sources', 'HelperSources')",
     'ReuseTests.test_resources_helper_sources_and_package_manifest_are_inputs'),
    ('reuse: HelperSources not an input', REUSE,
     "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')", "INPUT_DIRS = ('Sources', 'Resources')",
     'ReuseTests.test_resources_helper_sources_and_package_manifest_are_inputs'),
    ('reuse: Package.swift not an input', REUSE,
     "INPUT_FILES = ('Package.swift', 'Package.resolved')", "INPUT_FILES = ('Package.resolved',)",
     'ReuseTests.test_resources_helper_sources_and_package_manifest_are_inputs'),
    ('reuse: Package.resolved not an input', REUSE,
     "INPUT_FILES = ('Package.swift', 'Package.resolved')", "INPUT_FILES = ('Package.swift',)",
     'ReuseTests.test_exact_reuse_and_each_input_invalidation'),
    ('reuse: files named in the command are not inputs', REUSE,
     "named=named_files(command, output, scratch), ", "named=[], ",
     'ReuseTests.test_a_file_the_command_names_is_an_input_but_its_own_output_is_not'),
    ('reuse: the output file is an input of its own key', REUSE,
     "        if path.is_file() and path.resolve() != output.resolve():\n", "        if path.is_file():\n",
     'ReuseTests.test_a_file_the_command_names_is_an_input_but_its_own_output_is_not'),
    ('reuse: reuse-compile.py digest out of the key', REUSE,
     "    return {'reuse-compile': digest(Path(__file__)),\n", "    return {'reuse-compile': None,\n",
     'ReuseTests.test_the_guard_scripts_and_this_script_are_inputs'),
    ('reuse: compile-guard.sh digest out of the key', REUSE,
     "            'compile-guard': digest(guard) if guard.is_file() else None,\n", "            'compile-guard': None,\n",
     'ReuseTests.test_the_guard_scripts_and_this_script_are_inputs'),
    ('reuse: compile-bounded.py digest out of the key', REUSE,
     "            'compile-bounded': digest(bounded) if bounded.is_file() else None}\n", "            'compile-bounded': None}\n",
     'ReuseTests.test_the_guard_scripts_and_this_script_are_inputs'),
    ('reuse: SDK build version out of the key', REUSE,
     ",\n                 subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True)]", "]",
     'ReuseTests.test_the_sdk_build_version_is_an_input'),
    ('reuse: nothing masked', REUSE,
     "def mask(text, scratch):\n    for directory in scratch:\n        text = text.replace(directory, '<tmp>')\n    return RUN_TMP.sub('<tmp>', text)\n",
     "def mask(text, scratch):\n    return text\n",
     'ReuseTests.test_the_per_run_scratch_directory_is_not_part_of_the_key'),
    ('reuse: /tmp/cos-control-tests pattern not masked', REUSE,
     "    return RUN_TMP.sub('<tmp>', text)\n", "    return text\n",
     'ReuseTests.test_the_per_run_scratch_directory_is_not_part_of_the_key'),
    ('reuse: output and receipt parents not masked', REUSE,
     "        text = text.replace(directory, '<tmp>')\n", "        pass\n",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
    ('reuse: the checkout itself is masked when the output sits in it', REUSE,
     "            if len(parts) >= 3 and form.resolve() != root and form.resolve() not in root.parents:\n", "            if len(parts) >= 3:\n",
     'PersistentReuseTests.test_a_second_checkout_never_restores_the_first_ones_binary'),
    ('reuse: persistent store never consulted', REUSE,
     "    base = persistent_store()\n    if base is not None:\n        with Store(base) as store:\n            restored",
     "    base = None\n    if base is not None:\n        with Store(base) as store:\n            restored",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
    ('reuse: a build is never saved', REUSE,
     "        with Store(base) as store:\n            store.save(before, args.output, built)\n", "        pass\n",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
    ('reuse: restore leaves no receipt for the run', REUSE,
     "            write_json(args.receipt, dict(input=before, output=restored))\n", "            pass\n",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
    ('reuse: stored binary not verified before it is restored', REUSE,
     "            if digest(binary) != want:\n                return None\n            output.parent.mkdir(parents=True, exist_ok=True)\n"
     "            fd, temporary = tempfile.mkstemp(dir=output.parent, prefix='.restore-')\n            os.close(fd)\n"
     "            shutil.copy2(binary, temporary)\n            if digest(Path(temporary)) != want:\n                os.unlink(temporary)\n                return None\n",
     "            output.parent.mkdir(parents=True, exist_ok=True)\n"
     "            fd, temporary = tempfile.mkstemp(dir=output.parent, prefix='.restore-')\n            os.close(fd)\n"
     "            shutil.copy2(binary, temporary)\n",
     'PersistentReuseTests.test_a_tampered_stored_binary_is_never_restored'),
    ('reuse: inputs-changed-during-build refusal removed', REUSE,
     "    if fingerprint(root, command, toolchain, args.output, scratch) != before:\n", "    if False:\n",
     'ReuseTests.test_source_change_during_compile_rejects_success'),
    ('reuse: count cap removed', REUSE,
     "            if count and (count + 1 > limit_entries or total + size > limit_bytes):\n", "            if count and (total + size > limit_bytes):\n",
     'PersistentReuseTests.test_the_store_keeps_the_newest_binaries_within_the_cap'),
    ('reuse: byte cap removed', REUSE,
     "            if count and (count + 1 > limit_entries or total + size > limit_bytes):\n", "            if count and (count + 1 > limit_entries):\n",
     'PersistentReuseTests.test_the_byte_cap_always_keeps_the_newest'),
    ('reuse: store never trimmed', REUSE,
     "        write_json(self.dir / (fp + '.json'), dict(output=output_digest, name=output.name))\n        self.trim()\n",
     "        write_json(self.dir / (fp + '.json'), dict(output=output_digest, name=output.name))\n",
     'PersistentReuseTests.test_the_store_keeps_the_newest_binaries_within_the_cap'),
    ('reuse: half-written pairs kept', REUSE,
     "            else:\n                for f in files:\n                    f.unlink(missing_ok=True)\n", "            else:\n                pass\n",
     'PersistentReuseTests.test_a_half_written_pair_is_swept'),
    ('reuse: store lock not taken', REUSE,
     "        fcntl.flock(self.lock_fd, fcntl.LOCK_EX)\n        return self\n", "        return self\n",
     'PersistentReuseTests.test_processes_racing_with_a_tight_cap_leave_only_whole_entries'),
    ('reuse: store directory not private', REUSE,
     "os.makedirs(self.dir, mode=0o700, exist_ok=True)", "os.makedirs(self.dir, mode=0o777, exist_ok=True)",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
]


def run_tests(scratch, script, ids=''):
    command = [sys.executable, '-W', 'error::ResourceWarning', str(scratch / TESTS[script]), *ids.split()]
    p = subprocess.run(command, capture_output=True, text=True, timeout=900)
    return p.returncode, p.stdout + p.stderr


def main():
    only = set(sys.argv[1:])
    chosen = [m for m in MUTANTS if not only or m[0] in only]
    if only and len(chosen) != len(only):
        sys.exit('unknown mutant name: ' + ', '.join(sorted(only - {m[0] for m in chosen})))
    base = Path(os.environ.get('CLAUDE_JOB_DIR', tempfile.gettempdir()))
    scratch = Path(tempfile.mkdtemp(prefix='mutate-kit-persist.', dir=base))
    try:
        for name in (KIT, REUSE, *TESTS.values()):
            if (HERE / name).exists():
                shutil.copy2(HERE / name, scratch / name)
        for script in (KIT, REUSE):
            if script in {m[1] for m in chosen} or not only:
                code, out = run_tests(scratch, script)
                tail = out.strip().splitlines()[-3:]
                if code:
                    sys.exit(f'baseline {script} tests are RED; no mutant can be judged:\n' + out[-3000:])
                print(f'baseline {script}: green ({" ".join(tail)})', flush=True)
        survived = []
        for name, script, original, mutant, ids in chosen:
            path = scratch / script
            text = path.read_text()
            if text.count(original) != 1:
                print(f'MISSED TARGET ({text.count(original)}x): {name}', flush=True)
                survived.append(name)
                continue
            path.write_text(text.replace(original, mutant))
            try:
                code, out = run_tests(scratch, script, ids)
            finally:
                path.write_text(text)
            failed = sorted({line.split()[1] for line in out.splitlines() if line.startswith(('FAIL: ', 'ERROR: '))})
            if code == 0:
                print(f'SURVIVED: {name}  (ran {ids})', flush=True)
                survived.append(name)
            else:
                print(f'KILLED: {name}  <- {", ".join(failed) or "(test run failed)"}', flush=True)
        print(f'{len(chosen) - len(survived)} of {len(chosen)} mutants killed')
        sys.exit(1 if survived else 0)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == '__main__':
    main()
