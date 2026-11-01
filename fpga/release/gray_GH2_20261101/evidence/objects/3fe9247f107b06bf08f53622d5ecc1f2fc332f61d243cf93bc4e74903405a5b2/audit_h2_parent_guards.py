"""Prove relocated FSM predicate guards using actual escaped-port connections.

Parent ready/done conditions are otherwise arbitrary: this is a conservative
control-state proof, not a proof of the entire DDR arbiter's behavior.
"""
import itertools
import re
from gate_h2_read_port import cells, constant


def canon(s):
    return re.sub(r'\s+', '', s.strip().lstrip('\\'))


def inspect(modules):
    """Resolve both sides of each hierarchy connection before interpreting LUTs."""
    def child(ctx, name):
        block=modules[ctx['module']]
        found=list(re.finditer(r'(?m)^\s+(\w+)\s+'+name+r'\s*\((.*?)\);',block,re.S))
        assert len(found)==1, name
        m=found[0]; ports={}
        for key,expr in re.findall(r'\.(\\[^\s]+|\w+)\s*\(([^()]*)\)',m[2]):
            key=canon(key); expr=expr.strip()
            if expr.startswith('{'):
                bits=[x.strip() for x in expr[1:-1].split(',')]
                for i,x in enumerate(reversed(bits)):ports[f'{key}[{i}]']=resolve(ctx,x)
            else:ports[key]=resolve(ctx,expr)
        return dict(module=m[1],path=ctx['path']+'/'+name,ports=ports)
    def resolve(ctx,net):
        net=canon(net)
        if constant(net) is not None:return net
        return ctx['ports'].get(net,ctx['path']+':'+net)
    top=dict(module='pango_video_system',path='top',ports={})
    core=child(top,'core'); proc=child(core,'processor'); bridge=child(proc,'result_bridge')
    fabric=child(core,'fabric'); dma=child(fabric,'dma')
    def driver(ctx,net):
        found=[(c,p) for c in cells(modules[ctx['module']]) for p in ('Z','Z5','COUT')
               if c['ports'].get(p) and resolve(ctx,c['ports'][p])==resolve(ctx,net)]
        assert len(found)==1, (ctx['path'],net)
        return found[0]
    states={resolve(bridge,f'mstate[{i}]'):i for i in range(3)}
    cancel=resolve(bridge,'cancel_sync'); ce=resolve(bridge,'payload_read_enable')
    # These connections are evidence, not a name-based alias assumption.
    assert resolve(bridge,'N254')==resolve(fabric,'N3992')
    assert resolve(bridge,'N588')==resolve(fabric,'N3905')
    assert resolve(bridge,'core/fabric/dma/N490_3')==resolve(dma,'N490_3')
    assert resolve(bridge,'N240_0')==resolve(top,'N240_0')
    inv=re.search(r'GTP_INV\s+N240_0_vname\s*\((.*?)\);',modules[top['module']],re.S)
    assert inv
    ip={k:canon(v) for k,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',inv[1])}
    assert ip['Z']=='N240_0'
    # Verify the reset is the declared DDR/core reset net, not an inferred alias.
    assert ip['I']=='core_reset_n', ip
    records=[]
    for ctx,net,allowed_codes in [(fabric,'N3992',{2,3,4}),(fabric,'N3905',{1}),(dma,'N490_3',{3})]:
        leaves=set(); cone={}
        def scan(n):
            full=resolve(ctx,n)
            if full in states or full in (cancel,ce) or constant(n) is not None:return
            # Cut unrelated arbiter/data cones as independent free inputs.
            # Proving the guard for every value is stronger than relying on
            # their normal behavior; retain the relocated state decoder.
            if canon(n) not in {net,'_N225618'}:
                leaves.add(full);return
            try:c,port=driver(ctx,n)
            except AssertionError:leaves.add(full);return
            assert c['type'] in ('GTP_LUT6','GTP_LUT6D'),c['type']
            cone[full]=(c,port)
            for i in range(5 if port=='Z5' else 6):scan(c['ports'][f'I{i}'])
        scan(net); assert len(leaves)<=12, leaves
        def evaluate(n,code,cv,assignment):
            full=resolve(ctx,n); k=constant(n)
            if k is not None:return k
            if full in states:return (code>>states[full])&1
            if full==cancel:return cv
            if full==ce:return int(code in (2,3))
            if full in assignment:return assignment[full]
            c,port=cone[full]; p=c['ports']
            width=5 if port=='Z5' else 6
            idx=sum(evaluate(p[f'I{i}'],code,cv,assignment)<<i for i in range(width))
            init=re.fullmatch(r"64'b([01]{64})",p['INIT']);assert init
            return (int(init[1],2)>>idx)&1
        observed=set(); cases=0
        for code,cv in itertools.product(range(8),range(2)):
            for values in itertools.product(range(2),repeat=len(leaves)):
                val=evaluate(net,code,cv,dict(zip(sorted(leaves),values)));cases+=1
                if val:
                    assert code in allowed_codes,(net,code)
                    if net=='N490_3':assert cv==0
                    observed.add(code)
        assert observed==allowed_codes,(net,observed)
        records.append(dict(net=resolve(ctx,net),true_only_in_codes=sorted(observed),
            assignments=cases,unconstrained_parent_inputs=sorted(leaves),
            cone={k:v[0] for k,v in cone.items()}))
    return dict(passed=True,guards=records,reset_inverter=ip,
        limitation='Parent predicates otherwise unconstrained; proves state-code meaning and ownership guards, not full arbiter equivalence.')
