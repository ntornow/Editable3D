"""Run every regression suite headless in parallel and enforce tests/headless-baseline.json.

The baseline records, per suite, its last measured duration (used only to balance work across
processes) and the tests that legitimately cannot run outside Studio:

- nativeSkipped: tests that reached a native engine API (AssetService, Instance, EditableMesh).
  The headless runner reports these automatically; the baseline makes any change explicit.
- engineOnly: tests that run headless but depend on engine behavior the Lune stand-ins cannot
  reproduce. Each entry carries a reason. They are expected to fail headless.

- slowSuites: suites that dominate run time. `--tier fast` skips them (CI on every push);
  `--tier slow` runs only them; `--tier all` (default) runs everything.

The gate fails on any other failure, on a new or vanished native skip, and on an engine-only
test that starts passing. Checks cover only the suites that ran. `--shard I/N` runs one of N
duration-balanced slices of the selected tier (for CI matrix jobs). Use --update-baseline after
an intentional change (with the default tier and no shard).
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import json
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'tests/headless-baseline.json'
OUT = ROOT / '.validation'


def suite_names():
    names = re.findall(r'\n\t\t\t"(\w+)",', (ROOT / 'tests/RunAllTests.luau').read_text())
    assert names, 'No suites found in RunAllTests'
    return names


def partition(names, seconds, jobs):
    """Longest-processing-time-first assignment; unknown suites count as one second."""
    bins = [[0.0, []] for _ in range(max(1, min(jobs, len(names))))]
    for name in sorted(names, key=lambda n: -seconds.get(n, 1.0)):
        target = min(bins, key=lambda b: b[0])
        target[0] += seconds.get(name, 1.0)
        target[1].append(name)
    return [b[1] for b in bins if b[1]]


def run(lune, jobs, update, tier='all', shard=(1, 1)):
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {'suites': {}, 'engineOnly': {}}
    assert not update or (tier == 'all' and shard == (1, 1)), '--update-baseline needs --tier all and no shard'
    slow = set(baseline.get('slowSuites', []))
    names = [n for n in suite_names() if tier == 'all' or (n in slow) == (tier == 'slow')]
    seconds = {n: s.get('seconds', 1.0) for n, s in baseline['suites'].items()}
    index, count = shard
    if count > 1:
        names = partition(names, seconds, count)[index - 1]
    groups = partition(names, seconds, jobs)
    OUT.mkdir(exist_ok=True)

    def shard(index_group):
        index, group = index_group
        out = OUT / f'headless-{index + 1}.json'
        out.unlink(missing_ok=True)
        args = [lune, 'run', 'tools/headless.luau', '--out', str(out)]
        for name in group:
            args += ['--suite', name]
        with open(OUT / f'headless-{index + 1}.log', 'w') as log:
            subprocess.run(args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if not out.exists():
            raise SystemExit(f'Headless process {index + 1} crashed; see .validation/headless-{index + 1}.log')
        result = json.loads(out.read_text())
        print(f"  process {index + 1}: {len(group)} suites, {sum(s['passed'] for s in result['suites'].values())} passed,"
              f" {sum(s['failed'] for s in result['suites'].values())} failed", flush=True)
        return result

    label = f'tier {tier}' + (f', shard {index}/{count}' if count > 1 else '')
    print(f'Running {len(names)} suites headless ({label}) in {len(groups)} processes', flush=True)
    with ThreadPoolExecutor(len(groups)) as pool:
        results = list(pool.map(shard, enumerate(groups)))
    suites = {}
    for result in results:
        suites.update(result['suites'])

    engine_only = baseline.get('engineOnly', {})
    problems = []
    unexpected_native, vanished_native, failures, now_passing = [], [], [], []
    for name in names:
        summary = suites[name]
        expected = set(baseline['suites'].get(name, {}).get('nativeSkipped', []))
        actual = set(summary['nativeSkipped'])
        unexpected_native += [f'{name}/{t}' for t in sorted(actual - expected)]
        vanished_native += [f'{name}/{t}' for t in sorted(expected - actual)]
        failed = {f['name']: f['error'] for f in summary['failures']}
        for test, error in failed.items():
            if f'{name}/{test}' not in engine_only:
                failures.append(f'{name}/{test}: {error.splitlines()[0][:300]}')
    for key in engine_only:
        suite, test = key.split('/', 1)
        if suite in names and test not in {f['name'] for f in suites[suite]['failures']}:
            now_passing.append(key)

    totals = {
        'suites': len(names),
        'passed': sum(s['passed'] for s in suites.values()),
        'failed': len(failures),
        'nativeSkipped': sum(len(s['nativeSkipped']) for s in suites.values()),
        'engineOnly': sum(1 for key in engine_only if key.split('/', 1)[0] in names),
    }
    totals['total'] = totals['passed'] + totals['failed'] + totals['nativeSkipped'] + totals['engineOnly']

    if update:
        BASELINE.write_text(json.dumps({
            'about': 'Generated by tools/run_headless.py --update-baseline; slowSuites and engineOnly are maintained by hand.',
            'slowSuites': sorted(slow),
            'engineOnly': engine_only,
            'suites': {n: {'seconds': suites[n]['seconds'], 'nativeSkipped': sorted(suites[n]['nativeSkipped'])}
                       for n in names},
        }, indent=2, sort_keys=False) + '\n')
        print(f'Updated {BASELINE.relative_to(ROOT)}')
        unexpected_native, vanished_native = [], []

    for label, items in (('Unexpected failures', failures),
                         ('New native skips (headless coverage lost; --update-baseline if intended)', unexpected_native),
                         ('Native skips that now run (--update-baseline to record)', vanished_native),
                         ('Engine-only tests now passing headless (remove from engineOnly)', now_passing)):
        if items:
            problems.append(label)
            print(f'\n{label}:')
            for item in items:
                print(f'  - {item}')

    (OUT / 'headless.json').write_text(json.dumps({**totals, 'suites': suites}, indent=2) + '\n')
    print(f"\nHeadless: {totals['passed']} passed, {totals['failed']} failed, "
          f"{totals['nativeSkipped']} native-only skipped, {totals['engineOnly']} engine-only "
          f"({totals['total']} tests in {totals['suites']} suites)")
    if problems:
        raise SystemExit('Headless gate failed: ' + '; '.join(problems))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--lune', default=str(ROOT / '.tools/lune/lune'))
    parser.add_argument('--jobs', type=int, default=min(8, os.cpu_count() or 2))
    parser.add_argument('--update-baseline', action='store_true')
    parser.add_argument('--tier', choices=('all', 'fast', 'slow'), default='all')
    parser.add_argument('--shard', default='1/1', help='I/N: run one of N duration-balanced slices')
    args = parser.parse_args()
    index, count = (int(x) for x in args.shard.split('/'))
    assert 1 <= index <= count, 'Shard must be I/N with 1 <= I <= N'
    run(args.lune, args.jobs, args.update_baseline, args.tier, (index, count))
