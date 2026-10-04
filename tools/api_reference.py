"""Generate a signature index from public Luau definitions."""
from pathlib import Path
import json
import re


def generate(root: Path):
    initializer = (root / 'src/init.luau').read_text()
    version = re.search(r'Version = "([^"]+)"', initializer).group(1)
    export_table = re.search(r'for _, name in\s*\{(.*?)\}\s*do', initializer, re.S)
    if export_table is None:
        raise ValueError('Public namespace export table is missing from init.luau')
    public_modules = set(re.findall(r'"([A-Za-z_][\w]*)"', export_table.group(1)))
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
        functions = re.findall(r'^function\s+([A-Za-z_][\w]*)([.:])([A-Za-z_][\w]*)\s*\(([^)]*)\)', path.read_text(), re.M)
        if not functions:
            continue
        lines.extend(['## ' + path.stem, '', f'Source: [src/{path.name}](src/{path.name})', ''])
        if path.stem == 'Spatial':
            functions.append(('Spatial', '.', 'closestTriangle', 'point, a, b, c'))
        for receiver, separator, name, arguments in functions:
            if path.stem == 'Boolean' and receiver == 'Node':
                continue  # Private BSP nodes are not returned by the API.
            signature = path.stem + separator + name + '(' + re.sub(r'\s+', ' ', arguments).strip() + ')'
            lines.append('- `' + signature + '`')
            entries.append({'module': path.stem, 'member': name, 'method': separator == ':', 'signature': signature})
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
