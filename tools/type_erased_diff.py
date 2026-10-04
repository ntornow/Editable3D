"""Report functions whose code changed, ignoring type information (for typing-only refactors).

Usage: python3 tools/type_erased_diff.py [--rev HEAD]


Reports, per changed file, the top-level functions whose type-erased AST differs.
Erased: annotations, return annotations, generics, `::` casts, type aliases, locations.
Equivalences: `function M:f(...)` == `function M.f(self, ...)`; a group created only to hold a
cast around a non-call expression is unwrapped (grouping a call would truncate results, so
it is kept).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AST = str(ROOT / '.tools/luau/luau-ast')
DROP = {'location', 'nameLocation', 'varargLocation', 'luauType', 'returnAnnotation', 'generics',
        'genericPacks', 'annotation', 'attributes', 'isConst', 'argLocation', 'typeAnnotation'}


def norm(node):
    if isinstance(node, list):
        out = []
        for item in node:
            if isinstance(item, dict) and item.get('type') in ('AstStatTypeAlias', 'AstStatTypeFunction'):
                continue
            out.append(norm(item))
        return out
    if not isinstance(node, dict):
        return node
    kind = node.get('type')
    if kind == 'AstExprTypeAssertion':
        inner = node['expr']
        if isinstance(inner, dict) and inner.get('type') in ('AstExprCall', 'AstExprVarargs'):
            # A cast truncates a call or ... to one value, so it is not erasable.
            return {'type': 'TruncatedByCast', 'expr': norm(inner)}
        return norm(inner)
    if kind == 'AstExprGroup':
        inner = node['expr']
        while isinstance(inner, dict) and inner.get('type') == 'AstExprTypeAssertion':
            inner = inner['expr']
        if isinstance(inner, dict) and inner.get('type') not in ('AstExprCall', 'AstExprVarargs'):
            if node['expr'].get('type') == 'AstExprTypeAssertion':
                return norm(inner)
    if kind in ('AstExprLocal',):
        return {'type': kind, 'name': node['local']['name'] if 'local' in node else node['name']}
    if kind == 'AstLocal':
        return {'type': kind, 'name': node['name']}
    if kind == 'AstExprFunction':
        node = dict(node)
        args = list(node.get('args', []))
        if node.get('self'):
            args = [{'type': 'AstLocal', 'name': 'self'}] + args
        node['args'] = args
        node.pop('self', None)
        # `local p = p or d` redeclaring a parameter at function top == `p = p or d`.
        names = {a['name'] for a in args}
        body = dict(node['body'])
        stats = []
        leading = True
        for stat in body['body']:
            # Only before the first closure: a later redeclaration would not update captures.
            leading = leading and 'AstExprFunction' not in json.dumps(stat)
            if (leading and stat.get('type') == 'AstStatLocal' and len(stat['vars']) == len(stat['values'])
                    and all(v['name'] in names for v in stat['vars'])):
                stat = {'type': 'AstStatAssign',
                        'vars': [{'type': 'AstExprLocal', 'name': v['name']} for v in stat['vars']],
                        'values': stat['values']}
            stats.append(stat)
        body['body'] = stats
        node['body'] = body
    out = {}
    for key, value in node.items():
        if key in DROP or key.lower().endswith('location') or (isinstance(value, dict) and str(value.get('type', '')).startswith('AstType')):
            continue
        out[key] = norm(value)
    return out


def functions(path):
    data = json.loads(subprocess.run([AST, path], capture_output=True, text=True, check=True).stdout)
    result, other = {}, []
    for stat in data['root']['body']:
        kind = stat.get('type')
        if kind == 'AstStatFunction':
            name = stat['name']
            label = json.dumps(norm(name), sort_keys=True)
            try:
                label = f"{name['expr'].get('global') or name['expr'].get('local', {}).get('name')}.{name['index']}"
            except Exception:
                pass
            result[label] = json.dumps(norm(stat['func']), sort_keys=True)
        elif kind == 'AstStatLocalFunction':
            result['local ' + stat['name']['name']] = json.dumps(norm(stat['func']), sort_keys=True)
        else:
            other.append(json.dumps(norm(stat), sort_keys=True))
    result['<top-level statements>'] = '\n'.join(other)
    return result


def compare(old_path, new_path, label):
    a, b = functions(old_path), functions(new_path)
    changed = [k for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]
    if changed:
        print(f'{label}: {len(changed)} of {len(b) - 1} functions differ after type erasure')
        for k in changed:
            print('   ', k)
    return len(changed)


def main():
    """Compare every changed src/*.luau file against a git revision (default HEAD)."""
    import argparse
    import tempfile
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--rev', default='HEAD')
    args = parser.parse_args()
    names = subprocess.run(['git', 'diff', '--name-only', args.rev, '--', 'src'], cwd=ROOT,
                           capture_output=True, text=True, check=True).stdout.split()
    total = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name in names:
            path = ROOT / name
            if not path.exists():
                continue
            old = subprocess.run(['git', 'show', f'{args.rev}:{name}'], cwd=ROOT, capture_output=True, text=True)
            if old.returncode:
                print(f'{name}: new file')
                continue
            old_file = Path(tmp) / Path(name).name
            old_file.write_text(old.stdout)
            total += compare(old_file, path, name)
    print(f'{len(names)} changed files; {total} functions need review (all others are identical once types are erased)')


if __name__ == '__main__':
    main()
