"""Exact rational Cox-de Boor values and normalized first derivatives, independent of extraction."""
from fractions import Fraction as F
from pathlib import Path
import math
import struct

def bits(x):
    return struct.pack(">d", float(x)).hex()

def enclosure(x):
    n = float(x)
    lo = math.nextafter(n, -math.inf) if F(n) > x else n
    hi = math.nextafter(n, math.inf) if F(n) < x else n
    return '{"' + bits(lo) + '","' + bits(hi) + '"}'

def vector(values):
    return '{' + ','.join(enclosure(x) for x in values) + '}'

def basis(n, p, knots, parameter):
    k = list(map(F, knots)); t = F(parameter)
    scale = k[n] - k[p]; u = k[p] + t * scale
    b = [F(int((k[i] < u <= k[i+1]) if t == 1 else (k[i] <= u < k[i+1]))) for i in range(n+p)]
    d = [F(0)] * len(b)
    for degree in range(1, p+1):
        nb, nd = [], []
        for i in range(n+p-degree):
            a, z = k[i+degree]-k[i], k[i+degree+1]-k[i+1]
            nb.append(((u-k[i])*b[i]/a if a else 0) + ((k[i+degree+1]-u)*b[i+1]/z if z else 0))
            nd.append((degree*b[i]/a if a else 0) - (degree*b[i+1]/z if z else 0))
        b, d = nb, nd
    return b, [x*scale for x in d]

parameters = [0., .1, .2, .375, .5, .9, 1.]
cp = [[.25,-.5,0],[.75,.5,1],[1.25,-.25,-1],[2,0,.5]]
cw = [.5,1.5,.75,2.]
curve = []
for t in parameters:
    b, d = basis(4,2,[-2,-1,0,.375,1,2,3],t)
    h = [[F(x)*F(w)/2 for x in p+[1]] for p,w in zip(cp,cw)]
    value = [sum(b[i]*h[i][k] for i in range(4)) for k in range(4)]
    derivative = [sum(d[i]*h[i][k] for i in range(4)) for k in range(4)]
    curve.append('{t="'+bits(t)+'",value='+vector(value)+',derivative='+vector(derivative)+',position='+vector([x/value[3] for x in value[:3]])+'}')
points = [[[i*.5,(j-1)*.25,((i+1)*(j+1)%5)*.125] for j in range(4)] for i in range(3)]
weights = [[.5+(((i+1)*3+j+1)%7)/8 for j in range(4)] for i in range(3)]
maximum = max(map(max,weights))
h = [[[F(x)*F(weights[i][j])/F(maximum) for x in points[i][j]+[1]] for j in range(4)] for i in range(3)]
surface=[]
for u in parameters:
    bu,du=basis(3,2,[0,0,0,1,1,1],u)
    for v in parameters:
        bv,dv=basis(4,2,[-3,-1,2,3.5,5,7,9],v)
        def evaluate(a,b):return [sum(a[i]*b[j]*h[i][j][k] for i in range(3) for j in range(4)) for k in range(4)]
        value,hu,hv=evaluate(bu,bv),evaluate(du,bv),evaluate(bu,dv)
        surface.append('{u="'+bits(u)+'",v="'+bits(v)+'",value='+vector(value)+',du='+vector(hu)+',dv='+vector(hv)+',position='+vector([x/value[3] for x in value[:3]])+'}')
output='-- Generated independently by tools/generate_interval_spline_fixtures.py using Fraction.\nreturn {curve={'+',\n'.join(curve)+'},surface={'+',\n'.join(surface)+'}}\n'
assert len(output)<200000
(Path(__file__).resolve().parents[1]/'tests'/'IntervalSplineFixtures.luau').write_text(output)
print(f'Generated {len(curve)} curve and {len(surface)} tensor-surface exact jet fixtures')
