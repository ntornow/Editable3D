"""Independent Fraction masks, halo blocks, Krylov jets and root-known Schur cases."""
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

def multiply(p,q):
 out=[F(0)]*(len(p)+len(q)-1)
 for i,a in enumerate(p):
  for j,b in enumerate(q):out[i+j]+=a*b
 return out

def solve(A,b):
 n=len(A[0]);M=[row[:]+[x]for row,x in zip(A,b)];r=0;pivots=[]
 for c in range(n):
  k=next((i for i in range(r,len(M))if M[i][c]),None)
  if k is None:continue
  M[r],M[k]=M[k],M[r];scale=M[r][c];M[r]=[x/scale for x in M[r]]
  for i in range(len(M)):
   if i!=r and M[i][c]:
    scale=M[i][c];M[i]=[x-scale*y for x,y in zip(M[i],M[r])]
  pivots.append(c);r+=1
 if any(not any(row[:n])and row[-1]for row in M):return None
 assert len(pivots)==n
 return [M[i][-1]for i in range(n)]

def recurrence(B,raw,kind):
 N=len(B);n=(N-2)//2
 center=raw[0]if kind=='corner'else [(4*raw[0][j]+raw[1][j]+raw[n+1][j])/6 for j in range(3)]
 w=[[x-c for x,c in zip(row,center)]for row in raw];powers=[]
 for d in range(N+1):
  flat=[x for row in w for x in row]
  if not any(flat):p=[F(0)]*d+[F(1)];powers.append(flat);break
  if d:
   result=solve([list(row)for row in zip(*powers)],[-x for x in flat])
   if result is not None:p=result+[F(1)];powers.append(flat);break
  powers.append(flat);w=matmul(B,w)
 else:raise AssertionError('no recurrence')
 assert all(sum(p[j]*powers[j][i]for j in range(len(p)))==0 for i in range(3*N))
 q=p;unit=sum(p)==0
 if unit:
  q,rem=divide(p,[-F(1),F(1)]);assert not any(rem)
  if sum(q)==0:return p,None,'unitJordanMode'
 t=q[:]
 while len(t)>1:
  a,b=t[-1],t[0]
  if b*b>=a*a:return p,None,'noncontractingModes'
  t=[(a*t[i]-b*t[-1-i])/(a*a-b*b)for i in range(1,len(t))]
 D=[sum(q[j]*powers[j][i]for j in range(len(q)))/sum(q)if unit else F(0)for i in range(3*N)]
 return p,D,None

halo=[];full=[]
for n in (1,2,3,4,6,8,14):
 vs,A=masks(n,'corner');core=[('c',)]+[('r',j,1)for j in range(n+1)]+[('f',j,1,1)for j in range(n)]
 groups=[[('r',0,2),('f',0,2,1)]]+[[('r',j,2),('f',j-1,1,2),('f',j,2,1)]for j in range(1,n)]+[[('r',n,2),('f',n-1,1,2)]]+[[('f',j,2,2)]for j in range(n)]
 used=set(core)
 for g in groups:
  ids=[vs.index(v)for v in g];block=[[A[i][j]for j in ids]for i in ids]
  assert all(not A[i][j]or v in used or v in g for i in ids for j,v in enumerate(vs))
  expected=[F(1,8),F(1,16),F(1,32)]if len(g)==3 else [F(1,8),F(1,16)]if len(g)==2 else [F(1,64)]
  p=[F(1)]
  for eigen in expected:p=multiply(p,[-eigen,F(1)])
  assert characteristic(block)==p
  used.update(g)
 assert used==set(vs)
 halo.append(dict(sectors=n,controls=len(vs),blocks=len(groups)))
 if n in (4,6):
  for kind in ('corner','crease'):
   _,T=masks(n,kind);full.append(dict(sectors=n,kind=kind,vertices=vs,matrix=[[enc(x)for x in row]for row in T]))

cases=[];cycle=[(1,0),(0,1),(-1,0),(0,-1)]
for n in (3,4,5,6,7,8,10,14):
 for kind in ('corner','crease'):
  if kind=='crease'and n%4!=2:continue
  raw=[[F(0)]*3]
  for j in range(n+1):
   x,y=cycle[j%4];raw.append([F(x),F(y),F(y if n%2==0 else 0)])
  for j in range(n):
   a,b=cycle[j%4],cycle[(j+1)%4];raw.append([F(a[0]+b[0]),F(a[1]+b[1]),F(-2*(a[1]+b[1])if n%2==0 else 0)])
  # Nonorthogonal dyadic affine coordinate change exercises all axes.
  raw=[[2*x+y/2+3,z-x/4-2,y+z/2+5]for x,y,z in raw]
  vs,A=masks(n,kind);core=[('c',)]+[('r',j,1)for j in range(n+1)]+[('f',j,1,1)for j in range(n)];ids=[vs.index(v)for v in core]
  B=[[2*A[i][j]for j in ids]for i in ids];p,D,reason=recurrence(B,raw,kind);assert D is not None
  cases.append(dict(sectors=n,kind=kind,raw=[[float(x)for x in row]for row in raw],polynomial=list(map(enc,p)),limit=list(map(enc,D))))
# Independent generic source recurrences, including unit-Jordan and growing modes.
for n in range(1,8):
 for kind in ('corner','crease'):
  vs,A=masks(n,kind);core=[('c',)]+[('r',j,1)for j in range(n+1)]+[('f',j,1,1)for j in range(n)];ids=[vs.index(v)for v in core]
  B=[[2*A[i][j]for j in ids]for i in ids]
  raw=[[F(((i*17+j*11+n*3)**2+7*i*j)%37-18,8)for j in range(3)]for i in range(len(ids))]
  p,D,reason=recurrence(B,raw,kind)
  cases.append(dict(sectors=n,kind=kind,raw=[[float(x)for x in row]for row in raw],polynomial=list(map(enc,p)),limit=list(map(enc,D))if D is not None else None,reason=reason))

schur=[]
for k in range(96):
 p=[F(1)];stable=True
 for j in range(1,1+k%6):
  if (k+j)%3:
   r=F(((k*7+j*11)%25)-12,16);p=multiply(p,[-r,F(1)])
  else:
   a=F((k+j*3)%9-4,16);b=F((k*3+j)%9+1,16)
   p=multiply(p,[a*a+b*b,-2*a,F(1)])
 if k%3==1:p=multiply(p,[-F(1),F(1)]);stable=False
 elif k%3==2:
  if k%2:p=multiply(p,[F(65,64),F(-1,4),F(1)])
  else:p=multiply(p,[F(17,16),F(1)])
  stable=False
 schur.append(dict(polynomial=list(map(enc,p)),stable=stable))
data=dict(halo=halo,operators=full,jets=cases,schur=schur)
output=Path(__file__).resolve().parents[1]/'tests'/'ConstrainedJetFixtures.luau'
output.write_text('-- Independent exact Fraction references.\nreturn [==['+json.dumps(data,separators=(',',':'))+']==]\n')
print('Verified',sum(len(x['matrix'])**2 for x in full),'matrix coefficients,',len(cases),'vector recurrences,',len(schur),'known-root Schur cases, and',len(halo),'halo partitions.')
