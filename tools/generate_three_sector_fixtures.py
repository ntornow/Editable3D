"""Exact local Catmull-Clark masks on an n-face open quad sector and its full halo."""
from fractions import Fraction as F
from collections import defaultdict
from pathlib import Path
import json

def topology(n,extent=2):
 def vertex(k,i,j):
  if i==j==0:return ('c',)
  if j==0:return ('r',k,i)
  if i==0:return ('r',k+1,j)
  return ('f',k,i,j)
 vertices=[]
 for k in range(n):
  for j in range(extent+1):
   for i in range(extent+1):
    v=vertex(k,i,j)
    if v not in vertices:vertices.append(v)
 faces=[];face_keys={}
 for k in range(n):
  for j in range(extent):
   for i in range(extent):
    face=[vertex(k,i,j),vertex(k,i+1,j),vertex(k,i+1,j+1),vertex(k,i,j+1)]
    face_keys[(k,i,j)]=len(faces);faces.append(face)
 incident=defaultdict(list);edges=defaultdict(list);neighbors=defaultdict(set)
 for fi,face in enumerate(faces):
  for i,v in enumerate(face):
   incident[v].append(fi);w=face[(i+1)%4];key=tuple(sorted((v,w)));edges[key].append(fi);neighbors[v].add(w);neighbors[w].add(v)
 return vertex,vertices,faces,face_keys,incident,edges,neighbors

def masks(n,kind):
 vertex,vertices,faces,face_keys,incident,edges,neighbors=topology(n)
 def unit(v):return {v:F(1)}
 def blend(rows,weights):
  out=defaultdict(F)
  for row,w in zip(rows,weights):
   for v,x in row.items():out[v]+=x*w
  return {v:x for v,x in out.items()if x}
 face_rows=[blend([unit(v)for v in face],[F(1,4)]*4)for face in faces]
 edge_rows={}
 for (a,b),fs in edges.items():
  edge_rows[(a,b)]=blend([unit(a),unit(b)]+[face_rows[i]for i in fs],[F(1,4)]*4)if len(fs)==2 else blend([unit(a),unit(b)],[F(1,2)]*2)
 vertex_rows={}
 for v in vertices:
  hard=[w for w in neighbors[v]if len(edges[tuple(sorted((v,w)))])==1]
  if v==('c',)and kind=='corner':row=unit(v)
  elif hard:
   assert len(hard)==2
   row=blend([unit(v)]+[unit(w)for w in hard],[F(3,4),F(1,8),F(1,8)])
  else:
   count=len(neighbors[v]);assert count==len(incident[v])
   # (F+2R+(n-3)P)/n with R the average of edge midpoints.
   rows=[face_rows[i]for i in incident[v]]+[unit(w)for w in neighbors[v]]+[unit(v)]
   weights=[F(1,count**2)]*count+[F(1,count**2)]*count+[F(count-2,count)]
   row=blend(rows,weights)
  vertex_rows[v]=row
 def fine(k,i,j):
  a=vertex(k,i//2,j//2)
  if i%2 and j%2:return face_rows[face_keys[(k,i//2,j//2)]]
  if i%2:return edge_rows[tuple(sorted((a,vertex(k,i//2+1,j//2))))]
  if j%2:return edge_rows[tuple(sorted((a,vertex(k,i//2,j//2+1))))]
  return vertex_rows[a]
 output={}
 for k in range(n):
  for j in range(3):
   for i in range(3):
    v=vertex(k,i,j);row=fine(k,i,j)
    assert v not in output or output[v]==row
    output[v]=row
 A=[[output[v].get(w,F(0))for w in vertices]for v in vertices]
 assert all(sum(row)==1 for row in A)
 return vertices,A

def matmul(A,B):
 cols=list(zip(*B));return [[sum((x*y for x,y in zip(row,col)if x and y),F(0))for col in cols]for row in A]
def characteristic(A):
 n=len(A);B=[[F(int(i==j))for j in range(n)]for i in range(n)];p=[F(1)]
 for k in range(1,n+1):
  B=matmul(A,B);c=-sum(B[i][i]for i in range(n))/k;p.append(c)
  for i in range(n):B[i][i]+=c
 assert all(not x for row in B for x in row)
 return list(reversed(p))
def divide(p,q):
 p=p[:];out=[F(0)]*(len(p)-len(q)+1)
 for i in range(len(out)-1,-1,-1):
  out[i]=p[i+len(q)-1]/q[-1]
  for j,x in enumerate(q):p[i+j]-=out[i]*x
 return out,p[:len(q)-1]
def enc(x):return [str(x.numerator),str(x.denominator)]

from pathlib import Path
import json
class Q:
 # lambda=(11+sqrt(57))/32, lambda^2=11lambda/16-1/16.
 def __init__(self,a=0,b=0):self.a,self.b=F(a),F(b)
 def __add__(self,o):o=q(o);return Q(self.a+o.a,self.b+o.b)
 __radd__=__add__
 def __neg__(self):return Q(-self.a,-self.b)
 def __sub__(self,o):return self+-q(o)
 def __rsub__(self,o):return q(o)+-self
 def __mul__(self,o):o=q(o);return Q(self.a*o.a-self.b*o.b/16,self.a*o.b+self.b*o.a+F(11,16)*self.b*o.b)
 __rmul__=__mul__
 def __truediv__(self,o):
  o=q(o);den=o.a**2+F(11,16)*o.a*o.b+o.b**2/16
  assert den
  return self*Q((o.a+F(11,16)*o.b)/den,-o.b/den)
 def __rtruediv__(self,o):return q(o)/self
 def __eq__(self,o):o=q(o);return self.a==o.a and self.b==o.b
 def __bool__(self):return bool(self.a or self.b)
 def sign(self):
  a,b=32*self.a+11*self.b,self.b
  sg=lambda x:0 if not x else 1 if x>0 else -1
  if not a:return sg(b)
  if not b or sg(a)==sg(b):return sg(a)
  order=sg(a*a-57*b*b)
  assert order
  return sg(a)*order
 def __float__(self):return float(self.a)+float(self.b)*(11+57**.5)/32
 def __repr__(self):return str(self.a)+' + '+str(self.b)+' lambda'
def q(x):return x if isinstance(x,Q)else Q(x)
def null(A):
 A=[[q(x)for x in row]for row in A];m,n=len(A),len(A[0]);pivots=[];r=0
 for c in range(n):
  k=next((k for k in range(r,m)if A[k][c]),None)
  if k is None:continue
  A[r],A[k]=A[k],A[r];a=A[r][c];A[r]=[x/a for x in A[r]]
  for k in range(m):
   if k!=r and A[k][c]:
    a=A[k][c];A[k]=[x-a*y for x,y in zip(A[k],A[r])]
  pivots.append(c);r+=1
 free=[c for c in range(n)if c not in pivots];assert len(free)==1,free
 v=[Q()for _ in range(n)];v[free[0]]=Q(1)
 for r,c in enumerate(pivots):v[c]=-A[r][free[0]]
 return v
vertices,A=masks(3,'crease');size=len(A);at={v:i for i,v in enumerate(vertices)}
def eigen(value,normalize):
 matrix=[[Q(x)-(value if i==j else 0)for j,x in enumerate(row)]for i,row in enumerate(A)]
 right=null(matrix);factor=right[at[normalize]];right=[x/factor for x in right]
 left=null(list(zip(*matrix)));factor=sum((x*y for x,y in zip(left,right)),Q());left=[x/factor for x in left]
 assert all(sum((a*b for a,b in zip(row,right)),Q())==value*x for row,x in zip(A,right))
 return right,left
X,tx=eigen(Q(F(1,2)),('r',0,1));Y,ty=eigen(Q(0,1),('r',1,1))
print('Tangent coefficient',[(v,repr(x))for v,x in zip(vertices,tx)if x],flush=True)
print('Transverse coefficient',[(v,repr(x))for v,x in zip(vertices,ty)if x],flush=True)
print('X',[(v,repr(x))for v,x in zip(vertices,X)],flush=True)
# Recreate fine masks, now extracting regular annular patches through coordinates -1..3.
vertex,_,faces,face_keys,incident,edges,neighbors=topology(3)
def unit(v):return [Q(int(w==v))for w in vertices]
def blend(rows,weights):return [sum((row[i]*w for row,w in zip(rows,weights)),Q())for i in range(size)]
faceRows=[blend([unit(v)for v in face],[F(1,4)]*4)for face in faces]
edgeRows={}
for (a,b),fs in edges.items():edgeRows[(a,b)]=blend([unit(a),unit(b)]+[faceRows[i]for i in fs],[F(1,4)]*4)if len(fs)==2 else blend([unit(a),unit(b)],[F(1,2)]*2)
# old vertex updates needed only through old coordinate1, obtained directly from A fine even controls.
def fine(k,i,j):
 if i<0:
  if k<2:return fine(k+1,j,-i)
  return blend([fine(k,0,j),fine(k,-i,j)],[2,-1])
 if j<0:
  if k>0:return fine(k-1,-j,i)
  return blend([fine(k,i,0),fine(k,i,-j)],[2,-1])
 a=vertex(k,i//2,j//2)
 if i%2 and j%2:return faceRows[face_keys[(k,i//2,j//2)]]
 if i%2:return edgeRows[tuple(sorted((a,vertex(k,i//2+1,j//2))))]
 if j%2:return edgeRows[tuple(sorted((a,vertex(k,i//2,j//2+1))))]
 return [Q(x)for x in A[at[vertex(k,i,j)]]]
C=[[F(1,6),F(4,6),F(1,6),F(0)],[F(0),F(4,6),F(2,6),F(0)],[F(0),F(2,6),F(4,6),F(0)],[F(0),F(1,6),F(4,6),F(1,6)]]
from math import comb
def product(a,b):
 n,m=len(a)-1,len(a[0])-1;p,r=len(b)-1,len(b[0])-1
 out=[[Q()for _ in range(m+r+1)]for _ in range(n+p+1)]
 for i,row in enumerate(a):
  for j,x in enumerate(row):
   for k,other in enumerate(b):
    for l,y in enumerate(other):out[i+k][j+l]+=x*y*F(comb(n,i)*comb(p,k),comb(n+p,i+k))*F(comb(m,j)*comb(r,l),comb(m+r,j+l))
 return out
patches=[]
for k in range(3):
 for i0,j0 in [(1,0),(1,1),(0,1)]:
  # grid indexes i and j are the B-spline control indices.
  grid=[[fine(k,i0+i-1,j0+j-1)for j in range(4)]for i in range(4)]
  curves=[]
  for mode in [X,Y]:
   controls=[[sum((a*b for a,b in zip(row,mode)),Q())for row in col]for col in grid]
   bezier=[[sum((controls[i][j]*C[u][i]*C[v][j]for i in range(4)for j in range(4)),Q())for v in range(4)]for u in range(4)]
   du=[[3*(bezier[i+1][j]-bezier[i][j])for j in range(4)]for i in range(3)]
   dv=[[3*(bezier[i][j+1]-bezier[i][j])for j in range(3)]for i in range(4)]
   curves.append((bezier,du,dv))
  a,b=product(curves[0][1],curves[1][2]),product(curves[0][2],curves[1][1])
  jac=[[x-y for x,y in zip(row,other)]for row,other in zip(a,b)]
  signs=[x.sign()for row in jac for x in row]
  print('Patch',k,i0,j0,'Jacobian signs',min(signs),max(signs),'range',min(float(x)for row in jac for x in row),max(float(x)for row in jac for x in row),flush=True)
  patches.append((k,i0,j0,jac))
# X reproduces one linear chart on each sector, verified on the complete halo.
slopes=[(1,1),(1,-1),(-1,-1)]
for k in range(3):
 for i in range(3):
  for j in range(3):assert X[at[vertex(k,i,j)]]==slopes[k][0]*i+slopes[k][1]*j

def encode(x):x=q(x);return [[str(x.a.numerator),str(x.a.denominator)],[str(x.b.numerator),str(x.b.denominator)]]
data=dict(vertices=vertices,matrix=[[enc(x)for x in row]for row in A],cornerMatrix=[[enc(x)for x in row]for row in masks(3,'corner')[1]],rightX=list(map(encode,X)),leftX=list(map(encode,tx)),rightY=list(map(encode,Y)),leftY=list(map(encode,ty)),patches=[dict(sector=k,i=i,j=j,jacobian=[[encode(x)for x in row]for row in jac])for k,i,j,jac in patches])
# Exact full characteristic factorization, including all halo multiplicities.
p=characteristic(A)
factors=[([-F(1),F(1)],1),([-F(1,2),F(1)],1),([-F(1,4),F(1)],2),([-F(1,8),F(1)],4),([-F(1,16),F(1)],4),([-F(1,32),F(1)],2),([-F(1,64),F(1)],3),([F(1,16),-F(11,16),F(1)],1),([F(1,16),-F(9,16),F(1)],1)]
for factor,count in factors:
 for _ in range(count):p,r=divide(p,factor);assert not any(r)
assert p==[1]
assert all(x.sign()>0 for _,_,_,jac in patches for row in jac for x in row)
# Fixed-center restriction equals the crease operator on E0+E3=2P.
corner=masks(3,'corner')[1]
constraint=[F(2 if v==('c',)else -1 if v in [('r',0,1),('r',3,1)]else 0)for v in vertices]
assert [sum(constraint[i]*corner[i][j]for i in range(size))for j in range(size)]==[x/2 for x in constraint]
for i in range(size):assert [corner[i][j]-A[i][j]for j in range(size)]==[x/8 if vertices[i]==('c',)else F(0)for x in constraint]
(Path(__file__).resolve().parents[1]/'tests'/'ThreeSectorFixtures.luau').write_text('-- Exact full-halo masks and quadratic-field characteristic witnesses.\nreturn [==['+json.dumps(data,separators=(',',':'))+']==]\n')
print('Verified882 matrix entries, full spectrum, both eigenprojections,324 positive Jacobian coefficients, and fixed-midpoint restriction.')
