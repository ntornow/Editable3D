"""One reproducible local/CI gate. Native Studio tests are a separate release gate.

Runs formatting, Roblox-aware type checking (tools/check_types.py), the full regression suite
headless in parallel (tools/run_headless.py), coverage, benchmarks and portable builds.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from bootstrap import install
from check_types import check
from coverage import run as coverage
from run_headless import run as run_headless

ROOT = Path(__file__).resolve().parents[1]
FORMATTED = ('OperationBudget','PublishRetry','PublishTransaction','PublishPipeline','NativeContent','RobloxPublish','Types','Texture','Bake','Roblox','init')
NEW_TESTS = ('TestHarness','OperationBudgetTests','GuardedImageTests','PublishTests','NativeContentTests','NativePublishTests','ProductionBenchmarks','RunAllTests','TextureTests')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bootstrap', action='store_true', help='Download SHA-256 pinned official tools')
    parser.add_argument('--jobs', type=int, default=min(8, os.cpu_count() or 2), help='Parallel headless test processes')
    parser.add_argument('--tier', choices=('all', 'fast'), default='all', help='Headless suites: all, or fast (skips baseline slowSuites)')
    args = parser.parse_args()
    directory = install() if args.bootstrap else ROOT/'.tools'
    tools = {'luau':['luau'], 'lune':['lune'], 'rojo':['rojo'], 'stylua':['stylua'], 'luau-lsp':['luau-lsp'], 'roblox-types':['globalTypes.None.d.luau']}
    paths = {p: str(directory/name/p) for name, programs in tools.items() for p in programs}
    for path in paths.values():
        assert Path(path).is_file(), 'Run tools/validate.py --bootstrap to install pinned tools'
    lock=json.loads((ROOT/'toolchain.lock.json').read_text())
    for name in tools:
        receipt=json.loads((directory/name/'receipt.json').read_text())
        assert any(receipt['archive']==platform[name]['sha256'] for platform in lock['platforms'].values()), f'Unpinned tool: {name}'
        for binary,digest in receipt['binaries'].items():
            assert hashlib.sha256((directory/name/binary).read_bytes()).hexdigest()==digest, f'Modified tool: {binary}'
    started = time.monotonic()
    def command(*cmd):
        result = subprocess.run(cmd, cwd=ROOT)
        if result.returncode:
            raise SystemExit(f"Gate failed: {Path(cmd[0]).name} (exit {result.returncode})")
    strict = [p.stem for p in sorted((ROOT/'src').glob('*.luau')) if p.read_text().startswith('--!strict')]
    formatted = [f'src/{n}.luau' for n in sorted(set(FORMATTED) | set(strict))] + [f'tests/{n}.luau' for n in NEW_TESTS] + ['tools/headless.luau','tools/verify_portable.luau','tools/studio_install.luau','tools/studio_verify.luau','tools/studio_read_report.luau']
    command(paths['stylua'], '--check', *formatted)
    check(paths['luau-lsp'], paths['globalTypes.None.d.luau'], paths['rojo'])
    run_headless(paths['lune'], args.jobs, False, args.tier)
    command(paths['lune'], 'run', 'tools/headless.luau', '--bench')
    coverage(paths['luau'])
    for profile in ('development','production'):
        command(sys.executable, 'tools/package.py', '--profile', profile)
        project, output = ('default.project.json','dist') if profile=='development' else ('production.project.json','dist/production')
        command(paths['rojo'], 'build', project, '-o', output+'/Editable3D-rojo.rbxm')
    command(paths['lune'], 'run', 'tools/verify_portable.luau')
    # the root guides (except CHANGELOG) keyed by file stem, as tools/studio_install.luau reads them (docs.README)
    docs = {p.stem: p.read_text() for p in sorted(ROOT.glob('*.md')) if p.name != 'CHANGELOG.md'}
    assert 'README' in docs, 'README.md missing'
    (ROOT/'dist/docs.json').write_text(json.dumps(docs))
    report = {'success': True, 'seconds': time.monotonic()-started, 'nativeStudioExecuted': False, 'toolchain': json.loads((ROOT/'toolchain.lock.json').read_text())}
    (ROOT/'.validation/local.json').write_text(json.dumps(report, indent=2)+'\n')
    print('Local CI gates passed; run the native Studio release gate before installation.')


if __name__ == '__main__':
    main()
