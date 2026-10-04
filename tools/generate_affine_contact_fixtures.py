"""Independent Fraction/Cramer fixtures for exact affine surface contacts."""
from fractions import Fraction as F
from itertools import combinations, permutations, product
from pathlib import Path
import json
import random

ROOT = Path(__file__).resolve().parents[1]
RNG = random.Random(550019)


def rational(x):
    x = F(x)
    def limbs(n):
        out = []
        while n:
            out.append(n % 2**24)
            n //= 2**24
        return out
    return {"sign": (x > 0) - (x < 0), "n": limbs(abs(x.numerator)), "d": limbs(x.denominator)}


def determinant(m):
    n = len(m)
    result = F(0)
    for p in permutations(range(n)):
        sign = (-1) ** sum(p[i] > p[j] for i in range(n) for j in range(i+1, n))
        value = F(sign)
        for i in range(n):
            value *= m[i][p[i]]
        result += value
    return result


def rank(rows, columns):
    # Independent minors, rather than production row reduction.
    for size in range(min(len(rows), columns), 0, -1):
        for selected in combinations(rows, size):
            for axes in combinations(range(columns), size):
                if determinant([[row[a] for a in axes] for row in selected]):
                    return size
    return 0


def reference(a, b, bounds):
    equalities = [[F(a[1][k]), F(a[2][k]), -F(b[1][k]), -F(b[2][k]), F(b[0][k])-F(a[0][k])] for k in range(3)]
    candidates = list(equalities)
    for axis in range(4):
        for side in range(2):
            candidates.append([F(int(j == axis)) for j in range(4)] + [F(bounds[axis][side])])
    vertices = set()
    # All 4-row subsets of the original equality/boundary equations. Cramer's
    # determinants avoid production nullspace coordinates and elimination.
    for rows in combinations(candidates, 4):
        matrix = [r[:4] for r in rows]
        divisor = determinant(matrix)
        if not divisor:
            continue
        point = []
        for axis in range(4):
            replaced = [[r[4] if j == axis else r[j] for j in range(4)] for r in rows]
            point.append(determinant(replaced)/divisor)
        if not all(F(bounds[j][0]) <= point[j] <= F(bounds[j][1]) for j in range(4)):
            continue
        if any(sum(r[j]*point[j] for j in range(4)) != r[4] for r in equalities):
            continue
        vertices.add(tuple(point))
    vertices = sorted(vertices)
    dimension = rank([[p[j]-vertices[0][j] for j in range(4)] for p in vertices[1:]], 4) if vertices else -1
    world = [[F(a[0][j]) + F(a[1][j])*p[0] + F(a[2][j])*p[1] for j in range(3)] for p in vertices]
    spatial = rank([[p[j]-world[0][j] for j in range(3)] for p in world[1:]], 3) if world else -1
    return {"a": a, "b": b, "bounds": bounds, "dimension": dimension, "spatialDimension": spatial,
            "vertices": [[rational(x) for x in p] for p in vertices]}


def generate():
    unit = [[0,0,0], [1,0,0], [0,1,0]]
    seeds = [
        (unit, unit),
        (unit, [[.5,-.25,0], [.75,.75,0], [-.75,.75,0]]),
        (unit, [[1,1,0], [1,0,0], [0,1,0]]),
        (unit, [[1,0,0], [1,0,0], [0,1,0]]),
        (unit, [[0,.5,-1], [1,0,0], [0,0,2]]),
        (unit, [[0,0,1], [1,0,0], [0,1,0]]),
        (unit, [[.25,.75,0], [0,0,0], [0,0,0]]),
        ([[.5,.5,0],[0,0,0],[0,0,0]], [[.5,.5,0],[0,0,0],[0,0,0]]),
        (unit, [[-.5,-.5,0], [1,1,0], [1,1,0]]),
        ([[0,0,0],[1,0,0],[2,0,0]], [[0,0,0],[2,0,0],[1,0,0]]),
        ([[0,0,0],[1,0,0],[1,0,0]], [[0,2,0],[0,1,0],[0,1,0]]),
        (unit, [[1.25,0,0],[1,0,0],[0,1,0]]),
    ]
    rows = []
    for a, b in seeds:
        rows.append(reference(a,b,[[0,1] for _ in range(4)]))
    for i in range(60):
        if i < 24:
            a,b = seeds[i % len(seeds)]
            scale = 2.0 ** (-60 if i < 12 else 60)
            offset = [3*scale,-5*scale,7*scale]
            order = [(0,1,2),(2,0,1),(1,2,0)][i%3]
            def change(s):
                return [[s[0][j]*scale+offset[j] for j in order],
                        [s[1][j]*scale for j in order], [s[2][j]*scale for j in order]]
            a,b = change(a),change(b)
        else:
            a = [[RNG.randrange(-3,4) for _ in range(3)] for _ in range(3)]
            b = [[RNG.randrange(-3,4) for _ in range(3)] for _ in range(3)]
            if i % 3 == 0:
                for s in (a,b):
                    for v in s: v[2] = 0
            elif i % 3 == 1:
                # Force an interior common point with dyadic controls.
                b[0] = [a[0][j]+(a[1][j]+a[2][j]-b[1][j]-b[2][j])*.5 for j in range(3)]
        box = [[0,1] for _ in range(4)]
        if i >= 24 and i % 4 == 0:
            box = [[.125,.875],[0,.75],[.25,1],[.125,.625]]
        rows.append(reference(a,b,box))
    enclosures = []
    for i in range(80):
        bits = (1,17,53,100,250,1024)[i%6]
        n = RNG.randrange(1,2**bits)
        d = RNG.randrange(1,2**bits)
        x = F(n,d) * F(2)**((-120,-60,0,60,120)[i%5])
        enclosures.append(rational(x if i%2 else -x))
    enclosures += [rational(F(2)**2000),rational(-F(2)**2000),rational(F(2)**-2000),rational(-F(2)**-2000),rational(0)]
    output = {"rows":rows,"enclosures":enclosures}
    text = "-- Independent Fraction/Cramer and exact-minor references.\nreturn [===[" + json.dumps(output,separators=(',',':')) + "]===]\n"
    assert len(text.encode()) < 200000
    (ROOT/'tests/AffineContactFixtures.luau').write_text(text)
    print(len(rows),'affine configurations;',sum(len(row['vertices']) for row in rows),'vertices;',len(enclosures),'enclosures;',len(text),'source bytes')


if __name__ == '__main__':
    generate()
