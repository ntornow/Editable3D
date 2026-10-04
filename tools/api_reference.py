"""Generate a signature index from public Luau definitions."""
from pathlib import Path
import json
import re


HEADER = re.compile(r'^function\s+([A-Za-z_]\w*)([.:])([A-Za-z_]\w*)\s*(<[^>\n]*>)?\s*\(', re.M)


def _split_top(text):
    """Split on commas that are not nested inside (), {} or <>."""
    parts, depth, current = [], 0, ''
    for ch in text:
        if ch in '({<':
            depth += 1
        elif ch in ')}>':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(current)
            current = ''
        else:
            current += ch
    if current.strip():
        parts.append(current)
    return [re.sub(r'\s+', ' ', p).strip() for p in parts]


def signatures(source):
    """Yield (receiver, separator, name, params, returns) for top-level function definitions.

    Handles typed parameters (including function types with parentheses), generics, and the
    strict-mode method form `function M.name(self: T, ...)`, which is reported as `M:name(...)`.
    """
    for match in HEADER.finditer(source):
        receiver, separator, name, generics = match.group(1), match.group(2), match.group(3), match.group(4) or ''
        depth, i = 1, match.end()
        while depth:
            depth += {'(': 1, ')': -1}.get(source[i], 0)
            i += 1
        params = _split_top(source[match.end():i - 1])
        rest = source[i:source.index('\n', i) if '\n' in source[i:] else len(source)].strip()
        returns = rest[1:].strip() if rest.startswith(':') else ''
        if separator == '.' and params and re.match(r'^self\s*:', params[0]):
            separator, params = ':', params[1:]
        yield receiver, separator, name + generics, params, returns


def generate(root: Path):
    initializer = (root / 'src/init.luau').read_text()
    version = re.search(r'Version = "([^"]+)"', initializer).group(1)
    public_modules = set(re.findall(r'^\t(\w+) = require\(script\.(\w+)\),$', initializer, re.M))
    public_modules = {module for key, module in public_modules if key == module}
    if not public_modules:
        raise ValueError('Public namespace table is missing from init.luau')
    lines = [
        '# Editable3D API reference', '',
        f'Public callable signatures for version {version}. See [README.md](README.md) for coordinate, mutation, scope and algorithm contracts.', '',
        'Typed boundary contracts and resource/publishing options: [PRODUCTION.md](PRODUCTION.md). Development and release workflow: [MAINTAINING.md](MAINTAINING.md).', '',
        'Constructors use dots (`E.Mesh.new()`); instance methods use colons (`mesh:addVertex(...)`). Ordinary module operators use dots and generally return a new mesh/image.', '',
    ]
    entries = []
    for path in sorted((root / 'src').glob('*.luau')):
        if path.stem not in public_modules:
            continue
        functions = list(signatures(path.read_text()))
        if not functions:
            continue
        lines.extend(['## ' + path.stem, '', f'Source: [src/{path.name}](src/{path.name})', ''])
        if path.stem == 'Spatial':
            functions.append(('Spatial', '.', 'closestTriangle', ['point', 'a', 'b', 'c'], ''))
        for receiver, separator, name, params, returns in functions:
            if path.stem == 'Boolean' and receiver == 'Node':
                continue  # Private BSP nodes are not returned by the API.
            signature = path.stem + separator + name + '(' + ', '.join(params) + ')' + (': ' + returns if returns else '')
            lines.append('- `' + signature + '`')
            entries.append({'module': path.stem, 'member': re.sub(r'<.*', '', name), 'method': separator == ':', 'signature': signature})
        lines.append('')
    lines.extend([
        '## Additional returned objects', '',
        '- `Subdivision.multires(mesh, levels, options)` returns `get()`, `select(level)`, and `commit(editedMesh)` methods.',
        '- `Jobs.start(operation)` returns a job with `cancel()`, `status`, `progress`, `result`, and `error`.', '',
        '- `ArcLength.prepare(curve, options)` returns `atLength(distance)`, `atFraction(fraction)` and `sample(count)` dot-call functions with immutable length bounds.', '',
        '## Native handle ownership', '',
        '`Roblox.toEditable` returns an editable handle; destroy its `part` (if created) and `editable` when finished. `Roblox.toModel` and `toTexturedModel` return a bundle; use `Roblox.destroy(bundle)` for cleanup. Native content is ephemeral until explicitly published or reconstructed from a source checkpoint.', '',
    ])
    (root / 'API.md').write_text('\n'.join(lines))
    (root / 'dist').mkdir(exist_ok=True)
    (root / 'dist' / 'api-index.json').write_text(json.dumps(entries, indent=2) + '\n')
    return entries


if __name__ == '__main__':
    entries = generate(Path(__file__).resolve().parents[1])
    print(json.dumps({'publicFunctions': len(entries), 'namespaces': len({e['module'] for e in entries})}))
