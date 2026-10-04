from fractions import Fraction as F
from pathlib import Path
import json,random
rng=random.Random(6802)
def sub(a,b):return [x-y for x,y in zip(a,b)]
def det(a,b,c):return (a[0]*(b[1]*c[2]-b[2]*c[1])-a[1]*(b[0]*c[2]-b[2]*c[0])+a[2]*(b[0]*c[1]-b[1]*c[0]))
def cross(a,b):return [det([1,0,0],a,b),det([0,1,0],a,b),det([0,0,1],a,b)]
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def enc(x):return [x.numerator,x.denominator]
cases=[]
for k in range(72):
 old=[[F(rng.randrange(-16,17),rng.choice([1,2,3,4,5,7]))for _ in range(3)]for _ in range(3)]
 if k%6==0: old=[[F(0),F(0),F(0)],[F(1),F(0),F(0)],[F(0),F(1),F(0)]]
 new=[[v+F(rng.randrange(-3,4),8)for v in p]for p in old] if k%3 else [[-v for v in p] for p in old]
 if k%6==1:new=[old[0],old[1],old[1]]
 n=cross(sub(old[1],old[0]),sub(old[2],old[0]))
 def evaluate(t):
  points=[[(1-t)*a+t*b for a,b in zip(x,y)]for x,y in zip(old,new)]
  return det(n,sub(points[1],points[0]),sub(points[2],points[0]))
 first,mid,last=evaluate(F(0)),evaluate(F(1,2)),evaluate(F(1))
 coefficients=[first,4*mid-first-last,last]
 cases.append(dict(reference=[[enc(x)for x in p]for p in old],current=[[enc(x)for x in p]for p in new],coefficients=[enc(x)for x in coefficients],valid=all(x>0 for x in coefficients),samples=[enc(evaluate(F(t,8)))for t in range(9)]))
p=Path(__file__).resolve().parents[1]/'tests'/'FeatureMotionFixtures.luau'
p.write_text('-- Independent determinant evaluations and interpolation of triangle motion.\nreturn [==['+json.dumps(cases,separators=(',',':'))+']==]\n')
print(len(cases),'exact motion fixtures;',len(cases)*3,'coefficients;',len(cases)*9,'determinant samples')
