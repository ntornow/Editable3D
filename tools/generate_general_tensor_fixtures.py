from fractions import Fraction as Q
from pathlib import Path
import json,random,struct
rng=random.Random(66601)
def f32(x):return struct.unpack('<f',struct.pack('<f',float(x)))[0]
def limbs(n):
 out=[]
 while n:out.append(n%(1<<24));n>>=24
 return out
def encode(q):return {'sign':(q>0)-(q<0),'n':limbs(abs(q.numerator)),'d':limbs(q.denominator)}
def basis(n,degree,knots,t):
 endpoint=t==knots[n]
 values=[Q(int((knots[i]<t<=knots[i+1])if endpoint else(knots[i]<=t<knots[i+1])))for i in range(len(knots)-1)]
 for d in range(1,degree+1):
  out=[]
  for i in range(len(values)-1):
   a=knots[i+d]-knots[i];b=knots[i+d+1]-knots[i+1]
   out.append(((t-knots[i])*values[i]/a if a else Q(0))+((knots[i+d+1]-t)*values[i+1]/b if b else Q(0)))
  values=out
 assert len(values)==n and sum(values)==1
 return values
cases=[]
for index in range(12):
 degree=1+index%3;n=degree+2
 unclamped=index%2==1
 if unclamped:knots=[Q(i-degree)for i in range(n+degree+1)]
 else:knots=[Q(0)]*(degree+1)+[Q(1,2)]+[Q(1)]*(degree+1)
 factor,offset=(Q(8),Q(-3))if index%3==1 else(Q(1),Q(0))
 knots=[q*factor+offset for q in knots]
 control=[];weights=[]
 for i in range(n):
  row=[];wrow=[]
  for j in range(n):
   scale=Q(1,1024)if index%4==0 else Q(1)
   row.append([f32(Q(rng.randrange(-16,17),4)*scale+(Q(1048576)if index%4==3 else 0))for _ in range(3)])
   wrow.append(rng.choice([.5,1,2,3,4,8]))
  control.append(row);weights.append(wrow)
 samples=[]
 for u in [Q(0),Q(1,8),Q(1,4),Q(1,2),Q(3,4),Q(7,8),Q(1)]:
  for v in [Q(0),Q(1,4),Q(1,2),Q(3,4),Q(1)]:
   bu=basis(n,degree,knots,knots[degree]+u*(knots[n]-knots[degree]))
   bv=basis(n,degree,knots,knots[degree]+v*(knots[n]-knots[degree]))
   h=[Q(0)]*4
   for i in range(n):
    for j in range(n):
     w=bu[i]*bv[j]*Q.from_float(float(weights[i][j]))
     for k in range(3):h[k]+=w*Q.from_float(control[i][j][k])
     h[3]+=w
   samples.append({'uv':[float(u),float(v)],'h':[encode(q)for q in h]})
 cases.append({'control':control,'weights':weights,'degree':degree,'knots':[float(q)for q in knots],'clamped':not unclamped,'samples':samples})
p=Path(__file__).resolve().parents[1]/'tests'/'GeneralTensorFixtures.luau'
p.write_text('return [==['+json.dumps(cases,separators=(',',':'))+']==]\n')
print(len(cases),'original tensor descriptors',sum(len(c['samples'])*4 for c in cases),'exact homogeneous references',p.stat().st_size,'bytes')
