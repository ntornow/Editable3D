"""Generate reproducible independent rational common-cell retopology fixtures."""
from fractions import Fraction as F
from decimal import Decimal,localcontext
from pathlib import Path
import random,struct,json,math
rng=random.Random(530928)
uv={}
def det(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
def clip(poly,a,b):
 out=[]
 if not poly:return out
 for p,q in zip(poly,poly[1:]+poly[:1]):
  dp,dq=det(a,b,p),det(a,b,q)
  if dp>=0:out.append(p)
  if (dp<0 and dq>0) or (dp>0 and dq<0):
   t=dp/(dp-dq);out.append((p[0]+t*(q[0]-p[0]),p[1]+t*(q[1]-p[1])))
 return out

def intersection(a,b):
 poly=[tuple(map(F,uv[i])) for i in a]
 for i in range(3):poly=clip(poly,uv[b[i]],uv[b[(i+1)%3]])
 return poly

def value(t,p,positions):
 a,b,c=[uv[i] for i in t];d=det(a,b,c)
 w=[det(b,c,p)/d,det(c,a,p)/d,det(a,b,p)/d]
 return [sum(F(positions[t[i]-1][axis])*w[i] for i in range(3)) for axis in range(3)]

f32=lambda x:struct.unpack('f',struct.pack('f',x))[0]
rows=[]
for index in range(96):
 n=3 if index%2==0 else 4
 corners=[(0,0),(6,0),(0,6)] if n==3 else [(0,0),(6,0),(6,6),(0,6)]
 uv={i+1:p for i,p in enumerate(corners)}
 center=n+1;uv[center]=(2,2) if n==3 else (3,3)
 for i in range(n):uv[n+2+i]=tuple((corners[i][j]+corners[(i+1)%n][j])//2 for j in range(2))
 source=[[1,2,3]] if n==3 else ([[1,2,3],[1,3,4]] if index%4==1 else [[1,2,4],[2,3,4]])
 target=[]
 for i in range(n):
  a,b,c,d=i+1,n+2+i,center,n+2+(i-1)%n
  target+=([[a,b,c],[a,c,d]] if rng.choice((0,1)) else [[a,b,d],[b,c,d]])
 scale=2.**([-60,-20,0,20,60,0][index//16])
 original=[]
 for x,y in corners:original.append([f32(x*scale/6),f32(y*scale/6),f32(rng.uniform(-.25,.25)*scale)])
 positions=original[:]
 positions.append([f32(sum(p[j] for p in original)/n) for j in range(3)])
 for i in range(n):positions.append([f32((original[i][j]+original[(i+1)%n][j])/2)for j in range(3)])
 if index//16==5:
  for i in range(n,len(positions)):
   positions[i]=[f32(x+rng.uniform(-.02,.02))for x in positions[i]]
 largest=F(0);overlaps=[]
 for i,a in enumerate(source):
  for j,b in enumerate(target):
   poly=intersection(a,b)
   area=sum(p[0]*q[1]-p[1]*q[0] for p,q in zip(poly,poly[1:]+poly[:1]))
   if area>0:overlaps.append([i+1,j+1])
   for point in poly:
    va,vb=value(a,point,positions),value(b,point,positions)
    largest=max(largest,sum((x-y)**2 for x,y in zip(va,vb)))
 with localcontext() as ctx:
  ctx.prec=400
  val=(Decimal(largest.numerator)/Decimal(largest.denominator)).sqrt();upper=float(val)
  if Decimal(upper)<val:upper=math.nextafter(upper,math.inf)
 rows.append(dict(triangle=n==3,uv=list(uv.values()),source=source,target=target,positions=positions,upper=upper,overlaps=overlaps))
def luau(value):
 if isinstance(value, bool): return 'true' if value else 'false'
 if isinstance(value, (float, int)): return repr(value)
 if isinstance(value, (list, tuple)): return '{'+','.join(luau(v) for v in value)+'}'
 if isinstance(value, dict): return '{'+','.join(k+'='+luau(v) for k,v in value.items())+'}'
 raise TypeError(type(value))
root=Path(__file__).resolve().parents[1]
(root/'tests/QuadPatchFixtures.luau').write_text('-- Independent Fraction clipping and 400-digit norm references.\nreturn '+luau(rows)+'\n')
print({'cases':len(rows),'positivePairs':sum(len(row['overlaps']) for row in rows)})

density=[]
for index in range(64):
 den=2**([0,3,16,24][index%4])
 u=rng.randrange(den+1);v=rng.randrange(den-u+1)
 weights=[F(den-u-v,den),F(u,den),F(v,den)]
 scale=2.**([-60,-20,0,20,60,0,0,0][index//8])
 points=[[f32(rng.uniform(-2,2)*scale) for _ in range(3)] for _ in range(3)]
 exact=[sum(F(points[i][axis])*weights[i] for i in range(3)) for axis in range(3)]
 point=[f32(float(x)) for x in exact]
 if index%3==0:point[2]=f32(point[2]+0.015625*scale)
 squared=sum((x-F(y))**2 for x,y in zip(exact,point))
 with localcontext() as ctx:
  ctx.prec=400
  value=(Decimal(squared.numerator)/Decimal(squared.denominator)).sqrt();upper=float(value)
  if Decimal(upper)<value:upper=math.nextafter(upper,math.inf)
 density.append(dict(positions=points,point=point,uv=[u,v],denominator=den,upper=upper))
(root/'tests/QuadDensityFixtures.luau').write_text('-- Independent exact barycentric differences and 400-digit norms.\nreturn '+luau(density)+'\n')
print({'densityCases':len(density)})
