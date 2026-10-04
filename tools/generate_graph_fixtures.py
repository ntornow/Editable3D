from fractions import Fraction as Q
from pathlib import Path
import json, random
rng=random.Random(64065)

def encode(x):
 return [x.numerator,x.denominator]
def value(control,weights,u,v):
 bu=[(1-u)**2,2*u*(1-u),u*u];bv=[(1-v)**2,2*v*(1-v),v*v]
 out=[Q(0)]*4
 for i in range(3):
  for j in range(3):
   c=bu[i]*bv[j]*weights[i][j]
   for k in range(3):out[k]+=c*control[i][j][k]
   out[3]+=c
 return [x/out[3] for x in out[:3]]
def map_forms(direction,affine):
 drop=next(i for i,d in enumerate(direction)if d)
 rows=[]
 for axis in range(3):
  if axis==drop:continue
  forbase=affine[axis]if axis<2 else[Q(0)]*3
  dropbase=affine[drop]if drop<2 else[Q(0)]*3
  rows.append([direction[drop]*x-direction[axis]*y for x,y in zip(forbase,dropbase)])
 return rows
cases=[]
for n in range(12):
 direction=[Q(x)for x in ([0,0,1]if n%2==0 else[1,2,4])]
 A=[[Q(1,8),Q(2),Q(1,4)],[Q(-1,4),Q(-1,4),Q(1)]]
 # B parameters correspond to A coordinates (s + shear*(t-.5), t).
 shear=Q((n%3)-1,2)
 B=[[row[0]-row[1]*shear/2,row[1],row[2]+row[1]*shear]for row in A]
 controls=[];weights=[]
 for operand,affine in enumerate([A,B]):
  ws=([1,2,3]if (n+operand)%2==0 else[3,2,1])
  wt=([1,2,3]if (n+operand)%3==0 else[3,2,1])
  xs=([Q(0),Q(1,4),Q(1)]if ws[0]==1 else[Q(0),Q(3,4),Q(1)])
  ys=([Q(0),Q(1,4),Q(1)]if wt[0]==1 else[Q(0),Q(3,4),Q(1)])
  points=[];ww=[]
  for i,x in enumerate(xs):
   points.append([]);ww.append([])
   for j,y in enumerate(ys):
    height=Q(rng.randrange(-32,33),32)
    base=[row[0]+row[1]*x+row[2]*y for row in affine]+[Q(0)]
    points[-1].append([c+d*height for c,d in zip(base,direction)])
    ww[-1].append(ws[i]*wt[j])
  controls.append(points);weights.append(ww)
 samples=[]
 for i in range(1,9):
  for j in range(1,5):
   u,v=Q(i,10),Q(j,5)
   s,t=u-shear*(v-Q(1,2)),v
   if not 0<=s<=1:continue
   samples.append({'a':[encode(u),encode(v)],'b':[encode(s),encode(t)],
    'values':[[encode(x)for x in value(c,w,*uv)]for c,w,uv in zip(controls,weights,[(u,v),(s,t)])]})
 cases.append({'direction':[float(x)for x in direction],
  'control':[[[[float(x)for x in p]for p in row]for row in c]for c in controls],
  'weights':weights,'projectionForms':[[[encode(x)for x in row]for row in map_forms(direction,a)]for a in [A,B]],
  'parameterMap':[[encode(shear/2),encode(Q(1)),encode(-shear)],[encode(Q(0)),encode(Q(0)),encode(Q(1))]],'samples':samples})
data={'cases':cases,'evaluations':sum(len(c['samples'])*2 for c in cases)}
path=Path(__file__).resolve().parents[1]/'tests'/'WeightedGraphFixtures.luau'
path.write_text('return [==['+json.dumps(data,separators=(',',':'))+']==]\n')
print(len(cases),data['evaluations'],path.stat().st_size)
