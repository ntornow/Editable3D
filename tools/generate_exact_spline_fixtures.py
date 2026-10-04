"""Independent Fraction arithmetic and pointwise de Boor boundary references.

The production boundary test compares polynomial coefficients. Here, exact
pointwise evaluations at 2*q+1 distinct parameters decide each degree-2*q
cross-product polynomial. No production extraction or arithmetic is used.
"""
from fractions import Fraction as F
from pathlib import Path
import random, struct, json, math

root = Path(__file__).resolve().parents[1]
rng = random.Random(54002)
base = 2**24

def limbs(n):
    out = []
    while n:
        out.append(n % base)
        n //= base
    return out

def record(f):
    return dict(sign=(f > 0) - (f < 0), n=limbs(abs(f.numerator)), d=limbs(f.denominator))

def fixture(name, value):
    text = json.dumps(value, separators=(',', ':'))
    assert ']===]' not in text
    source = '-- Generated independent references; decode only when running tests.\nreturn [===[' + text + ']===]\n'
    assert len(source.encode()) < 200000
    (root / 'tests' / (name + '.luau')).write_text(source)

rows = []
for i in range(64):
    bits = [8, 24, 53, 96, 160, 256, 512, 1024][i // 8]
    a = F(rng.getrandbits(bits) * rng.choice([-1, 1]), rng.getrandbits(bits) or 1)
    b = F(rng.getrandbits(bits) * rng.choice([-1, 1]), rng.getrandbits(bits) or 1)
    if i % 11 == 0:
        b = a
    if i % 13 == 0:
        a = F(0)
    rows.append(dict(a=record(a), b=record(b), add=record(a+b), sub=record(a-b), mul=record(a*b), div=record(a/b) if b else None, comparison=(a>b)-(a<b)))
values = []
for bits in [0, 1, 2, 2**52-1, 2**52, 2**63, 2**63+1, 0x7fefffffffffffff] + [rng.getrandbits(64) for _ in range(88)]:
    x = struct.unpack('<d', struct.pack('<Q', bits))[0]
    if math.isfinite(x):
        values.append(dict(lo=bits % 2**32, hi=bits // 2**32, expected=record(F(x))))
fixture('ExactRationalFixtures', dict(rows=rows, values=values))

def de_boor(points, degree, knots, parameter):
    count = len(points)
    span = count-1 if parameter == knots[count] else next(i for i in range(degree, count) if knots[i] <= parameter < knots[i+1])
    data = [list(points[span-degree+j]) for j in range(degree+1)]
    for r in range(1, degree+1):
        for j in range(degree, r-1, -1):
            i = span-degree+j
            alpha = (parameter-knots[i])/(knots[i+degree-r+1]-knots[i])
            data[j] = [(1-alpha)*a+alpha*b for a, b in zip(data[j-1], data[j])]
    return data[degree]

def identity(row):
    p, q = row['degreeU'], row['degreeV']
    ku, kv = list(map(F, row['knotsU'])), list(map(F, row['knotsV']))
    nu, nv = len(row['control']), len(row['control'][0])
    endpoints = []
    for t in (ku[p], ku[nu]):
        boundary = []
        for j in range(nv):
            points = [[F(x)*F(row['weights'][i][j]) for x in row['control'][i][j]] + [F(row['weights'][i][j])] for i in range(nu)]
            boundary.append(de_boor(points, p, ku, t))
        endpoints.append(boundary)
    samples = 0
    for span in range(q, nv):
        lo, hi = kv[span:span+2]
        if lo == hi:
            continue
        for i in range(2*q+1):
            t = lo+(hi-lo)*F(i, 2*q)
            a, b = [de_boor(c, q, kv, t) for c in endpoints]
            samples += 1
            if any(a[k]*b[3] != b[k]*a[3] for k in range(3)):
                return False, samples
    return True, samples

def knots(degree, count, clamped, scale):
    values = ([0]*(degree+1)+[1/3, 2/3]+[1]*(degree+1)) if clamped else list(range(-degree, count+1))
    assert len(values) == count+degree+1
    return [x*scale for x in values]

boundaries = []
for i in range(32):
    p, q = i % 6+1, (i//6) % 4+1
    nu, nv = p+3, q+3
    scale = 2.**([-50, 0, 50, 0][i % 4])
    knot_scale = 2.**([-901, 0, 901, 0][i % 4])
    control = [[[rng.randrange(-8, 9)*scale/4 for _ in range(3)] for _ in range(nv)] for _ in range(nu)]
    weights = [[rng.choice([.5, 1., 2., 4.]) for _ in range(nv)] for _ in range(nu)]
    if i % 4 in (0, 1):
        control[-1] = [v[:] for v in control[0]]
        weights[-1] = [2*x for x in weights[0]]
        if i % 4 == 1:
            control[-1][0][2] += scale*2**-20
    elif i % 4 == 2:
        for j in range(nv):
            for k in range(1, nu):
                control[k][j] = control[0][j][:]
                weights[k][j] = weights[0][j]*2**(k % 3)
    row = dict(control=control, weights=weights, degreeU=p, degreeV=q, knotsU=knots(p, nu, i % 4 < 2, knot_scale), knotsV=knots(q, nv, i % 3 != 0, 1))
    row['expected'], row['referenceSamples'] = identity(row)
    assert row['expected'] == (i % 2 == 0)
    boundaries.append(row)
fixture('BoundaryIdentityFixtures', boundaries)
print(dict(arithmeticCases=len(rows), float64Inputs=len(values), boundaryCases=len(boundaries), referenceSamples=sum(r['referenceSamples'] for r in boundaries)))
