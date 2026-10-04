"""One reproducible local/CI gate. Native Studio tests are a separate release gate."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import time
from bootstrap import install
from check_types import check
from coverage import run as coverage

ROOT = Path(__file__).resolve().parents[1]
FORMATTED = ('OperationBudget','PublishRetry','PublishTransaction','PublishPipeline','NativeContent','RobloxPublish','Types','Texture','Bake','Roblox','init')
NEW_TESTS = ('TestHarness','OperationBudgetTests','GuardedImageTests','PublishTests','NativeContentTests','NativePublishTests','ProductionBenchmarks','RunAllTests','TextureTests')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bootstrap', action='store_true', help='Download SHA-256 pinned official tools')
    args = parser.parse_args()
    directory = install() if args.bootstrap else ROOT/'.tools'
    paths = {p: str(directory/name/p) for name, programs in {'luau':['luau','luau-analyze'], 'lune':['lune'], 'rojo':['rojo'], 'stylua':['stylua']}.items() for p in programs}
    for path in paths.values():
        assert Path(path).is_file(), 'Run tools/validate.py --bootstrap to install pinned tools'
    lock=json.loads((ROOT/'toolchain.lock.json').read_text())
    for name in ('luau','lune','rojo','stylua'):
        receipt=json.loads((directory/name/'receipt.json').read_text())
        assert any(receipt['archive']==platform[name]['sha256'] for platform in lock['platforms'].values()), f'Unpinned tool: {name}'
        for binary,digest in receipt['binaries'].items():
            assert hashlib.sha256((directory/name/binary).read_bytes()).hexdigest()==digest, f'Modified tool: {binary}'
    started = time.monotonic()
    def command(*cmd):
        result = subprocess.run(cmd, cwd=ROOT)
        if result.returncode:
            raise SystemExit(f"Gate failed: {Path(cmd[0]).name} (exit {result.returncode})")
    formatted = [f'src/{n}.luau' for n in FORMATTED] + [f'tests/{n}.luau' for n in NEW_TESTS] + ['tools/headless.luau','tools/verify_portable.luau','tools/studio_install.luau','tools/studio_verify.luau','tools/studio_read_report.luau']
    command(paths['stylua'], '--check', *formatted)
    check(paths['luau-analyze'])
    # Nonstrict baseline is still analyzed; strict modules use the path-correct mirror.
    legacy = [str(p) for folder in ('src','tests','examples') for p in (ROOT/folder).glob('*.luau') if p.name != 'init.luau' and not p.read_text().startswith('--!strict')]
    command(paths['luau-analyze'], *legacy, 'tools/studio_install.luau', 'tools/studio_verify.luau')
    command(paths['lune'], 'run', 'tools/headless.luau', '--bench')
    coverage(paths['luau'])
    for profile in ('development','production'):
        command(sys.executable, 'tools/package.py', '--profile', profile)
        project, output = ('default.project.json','dist') if profile=='development' else ('production.project.json','dist/production')
        command(paths['rojo'], 'build', project, '-o', output+'/Editable3D-rojo.rbxm')
    command(paths['lune'], 'run', 'tools/verify_portable.luau')
    report = {'success': True, 'seconds': time.monotonic()-started, 'nativeStudioExecuted': False, 'toolchain': json.loads((ROOT/'toolchain.lock.json').read_text())}
    (ROOT/'.validation/local.json').write_text(json.dumps(report, indent=2)+'\n')
    print('Local CI gates passed; run the native Studio release gate before installation.')


if __name__ == '__main__':
    main()
