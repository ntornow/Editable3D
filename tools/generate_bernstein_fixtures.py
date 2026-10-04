from pathlib import Path
from fractions import Fraction as F
from itertools import product
from math import comb
import json,random
rng=random.Random(6719)
cases=[]
def evaluate(control,weights,degree,u,v):
 out=[F(0)]*4
 for i,row in enumerate(control):
  for j,p in enumerate(row):
   b=comb(degree,i)*u**i*(1-u)**(degree-i)*comb(degree,j)*v**j*(1-v)**(degree-j)*F(weights[i][j])
   for k in range(3):out[k]+=b*F(p[k])
   out[3]+=b
 return [out[k]/out[3] for k in range(3)]
for index in range(48):
 degree=1+index%3
 surfaces=[];weights=[]
 for operand in range(2):
  grid=[];ws=[]
  for i in range(degree+1):
   row=[];wrow=[]
   for j in range(degree+1):
    p=[]
    for axis in range(3):
     if index<6:value=0
     elif index<18:value=(1 if (i,j,axis)==(index%(degree+1),(index//3)%(degree+1),0) else 0)
     elif index<36:value=rng.choice([0,0,0,1,2])/8
     else:value=rng.randrange(-2,3)/8
     p.append(value*(1 if operand==0 else -1))
    row.append(p);wrow.append(rng.choice([.5,1,2,4]))
   grid.append(row);ws.append(wrow)
  surfaces.append(grid);weights.append(ws)
 samples=[]
 for u,v,s,t in product([F(0),F(1,2),F(1)],repeat=4):
  samples.append(evaluate(surfaces[0],weights[0],degree,u,v)==evaluate(surfaces[1],weights[1],degree,s,t))
 cases.append(dict(degree=degree,control=surfaces,weights=weights,expected=''.join('1' if x else '0' for x in samples)))
out='-- Independent Fraction tensor Bernstein face-center truth fixtures.\nreturn [==['+json.dumps(cases,separators=(',',':'))+']==]\n'
(Path(__file__).resolve().parents[1]/'tests'/'TensorBernsteinFixtures.luau').write_text(out)
print(len(cases),'independent weighted pairs',sum(len(c['expected'])for c in cases),'exact contact truth references')
