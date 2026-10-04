"""Independent exact stationary-star recurrences for fixed two-face sectors."""
from fractions import Fraction as F
from pathlib import Path
import json
import random

rng = random.Random(5701)
fixtures = []
for _ in range(48):
    scale = F(2) ** rng.randint(-24, 24)
    p = [F(rng.randint(-32, 32)) * scale for _ in range(3)]
    axis = [F(rng.randint(-8, 8)) * scale for _ in range(3)]
    edge = [F(rng.randint(-32, 32)) * scale for _ in range(3)]
    d0 = [F(rng.randint(-32, 32)) * scale for _ in range(3)]
    d1 = [F(rng.randint(-32, 32)) * scale for _ in range(3)]
    q = [edge[j] - p[j] for j in range(3)]
    ds = [d0[j] + d1[j] - 2 * p[j] for j in range(3)]
    expected = [(4 * q[j] + ds[j]) / 6 for j in range(3)]
    original = q[:]
    for k in range(12):
        # Face-center and smooth edge masks, relative to the fixed center.
        q, ds = ([F(3, 8) * q[j] + ds[j] / 16 for j in range(3)],
                 [q[j] / 2 + ds[j] / 4 for j in range(3)])
        for j in range(3):
            assert 2 ** (k + 1) * q[j] == (
                expected[j] + (original[j] - expected[j]) / 4 ** (k + 1))
    fixtures.append({
        'p': list(map(float, p)),
        'first': [float(p[j] + axis[j]) for j in range(3)],
        'last': [float(p[j] - axis[j]) for j in range(3)],
        'middle': list(map(float, edge)),
        'diagonals': [list(map(float, d0)), list(map(float, d1))],
        'tangent': list(map(float, axis)),
        'cross': list(map(float, expected)),
    })

target = Path(__file__).resolve().parents[1] / 'tests/FixedSectorFixtures.luau'
target.write_text('-- Independent Fraction recurrences: 48 stars, 12 exact refinement levels.\n'
                  'return game:GetService("HttpService"):JSONDecode([==['
                  + json.dumps(fixtures, separators=(',', ':')) + ']==])\n')
print('Generated 48 exact stationary-star references')
