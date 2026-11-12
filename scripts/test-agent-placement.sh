#!/bin/sh
# Weir — exercises shared placement through the actual agent shims.
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
python3 - "$repo" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
resources = repo / 'Weir/Resources'


def wait_for(path):
    deadline = time.monotonic() + 5
    while not path.exists():
        if time.monotonic() > deadline:
            raise AssertionError(f'timed out waiting for {path}')
        time.sleep(0.01)


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix='weir-placement-') as scratch:
    root = Path(scratch).resolve()
    processes = []

    def launch(build, provider, home, extra=None):
        script, variable = {
            'opencode': ('opencode', 'OPENCODE'),
            'antigravity': ('agy', 'ANTIGRAVITY'),
            'kiro': ('kiro-cli', 'KIRO'),
        }[provider]
        env = dict(os.environ, HOME=str(home), PATH=f'{root}/bin:/usr/bin:/bin',
                   WEIR_HOOK_HELPER='/usr/bin/true',
                   PLACEMENT_TEMP_LOG=str(root / 'staging-paths'))
        for key in list(env):
            if key.startswith('WEIR_') or key in ('XDG_CONFIG_HOME', 'OPENCODE_CONFIG_DIR'):
                del env[key]
        env.update({f'WEIR_REAL_{variable}': '/usr/bin/true',
                    f'WEIR_{variable}_AGENT_STATES_DIR': str(root / 'states')})
        env.update(extra or {})
        process = subprocess.Popen(['/bin/sh', str(build / f'{provider}-shim' / script)],
                                   env=env, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(process)
        return process

    def finish(process):
        out, err = process.communicate(timeout=5)
        assert process.returncode == 0, (process.returncode, out, err)

    try:
        (root / 'bin').mkdir()
        # Pause after the newer code reaches its final path, before its mark.
        # Without exclusion the older writer completes here, then the newer
        # writer publishes a mark that describes the older writer's code.
        executable(root / 'bin/mv', '''#!/bin/sh
if [ -n "${PLACEMENT_PERSONAL_RACE:-}" ] && [ "$1" = -n ]; then
  mkdir -p "$PLACEMENT_PERSONAL_RACE"
  : >"$PLACEMENT_PERSONAL_RACE/personal"
fi
/bin/mv "$@" || exit $?
for destination do :; done
case "${PLACEMENT_GATE_STAGE:-code}:$destination" in
  code:*/tui.js|code:*/scripts/weir-dispatch|code:*/weir.json|pending:*/.weir.json.pending)
    if [ -n "${PLACEMENT_GATE:-}" ]; then
      : >"$PLACEMENT_GATE.ready"
      while [ ! -e "$PLACEMENT_GATE.release" ]; do /bin/sleep 0.01; done
    fi ;;
esac
''')
        # Record staging paths to reject temporary files exposed to loaders,
        # including ones that a successful placement would clean up.
        executable(root / 'bin/mktemp', '''#!/bin/sh
for template do :; done
printf '%s\\n' "$template" >>"$PLACEMENT_TEMP_LOG"
exec /usr/bin/mktemp "$@"
''')
        builds = {}
        for version in (12, 13, 14, 15):
            build = root / f'build-{version}'
            build.mkdir()
            for folder in ('agent-shim', 'opencode-shim', 'opencode-plugin',
                           'antigravity-shim', 'antigravity-plugin', 'kiro-shim', 'kiro-hooks'):
                shutil.copytree(resources / folder, build / folder)
            for provider, files in {
                'opencode': ('tui.js',),
                'antigravity': ('scripts/weir-dispatch', 'plugin.json', 'hooks.json'),
            }.items():
                source = build / f'{provider}-plugin'
                (source / '.weir-managed').write_text(f'{version}\n')
                for file in files:
                    (source / file).write_text(f'code-{version}\n')
            hooks = build / 'kiro-hooks/weir.json'
            hooks.write_text(hooks.read_text().replace('Weir 1:', f'Weir {version}:'))
            builds[version] = build

        race_home = root / 'personal-race'
        race_target = race_home / '.config/opencode/plugins/weir'
        finish(launch(builds[14], 'opencode', race_home,
                      {'PLACEMENT_PERSONAL_RACE': str(race_target)}))
        assert sorted(path.name for path in race_target.iterdir()) == ['personal']
        print('PASS: a personal folder appearing during initial placement is untouched')

        for provider, relative, code in (
            ('opencode', '.config/opencode/plugins/weir', 'tui.js'),
            ('antigravity', '.gemini/config/plugins/weir', 'scripts/weir-dispatch'),
            ('kiro', '.kiro/hooks', 'weir.json'),
        ):
            home = root / provider
            # Seed an existing managed version, exercising the re-read after lock.
            finish(launch(builds[12], provider, home))
            target = home / relative
            config_root = target.parent if provider == 'kiro' else target.parent.parent
            assert (config_root / '.weir-placement.lock').is_file()
            expected = ['.weir.json.cksum', 'weir.json'] if provider == 'kiro' else ['weir']
            scanned = target if provider == 'kiro' else target.parent
            assert sorted(path.name for path in scanned.iterdir()) == expected
            gate = root / f'{provider}-gate'
            newer = launch(builds[14], provider, home, {'PLACEMENT_GATE': str(gate)})
            wait_for(Path(f'{gate}.ready'))
            older = launch(builds[13], provider, home)
            was_waiting = False
            try:
                older.wait(timeout=0.15)
            except subprocess.TimeoutExpired:
                was_waiting = True
            Path(f'{gate}.release').touch()
            finish(newer)
            finish(older)
            if provider == 'kiro':
                assert (target / code).read_bytes() == (builds[14] / 'kiro-hooks' / code).read_bytes()
                checksum = subprocess.check_output(['cksum'], input=(target / code).read_bytes()).decode().strip()
                assert (target / '.weir.json.cksum').read_text().strip() == checksum
            else:
                assert (target / code).read_text() == 'code-14\n', (provider, 'code does not match generation 14', (target / '.weir-managed').read_text())
                assert (target / '.weir-managed').read_text().strip() == '14'
                source = builds[14] / f'{provider}-plugin'
                for file in source.rglob('*'):
                    if file.is_file():
                        assert (target / file.relative_to(source)).read_bytes() == file.read_bytes()
            # Partial-copy failures must start the agent and remain repairable.
            failed_home = root / f'{provider}-failed'
            blocked = failed_home / relative
            finish(launch(builds[13], provider, failed_home))
            if provider == 'kiro':
                sidecar = blocked / '.weir.json.pending'
            else:
                sidecar = blocked / code
            if sidecar.exists():
                sidecar.unlink()
            sidecar.mkdir()
            finish(launch(builds[14], provider, failed_home))
            sidecar.rmdir()
            finish(launch(builds[14], provider, failed_home))
            assert (blocked / code).read_bytes() == (target / code).read_bytes()

            # A later older launch must not downgrade a completed placement.
            finish(launch(builds[13], provider, home))
            assert (target / code).read_bytes() == (
                builds[14] / ('kiro-hooks' if provider == 'kiro' else f'{provider}-plugin') / code
            ).read_bytes()
            assert was_waiting, 'the second placement bypassed the held lock'
            print(f'PASS: {provider} concurrent placement and downgrade protection')

            # A killed writer leaves a recovery record, not a completed mark.
            interrupted = root / f'{provider}-interrupted'
            finish(launch(builds[13], provider, interrupted))
            gate = root / f'{provider}-kill'
            writer = launch(builds[14], provider, interrupted, {'PLACEMENT_GATE': str(gate)})
            wait_for(Path(f'{gate}.ready'))
            # A busy placement must still let the agent start promptly.
            started = time.monotonic()
            finish(launch(builds[14], provider, interrupted))
            assert time.monotonic() - started < 3
            os.killpg(writer.pid, signal.SIGKILL)
            writer.communicate(timeout=5)
            repaired = interrupted / relative
            if provider != 'kiro':
                assert (repaired / '.weir-managed').read_bytes() == b'placing:14\n'
                before = {path.relative_to(repaired): (path.read_bytes(), path.stat().st_mtime_ns)
                          for path in repaired.rglob('*') if path.is_file()}
                finish(launch(builds[13], provider, interrupted))
                after = {path.relative_to(repaired): (path.read_bytes(), path.stat().st_mtime_ns)
                         for path in repaired.rglob('*') if path.is_file()}
                assert after == before, 'an older build wrote during a pending upgrade'
                assert (repaired / '.weir-managed').read_bytes() == b'placing:14\n'
                print(f'PASS: {provider} build 13 leaves interrupted placing:14 unchanged')
            finish(launch(builds[14], provider, interrupted))
            assert (repaired / code).read_bytes() == (target / code).read_bytes()
            marker = '.weir.json.cksum' if provider == 'kiro' else '.weir-managed'
            assert (repaired / marker).read_bytes() == (target / marker).read_bytes()
            print(f'PASS: {provider} bounded wait and recovery after termination')

            if provider == 'kiro':
                # A second interrupted upgrade must retain the first writer's
                # ownership evidence while replacing its pending checksum.
                chained = root / 'kiro-chained'
                finish(launch(builds[13], provider, chained))
                for version, stage in ((14, 'code'), (15, 'pending')):
                    gate = root / f'kiro-chain-{version}'
                    writer = launch(builds[version], provider, chained,
                                    {'PLACEMENT_GATE': str(gate), 'PLACEMENT_GATE_STAGE': stage})
                    wait_for(Path(f'{gate}.ready'))
                    os.killpg(writer.pid, signal.SIGKILL)
                    writer.communicate(timeout=5)
                finish(launch(builds[15], provider, chained))
                hook = chained / relative / code
                assert hook.read_bytes() == (builds[15] / 'kiro-hooks' / code).read_bytes()
                checksum = subprocess.check_output(['cksum'], input=hook.read_bytes()).decode().strip()
                assert (hook.parent / '.weir.json.cksum').read_text().strip() == checksum
                print('PASS: kiro recovery across successive interrupted upgrades')
                fifo_home = root / 'kiro-fifo'
                finish(launch(builds[14], provider, fifo_home))
                fifo = fifo_home / relative / '.weir.json.cksum'
                fifo.unlink()
                os.mkfifo(fifo)
                finish(launch(builds[14], provider, fifo_home))
                assert fifo.is_fifo()
                print('PASS: kiro starts without reading a checksum FIFO')

            # Ownership and symlinks must survive a launch unchanged.
            personal = root / f'{provider}-personal' / relative
            personal.mkdir(parents=True)
            (personal / code).parent.mkdir(parents=True, exist_ok=True)
            (personal / code).write_text('personal\n')
            finish(launch(builds[14], provider, root / f'{provider}-personal'))
            assert (personal / code).read_text() == 'personal\n'
            if provider == 'kiro':
                (target / code).write_text('edited\n')
                finish(launch(builds[14], provider, home))
                assert (target / code).read_text() == 'edited\n'
                (target / code).unlink()
                (target / code).symlink_to(personal / code)
            else:
                shutil.rmtree(target)
                target.symlink_to(personal, target_is_directory=True)
            finish(launch(builds[14], provider, home))
            assert (personal / code).read_text() == 'personal\n'
            assert (target / code).is_symlink() if provider == 'kiro' else target.is_symlink()
            print(f'PASS: {provider} ownership and symlink preservation')
        # An explicit config folder replaces XDG rather than adding a second
        # placement, and all builds must use that folder's one lock.
        custom_home = root / 'custom-home'
        custom_config = root / 'custom-config'
        xdg_config = root / 'xdg-config'
        overrides = {'OPENCODE_CONFIG_DIR': str(custom_config), 'XDG_CONFIG_HOME': str(xdg_config)}
        finish(launch(builds[14], 'opencode', custom_home, overrides))
        finish(launch(builds[13], 'opencode', custom_home, overrides))
        assert (custom_config / '.weir-placement.lock').is_file()
        assert sorted(path.name for path in (custom_config / 'plugins').iterdir()) == ['weir']
        assert (custom_config / 'plugins/weir/.weir-managed').read_text() == '14\n'
        assert not xdg_config.exists()
        print('PASS: OpenCode explicit config root replaces XDG and shares its lock')

        for template in (root / 'staging-paths').read_text().splitlines():
            assert not {'plugins', 'hooks'} & set(Path(template).parts), template
            assert (Path(template).parent / '.weir-placement.lock').is_file(), template
        print('PASS: all staging paths stay in config roots outside loader scans')
    finally:
        for process in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
PY
