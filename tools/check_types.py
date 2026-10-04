"""Roblox-aware type checking for the whole package, plus public contract fixtures.

luau-lsp analyzes every source, test and example with the pinned Roblox API definitions and
a Rojo sourcemap, so `require(script.Parent.X)`, Vector3, CFrame, EditableMesh and friends are
real types rather than `any`. Two levels are enforced:

1. Zero analyzer errors anywhere (nonstrict modules included).
2. Every module in STRICT_MODULES is `--!strict` (it may not silently regress to nonstrict).

Contract fixtures then exercise the public API as a strict caller would: the positive fixture
must type-check, and each negative fixture must be rejected with a TypeError in the fixture.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / '.validation/contracts'
# Studio release scripts are analyzed too; studio_read_report is a placeholder template.
ANALYZED = ['src', 'tests', 'examples', 'tools/studio_install.luau', 'tools/studio_verify.luau']

# Modules promoted to --!strict (every public namespace plus internal helpers promoted so far).
# Add to this list when promoting; never remove silently.
STRICT_MODULES = (
    'ARAP', 'Adaptive', 'Animation', 'ArcLength', 'Attributes', 'BSDF', 'Bake', 'Bezier',
    'Boolean', 'Camera', 'Capabilities', 'Conformal', 'Connectivity', 'Constraints', 'Convex',
    'Curves', 'Cyclic', 'Deform', 'Dynamics', 'Fields', 'Fluid', 'GLTF', 'Geometry', 'Graph',
    'History', 'IO', 'Integrator', 'Intersections', 'Jobs', 'Laplacian', 'Lighting', 'Mesh',
    'MeshEdit', 'MeshRepair', 'Modifiers', 'Morph', 'NURBS', 'Normals', 'OperationBudget',
    'Particles', 'PathTrace', 'Pattern', 'Planar', 'Predicates', 'Primitives', 'PublishPipeline',
    'PublishRetry', 'PublishTransaction', 'Quaternion', 'Registration', 'Remesh', 'Render', 'Rig',
    'RigidBody', 'Roblox', 'Sculpt', 'Selection', 'Simplify', 'Simulation', 'Spatial', 'SplineFit',
    'SplineQuery', 'Stroke', 'Subdivision', 'SurfaceAdaptive', 'SurfaceDeform', 'SurfaceEdit',
    'SurfaceTrim', 'Surfaces', 'Texture', 'Timeline', 'Topology', 'Types', 'UV', 'Unwrap', 'Util',
    'init',
)

PRELUDE = '--!strict\nlocal E = require("../../src")\nlocal T = require("../../src/Types")\n'

POSITIVE = '''
local limits: T.Limits = { maxWork = 100, cancelled = function() return false end }
local bake: T.BakeOptions = { samples = 16, padding = 2, maxTriangles = 100 }
local publish: T.PublishOptions = { attempts = 3, resume = {} }
local function resize(texture: E.Texture): E.Texture
	return texture:resize(4, 8, limits)
end
local mesh: E.Mesh = E.Mesh.new()
local a = mesh:addVertex(Vector3.new(0, 0, 0))
local b = mesh:addVertex(Vector3.new(1, 0, 0))
local c = mesh:addVertex(Vector3.new(0, 1, 0))
local face: number = mesh:addFace({ a, b, c }, nil, 1)
local normal: Vector3, area: number = mesh:faceNormal(face)
local report: E.ValidationReport = mesh:validate({ minimumFaceArea = 0 })
local closed: boolean = report.closed
local triangles = mesh:faceTriangles(face, { maxWork = 1000 })
local first: number = triangles[1][1]
local lo: Vector3, hi: Vector3 = mesh:bounds()
local version: string = E.Version
local box: E.Mesh = E.Primitives.box(Vector3.new(4, 5, 3))
local smooth: E.Mesh = E.Subdivision.catmullClark(box, 2)
local mapped: E.Mesh = E.UV.spherical(smooth)
local json: string = E.IO.encode(mapped)
local decoded: E.Mesh = E.IO.decode(json)
local image: E.Texture = E.Texture.noise(64, 64, 8, 4, 1)
return {
	resize = resize, bake = bake, publish = publish, normal = normal, area = area, closed = closed,
	first = first, lo = lo, hi = hi, version = version, decoded = decoded, image = image,
}
'''

# Each statement must fail to type-check. Keep these small and unambiguous.
NEGATIVE = [
    'local value: T.Limits = { maxWork = "unbounded" }',
    'local value: T.BakeOptions = { samples = "many" }',
    'local value: T.PublishOptions = { attempts = false }',
    'local function value(t: T.Texture) return t:resize("wide", 4) end',
    'local function value(t: T.Texture): number return t:clone() end',
    'local value = E.Mesh.new():addVertex(1)',
    'local value: string = E.Mesh.new():validate().faces',
    'local value = E.Mesh.new():faceTriangles("first")',
    'local value = E.Mesh.new():validate({ minimumFaceArea = "small" })',
    'local value: number = E.Mesh.new():bounds()',
    'local value = E.Missing',
    'local value = E.Primitives.box("wide")',
    'local value: number = E.Primitives.sphere(1)',
    'local value = E.Subdivision.catmullClark(E.Primitives.box(), "twice")',
    'local value = E.IO.encode(42)',
    'local value: number = E.IO.encode(E.Mesh.new())',
    'local value = E.Texture.noise("64", 64)',
    'local value = E.Roblox.toModel(42)',
]


def analyze(lsp, definitions, sourcemap, paths):
    result = subprocess.run(
        [lsp, 'analyze', '--platform=roblox', f'--sourcemap={sourcemap}',
         f'--definitions=@roblox={definitions}', '--base-luaurc=.luaurc', *map(str, paths)],
        cwd=ROOT, capture_output=True, text=True)
    return [line for line in (result.stdout + result.stderr).splitlines()
            if re.search(r'\(\d+,\d+\): \w+Error: ', line)]


def check(lsp, definitions, rojo):
    strict = {p.stem for p in (ROOT / 'src').glob('*.luau') if p.read_text().startswith('--!strict')}
    missing = set(STRICT_MODULES) - strict
    assert not missing, f'Modules must stay --!strict: {sorted(missing)}'
    unlisted = strict - set(STRICT_MODULES)
    assert not unlisted, f'Add newly strict modules to STRICT_MODULES: {sorted(unlisted)}'

    sourcemap = ROOT / '.validation/sourcemap.json'
    sourcemap.parent.mkdir(exist_ok=True)
    subprocess.run([rojo, 'sourcemap', 'default.project.json', '-o', str(sourcemap)],
                   cwd=ROOT, check=True, capture_output=True)

    errors = analyze(lsp, definitions, sourcemap, ANALYZED)
    if errors:
        raise RuntimeError('Type errors:\n' + '\n'.join(errors))

    FIXTURES.mkdir(parents=True, exist_ok=True)
    for stale in FIXTURES.glob('*.luau'):
        stale.unlink()
    positive = FIXTURES / 'positive.luau'
    positive.write_text(PRELUDE + POSITIVE)
    errors = [e for e in analyze(lsp, definitions, sourcemap, [positive]) if 'contracts/positive' in e]
    if errors:
        raise RuntimeError('Positive contract fixture rejected:\n' + '\n'.join(errors))

    for index, statement in enumerate(NEGATIVE):
        path = FIXTURES / f'negative_{index}.luau'
        path.write_text(PRELUDE + statement + '\nreturn value\n')
        errors = [e for e in analyze(lsp, definitions, sourcemap, [path]) if f'contracts/negative_{index}' in e]
        if not any('TypeError' in e for e in errors):
            raise AssertionError(f'Invalid contract accepted: {statement}')

    report = {
        'strictModules': sorted(strict),
        'analyzed': ANALYZED,
        'analyzerErrors': 0,
        'positivePassed': True,
        'negativeCasesRejected': len(NEGATIVE),
        'robloxDefinitions': Path(definitions).name,
    }
    (ROOT / '.validation/types.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Type check: 0 errors across src/tests/examples; {len(strict)} strict modules; '
          f'rejected invalid contracts: {len(NEGATIVE)}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--lsp', default=str(ROOT / '.tools/luau-lsp/luau-lsp'))
    parser.add_argument('--definitions', default=str(ROOT / '.tools/roblox-types/globalTypes.None.d.luau'))
    parser.add_argument('--rojo', default=str(ROOT / '.tools/rojo/rojo'))
    args = parser.parse_args()
    check(args.lsp, args.definitions, args.rojo)
