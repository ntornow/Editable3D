"""Independent Fraction nearest-representative references for native float32 clouds."""
from fractions import Fraction as Q
import json, random, struct
from pathlib import Path

def native(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]

def reference(points, radius):
    exact = [[Q(x) for x in p] for p in points]
    representatives = []
    max_squared = Q(0)
    for i, p in enumerate(exact):
        candidates = []
        for j, q in enumerate(exact[:i]):
            if representatives[j] != j + 1:
                continue
            squared = sum((a-b)**2 for a,b in zip(p,q))
            if squared <= Q(radius)**2:
                candidates.append((squared,j))
        if candidates:
            distance, j = min(candidates)
            representatives.append(j+1)
            max_squared = max(max_squared, distance)
        else:
            representatives.append(i+1)
    return representatives, {'n':str(max_squared.numerator),'d':str(max_squared.denominator)}

def generate():
    rng = random.Random(63064)
    cases = []
    for scene in range(8):
        anchors = []
        radius = (5 if scene == 0 else 4)/1024
        for i in range(24):
            group = i//3
            anchors.append([group*4 + rng.randrange(-3,4)/1024,
                            group%3*4 + rng.randrange(-3,4)/1024,
                            rng.randrange(-3,4)/1024])
        if scene == 0:
            anchors[:6]=[[0,0,0],[10/1024,0,0],[5/1024,0,0],
                         [4,0,0],[4+3/1024,4/1024,0],[4+3/1024,5/1024,0]]
        for scale in [2**-12,1,2**12]:
            shift = [0,0,0] if scene%2==0 else [64*scale,-32*scale,16*scale]
            points=[]
            for i,p in enumerate(anchors):
                for delta in [[0,0,0],[0,0,20+i],[0,2,20+i]]:
                    points.append([native((x+d)*scale+t) for x,d,t in zip(p,delta,shift)])
            reps, bound = reference(points, radius*scale)
            cases.append({'points':points,'distance':radius*scale,'representatives':reps,'maxSquared':bound})
    return {'reference':'Python Fraction exhaustive nearest canonical representative, lower ID on ties',
            'cases':cases,'memberships':sum(len(x['points']) for x in cases)}

if __name__ == '__main__':
    data=generate()
    path=Path(__file__).resolve().parents[1]/'tests'/'VertexClusterFixtures.luau'
    path.write_text('return [==['+json.dumps(data,separators=(',',':'))+']==]\n')
    print(len(data['cases']),data['memberships'],path.stat().st_size)
