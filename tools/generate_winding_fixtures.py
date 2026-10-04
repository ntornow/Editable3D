"""Independent Fraction/Cramer winding and homogeneous-integer fixtures."""
from fractions import Fraction as F
from itertools import permutations
from pathlib import Path
import json,random,struct,math

def determinant(m):
    value=F(0)
    for p in permutations(range(3)):
        sign=(-1)**sum(p[i]>p[j] for i in range(3)for j in range(i+1,3))
        value+=sign*m[0][p[0]]*m[1][p[1]]*m[2][p[2]]
    return value

def rational(x):
    x=F(x)
    def limbs(n):
        out=[]
        while n:out.append(n%2**24);n//=2**24
        return out
    return {'sign':(x>0)-(x<0),'n':limbs(abs(x.numerator)),'d':limbs(x.denominator)}

def f32(x):return struct.unpack('f',struct.pack('f',float(x)))[0]

def box(center=(0,0,0),scale=1,matrix=None,reverse=False):
    verts=[[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]]
    if matrix is None:matrix=[[1,0,0],[0,1,0],[0,0,1]]
    verts=[[f32(center[i]+scale*sum(matrix[i][j]*p[j] for j in range(3)))for i in range(3)]for p in verts]
    faces=[[0,3,2,1],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]]
    triangles=[]
    for a,b,c,d in faces:
        for ids in ([a,b,c],[a,c,d]):
            if reverse:ids=ids[::-1]
            triangles.append([verts[i]for i in ids])
    return triangles

def count(triangles,groups,p):
    p=list(map(F,p));hi=[max(F(v[i])for tri in triangles for v in tri)for i in range(3)]
    lo=[min(F(v[i])for tri in triangles for v in tri)for i in range(3)]
    scale=max([F(1)]+[hi[i]-lo[i]for i in range(3)])
    first=None
    for trial in range(1,20):
        q=[hi[0]+scale*(23+2*trial),hi[1]+scale*(41+6*trial),hi[2]+scale*(67+trial*trial)]
        direction=[q[i]-p[i]for i in range(3)]
        total=[0]*max(groups);ambiguous=False
        for tri,group in zip(triangles,groups):
            a,b,c=[list(map(F,v))for v in tri]
            u=[b[i]-a[i]for i in range(3)];v=[c[i]-a[i]for i in range(3)]
            matrix=[[-direction[i],u[i],v[i]]for i in range(3)]
            rhs=[p[i]-a[i]for i in range(3)]
            divisor=determinant(matrix)
            if divisor==0:
                if determinant([[rhs[i],u[i],v[i]]for i in range(3)])==0:ambiguous=True;break
                continue
            values=[]
            for axis in range(3):
                values.append(determinant([[rhs[i]if j==axis else matrix[i][j]for j in range(3)]for i in range(3)])/divisor)
            t,s,w=values
            if not(0<=t<=1 and 0<=s and 0<=w and s+w<=1):continue
            if t in (0,1) or s==0 or w==0 or s+w==1:ambiguous=True;break
            # sign of the endpoint's oriented triangle plane.
            sign=determinant([[u[i],v[i],q[i]-a[i]]for i in range(3)])
            total[group-1]+=(sign>0)-(sign<0)
        if ambiguous:continue
        if first is not None:
            assert first==total
            return total
        first=total
    raise ValueError('Reference ray degeneracy')

rng=random.Random(561193)
scenes=[]
configs=[(box(),[1]*12),
    (box()+box((2+2**-22,0,0)),[1]*12+[2]*12),
    (box()+box(scale=1-2**-22),[1]*12+[2]*12),
    (box()+box((.5,.25,0)),[1]*12+[2]*12),
    (box()+box(scale=.5,reverse=True),[1]*24),
    (box((16,-8,32),matrix=[[1,.25,.125],[.5,1,.25],[.25,-.125,1]]),[1]*12),
    (box((16,-8,32),matrix=[[.936293,-.275096,.218351],[.289629,.956425,-.036957],[-.198669,.097843,.975170]]),[1]*12),
    (box(scale=2**-60)+box((2**61,0,0),scale=2**60),[1]*12+[2]*12)]
for index,(triangles,groups) in enumerate(configs):
    points=[]
    if index in (0,1,2,3,4):
        points=[(0,0,0),(F(1)+F(2)**-24,F(1,7),F(-1,5)),(F(1)-F(2)**-24,F(1,7),F(-1,5)),(F(1,3),F(1,5),F(1,7)),(F(7,3),F(2,7),F(3,5)),(-3,4,5)]
    elif index in (5,6):
        points=[(16+F(rng.randrange(-12,13),7),-8+F(rng.randrange(-12,13),7),32+F(rng.randrange(-12,13),7))for _ in range(8)]
        points.append((16,-8,32))
    else:points=[(0,0,0),(F(1,3)*F(2)**-60,0,0),(F(2)**61,0,0),(F(2)**62,0,0),(F(2)**-59,0,0),(F(2)**61,F(2)**59,0)]
    rows=[]
    for p in points:
        rows.append({'point':[rational(x)for x in p],'winding':count(triangles,groups,p)})
    scenes.append({'triangles':triangles,'groups':groups,'rows':rows})
homogeneous=[]
for index in range(64):
    values=[]
    for j in range(1+index%6):
        bits=(1,17,53,100,250,1024)[(index+j)%6]
        x=F(rng.randrange(0,2**bits),rng.randrange(1,2**bits+1))*F(2)**((-80,0,80)[j%3])
        values.append(x if (index+j)%2 else -x)
    denominator=math.lcm(*(x.denominator for x in values))
    homogeneous.append({'values':[rational(x)for x in values],'integers':[rational(x*denominator)for x in values],'denominator':rational(denominator)})
output={'scenes':scenes,'homogeneous':homogeneous}
text='-- Independent Fraction/Cramer winding and LCM references.\nreturn [===['+json.dumps(output,separators=(',',':'))+']===]\n'
assert len(text.encode())<200000
path=Path(__file__).resolve().parents[1]/'tests/RationalWindingFixtures.luau'
path.write_text(text)
print(len(scenes),'scenes',sum(len(s['rows'])for s in scenes),'exact reference points;',len(homogeneous),'homogeneous vectors;',len(text),'source bytes')
