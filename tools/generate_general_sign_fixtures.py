from fractions import Fraction as Q
from pathlib import Path
import random,json
rng=random.Random(66317)
def limbs(n):
 out=[]
 while n:out.append(n%(1<<24));n>>=24
 return out
def encode(q):return {'sign':(q>0)-(q<0),'n':limbs(abs(q.numerator)),'d':limbs(q.denominator)}
def mul(a,b):
 out=[Q(0)]*(len(a)+len(b)-1)
 for i,x in enumerate(a):
  for j,y in enumerate(b):out[i+j]+=x*y
 return out
def sign_at(poly,d,orientation):
 a=sum((v*d**(i//2)for i,v in enumerate(poly)if i%2==0),Q(0))
 b=orientation*sum((v*d**(i//2)for i,v in enumerate(poly)if i%2),Q(0))
 if not a:return (b>0)-(b<0)
 if not b:return (a>0)-(a<0)
 if (a>0)==(b>0):return (a>0)-(a<0)
 delta=a*a-b*b*d
 return ((a>0)-(a<0))*((delta>0)-(delta<0))
cases=[]
for d in [Q(1,2),Q(2,3),Q(3,5),Q(5,7),Q(25,128),Q(33,128)]:
 lo,hi=Q(0),Q(1)
 for _ in range(420):
  mid=(lo+hi)/2
  if mid*mid<d:lo=mid
  else:hi=mid
 for orientation in [-1,1]:
  f=mul([-d,Q(0),Q(1)],[Q(-2),Q(-1),Q(1)]) # extra roots -1,2
  # Use a broad initial isolator to exercise sign determination, not refinement.
  low,high=(Q(-1),Q(0))if orientation<0 else(Q(0),Q(1))
  # Extra root -1 would be a bad endpoint: move it to -2 with polynomial (x+2)(x-2).
  f=mul([-d,Q(0),Q(1)],[Q(-4),Q(0),Q(1)])
  polynomials=[]
  for j in range(10):
   p=[Q(rng.randrange(-20,21),rng.randrange(1,9))for _ in range(1+j%7)]
   polynomials.append(p)
  polynomials.extend([mul([-d,Q(0),Q(1)],[Q(3),Q(-2),Q(4)]),[-orientation*lo,Q(1)],[-orientation*hi,Q(1)]])
  for p in polynomials:
   cases.append({'f':[encode(x)for x in f],'g':[encode(x)for x in p],'low':encode(low),'high':encode(high),'sign':sign_at(p,d,orientation)})
# The exact cancellation captured in the nonlinear closure experiment.
path=Path(__file__).resolve().parent/'fixtures'/'general_sign_cancellation.json'
assert path.exists(), "Missing captured cancellation reference"
if path.exists():
 x=json.loads(path.read_text())
 cases.append({'f':x['modulus'],'g':x['p'],'low':x['low'],'high':x['high'],'sign':1})
p=Path(__file__).resolve().parents[1]/'tests'/'SturmTarskiFixtures.luau'
p.write_text('return [==['+json.dumps(cases,separators=(',',':'))+']==]\n')
print(len(cases),'independent quadratic-field sign fixtures',p.stat().st_size,'bytes')
