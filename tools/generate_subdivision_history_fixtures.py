"""Independent Fraction Catmull-Clark references for finite-sharpness histories."""
from fractions import Fraction as F
from collections import defaultdict
from pathlib import Path
import json

def edge(a,b): return f'{min(a,b)}:{max(a,b)}'
def blend(points,weights=None):
    weights=weights or [F(1,len(points))]*len(points)
    return [sum((w*p[j] for w,p in zip(weights,points)),F(0)) for j in range(3)]
def refine(m,boundary,method):
    v,faces,sharp,creases=m
    ef=defaultdict(list);vf=defaultdict(list);neighbors=defaultdict(set)
    for fid,face in faces.items():
        for a,b in zip(face,face[1:]+face[:1]):
            ef[edge(a,b)].append(fid);vf[a].append(fid);neighbors[a].add(b);neighbors[b].add(a)
    fp={fid:blend([v[a]for a in face]) for fid,face in faces.items()}
    es={key:F(10)if len(fs)==1 else creases.get(key,F(0))for key,fs in ef.items()}
    ep={}
    for key,fs in ef.items():
        a,b=map(int,key.split(':'));mid=blend([v[a],v[b]])
        smooth=blend([v[a],v[b],fp[fs[0]],fp[fs[1]]])if len(fs)==2 else mid
        alpha=min(es[key],1);ep[key]=blend([smooth,mid],[1-alpha,alpha])
    vp={};vs={};cs={}
    decay=lambda s:s if s==10 else max(s-1,0)
    for a,p in v.items():
        ns=sorted(neighbors[a]);boundary_ns=[b for b in ns if len(ef[edge(a,b)])==1]
        s=sharp.get(a,F(0))
        if boundary_ns and (boundary=='fixed' or boundary=='edgeAndCorner' and len(vf[a])==1):s=F(10)
        vs[a]=decay(s)
        finite=[es[edge(a,b)]for b in ns if 0<es[edge(a,b)]<10]
        children={}
        for b in ns:
            q=es[edge(a,b)];t=decay(q)
            if method=='chaikin' and 0<q<10 and len(finite)>1:
                t=max(F(0),(3*q+(sum(finite)-q)/(len(finite)-1))/4-1)
            children[b]=t
        cs[a]=children
        disappearing=([s]if s>0 and vs[a]==0 else [])+[es[edge(a,b)]for b in ns if es[edge(a,b)]>0 and children[b]==0]
        alpha=min(F(1),sum(disappearing)/len(disappearing))if disappearing else F(0)
        if len(boundary_ns)==2:smooth=blend([p]+[v[b]for b in boundary_ns],[F(3,4),F(1,8),F(1,8)])
        elif not boundary_ns and len(ns)>=2:
            # Independent F/R formulation, with R the average edge midpoint.
            face_mean=blend([fp[f]for f in vf[a]])
            edge_mean=blend([blend([p,v[b]])for b in ns])
            smooth=blend([face_mean,edge_mean,p],[F(1,len(ns)),F(2,len(ns)),F(len(ns)-3,len(ns))])
        else:smooth=p
        def mask(pin,hard):
            if pin>0 or len(hard)>2:return p
            if len(hard)==2:return blend([p]+[v[b]for b in hard],[F(3,4),F(1,8),F(1,8)])
            return smooth
        parent=[b for b in ns if es[edge(a,b)]>0];child=[b for b in ns if children[b]>0]
        vp[a]=blend([mask(vs[a],child),mask(s,parent)],[1-alpha,alpha])
    out={};vid={};eid={};fidmap={}
    for values,ids in ((vp,vid),(ep,eid),(fp,fidmap)):
        for key in sorted(values):ids[key]=len(out)+1;out[len(out)+1]=values[key]
    nextfaces={};nextcreases={};nextsharp={vid[a]:s for a,s in vs.items()}
    for key in ef:
        a,b=map(int,key.split(':'));nextcreases[edge(vid[a],eid[key])]=cs[a][b];nextcreases[edge(vid[b],eid[key])]=cs[b][a]
    for fid,face in sorted(faces.items()):
        for i,a in enumerate(face):
            b=face[(i+1)%len(face)];c=face[(i-1)%len(face)]
            nextfaces[len(nextfaces)+1]=[vid[a],eid[edge(a,b)],fidmap[fid],eid[edge(c,a)]]
    return out,nextfaces,nextsharp,nextcreases

def enc(x):return [str(x.numerator),str(x.denominator)]
def encoded(m):
    v,f,s,e=m
    return {'vertices':{str(i):list(map(enc,p))for i,p in v.items()},'faces':{str(i):p for i,p in f.items()},'sharp':{str(i):enc(x)for i,x in s.items()},'edges':{i:enc(x)for i,x in e.items()}}

cases=[]
for mixed in (False,True):
    v={1:[F(1,8),F(1,4),F(-1,8)]}
    for i,p in enumerate(((-2,0,1),(-1,2,0),(1,2,-1),(2,0,0)),2):v[i]=list(map(F,p))
    faces={}
    for i,p in enumerate(((-3,3,2),(0,4,1),(3,3,-2)),1):
        a=len(v)+1;v[a]=list(map(F,p));face=[1,i+1,a,i+2]
        if mixed and i==1:
            b=len(v)+1;v[b]=blend([v[a],v[i+2]]);face.insert(3,b)
        if mixed and i==3:face=[1,i+1,i+2]
        faces[i]=face
    initial=(v,faces,{1:F(9,4),4:F(3,8)},{'1:3':F(7,4),'1:4':F(3,8),'2:6':F(10),'3:6':F(1,8)})
    for boundary in ('edge','fixed','edgeAndCorner'):
        for method in ('uniform','chaikin'):
            first=refine(initial,boundary,method);second=refine(first,boundary,method)
            entry={'source':encoded(initial),'boundary':boundary,'creasing':method,'first':encoded(first),'second':encoded(second)}
            if boundary=='edge':
                cv,cf,cs,ce=first
                cf={i:face for i,face in cf.items()if i<=len(cf)//2}
                used={i for face in cf.values()for i in face};keys={edge(a,b)for face in cf.values()for a,b in zip(face,face[1:]+face[:1])}
                cropped=({i:p for i,p in cv.items()if i in used},cf,{i:s for i,s in cs.items()if i in used},{k:s for k,s in ce.items()if k in keys})
                entry['cropFaces']=list(cf);entry['croppedSecond']=encoded(refine(cropped,boundary,method))
            cases.append(entry)
text=json.dumps(cases,separators=(',',':'))
path=Path(__file__).resolve().parents[1]/'tests'/'SubdivisionHistoryFixtures.luau'
path.write_text('-- Generated by tools/generate_subdivision_history_fixtures.py.\nreturn [==['+text+']==]\n')
print(len(cases),'histories',sum(len(c[k]['vertices'])*3 for c in cases for k in ('first','second')),'coordinates',len(text),'bytes')
