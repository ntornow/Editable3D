"""Independent SciPy BFGS UV relaxation references; NumPy/SciPy needed only for regeneration."""
import numpy as np
from scipy.optimize import minimize
import json

def build(n,curved=False):
    positions=np.array([(i/n,j/n,0.18*np.sin(np.pi*i/n)*np.sin(np.pi*j/n) if curved else 0) for j in range(n+1) for i in range(n+1)])
    triangles=np.array([(j*(n+1)+i,j*(n+1)+i+1,(j+1)*(n+1)+i+1) if k==0 else (j*(n+1)+i,(j+1)*(n+1)+i+1,(j+1)*(n+1)+i) for j in range(n) for i in range(n) for k in range(2)])
    uv=positions[:,:2].copy()
    movable=np.array([i for i in range(len(uv)) if i%(n+1) not in (0,n) and i//(n+1) not in (0,n)])
    for i in movable:
        u,v=uv[i];uv[i]+=[0.05*np.sin(3*u+v),0.06*np.sin(u+4*v)]
    return positions,triangles,uv,movable

def prepare(positions,triangles):
    data=[]
    areas=[]
    for tri in triangles:
        p=positions[tri]; a=p[1]-p[0];b=p[2]-p[0];length=np.linalg.norm(a);x=a.dot(b)/length;y=np.linalg.norm(np.cross(a,b))/length
        target=[]
        for i in range(3):
            u=p[(i+1)%3]-p[i];v=p[(i+2)%3]-p[i];target.append(np.arctan2(np.linalg.norm(np.cross(u,v)),u.dot(v)))
        data.append((length,x,y,np.array(target)));areas.append(length*y/2)
    area=sum(areas)
    return [(tri, d[0],d[1],d[2],d[3],a/area) for tri,d,a in zip(triangles,data,areas)],area

def evaluate(uv,records,mode,density):
    energy=0.;gradient=np.zeros_like(uv)
    for tri,length,x,y,target,weight in records:
        p=uv[tri];u=p[1]-p[0];v=p[2]-p[0];det=np.linalg.det(np.array([u,v]))
        if det<=0:return float('inf'),gradient
        if mode=='angle':
            for k in range(3):
                a=p[(k+1)%3]-p[k];b=p[(k+2)%3]-p[k];cross=a[0]*b[1]-a[1]*b[0];theta=np.arctan2(cross,a.dot(b));diff=theta-target[k];energy+=weight*diff*diff
                ga=np.array([a[1],-a[0]])/a.dot(a);gb=np.array([-b[1],b[0]])/b.dot(b);factor=2*weight*diff
                gradient[tri[(k+1)%3]]+=factor*ga;gradient[tri[(k+2)%3]]+=factor*gb;gradient[tri[k]]-=factor*(ga+gb)
        else:
            jac=np.column_stack([u/length,(v-u*x/length)/y])/density
            det=np.linalg.det(jac);norm=np.sum(jac**2);energy+=weight*norm*(1+1/det**2)
            cofactor=np.array([[jac[1,1],-jac[1,0]],[-jac[0,1],jac[0,0]]])
            gj=weight*(2*jac*(1+1/det**2)-2*norm/det**3*cofactor)
            gu=gj[:,0]/length/density-gj[:,1]*x/(length*y*density);gv=gj[:,1]/y/density
            gradient[tri[1]]+=gu;gradient[tri[2]]+=gv;gradient[tri[0]]-=gu+gv
    return energy,gradient


def luau(value):
    if isinstance(value,str):return json.dumps(value)
    if isinstance(value,bool):return "true" if value else "false"
    if isinstance(value,dict):return "{ " + ", ".join(k+" = "+luau(v) for k,v in value.items())+" }"
    if isinstance(value,(list,tuple)):return "{ " + ", ".join(luau(v) for v in value)+" }"
    return repr(value)

if __name__ == '__main__':
    from pathlib import Path
    output=[]
    for n,curved in [(2,False),(4,False),(4,True),(8,True)]:
        positions,triangles,uv,movable=build(n,curved)
        positions=positions.astype(np.float32).astype(float)
        uv=uv.astype(np.float32).astype(float)
        records,area=prepare(positions,triangles)
        density=float(np.sqrt(1/area))
        for mode in ['angle','symmetricDirichlet']:
            initial,gradient=evaluate(uv,records,mode,density)
            maximum_error=0
            for i in range(len(uv)):
                for j in range(2):
                    a=uv.copy();b=uv.copy();a[i,j]+=1e-6;b[i,j]-=1e-6
                    difference=(evaluate(a,records,mode,density)[0]-evaluate(b,records,mode,density)[0])/2e-6
                    maximum_error=max(maximum_error,abs(difference-gradient[i,j]))
            assert maximum_error<1e-7
            def energy(x):
                q=uv.copy();q[movable]=x.reshape(-1,2)
                value,g=evaluate(q,records,mode,density)
                return value,g[movable].flatten()
            reference=minimize(energy,uv[movable].flatten(),jac=True,method='BFGS',options={'gtol':1e-9,'maxiter':1000})
            value,g=energy(reference.x)
            assert max(abs(g))<1e-7
            output.append(dict(n=n,curved=curved,method=mode,positions=positions.tolist(),triangles=(triangles+1).tolist(),uv=uv.tolist(),movable=(movable+1).tolist(),referenceEnergy=float(reference.fun),referenceCoordinates=reference.x.tolist(),density=density,initialGradient=gradient.flatten().tolist(),initialEnergy=float(initial)))
    target=Path(__file__).resolve().parents[1]/'tests'/'UVRelaxFixtures.luau'
    target.write_text('-- Generated independent dense BFGS references; see tools/generate_uv_relax_fixtures.py.\nreturn '+luau(output)+'\n')
    print(f'Wrote {len(output)} UV relaxation references to {target}')
