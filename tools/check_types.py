"""Strict core and public contract checks, including expected type failures.

The standalone analyzer cannot resolve Roblox Instance requires. Only the require
syntax is rewritten in a disposable mirror; source annotations remain unchanged.
Native Roblox value types are provided by Studio, not by this CLI's globals.
"""
from pathlib import Path
import argparse
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MODULES = ('OperationBudget', 'PublishRetry', 'PublishTransaction', 'PublishPipeline', 'Types')


def check(analyzer='luau-analyze'):
    strict = {p.stem for p in (ROOT/'src').glob('*.luau') if p.read_text().startswith('--!strict')}
    assert strict == set(MODULES), f'Update strict module coverage for: {strict.symmetric_difference(MODULES)}'
    mirror = ROOT / '.validation/types'
    mirror.mkdir(parents=True, exist_ok=True)
    (mirror / '.luaurc').write_text((ROOT / '.luaurc').read_text())
    for name in MODULES:
        source = (ROOT / 'src' / (name + '.luau')).read_text()
        assert source.startswith('--!strict'), name
        source = re.sub(r'require\(script\.Parent\.(\w+)\)', r'require("./\1")', source)
        (mirror / (name + '.luau')).write_text(source)
    good = '''--!strict
local T=require("./Types")
local B=require("./OperationBudget")
local P=require("./PublishTransaction")
local limits:T.Limits={maxWork=100,cancelled=function()return false end}
local opts:T.BakeOptions={samples=16,padding=2,maxTriangles=100}
local publish:T.PublishOptions={attempts=3,resume={}}
local action:P.Action={name="a",apply=function()end,rollback=function()end}
local function use(texture:T.Texture):T.Texture return texture:resize(4,8,limits) end
return {budget=B.new(limits,"test"),bake=opts,publish=publish,action=action,use=use}
'''
    initializer = mirror / 'initializer.luau'
    initializer.write_text((ROOT/'src/init.luau').read_text().replace('require(script.Types)', 'require("./Types")'))
    positive = mirror / 'positive.luau'
    positive.write_text(good)
    result = subprocess.run([analyzer, *[str(mirror / (n+'.luau')) for n in MODULES], str(positive), str(initializer)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    negatives = [
        'local value:T.Limits={maxWork="unbounded"}',
        'local value:T.BakeOptions={samples="many"}',
        'local value:T.PublishOptions={attempts=false}',
        'local value:P.Action={name="a",apply=function()end}',
        'local function value(t:T.Texture) return t:resize("wide",4) end',
        'local function value(t:T.Texture):number return t:clone() end',
    ]
    for index, statement in enumerate(negatives):
        path = mirror / f'negative_{index}.luau'
        path.write_text('--!strict\nlocal T=require("./Types")\nlocal P=require("./PublishTransaction")\n'+statement+'\nreturn value\n')
        result = subprocess.run([analyzer, str(path)], capture_output=True, text=True)
        if result.returncode == 0 or 'TypeError' not in result.stdout + result.stderr:
            raise AssertionError(f'Invalid contract accepted: {statement}\n{result.stdout}{result.stderr}')
    report = {'strictModules': list(MODULES), 'positivePassed': True, 'negativeCasesRejected': len(negatives), 'nativeValueTypesCheckedByCLI': False}
    (ROOT / '.validation/types.json').write_text(json.dumps(report, indent=2)+'\n')
    print(f'Strict modules: {len(MODULES)}; rejected invalid contracts: {len(negatives)}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--analyzer', default='luau-analyze')
    check(parser.parse_args().analyzer)
