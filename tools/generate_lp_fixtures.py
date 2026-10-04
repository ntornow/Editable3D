"""Independent Fraction RREF and line/rectangle clipping references."""
from fractions import Fraction as F
from pathlib import Path
import json
import random

rng = random.Random(620062)


def add(a, b):
    return [[(a[i][j] if i < len(a) and j < len(a[i]) else 0) + (b[i][j] if i < len(b) and j < len(b[i]) else 0) for j in range(max(max(map(len, a), default=0), max(map(len, b), default=0)))] for i in range(max(len(a), len(b)))]


def multiply(a, b):
    if not a or not b:
        return []
    out = [[0] * (max(map(len, a)) + max(map(len, b)) - 1) for _ in range(len(a) + len(b) - 1)]
    for i, row in enumerate(a):
        for j, x in enumerate(row):
            for k, other in enumerate(b):
                for l, y in enumerate(other):
                    out[i + k][j + l] += x * y
    return out


def value(p, s, t):
    return sum((F(x) * s**j * t**i for i, row in enumerate(p) for j, x in enumerate(row)), F(0))


def reference(equations, s, t):
    matrix = [[value(e[k], s, t) for k in ('a', 'b', 'c')] for e in equations]
    row = 0
    pivots = []
    for column in range(2):
        pivot = next((i for i in range(row, len(matrix)) if matrix[i][column]), None)
        if pivot is None:
            continue
        matrix[row], matrix[pivot] = matrix[pivot], matrix[row]
        coefficient = matrix[row][column]
        matrix[row] = [x / coefficient for x in matrix[row]]
        for i in range(len(matrix)):
            if i != row:
                coefficient = matrix[i][column]
                matrix[i] = [x - coefficient * y for x, y in zip(matrix[i], matrix[row])]
        pivots.append(column)
        row += 1
    if any(not a and not b and c for a, b, c in matrix):
        return -1
    if row == 0:
        return 2
    if row == 2:
        x, y = -matrix[0][2], -matrix[1][2]
        return 0 if 0 <= x <= 1 and 0 <= y <= 1 else -1
    a, b, c = matrix[0]
    points = set()
    for x in (F(0), F(1)):
        if b:
            y = -(c + a * x) / b
            if 0 <= y <= 1:
                points.add((x, y))
    for y in (F(0), F(1)):
        if a:
            x = -(c + b * y) / a
            if 0 <= x <= 1:
                points.add((x, y))
    return -1 if not points else 0 if len(points) == 1 else 1


def random_poly():
    return [[rng.randint(-2, 2), rng.randint(-2, 2)], [rng.randint(-2, 2)]]


rows = []
for index in range(64):
    if index % 4 == 0:
        base = {k: random_poly() for k in ('a', 'b', 'c')}
        equations = [{k: multiply(p, m) for k, p in base.items()} for m in ([[1]], [[0, 1]], [[0], [1]])]
    elif index % 4 == 1:
        a, b = ({k: random_poly() for k in ('a', 'b', 'c')} for _ in range(2))
        equations = [a, b, {k: add(multiply(a[k], [[0, 1]]), multiply(b[k], [[0], [1]])) for k in a}]
    elif index % 4 == 2:
        p = random_poly()
        equations = [dict(a=[], b=[], c=p), dict(a=[], b=[], c=multiply(p, [[0, 1]])), dict(a=[], b=[], c=[])]
    else:
        equations = [dict(a=[[0, 1]], b=[], c=multiply([[0, 1]], random_poly())), dict(a=[], b=[[0], [1]], c=multiply([[0], [1]], random_poly())), dict(a=[], b=[], c=[])]
    probes = [dict(s=float(s), t=float(t), dimension=reference(equations, s, t)) for s in (F(0), F(1, 4), F(1, 2), F(1)) for t in (F(0), F(1, 4), F(1, 2), F(1))]
    rows.append(dict(equations=equations, probes=probes))
path = Path(__file__).resolve().parents[1]/'tests/RuledFiberFixtures.luau'
path.write_text('-- Generated independent Fraction references.\nreturn [=['+json.dumps(rows, separators=(',', ':'))+']=]\n')
counts = {i: sum(p['dimension'] == i for row in rows for p in row['probes']) for i in (-1, 0, 1, 2)}
print(len(rows), 'systems;', sum(counts.values()), 'rational fibers;', counts)
