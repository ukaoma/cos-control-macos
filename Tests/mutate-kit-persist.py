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
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused_in_any_letter_case'),
    ('iCloud-synced store accepted', KIT,
     "    if synced_place(real):\n", "    if False:\n",
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused_in_any_letter_case'),
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
     "[(k, os.environ.get(k)) for k in ENV_KEYS], sdk_build, sorted(tool_digests(prefix).items()), host_build]",
     "[(k, os.environ.get(k)) for k in ENV_KEYS], sorted(tool_digests(prefix).items()), host_build]",
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
     "os.makedirs(store, mode=0o700, exist_ok=True)", "os.makedirs(store, mode=0o777, exist_ok=True)",
     'PersistentKitTests.test_a_store_in_a_synced_or_relative_place_is_refused_in_any_letter_case'),
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
     'PersistentKitTests.test_off_switch_keeps_the_ten_kit_eviction_and_no_out_cap'),
    # ---- reuse-compile.py
    ('reuse: persist flag no longer required', REUSE,
     "    if os.environ.get('COS_TEST_KIT_PERSIST') != '1' or not raw:\n", "    if not raw:\n",
     'PersistentReuseTests.test_off_switch_means_nothing_is_kept_between_runs'),
    ('reuse: store not required to be absolute', REUSE,
     "    if not os.path.isabs(raw):\n", "    if False:\n",
     'PersistentReuseTests.test_an_icloud_or_relative_store_is_refused_in_any_letter_case'),
    ('reuse: iCloud-synced store accepted', REUSE,
     "    if synced_place(real):\n", "    if False:\n",
     'PersistentReuseTests.test_an_icloud_or_relative_store_is_refused_in_any_letter_case'),
    ('reuse: whole environment hashed again', REUSE,
     "    env = [(key, os.environ.get(key)) for key in ENV_ALLOW]\n", "    env = sorted(os.environ.items())\n",
     'PersistentReuseTests.test_exact_reuse_and_each_input_invalidation_narrowed'),
    ('reuse: Tests/ is an input again', REUSE,
     "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')", "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources', 'Tests')",
     'PersistentReuseTests.test_exact_reuse_and_each_input_invalidation_narrowed'),
    ('reuse: Resources not an input', REUSE,
     "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')", "INPUT_DIRS = ('Sources', 'HelperSources')",
     'PersistentReuseTests.test_resources_helper_sources_and_package_manifest_are_inputs_narrowed'),
    ('reuse: HelperSources not an input', REUSE,
     "INPUT_DIRS = ('Sources', 'HelperSources', 'Resources')", "INPUT_DIRS = ('Sources', 'Resources')",
     'PersistentReuseTests.test_resources_helper_sources_and_package_manifest_are_inputs_narrowed'),
    ('reuse: Package.swift not an input', REUSE,
     "INPUT_FILES = ('Package.swift', 'Package.resolved')", "INPUT_FILES = ('Package.resolved',)",
     'PersistentReuseTests.test_resources_helper_sources_and_package_manifest_are_inputs_narrowed'),
    ('reuse: Package.resolved not an input', REUSE,
     "INPUT_FILES = ('Package.swift', 'Package.resolved')", "INPUT_FILES = ('Package.swift',)",
     'PersistentReuseTests.test_exact_reuse_and_each_input_invalidation_narrowed'),
    ('reuse: files named in the command are not inputs', REUSE,
     "named=named_files(command, output, scratch), ", "named=[], ",
     'PersistentReuseTests.test_a_file_the_command_names_is_an_input_but_its_own_output_is_not'),
    ('reuse: the output file is an input of its own key', REUSE,
     "        if path.is_file() and path.resolve() != output.resolve():\n", "        if path.is_file():\n",
     'PersistentReuseTests.test_a_file_the_command_names_is_an_input_but_its_own_output_is_not'),
    ('reuse: reuse-compile.py digest out of the key', REUSE,
     "    return {'reuse-compile': digest(Path(__file__)),\n", "    return {'reuse-compile': None,\n",
     'PersistentReuseTests.test_the_guard_scripts_and_this_script_are_inputs'),
    ('reuse: compile-guard.sh digest out of the key', REUSE,
     "            'compile-guard': digest(guard) if guard.is_file() else None,\n", "            'compile-guard': None,\n",
     'PersistentReuseTests.test_the_guard_scripts_and_this_script_are_inputs'),
    ('reuse: compile-bounded.py digest out of the key', REUSE,
     "            'compile-bounded': digest(bounded) if bounded.is_file() else None}\n", "            'compile-bounded': None}\n",
     'PersistentReuseTests.test_the_guard_scripts_and_this_script_are_inputs'),
    ('reuse: SDK build version out of the key', REUSE,
     "        toolchain += [subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True),\n                      subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()]\n",
     "        toolchain += [subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()]\n",
     'PersistentReuseTests.test_the_sdk_build_and_the_host_macos_build_are_inputs'),
    ('reuse: host macOS build out of the key', REUSE,
     "        toolchain += [subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True),\n                      subprocess.run(['sw_vers', '-buildVersion'], capture_output=True, text=True).stdout.strip()]\n",
     "        toolchain += [subprocess.check_output(['xcrun', '--show-sdk-build-version'], text=True)]\n",
     'PersistentReuseTests.test_the_sdk_build_and_the_host_macos_build_are_inputs'),
    ('reuse: nothing masked', REUSE,
     "def mask(text, scratch):\n    for directory in scratch:\n        text = text.replace(directory, '<tmp>')\n    return RUN_TMP.sub('<tmp>', text)\n",
     "def mask(text, scratch):\n    return text\n",
     'PersistentReuseTests.test_the_per_run_scratch_directory_is_not_part_of_the_key'),
    ('reuse: /tmp/cos-control-tests pattern not masked', REUSE,
     "    return RUN_TMP.sub('<tmp>', text)\n", "    return text\n",
     'PersistentReuseTests.test_the_per_run_scratch_directory_is_not_part_of_the_key'),
    ('reuse: output and receipt parents not masked', REUSE,
     "        text = text.replace(directory, '<tmp>')\n", "        pass\n",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
    ('reuse: the checkout itself is masked when the output sits in it', REUSE,
     "            if len(parts) >= 3 and form.resolve() != root and form.resolve() not in root.parents:\n", "            if len(parts) >= 3:\n",
     'PersistentReuseTests.test_a_second_checkout_never_restores_the_first_ones_binary'),
    ('reuse: persistent store never consulted', REUSE,
     "    base = usable(persistent_store(command), root)\n", "    base = None\n",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
    ('reuse: a build is never saved', REUSE,
     "            with Store(base) as store:\n                store.save(before, args.output, built)\n", "            pass\n",
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
     "    if fingerprint_now() != before:\n", "    if False:\n",
     'ReuseTests.test_source_change_during_compile_rejects_success'),
    ('reuse: count cap removed', REUSE,
     "            if count and (count + 1 > limit_entries or total + size > limit_bytes):\n", "            if count and (total + size > limit_bytes):\n",
     'PersistentReuseTests.test_the_store_keeps_the_newest_binaries_within_the_cap'),
    ('reuse: byte cap removed', REUSE,
     "            if count and (count + 1 > limit_entries or total + size > limit_bytes):\n", "            if count and (count + 1 > limit_entries):\n",
     'PersistentReuseTests.test_the_byte_cap_always_keeps_the_newest'),
    ('reuse: store never trimmed', REUSE,
     "            self.trim()\n        except BaseException:", "            pass\n        except BaseException:",
     'PersistentReuseTests.test_the_store_keeps_the_newest_binaries_within_the_cap'),
    ('reuse: half-written pairs kept', REUSE,
     "            else:\n                for f in files:\n                    f.unlink(missing_ok=True)\n", "            else:\n                pass\n",
     'PersistentReuseTests.test_a_half_written_pair_is_swept'),
    ('reuse: store lock not taken', REUSE,
     "        fcntl.flock(self.lock_fd, fcntl.LOCK_EX)\n        return self\n", "        return self\n",
     'PersistentReuseTests.test_processes_racing_with_a_tight_cap_leave_only_whole_entries'),
    ('reuse: store directory not private', REUSE,
     "os.makedirs(base / 'reuse', mode=0o700, exist_ok=True)", "os.makedirs(base / 'reuse', mode=0o777, exist_ok=True)",
     'PersistentReuseTests.test_the_next_run_restores_the_binary_instead_of_compiling'),
]


def both(name, original, mutant, kit_tests, reuse_tests):
    return [(name, KIT, original, mutant, kit_tests), ('reuse: ' + name, REUSE, original, mutant, reuse_tests)]


KP, RP, K, R = 'PersistentKitTests.', 'PersistentReuseTests.', 'KitTests.', 'ReuseTests.'


def m2(prefix, names):
    return ' '.join(prefix + n for n in names.split())


ENVT = ('test_environment_that_changes_the_compile_but_is_not_hashed_turns_persistence_off',) * 2
CMDT = ('test_a_command_with_unhashed_search_paths_does_not_persist',) * 2
ICT = ('test_a_store_in_a_synced_or_relative_place_is_refused_in_any_letter_case',
       'test_an_icloud_or_relative_store_is_refused_in_any_letter_case')
EXTRA = []
# unhashed environment: each alternative and each search path, plus the one allowed default value
for label, original, mutant in (
        ('SWIFT_DRIVER_*_EXEC not refused', "r'^(SWIFT_DRIVER_.*_EXEC|DYLD_.*)$'", "r'^(DYLD_.*)$'"),
        ('DYLD_* not refused', "r'^(SWIFT_DRIVER_.*_EXEC|DYLD_.*)$'", "r'^(SWIFT_DRIVER_.*_EXEC)$'"),
        ('CPATH not refused', "'CPATH': '/usr/local/include', ", ""),
        ('C_INCLUDE_PATH not refused', "'C_INCLUDE_PATH': None, ", ""),
        ('LIBRARY_PATH not refused', ", 'LIBRARY_PATH': '/usr/local/lib'}", "}"),
        ('python shim default CPATH no longer allowed', "'CPATH': '/usr/local/include'", "'CPATH': '/usr/local/nothing'"),
        ('python shim default LIBRARY_PATH no longer allowed', "'LIBRARY_PATH': '/usr/local/lib'}", "'LIBRARY_PATH': '/usr/local/nothing'}"),
        ('environment refusal never evaluated', "    unsafe = sorted([k for k in os.environ if UNSAFE_ENV.match(k)]\n",
         "    unsafe = [] and sorted([k for k in os.environ if UNSAFE_ENV.match(k)]\n")):
    EXTRA += both(label, original, mutant, KP + ENVT[0], RP + ENVT[1])
# unhashed command options
for flag in ('-I', '-F', '-L', '-sdk', '-Xcc'):
    pair = f"'{flag}', "
    for name, script in (('', KIT), ('reuse: ', REUSE)):
        text = "        if a in ('-I', '-F', '-L', '-sdk', '-Xcc')"
        if script == KIT:
            original, tests = text, KP + CMDT[0]
            mutant = text.replace(pair, '') if flag != '-Xcc' else text.replace(", '-Xcc'", '')
        else:
            original, tests = "        if a in ('-I', '-F', '-L', '-sdk', '-Xcc') or", RP + CMDT[1]
            mutant = original.replace(pair, '') if flag != '-Xcc' else original.replace(", '-Xcc'", '')
        EXTRA.append((f'{name}{flag} not refused', script, original, mutant, tests))
EXTRA += [
    ('reuse: joined -I/path not refused', REUSE, "or (len(a) > 2 and a[:2] in ('-I', '-F', '-L')):", ":", RP + CMDT[1]),
    ('-Xlinker <directory> not refused', KIT, "if a == '-Xlinker' and i + 1 < len(args) and os.path.isdir(args[i + 1]):", "if False:", KP + CMDT[0]),
    ('reuse: -Xlinker <directory> not refused', REUSE, "if a == '-Xlinker' and i + 1 < len(args) and os.path.isdir(args[i + 1]):", "if False:", RP + CMDT[1]),
    ('this command may persist despite its own refusal', KIT, "    if BLOCK:\n", "    if False:\n", KP + CMDT[0]),
    ('the command check is never run', KIT, "    BLOCK = command_blocker(args)\n", "    BLOCK = None\n", KP + CMDT[0]),
    ('reuse: the command check is never run', REUSE, "    blocker = command_blocker(command[2:])\n", "    blocker = None\n", RP + CMDT[1]),
]
# iCloud layers: each synced root, the case folding, each cloud folder name
for label, original, mutant in (
        ('Documents not refused', "SYNCED = (('Documents',), ('Desktop',))", "SYNCED = (('Desktop',),)"),
        ('Desktop not refused', "SYNCED = (('Documents',), ('Desktop',))", "SYNCED = (('Documents',),)"),
        ('home roots compared case-sensitively (stored path)', "    folded = str(real).casefold()\n", "    folded = str(real)\n"),
        ('home roots compared case-sensitively (root)', "        name = str(home.joinpath(*parts)).casefold()\n", "        name = str(home.joinpath(*parts))\n"),
        ('cloud folder names compared case-sensitively', "any(part.casefold() in CLOUD_PARTS for part in real.parts)", "any(part in CLOUD_PARTS for part in real.parts)"),
        ('Mobile Documents not recognised', "CLOUD_PARTS = {'mobile documents', ", "CLOUD_PARTS = {"),
        ('CloudStorage not recognised', "'cloudstorage', ", ""),
        ('com~apple~CloudDocs not recognised', ", 'com~apple~clouddocs'}", "}"),
        ('a path below a synced root is not refused', "folded == name or folded.startswith(name + os.sep)", "folded == name")):
    EXTRA += both(label, original, mutant, KP + ICT[0], RP + ICT[1])
# every hashed environment variable, the host build, off-path parity, the legacy fingerprint
for key in ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET'):
    keys = ['SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET']
    keys.remove(key)
    EXTRA.append((f'{key} out of the kit key', KIT, "ENV_KEYS = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET')",
                  'ENV_KEYS = (' + ', '.join(f"'{k}'" for k in keys) + ')', KP + 'test_every_hashed_environment_variable_and_the_host_build_are_inputs'))
    allowed = ['SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET', 'SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH']
    allowed.remove(key)
    EXTRA.append((f'reuse: {key} out of the allowlist', REUSE, "ENV_ALLOW = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET', 'SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH')",
                  'ENV_ALLOW = (' + ', '.join(f"'{k}'" for k in allowed) + ')', RP + 'test_every_allowlisted_environment_variable_is_an_input'))
for key in ('SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH'):
    allowed = ['SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET', 'SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH']
    allowed.remove(key)
    EXTRA.append((f'reuse: {key} out of the allowlist', REUSE, "ENV_ALLOW = ('SDKROOT', 'DEVELOPER_DIR', 'TOOLCHAINS', 'MACOSX_DEPLOYMENT_TARGET', 'SWIFT_DETERMINISTIC_HASHING', 'SOURCE_DATE_EPOCH')",
                  'ENV_ALLOW = (' + ', '.join(f"'{k}'" for k in allowed) + ')', RP + 'test_every_allowlisted_environment_variable_is_an_input'))
EXTRA += [
    ('host macOS build out of the kit key', KIT, "sorted(tool_digests(prefix).items()), host_build]", "sorted(tool_digests(prefix).items())]",
     KP + 'test_every_hashed_environment_variable_and_the_host_build_are_inputs'),
    ('reuse off-path: Tests/ and scripts/ no longer hashed', REUSE, "    for name in ('Sources', 'HelperSources', 'Tests', 'scripts', 'Resources',",
     "    for name in ('Sources', 'HelperSources', 'Resources',", m2(R, 'test_exact_reuse_and_each_input_invalidation test_the_fingerprint_is_byte_identical_to_the_original')),
    ('reuse off-path: scripts/ no longer hashed', REUSE, "    for name in ('Sources', 'HelperSources', 'Tests', 'scripts', 'Resources',",
     "    for name in ('Sources', 'HelperSources', 'Tests', 'Resources',", m2(R, 'test_scripts_and_any_environment_variable_still_invalidate test_the_fingerprint_is_byte_identical_to_the_original')),
    ('reuse off-path: environment no longer hashed', REUSE, "    env = sorted((key, value) for key, value in os.environ.items() if key not in ('_', 'SHLVL'))\n",
     "    env = []\n", m2(R, 'test_scripts_and_any_environment_variable_still_invalidate test_exact_reuse_and_each_input_invalidation')),
    ('reuse off-path: working directory no longer hashed', REUSE, "    material = dict(files=files, command=command, toolchain=toolchain, env=env, cwd=os.getcwd())",
     "    material = dict(files=files, command=command, toolchain=toolchain, env=env, cwd='')", R + 'test_the_fingerprint_is_byte_identical_to_the_original'),
    ('reuse: the narrow fingerprint is used even when off', REUSE, "    if base is None:\n        def fingerprint_now():", "    if False:\n        def fingerprint_now():",
     m2(R, 'test_exact_reuse_and_each_input_invalidation test_scripts_and_any_environment_variable_still_invalidate')),
    ('reuse: the legacy fingerprint is used even when persisting', REUSE, "    if base is None:\n        def fingerprint_now():", "    if True:\n        def fingerprint_now():",
     RP + 'test_exact_reuse_and_each_input_invalidation_narrowed'),
    # origin, sweep
    ('store never claims its worktree', KIT, "                claim_store(store)\n", "                pass\n", KP + 'test_the_store_carries_its_origin_and_is_touched_on_every_use'),
    ('store use not recorded on every run', KIT, "    try:\n        os.utime(origin)\n    except FileNotFoundError:\n        fd, temporary = tempfile.mkstemp(dir=store, prefix='.origin-')",
     "    try:\n        pass\n    except FileNotFoundError:\n        fd, temporary = tempfile.mkstemp(dir=store, prefix='.origin-')", KP + 'test_the_store_carries_its_origin_and_is_touched_on_every_use'),
    ('reuse: store never claims its worktree', REUSE, "        claim_store(base, root)\n", "        pass\n", RP + 'test_the_store_carries_its_origin_and_is_touched_on_every_use'),
    ('reuse: store use not recorded on every run', REUSE, "    try:\n        os.utime(origin)\n    except FileNotFoundError:\n        fd, temporary = tempfile.mkstemp(dir=base, prefix='.origin-')",
     "    try:\n        pass\n    except FileNotFoundError:\n        fd, temporary = tempfile.mkstemp(dir=base, prefix='.origin-')", RP + 'test_the_store_carries_its_origin_and_is_touched_on_every_use'),
    ('sweep ignores a store whose worktree is gone', KIT, "            if not os.path.isdir(worktree) or time.time() - used > STORE_IDLE_SECONDS:\n",
     "            if time.time() - used > STORE_IDLE_SECONDS:\n", KP + 'test_the_sweep_removes_stores_of_gone_or_idle_worktrees_and_nothing_else'),
    ('sweep ignores an idle store', KIT, "            if not os.path.isdir(worktree) or time.time() - used > STORE_IDLE_SECONDS:\n",
     "            if not os.path.isdir(worktree):\n", KP + 'test_the_sweep_removes_stores_of_gone_or_idle_worktrees_and_nothing_else'),
    ('sweep removes a directory that is not one of its stores', KIT, "                continue  # not one of ours: never touched\n",
     "                worktree, used = '', 0\n", KP + 'test_the_sweep_removes_stores_of_gone_or_idle_worktrees_and_nothing_else'),
    ('sweep has no size cap', KIT, "            if total <= env_number('COS_TEST_KIT_STORES_MAX_BYTES', 20 << 30):\n                break\n",
     "            if True:\n                break\n", KP + 'test_the_sweep_caps_all_stores_together_oldest_first_and_never_the_own_store'),
    ('sweep removes the newest store first', KIT, "        for _, p in sorted(others):\n", "        for _, p in sorted(others, reverse=True):\n",
     KP + 'test_the_sweep_caps_all_stores_together_oldest_first_and_never_the_own_store'),
    ('sweep may remove its own store', KIT, "            if p == store:\n                continue\n", "", KP + 'test_the_sweep_caps_all_stores_together_oldest_first_and_never_the_own_store'),
    ('sweep removes a store in use', KIT, "            held.append(fd)\n            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n", "            held.append(fd)\n",
     KP + 'test_the_sweep_leaves_a_store_that_a_lane_is_using'),
    ('sweep runs on every call', KIT, "        if time.time() - marker.stat().st_mtime < interval:\n            return\n", "        pass\n",
     KP + 'test_the_sweep_runs_at_most_once_per_interval'),
    # best-effort writes
    ('a failed exact-reuse cache write fails the lane', KIT, "            except (OSError, shutil.Error) as error:  # the compile succeeded", "            except ZeroDivisionError as error:  # the compile succeeded",
     KP + 'test_a_cache_write_that_fails_never_fails_a_lane_that_compiled'),
    ('an unusable store fails the lane', KIT, "            except OSError as error:\n                say(f'persistent store unusable", "            except ZeroDivisionError as error:\n                say(f'persistent store unusable",
     KP + 'test_a_store_that_cannot_be_made_or_is_short_of_disk_falls_back_to_per_run'),
    ('low disk does not stop persistence', KIT, "                if shutil.disk_usage(store).free < env_number('COS_TEST_KIT_MIN_FREE_BYTES', 3 << 30):\n", "                if False:\n",
     KP + 'test_a_store_that_cannot_be_made_or_is_short_of_disk_falls_back_to_per_run'),
    ('reuse: a failed cache write fails the compile', REUSE, "        except (OSError, shutil.Error) as error:  # the compile succeeded", "        except ZeroDivisionError as error:  # the compile succeeded",
     RP + 'test_a_cache_write_that_fails_never_fails_a_compile_that_succeeded'),
    ('reuse: an unusable store fails the compile', REUSE, "    except OSError as error:\n        say(f'persistent store unusable", "    except ZeroDivisionError as error:\n        say(f'persistent store unusable",
     RP + 'test_a_store_that_cannot_be_made_or_is_short_of_disk_is_skipped'),
    ('reuse: low disk does not stop persistence', REUSE, "        if shutil.disk_usage(base).free < env_number('COS_TEST_KIT_MIN_FREE_BYTES', 3 << 30):\n", "        if False:\n",
     RP + 'test_a_store_that_cannot_be_made_or_is_short_of_disk_is_skipped'),
    ('reuse: an unreadable store fails the compile', REUSE, "        except OSError as error:\n            say(f'could not read the persistent store", "        except ZeroDivisionError as error:\n            say(f'could not read the persistent store",
     RP + 'test_a_store_that_vanishes_mid_run_never_fails_the_compile'),
    # per-run layout
    ('per-run layout keeps only four kits', KIT, "KEEP_KITS = 10 ", "KEEP_KITS = 4 ", K + 'test_all_five_kit_names_stay_in_a_per_run_dir'),
    ('a lane linking in the per-run layout holds no lock', KIT, "        if not root.persistent:\n            root.lock(exclusive=False)\n", "        if False:\n            root.lock(exclusive=False)\n",
     K + 'test_a_lane_linking_in_the_per_run_layout_keeps_other_builds_out'),
]
MUTANTS += EXTRA


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
