"""Independent convex clip reference: enumerate original/box vertices and edge hits, then take an exact hull.

The Luau implementation uses sequential half-plane clipping instead. Run StyLua on
the generated fixture after regeneration. Standard library only.
"""
from fractions import Fraction as F
from decimal import Decimal, localcontext
from pathlib import Path
import struct, random, math, json
rng=random.Random(51928)
def f32(x):return struct.unpack('<f',struct.pack('<f',float(x)))[0]
def cross(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
def hull(points):
 p=sorted(set(points))
 if len(p)<3:return []
 def half(q):
  out=[]
  for t in q:
   while len(out)>=2 and cross(out[-2],out[-1],t)<=0:out.pop()
   out.append(t)
  return out
 return half(p)[:-1]+half(p[::-1])[:-1]
def clip(poly):
 pts=[p for p in poly if all(0<=v<=1 for v in p)]
 for p in [(F(0),F(0)),(F(1),F(0)),(F(1),F(1)),(F(0),F(1))]:
  if all(cross(poly[i],poly[(i+1)%len(poly)],p)>=0 for i in range(len(poly))):pts.append(p)
 for i,a in enumerate(poly):
  b=poly[(i+1)%len(poly)]
  for ax in (0,1):
   for side in (0,1):
    if b[ax]==a[ax]:continue
    t=(side-a[ax])/(b[ax]-a[ax])
    if 0<=t<=1:
     p=tuple(a[j]+t*(b[j]-a[j]) for j in (0,1))
     if all(0<=v<=1 for v in p):pts.append(p)
 return hull(pts)
def rounded(q):
 # Independent candidate from Python's IEEE conversion, audited against exact midpoint neighbors.
 v=f32(float(q));bits=struct.unpack('<I',struct.pack('<f',v))[0]
 choices=[]
 for n in range(max(0,bits-2),min(0x3f800000,bits+2)+1):
  x=struct.unpack('<f',struct.pack('<I',n))[0]
  choices.append((abs(F(x)-q),n%2,x))
 return min(choices)[2]
fixtures=[]
for i in range(160):
 raw=[(F(f32(rng.uniform(-.6,1.6))),F(f32(rng.uniform(-.6,1.6))))for _ in range(3+i%7)]
 poly=hull(raw);shift=(rng.choice((-1,0,1)),rng.choice((-1,0,1))) if i%4==0 else (0,0)
 moved=[(x+shift[0],y+shift[1])for x,y in poly];out=clip(moved)
 err=F(0);native=[]
 for p in out:
  q=tuple(rounded(v)for v in p);native.append(list(q));err=max(err,sum((F(q[j])-p[j])**2 for j in (0,1)))
 with localcontext() as ctx:
  ctx.prec=400
  exact=(Decimal(err.numerator)/Decimal(err.denominator)).sqrt();bound=float(exact)
  if Decimal(bound)<exact:bound=math.nextafter(bound,math.inf)
 fixtures.append({'input':[[float(x),float(y)]for x,y in poly],'shift':shift,'output':native,'bound':bound})
def luau(value):
 if isinstance(value,dict):return '{'+','.join(key+'='+luau(item) for key,item in value.items())+'}'
 if isinstance(value,(tuple,list)):return '{'+','.join(luau(item) for item in value)+'}'
 return repr(value)
root=Path(__file__).resolve().parents[1]
(root/'tests/TrimClipFixtures.luau').write_text('-- Independent Fraction clipping vertices and 400-digit distance bounds.\nreturn {\n'+',\n'.join(luau(f) for f in fixtures)+'\n}\n')
print({'cases':len(fixtures),'nonempty':sum(bool(f['output']) for f in fixtures),'points':sum(len(f['output']) for f in fixtures)})
