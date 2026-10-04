from fractions import Fraction as Q
from pathlib import Path
import random,json
rng=random.Random(66003)
one={(0,0,0):Q(1)}
def add(a,b):
 out=dict(a)
 for k,v in b.items():out[k]=out.get(k,Q(0))+v
 return {k:v for k,v in out.items()if v}
def mul(a,b):
 out={}
 for i,x in a.items():
  for j,y in b.items():
   k=tuple(i[t]+j[t]for t in range(3));out[k]=out.get(k,Q(0))+x*y
 return {k:v for k,v in out.items()if v}
def product(factors):
 out=one
 for p in factors:out=mul(out,p)
 return out
def encode(p):return [list(k)+[v.numerator,v.denominator]for k,v in sorted(p.items())]
factors=[{(1,0,0):Q(1)},{(0,1,0):Q(1)},{(0,0,1):Q(1)}]
for i in range(9):
 # Distinct slopes guarantee nonassociate rational linear forms.
 factors.append({(0,0,0):Q(i-4,3),(1,0,0):Q(1),(0,1,0):Q(i+1),(0,0,1):Q((i+1)**2)})
cases=[]
for i in range(60):
 a=[0]*12;b=[0]*12
 for _ in range(1+i%4):a[rng.randrange(12)]+=1
 for _ in range(1+(i//4)%4):b[rng.randrange(12)]+=1
 cases.append({'a':encode(product([p for j,p in enumerate(factors)for _ in range(a[j])])),
 'b':encode(product([p for j,p in enumerate(factors)for _ in range(b[j])])),
 'gcd':encode(product([p for j,p in enumerate(factors)for _ in range(min(a[j],b[j]))]))})
for i in range(18):
 g=mul(factors[i%12],factors[(i+3)%12])
 p=add(mul(factors[(i+1)%12],factors[(i+7)%12]),one)
 h=mul(factors[(i+2)%12],factors[(i+5)%12])
 cases.append({'a':encode(mul(g,p)),'b':encode(mul(g,add(mul(p,h),one))),'gcd':encode(g)})
# Bad modular specializations must remain inconclusive, never false coprime.
p=add({(0,0,1):Q(65521)},one)
q=add({(0,1,0):Q(1,65521)},one)
for g in (p,q,mul(p,q)):
 cases.append({'a':encode(mul(g,factors[0])),'b':encode(mul(g,factors[1])),'gcd':encode(g)})
path=Path(__file__).resolve().parents[1]/'tests'/'MultivariateGcdFixtures.luau'
path.write_text('return [==['+json.dumps(cases,separators=(',',':'))+']==]\n')
print(len(cases),'independent exact factor identities',path.stat().st_size,'bytes')
