"""Dense harmonic/biharmonic geometry fairing reference experiments."""
import numpy as np
import json

def operator(points,triangles,mode):
    n=len(points);K=np.zeros((n,n));mass=np.zeros(n);edges={}
    for t in triangles:
        p=points[t];area=np.linalg.norm(np.cross(p[1]-p[0],p[2]-p[0]))/2
        assert area>0
        for i in t:mass[i]+=area/3
        for k in range(3):
            a,b,c=t[k],t[(k+1)%3],t[(k+2)%3]
            u=points[a]-points[c];v=points[b]-points[c]
            key=tuple(sorted((a,b)))
            if mode=='uniform':edges[key]=1.
            else:edges[key]=edges.get(key,0)+.5*u.dot(v)/np.linalg.norm(np.cross(u,v))
    for (a,b),w in edges.items():
        K[a,a]+=w;K[b,b]+=w;K[a,b]-=w;K[b,a]-=w
    if mode=='uniform':mass[:]=1.
    return K,mass,edges

def grid(n,quadratic=False):
    points=np.array([[i/n,j/n,.15*((i/n)**2+(j/n)**2) if quadratic else 0.] for j in range(n+1) for i in range(n+1)])
    tri=[]
    for j in range(n):
        for i in range(n):
            a=j*(n+1)+i;b=a+1;c=a+n+2;d=a+n+1
            tri += [[a,b,c],[a,c,d]]
    return points,np.array(tri)

def solve(points,triangles,free,mode,order):
    origin=points.min(axis=0);span=np.max(points.max(axis=0)-origin);p=(points-origin)/span
    K,mass,edges=operator(p,triangles,mode)
    Q=K if order==1 else (K/mass[None,:])@K
    rhs=-(Q@p)[free]
    delta=np.linalg.solve(Q[np.ix_(free,free)],rhs)
    target=p.copy();target[free]+=delta
    out=points.copy();out[free]=(origin+span*target[free]).astype(np.float32).astype(float)
    actual=(out-origin)/span
    residual=(Q@actual)[free]
    return out,dict(relativeResidual=[float(np.linalg.norm(residual[:,k])/max(np.linalg.norm(rhs[:,k]),1e-300)) for k in range(3)],absoluteResidual=[float(np.linalg.norm(residual[:,k])) for k in range(3)],energyBefore=float(np.sum(p*(Q@p))),energyAfter=float(np.sum(actual*(Q@actual))),minWeight=min(edges.values()),minimumEigenvalue=float(np.linalg.eigvalsh(Q[np.ix_(free,free)]).min())),Q


def luau(value):
    if isinstance(value,str):return json.dumps(value)
    if isinstance(value,bool):return "true" if value else "false"
    if isinstance(value,dict):return "{ " + ", ".join(k+" = "+luau(v) for k,v in value.items())+" }"
    if isinstance(value,(list,tuple)):return "{ " + ", ".join(luau(v) for v in value)+" }"
    if isinstance(value,np.generic):value=value.item()
    return repr(value)

if __name__ == '__main__':
    from pathlib import Path
    fixtures=[]
    for mode in ['uniform','cotangent']:
        for order in [1,2]:
            for n,quadratic in [(4,False),(8,True)]:
                points,triangles=grid(n,quadratic)
                band=2 if quadratic else 1
                free=np.array([i for i in range(len(points)) if band<=i%(n+1)<=n-band and band<=i//(n+1)<=n-band])
                baseline=points.copy()
                for i in free:
                    x,y=points[i,:2];points[i,2]+=.12*np.sin(np.pi*x)*np.sin(np.pi*y)
                points=points.astype(np.float32).astype(float)
                out,report,Q=solve(points,triangles,free,mode,order)
                assert report['minimumEigenvalue']>0
                if mode=='uniform' and order==2 and quadratic:
                    assert np.max(abs(out[free,2]-baseline[free,2]))<1e-7
                fixtures.append(dict(mode=mode,order=order,n=n,quadratic=quadratic,positions=points.tolist(),triangles=(triangles+1).tolist(),free=(free+1).tolist(),expected=out.tolist(),energyBefore=report['energyBefore'],energyAfter=report['energyAfter']))
    target=Path(__file__).resolve().parents[1]/'tests'/'FairingFixtures.luau'
    target.write_text('-- Independent dense constrained solves; see tools/generate_fairing_fixtures.py.\nreturn '+luau(fixtures)+'\n')
    print(f'Wrote {len(fixtures)} dense fairing references to {target}')
