from fractions import Fraction as F
from pathlib import Path
import random,json
rng=random.Random(6901)
def add(a,b):return [x+y for x,y in zip(a,b)]
def scale(a,s):return [x*s for x in a]
def sub(a,b):return add(a,scale(b,-1))
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def cross(a,b):return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def enc(q):return [q.numerator,q.denominator]
cases=[]
for index in range(96):
 a0=[F(rng.randrange(-8,9),4)for _ in range(3)]
 while True:
  e=[F(rng.randrange(-5,6),4)for _ in range(3)];f=[F(rng.randrange(-5,6),4)for _ in range(3)];n=cross(e,f)
  if dot(n,n)>0:break
 s=F(rng.randrange(1,8),8);t=F(rng.randrange(1,8),8)
 q=add(a0,scale(e,s));h=F(rng.randrange(-4,5),16);r=add(q,scale(n,h));b0=sub(r,scale(f,t))
 assert dot(sub(r,q),e)==0 and dot(sub(r,q),f)==0
 cases.append(dict(a=[[enc(x)for x in p]for p in [a0,add(a0,e)]],b=[[enc(x)for x in p]for p in [b0,add(b0,f)]],first=[enc(x)for x in q],second=[enc(x)for x in r],s=enc(s),t=enc(t),squared=enc(dot(sub(r,q),sub(r,q)))))
for index in range(64):
 a0=[F(rng.randrange(-8,9),4)for _ in range(3)]
 while True:
  e=[F(rng.randrange(-5,6),4)for _ in range(3)];w=[F(rng.randrange(-5,6),4)for _ in range(3)];n=scale(cross(e,w),F(1,16))
  if dot(n,n)>0:break
 while True:
  k,l=rng.randrange(-4,13),rng.randrange(-4,13)
  lo,hi=max(0,min(k,l)),min(8,max(k,l))
  if lo<hi:break
 mid=F(lo+hi,2);q=add(a0,scale(e,mid));r=add(q,n)
 a=[a0,add(a0,scale(e,8))];b=[add(add(a0,scale(e,k)),n),add(add(a0,scale(e,l)),n)]
 cases.append(dict(a=[[enc(x)for x in p]for p in a],b=[[enc(x)for x in p]for p in b],first=[enc(x)for x in q],second=[enc(x)for x in r],s=enc(mid/8),t=enc((mid-k)/(l-k)),squared=enc(dot(n,n)),parallel=True))
(Path(__file__).resolve().parents[1]/'tests'/'EdgeClosestFixtures.luau').write_text('-- Independent orthogonal and parallel-overlap interior edge-pair witnesses.\nreturn [==['+json.dumps(cases,separators=(',',':'))+']==]\n')
print(len(cases),'independent exact closest edge-pair fixtures')
