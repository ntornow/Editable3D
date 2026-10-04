"""Install only the exact official CLI archives and SHA-256s in toolchain.lock.json."""
from pathlib import Path
import hashlib
import io
import json
import platform
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def install():
    system = {'Linux': 'linux', 'Darwin': 'macos'}.get(platform.system(), platform.system())
    arch = {'arm64': 'aarch64', 'AMD64': 'x86_64'}.get(platform.machine(), platform.machine())
    key = f'{system}-{arch}'
    lock = json.loads((ROOT/'toolchain.lock.json').read_text())
    assert key in lock['platforms'], f'Unsupported toolchain platform: {key}'
    destination = ROOT/'.tools'
    destination.mkdir(exist_ok=True)
    for name, entry in lock['platforms'][key].items():
        target = destination/name
        receipt = target/'receipt.json'
        if receipt.exists():
            saved = json.loads(receipt.read_text())
            if saved.get('archive') == entry['sha256'] and all((target/p).is_file() and hashlib.sha256((target/p).read_bytes()).hexdigest() == h for p,h in saved.get('binaries', {}).items()) and set(saved.get('binaries', {})) == set(entry['programs']):
                continue
        print(f'Downloading {name} {entry["version"]} ({key})', flush=True)
        request = urllib.request.Request(entry['url'], headers={'User-Agent': 'Editable3D-toolchain'})
        with urllib.request.urlopen(request, timeout=60) as response:
            archive = response.read()
        assert hashlib.sha256(archive).hexdigest() == entry['sha256'], f'Checksum mismatch: {name}'
        target.mkdir(exist_ok=True)
        hashes = {}
        with zipfile.ZipFile(io.BytesIO(archive)) as source:
            for program in entry['programs']:
                members = [p for p in source.namelist() if Path(p).name == program and not p.endswith('/')]
                assert len(members) == 1, f'Missing or ambiguous binary: {program}'
                data = source.read(members[0])
                path = target/program
                path.write_bytes(data)
                path.chmod(0o755)
                hashes[program] = hashlib.sha256(data).hexdigest()
        receipt.write_text(json.dumps({'archive': entry['sha256'], 'version': entry['version'], 'binaries': hashes}, indent=2)+'\n')
    return destination


if __name__ == '__main__':
    print(install())
