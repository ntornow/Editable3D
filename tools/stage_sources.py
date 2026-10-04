"""Write an isolated Studio development source bundle, leaving release artifacts alone."""
from pathlib import Path
import json
import sys

root = Path(__file__).resolve().parents[1]
files = []
for folder in ('src', 'tests', 'examples'):
    for path in sorted((root / folder).glob('*.luau')):
        files.append({
            'name': 'Editable3D' if path.stem == 'init' else path.stem,
            'path': '' if path.stem == 'init' else ('Examples/' if folder == 'examples' else '') + path.stem,
            'source': path.read_text(),
        })
for entry in files:
    assert len(entry['source'].encode('utf-8')) < 200000, f"Studio source limit exceeded: {entry['path']}"
target = Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(files))
print(f'Staged {len(files)} ModuleScripts')
