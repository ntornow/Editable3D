"""Build a portable ModuleScript tree and source manifest. Standard library only."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from api_reference import generate

parser = argparse.ArgumentParser()
parser.add_argument("--profile", choices=("development", "production"), default="development")
profile = parser.parse_args().profile
root = Path(__file__).resolve().parents[1]
api_entries = generate(root)
files = []
for path in sorted((root / 'src').glob('*.luau')):
    files.append({'name': 'Editable3D' if path.stem == 'init' else path.stem,
                  'path': '' if path.stem == 'init' else path.stem,
                  'source': path.read_text()})
for folder in (('tests', 'examples') if profile == 'development' else ()):
    for path in sorted((root / folder).glob('*.luau')):
        files.append({'name': path.stem, 'path': path.stem if folder == 'tests' else 'Examples/' + path.stem,
                      'source': path.read_text()})
for entry in files:
    assert len(entry['source'].encode('utf-8')) < 200000, f"Studio source limit exceeded: {entry['path']}"
doc = ET.Element('roblox', {'version': '4'})
counter = 0
def item(parent, classname, name, source=None):
    global counter
    counter += 1
    node = ET.SubElement(parent, 'Item', {'class': classname, 'referent': f'RBX{counter}'})
    props = ET.SubElement(node, 'Properties')
    ET.SubElement(props, 'string', {'name': 'Name'}).text = name
    if source is not None:
        ET.SubElement(props, 'ProtectedString', {'name': 'Source'}).text = source
    return node
main = next(f for f in files if f['path'] == '')
module = item(doc, 'ModuleScript', 'Editable3D', main['source'])
folders = {'': module}
for f in files:
    if not f['path']:
        continue
    parent_path = str(Path(f['path']).parent).replace('.', '')
    if parent_path not in folders:
        folders[parent_path] = item(module, 'Folder', parent_path)
    item(folders[parent_path], 'ModuleScript', f['name'], f['source'])
for name in ([p.stem for p in sorted(root.glob('*.md')) if p.stem != 'CHANGELOG'] if profile == 'development' else ['README']):
    path = root / (name + '.md')
    if path.exists():
        doc_name = name + '_GUIDE' if any(f['name'] == name and '/' not in f['path'] for f in files) else name
        node = item(module, 'StringValue', doc_name)
        ET.SubElement(node.find('Properties'), 'string', {'name': 'Value'}).text = path.read_text()
output = root / 'dist' / ('production' if profile == 'production' else '')
output.mkdir(parents=True, exist_ok=True)
artifact = output / 'Editable3D.rbxmx'
ET.ElementTree(doc).write(artifact, encoding='utf-8', xml_declaration=False)
(output / 'sources.json').write_text(json.dumps(files))
version = re.search(r'Version = "([^"]+)"', main['source']).group(1)
manifest = {'profile': profile, 'version': version, 'modules': len(files), 'publicFunctions': len(api_entries), 'sourceBytes': sum(len(f['source'].encode()) for f in files),
            'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(), 'files': [{'path': f['path'], 'sha256': hashlib.sha256(f['source'].encode()).hexdigest()} for f in files]}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({k: manifest[k] for k in ('version', 'modules', 'publicFunctions', 'sourceBytes', 'sha256')}))
