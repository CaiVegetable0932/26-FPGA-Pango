"""Prove actual GH2 relocated FSM guards without naming an intermediate wire.

Unlike the preserved H2 auditor, trace every local combinational driver until
a declared input or FF output. Parent events remain free Boolean inputs; no
internal state-dependent LUT is silently turned into an arbitrary input.
"""
import itertools
import re
from gate_h2_read_port import cells, constant


def canon(signal):
    """Canonicalize PDS escaped identifiers while retaining explicit bit order."""
    return re.sub(r'\s+', '', signal.strip().lstrip('\\'))


def inspect(modules):
    """Resolve real hierarchy aliases, then exhaust every guard input vector."""
    def resolve(ctx, net):
        net=canon(net)
        return net if constant(net) is not None else ctx['ports'].get(net,ctx['path']+':'+net)

    def child(ctx,name):
        found=list(re.finditer(r'(?m)^\s+(\w+)\s+'+re.escape(name)+r'\s*\((.*?)\);',modules[ctx['module']],re.S))
        assert len(found)==1, ('ambiguous hierarchy child',ctx['path'],name)
        m=found[0]; ports={}
        for key,expr in re.findall(r'\.(\\[^\s]+|\w+)\s*\(([^()]*)\)',m[2]):
            key=canon(key);expr=expr.strip()
            if expr.startswith('{'):
                for index,net in enumerate(reversed(expr[1:-1].split(','))):
                    ports[f'{key}[{index}]']=resolve(ctx,net)
            else:ports[key]=resolve(ctx,expr)
        return dict(module=m[1],path=ctx['path']+'/'+name,ports=ports)

    top=dict(module='pango_video_system',path='top',ports={})
    core=child(top,'core');proc=child(core,'processor');bridge=child(proc,'result_bridge')
    fabric=child(core,'fabric');dma=child(fabric,'dma')
    contexts=(top,core,proc,bridge,fabric,dma)
    drivers={};declared_inputs={}
    for ctx in contexts:
        primitive=cells(modules[ctx['module']])
        for m in re.finditer(r'\bGTP_INV\s+(\w+)\s*\((.*?)\);',modules[ctx['module']],re.S):
            primitive.append(dict(type='GTP_INV',name=m[1],ports={k:v.strip() for k,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',m[2])}))
        local={}
        for cell in primitive:
            for port in ('Z','Z5','COUT','Q'):
                net=cell['ports'].get(port)
                if net:
                    key=canon(net)
                    assert key not in local, ('multiple local drivers',ctx['path'],key)
                    local[key]=(cell,port)
        drivers[ctx['path']]=local
        inputs=set()
        for m in re.finditer(r'(?m)^\s*input\s+(?:\[(\d+):(\d+)\]\s+)?(\\[^\s]+|\w+)',modules[ctx['module']]):
            key=canon(m[3])
            if m[1] is None:inputs.add(key)
            else:
                high,low=int(m[1]),int(m[2]);assert high>=low
                inputs.update(f'{key}[{i}]' for i in range(low,high+1))
        declared_inputs[ctx['path']]=inputs

    def root_driver(ctx,full):
        found=[(net,cell,port) for net,(cell,port) in drivers[ctx['path']].items() if resolve(ctx,net)==full]
        assert len(found)==1, ('parent output not uniquely driven',ctx['path'],full)
        return found[0]

    states={resolve(bridge,f'mstate[{i}]'):i for i in range(3)}
    assert len(states)==3, 'Collapsed bridge state aliases'
    cancel=resolve(bridge,'cancel_sync');ce=resolve(bridge,'payload_read_enable')
    assert cancel not in states and ce not in states and cancel!=ce
    reset_net=resolve(bridge,'N240_0')
    reset_local,reset_cell,reset_port=root_driver(top,reset_net)
    assert reset_cell['type']=='GTP_INV' and reset_port=='Z'
    assert canon(reset_cell['ports']['I'])=='core_reset_n', 'Reset inverter is not driven by actual core_reset_n'
    records=[]; connections=[]
    # The leaf FSM consumes these actual imported ports. Their parent drivers
    # are found through resolved connections, not by a fabricated net alias.
    roles=((fabric,'N254',{2,3,4},False),(fabric,'N588',{1},False),
           (dma,'core/fabric/dma/N490_3',{3},True))
    for ctx,leaf_port,allowed,requires_not_cancel in roles:
        full_root=resolve(bridge,leaf_port)
        root,_,_=root_driver(ctx,full_root)
        connections.append(dict(leaf_port=leaf_port,resolved_net=full_root,parent_context=ctx['path'],parent_local_net=root))
        leaves={};cone={};visiting=set()

        def scan(net):
            local=canon(net);full=resolve(ctx,local)
            if full in states or full in (cancel,ce) or constant(local) is not None:return
            assert full not in visiting, ('combinational cycle',full)
            if full in cone or full in leaves:return
            # A declared parent input is deliberately unconstrained. This
            # universal abstraction can reject a valid guard, but cannot hide
            # a state-code violation behind assumptions about the arbiter.
            if local in declared_inputs[ctx['path']]:
                leaves[full]=dict(reason='declared_parent_input',local_net=local);return
            assert local in drivers[ctx['path']], ('undriven internal predicate net',ctx['path'],local)
            cell,port=drivers[ctx['path']][local]
            if cell['type'].startswith('GTP_DFF') and port=='Q':
                leaves[full]=dict(reason='parent_FF_Q',cell=cell['name'],primitive=cell['type']);return
            match=re.fullmatch(r'GTP_LUT([1-6])(D)?',cell['type'])
            assert match and port in ('Z','Z5'), ('unknown predicate primitive',cell['type'],port)
            width=5 if port=='Z5' else int(match[1])
            assert port!='Z5' or cell['type']=='GTP_LUT6D'
            visiting.add(full);cone[full]=(cell,port,width)
            for index in range(width):scan(cell['ports'][f'I{index}'])
            visiting.remove(full)

        scan(root)
        assert len(leaves)<=20, ('unbounded predicate leaf domain',leaf_port,len(leaves))
        # Bit-parallel truth vectors exhaust all parent FF/input assignments.
        # This avoids cutting deeper arbiter gates merely to keep a scalar
        # Cartesian-product loop small; every traced combinational node stays.
        count=1<<len(leaves);mask=(1<<count)-1
        values={}
        for i,name in enumerate(sorted(leaves)):
            block=1<<i;pattern=((1<<block)-1)<<block
            values[name]=pattern*(mask//((1<<(2*block))-1))

        def mux(select,yes,no):return (select&yes)|((mask^select)&no)

        def lut(table,inputs):
            if not inputs:return mask if table&1 else 0
            half=1<<(len(inputs)-1)
            return mux(inputs[-1],lut(table>>half,inputs[:-1]),lut(table&((1<<half)-1),inputs[:-1]))

        def evaluate(net,code,cv,cache):
            local=canon(net);full=resolve(ctx,local);k=constant(local)
            if k is not None:return mask if k else 0
            if full in states:return mask if (code>>states[full])&1 else 0
            if full==cancel:return mask if cv else 0
            if full==ce:return mask if code in (2,3) else 0
            if full in cache:return cache[full]
            cell,port,width=cone[full];p=cell['ports']
            literal=re.fullmatch(r"(\d+)'([bh])([0-9a-fA-F_]+)",p['INIT']);assert literal
            table=int(literal[3].replace('_',''),2 if literal[2]=='b' else 16)
            assert int(literal[1])>=1<<width
            value=lut(table,[evaluate(p[f'I{i}'],code,cv,cache) for i in range(width)])
            cache[full]=value
            return value

        observed=set();cases=0
        for code,cv in itertools.product(range(8),range(2)):
            value=evaluate(root,code,cv,dict(values));cases+=count
            if value:
                assert code in allowed, ('predicate violates state guard',leaf_port,code)
                assert not requires_not_cancel or cv==0, ('predicate ignores cancellation',leaf_port)
                observed.add(code)
        assert observed==allowed, ('missing allowed state behavior',leaf_port,observed)
        records.append(dict(leaf_port=leaf_port,net=full_root,true_only_in_codes=sorted(observed),
            requires_cancel_zero=requires_not_cancel,assignments=cases,
            unconstrained_parent_inputs=sorted(leaves),leaf_boundaries=leaves,
            cone={k:dict(cell=v[0],output_port=v[1],lut_width=v[2]) for k,v in cone.items()}))
    return dict(passed=True,guards=records,hierarchy_connections=connections,bridge_state_aliases=states,
        reset_inverter=dict(net=reset_net,cell=reset_cell),
        algorithm='Trace all local combinational drivers; only declared parent inputs and FF Q may be free leaves.',
        limitation='Conservative guard/state-code proof, not complete DDR arbiter equivalence or routed STA.')
