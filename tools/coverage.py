"""Run actual Luau VM line coverage for the service-independent strict core.

Inline modules allow the CLI to instrument their closures. The emitted LCOV maps
executable lines back to original files; tests and loader code are excluded.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CORE = ('OperationBudget', 'PublishRetry', 'PublishTransaction', 'PublishPipeline')
TESTS = ('TestHarness', 'OperationBudgetTests', 'PublishTests')


def run(luau='luau'):
    directory = ROOT / '.validation/coverage'
    directory.mkdir(parents=True, exist_ok=True)
    lines = ['local loaders,cache={},{}', 'local function loadModule(name)', 'if cache[name]==nil then cache[name]=loaders[name]() end', 'return cache[name]', 'end']
    spans = {}
    for name in CORE + TESTS:
        path = ROOT / ('src' if name in CORE else 'tests') / (name + '.luau')
        source = re.sub(r'require\(script\.Parent\.(\w+)\)', r'loadModule("\1")', path.read_text())
        lines.append(f'loaders["{name}"]=function()')
        start = len(lines) + 1
        lines.extend(source.splitlines())
        if name in CORE:
            spans[name] = (start, len(lines))
        lines.append('end')
    lines.extend(['for _,name in {"OperationBudgetTests","PublishTests"} do', 'local r=loadModule(name)()', 'for _,c in r.results do if not c.passed then print(c.name,c.error) end end', 'assert(r.failed==0,name)', 'end'])
    bundle = directory / 'bundle.luau'
    bundle.write_text('\n'.join(lines)+'\n')
    subprocess.run([luau, '--coverage', str(bundle)], cwd=directory, check=True)
    hits = {}
    for line in (directory/'coverage.out').read_text().splitlines():
        if line.startswith('DA:'):
            number, count = map(int, line[3:].split(','))
            hits[number] = hits.get(number, 0) + count
    reports, lcov = {}, []
    for name, (start, end) in spans.items():
        executable = {number-start+1: count for number, count in hits.items() if start <= number <= end}
        assert executable, f'Missing instrumentation: {name}'
        covered = sum(count > 0 for count in executable.values())
        ratio = covered / len(executable)
        reports[name] = {'covered': covered, 'executable': len(executable), 'percent': round(100*ratio, 2), 'uncovered': [n for n,c in executable.items() if not c]}
        lcov.extend(['TN:', f'SF:src/{name}.luau', *[f'DA:{n},{c}' for n,c in sorted(executable.items())], f'LF:{len(executable)}', f'LH:{covered}', 'end_of_record'])
    (directory/'lcov.info').write_text('\n'.join(lcov)+'\n')
    (ROOT/'.validation/coverage.json').write_text(json.dumps({'metric': 'Luau VM executable line coverage', 'thresholdPerModule': 90, 'modules': reports}, indent=2)+'\n')
    print(json.dumps(reports))
    assert all(row['percent'] >= 90 for row in reports.values()), 'Strict core line coverage below 90%'


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--luau', default='luau')
    run(parser.parse_args().luau)
