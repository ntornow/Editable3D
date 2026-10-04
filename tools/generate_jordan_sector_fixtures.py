"""Exact 15-control constrained half-grid: includes the complete annular halo."""
from fractions import Fraction as F
from pathlib import Path
import json
coords=[(i,j) for j in range(3) for i in range(-2,3)]
index={p:i for i,p in enumerate(coords)}
n=len(coords)
zero=lambda:[[F(0) for _ in range(n)]for _ in range(n)]
I=zero()
for i in range(n):I[i][i]=F(1)
def add(a,b):return [[x+y for x,y in zip(row,other)]for row,other in zip(a,b)]
def scale(a,k):return [[x*k for x in row]for row in a]
def product(a,b):return [[sum((a[i][k]*b[k][j] for k in range(n)),F(0))for j in range(n)]for i in range(n)]
def outer(a,b):return [[x*y for y in b]for x in a]
def poly_matrix(p,a):
    out=zero()
    for x in reversed(p):out=add(product(out,a),scale(I,x))
    return out

def mask(i):
    if i%2:return {i//2:F(1,2),i//2+1:F(1,2)}
    return {i//2-1:F(1,8),i//2:F(6,8),i//2+1:F(1,8)}
A=zero()
for r,(i,j) in enumerate(coords):
    if (i,j)==(0,0):A[r][index[(0,0)]]=1;continue
    for x,wx in mask(i).items():
        for y,wy in ({0:F(1)} if j==0 else mask(j)).items():A[r][index[(x,y)]]+=wx*wy
assert all(sum(row)==1 for row in A)
# Faddeev-LeVerrier, exact independent matrix characteristic polynomial.
B=I
coeff=[F(1)]
for k in range(1,n+1):
    AB=product(A,B)
    c=-sum(AB[i][i] for i in range(n))/k
    coeff.append(c);B=add(AB,scale(I,c))
assert B==zero()
p=list(reversed(coeff))
def divide(p,root):
    q=[F(0)]*(len(p)-1)
    for j in range(len(q)-1,-1,-1):q[j]=p[j+1]+(root*q[j+1]if j+1<len(q)else 0)
    return q,p[0]+root*q[0]
def value(p,x):return sum((c*x**i for i,c in enumerate(p)),F(0))
factors={}
q=p
for root in [F(1),F(1,2),F(1,4),F(1,8),F(1,16),F(1,32),F(1,64),F(1,128)]:
    while len(q)>1:
        trial,remainder=divide(q,root)
        if remainder:break
        factors[root]=factors.get(root,0)+1;q=trial
assert q==[1],q
print('Exact spectrum:',{str(k):v for k,v in factors.items()})
assert factors[F(1,2)]==3
q=p
for _ in range(3):q,remainder=divide(q,F(1,2));assert not remainder
q0=value(q,F(1,2));q1=value([i*q[i]for i in range(1,len(q))],F(1,2));q2=value([F(i*(i-1),2)*q[i]for i in range(2,len(q))],F(1,2))
N0=add(A,scale(I,F(-1,2)))
h=add(add(scale(I,1/q0),scale(N0,-q1/q0**2)),scale(product(N0,N0),q1**2/q0**3-q2/q0**2))
P=product(poly_matrix(q,A),h)
N=product(N0,P)
assert product(P,P)==P and product(N,N)==zero()
center=[F(int(p==(0,0)))for p in coords]
C=outer([F(1)]*n,center)
assert product(A,C)==C and product(C,A)==C and product(C,P)==zero()
X=[F(i)for i,j in coords];Y=[F(j)for i,j in coords]
s=[F(0)]*n;s[index[(1,0)]]=s[index[(-1,0)]]=1;s[index[(0,0)]]=-2
t=[F(0)]*n;t[index[(1,0)]]=F(1,2);t[index[(-1,0)]]=F(-1,2)
a=[F(0)]*n;a[index[(0,1)]]=F(2,3);a[index[(1,1)]]=a[index[(-1,1)]]=F(1,6);a[index[(0,0)]]=-1
W=[(row[index[(1,0)]]+row[index[(-1,0)]])/2 for row in P]
assert N==scale(outer(Y,s),F(1,12))
assert P==add(add(outer(X,t),outer(Y,a)),outer(W,s))
assert product(A,outer(X,t))==scale(outer(X,t),F(1,2))
assert product(A,outer(Y,a))==scale(outer(Y,a),F(1,2))
print('Exact generalized projection = X*t + Y*a + W*s')
print('Exact nilpotent coupling = Y*s/12; N^2=0')
print('W =',{str(c):str(v)for c,v in zip(coords,W)})
R=add(add(add(A,scale(C,-1)),scale(P,F(-1,2))),scale(N,-1))
assert product(R,P)==zero()and product(R,C)==zero()
# Full identity, including the halo, for initial powers.
Ak=I;Rk=I
for k in range(1,9):
    Ak=product(Ak,A);Rk=product(Rk,R)
    exact=add(add(add(C,scale(P,F(1,2)**k)),scale(N,k*F(1,2)**(k-1))),Rk)
    assert Ak==exact
print('Full exact A^k decomposition verified at 8 powers')
def enc(x):return [str(x.numerator),str(x.denominator)]
data=dict(coordinates=coords,matrix=[[enc(x)for x in row]for row in A],projector=[[enc(x)for x in row]for row in P],nilpotent=[[enc(x)for x in row]for row in N],generalizedMode=list(map(enc,W)),spectrum=[[enc(k),v]for k,v in factors.items()])
(Path(__file__).resolve().parents[1]/'tests/JordanSectorFixtures.luau').write_text('-- Generated independent Fraction matrix certificate.\nreturn [=['+json.dumps(data,separators=(',',':'))+']=]\n')
