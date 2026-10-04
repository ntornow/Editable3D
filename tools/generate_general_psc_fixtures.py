from fractions import Fraction as Q
from itertools import permutations
from pathlib import Path
import json,random
rng=random.Random(65066)

def add(a,b):
 out=dict(a)
 for k,v in b.items():
  out[k]=out.get(k,Q(0))+v
  if not out[k]:del out[k]
 return out

def scale(a,c):return {k:v*c for k,v in a.items()if v*c}
def mul(a,b):
 out={}
 for (i,j),x in a.items():
  for (k,l),y in b.items():
   key=(i+k,j+l);out[key]=out.get(key,Q(0))+x*y
 return {k:v for k,v in out.items()if v}
def determinant(matrix):
 n=len(matrix);out={}
 if n==0:return {(0,0):Q(1)}
 for order in permutations(range(n)):
  inversions=sum(order[i]>order[j]for i in range(n)for j in range(i+1,n))
  product={(0,0):Q((-1)**inversions)}
  for i,j in enumerate(order):product=mul(product,matrix[i][j])
  out=add(out,product)
 return out

def psc(a,b):
 m,n=len(a)-1,len(b)-1;result=[]
 for j in range(min(m,n)+1):
  size=m+n-2*j;matrix=[]
  for row in range(size):
   poly,degree,shift=(a,m,row)if row<n-j else(b,n,row-(n-j))
   matrix.append([poly[degree-column+shift]if 0<=degree-column+shift<len(poly)else{}for column in range(size)])
  result.append(determinant(matrix))
 return result

def encode(coefficients):
 return [[i,j,k,v.numerator,v.denominator]for k,p in enumerate(coefficients)for(i,j),v in sorted(p.items())]
def random_poly(degree):
 out=[]
 for _ in range(degree+1):
  p={(0,0):Q(rng.randrange(-3,4)),(1,0):Q(rng.randrange(-2,3)),(0,1):Q(rng.randrange(-2,3))}
  out.append({k:v for k,v in p.items()if v})
 if not out[-1]:out[-1]={(0,0):Q(1)}
 return out
cases=[]
for i in range(20):
 m,n=[(1,1),(2,1),(2,2),(3,1),(3,2)][i%5]
 a,b=random_poly(m),random_poly(n)
 cases.append({'a':encode(a),'b':encode(b),'psc':[encode([p])for p in psc(a,b)]})
# Shared z+x factor; independent symbolic expansion.
a=[{(1,1):Q(-1)},{(1,0):Q(1),(0,1):Q(-1)},{(0,0):Q(1)}]
b=[{(1,0):Q(1)},{(1,0):Q(1),(0,0):Q(1)},{(0,0):Q(1)}]
cases.append({'a':encode(a),'b':encode(b),'psc':[encode([p])for p in psc(a,b)]})
result={'cases':cases,'minors':sum(len(c['psc'])for c in cases)}
p=Path(__file__).resolve().parents[1]/'tests'/'PrincipalSubresultantFixtures.luau'
p.write_text('return [==['+json.dumps(result,separators=(',',':'))+']==]\n')
print('Independent permutation determinants',result['minors'],'minors',p.stat().st_size,'bytes')
