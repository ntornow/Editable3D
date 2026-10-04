from fractions import Fraction as F
from pathlib import Path
import json,random
rng=random.Random(6801)
def add(a,b):return [x+y for x,y in zip(a,b)]
def scale(a,s):return [x*s for x in a]
def sub(a,b):return add(a,scale(b,-1))
def cross(a,b):return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def encode(q):return [q.numerator,q.denominator]
cases=[]
for index in range(48):
 a=[F(rng.randrange(-32,33),8) for _ in range(3)]
 while True:
  e=[F(rng.randrange(-6,7),4) for _ in range(3)];f=[F(rng.randrange(-6,7),4)for _ in range(3)]
  n=cross(e,f)
  if dot(n,n)>0:break
 tri=[a,add(a,e),add(a,f)]
 noise=scale(n,F((-1)**index,8))
 # Known KKT witnesses: interior normal, edge outward conormal, corner dual cone.
 weights=[[F(1,2),F(1,4),F(1,4)],[F(3,4),F(1,4),F(0)],[F(1),F(0),F(0)]]
 face=add(add(a,scale(e,F(1,4))),scale(f,F(1,4)))
 edge=add(a,scale(e,F(1,4)))
 points=[add(face,noise),add(add(edge,scale(cross(e,n),F(1,8))),noise),add(add(add(a,scale(cross(f,n),F(-1,8))),scale(cross(n,e),F(-1,8))),noise)]
 for dimension,p,q,w in zip([2,1,0],points,[face,edge,a],weights):
  delta=sub(p,q)
  assert all(dot(delta,sub(x,q))<=0 for x in tri)
  cases.append(dict(triangle=[[encode(x)for x in row]for row in tri],point=[encode(x)for x in p],closest=[encode(x)for x in q],squared=encode(dot(delta,delta)),weights=[encode(x)for x in w],dimension=dimension))
text='-- Independent exact KKT closest-feature fixtures.\nreturn [==['+json.dumps(cases,separators=(',',':'))+']==]\n'
(Path(__file__).resolve().parents[1]/'tests'/'FeatureClosestFixtures.luau').write_text(text)
print(len(cases),'independent exact closest-feature KKT fixtures')
