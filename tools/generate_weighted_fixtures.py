"""Independent exact de Boor, Gaussian elimination and rectangle clipping."""
from fractions import Fraction as F
from pathlib import Path
import json, random
rng=random.Random(620071)

def rref_vertices(equations):
    m=[list(row) for row in equations]
    row=0
    for column in range(2):
        pivot=next((i for i in range(row,3) if m[i][column]),None)
        if pivot is None:continue
        m[row],m[pivot]=m[pivot],m[row]
        c=m[row][column];m[row]=[v/c for v in m[row]]
        for i in range(3):
            if i!=row:
                c=m[i][column];m[i]=[v-c*w for v,w in zip(m[i],m[row])]
        row+=1
    if any(not a and not b and c for a,b,c in m):return []
    if row==0:return [(F(a),F(b)) for a in (0,1) for b in (0,1)]
    if row==2:
        a,b=-m[0][2],-m[1][2]
        return [(a,b)] if 0<=a<=1 and 0<=b<=1 else []
    a,b,c=m[0];points=set()
    for x in (F(0),F(1)):
        if b:
            y=-(c+a*x)/b
            if 0<=y<=1:points.add((x,y))
    for y in (F(0),F(1)):
        if a:
            x=-(c+b*y)/a
            if 0<=x<=1:points.add((x,y))
    return sorted(points)

def endpoint(surface,t,side):
    p=surface['degree'];knots=list(map(F,surface['knots']));n=len(surface['control'])
    t=knots[p]+t*(knots[n]-knots[p])
    k=n-1 if t==knots[n] else next(i for i in range(p,n) if knots[i]<=t<knots[i+1])
    h=[]
    for i in range(k-p,k+1):
        w=F(surface['weights'][i][side]);h.append([w*F(v) for v in surface['control'][i][side]]+[w])
    for r in range(1,p+1):
        for j in range(p,r-1,-1):
            i=k-p+j;a=(t-knots[i])/(knots[i+p-r+1]-knots[i])
            h[j]=[(1-a)*x+a*y for x,y in zip(h[j-1],h[j])]
    return h[p]

def ends(surface,t,range):
    h0,h1=endpoint(surface,t,0),endpoint(surface,t,1)
    return [[(1-F(x))*a+F(x)*b for a,b in zip(h0,h1)] for x in range]

def encode(x):return [str(x.numerator),str(x.denominator)]

rows=[]
for index in range(24):
    surfaces=[]
    for operand in range(2):
        degree=1+index%3;n=degree+1+(index//3)%2
        if index%2:
            knots=[float(i*2-5) for i in range(n+degree+1)]
        else:knots=[-2.]*(degree+1)+([0.] if n>degree+1 else [])+[6.]*(degree+1)
        control=[];weights=[]
        for i in range(n):
            points=[];w=[]
            for side in range(2):
                if index%4==0:point=[rng.randint(-2,2),rng.randint(-2,2),0]
                elif index%4==1:point=[rng.randint(-2,2),0,0]
                elif index%4==2:point=[0,0,0]
                else:point=[rng.randint(-2,2) for _ in range(3)]
                points.append(point);w.append(2.**rng.randint(-2,2))
            control.append(points);weights.append(w)
        surfaces.append(dict(control=control,weights=weights,degree=degree,knots=knots,transpose=bool((index+operand)%2)))
    ranges=[[0.,1.],[0.,1.]] if index%3==0 else [[.125,.75],[.25,1.]]
    probes=[]
    for s in map(F,(0,.25,.5,1)):
        for t in map(F,(0,.25,.5,1)):
            a,b=ends(surfaces[0],s,ranges[0]),ends(surfaces[1],t,ranges[1])
            x=[[v/h[3] for v in h[:3]] for h in a];y=[[v/h[3] for v in h[:3]] for h in b]
            equations=[(x[1][k]-x[0][k],y[0][k]-y[1][k],x[0][k]-y[0][k]) for k in range(3)]
            vertices=rref_vertices(equations)
            expected=[]
            for alpha,beta in vertices:
                parameters=[]
                for operand,(profile,ab,h) in enumerate(((s,alpha,a),(t,beta,b))):
                    xi=ab*h[0][3]/((1-ab)*h[1][3]+ab*h[0][3])
                    lo,hi=map(F,ranges[operand]);linear=lo+(hi-lo)*xi
                    parameters.extend((linear,profile) if surfaces[operand]['transpose'] else (profile,linear))
                point=[(1-alpha)*x[0][k]+alpha*x[1][k] for k in range(3)]
                expected.append(dict(affine=list(map(encode,(alpha,beta))),parameters=list(map(encode,parameters)),position=list(map(encode,point))))
            probes.append(dict(s=float(s),t=float(t),vertices=expected,dimension=-1 if not vertices else 0 if len(vertices)==1 else 2 if len(vertices)==4 else 1))
    rows.append(dict(surfaces=surfaces,ranges=ranges,probes=probes))
(Path(__file__).resolve().parents[1]/'tests/RuledWeightedFixtures.luau').write_text('-- Generated independent Fraction references.\nreturn [=['+json.dumps(rows,separators=(',',':'))+']=]\n')
print(len(rows),'surface pairs',sum(len(r['probes']) for r in rows),'fibers',sum(len(p['vertices']) for r in rows for p in r['probes']),'vertices')
