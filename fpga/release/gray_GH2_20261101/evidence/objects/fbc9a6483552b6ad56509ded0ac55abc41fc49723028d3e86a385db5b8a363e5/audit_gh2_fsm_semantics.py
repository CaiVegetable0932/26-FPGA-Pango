"""Exhaustive binary truth-vector audit of the actual bridge FSM next-state cone.

LUT/CARRY equations follow installed PDS 2022.2-SP6.4 simulation primitives.
This complements four-state RTL ownership tests; it is not physical STA.
Unknown primitives, aliases or state forms fail closed. Never starts PDS.

Independent GH2 copy of the frozen H2 transition auditor. Only the parent-
guard import changes: local combinational nets are now traced structurally
instead of accepting a particular intermediate-net spelling. State equations,
legal-domain bounds and event abstractions below remain byte-for-byte logic.
"""
import argparse
import json
from pathlib import Path
import re
from gate_h2_read_port import cells, instance, sha, constant


def audit(path, leaf=False, guarded_board=False):
    text = path.read_text()
    modules = {m[1]:m[0] for m in re.finditer(r'(?m)^module\s+(\w+)\s.*?endmodule',text,re.S)}
    parent_guards=None
    if guarded_board:
        assert not leaf
        from audit_gh2_parent_guards import inspect
        parent_guards=inspect(modules)
    name = next(iter(modules)) if leaf else 'pango_video_system'
    if not leaf:
        for child in ('core','processor','result_bridge'):
            name, _ = instance(modules[name], child)
    primitive = cells(modules[name]); drivers = {}; ff = {}
    # PDS emits simple inverter cells without the comment used by LUTs/FFs.
    for m in re.finditer(r'\bGTP_INV\s+(\w+)\s*\((.*?)\);',modules[name],re.S):
        primitive.append(dict(type='GTP_INV',name=m[1],
            ports={p:v.strip() for p,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',m[2])}))
    for c in primitive:
        p = c['ports']
        for port in ('Z','Z5','COUT'):
            if p.get(port):
                assert p[port] not in drivers, p[port]
                drivers[p[port]] = (c, port)
        if re.fullmatch(r'mstate\[[0-2]\]',c['name']):
            assert c['type'] == 'GTP_DFF_CE' and constant(p['INIT']) == 0
            assert p['Q'] == c['name'] and p['CLK'] == 'memory_clk'
            ff[int(c['name'][7])] = p
    assert set(ff) == {0,1,2}, 'Unknown FSM coding'
    # Discover only the actual combinational fan-in; unrelated output logic is
    # intentionally excluded, while every leaf in the next-state cone is free.
    leaves = set(); visited = set()
    def discover(net):
        if constant(net) is not None or net in visited:return
        visited.add(net)
        if net not in drivers:
            leaves.add(net); return
        c, _ = drivers[net]
        assert c['type'].startswith('GTP_LUT') or c['type']=='GTP_INV', c['type']
        for pin,value in c['ports'].items():
            if re.fullmatch(r'I[0-5]?|CIN',pin):discover(value)
    for p in ff.values():
        for pin in ('D','CE','C'):discover(p[pin])
    required = {'mstate[0]','mstate[1]','mstate[2]','memory_rst_n',
        'request_sync','response_toggle','free_sync','memory_req_ready',
        'cancel_sync','memory_w_ready','memory_done'}
    allowed = required | {f'read_index[{i}]' for i in range(5)} | {f'memory_req_beats[{i}]' for i in range(5)}
    relocated={'N240_0','N254','N588',r'\core/fabric/dma/N490_3'} if guarded_board else set()
    assert leaves <= allowed|relocated, sorted(leaves-allowed-relocated)
    # Include all semantic inputs even if SYN prunes one, to detect accidental
    # omission. Each bit position represents one complete binary assignment.
    names = sorted(allowed); count = 1 << len(names); mask = (1 << count)-1
    values = {}
    for i,n in enumerate(names):
        if i < 3:
            octet = sum(((j >> i)&1) << j for j in range(8))
            data = bytes([octet]) * (count//8)
        else:
            block = 1 << (i-3)
            data = (bytes(block)+bytes([255])*block) * (count//(block*16))
        values[n] = int.from_bytes(data,'little')
    def mux(s,a,b):return (s&a)|((mask^s)&b)
    def lut(init,inputs):
        if not inputs:return mask if init&1 else 0
        half = 1 << (len(inputs)-1)
        return mux(inputs[-1],lut(init>>half,inputs[:-1]),lut(init&((1<<half)-1),inputs[:-1]))
    cache = dict(values)
    def ev(net):
        k=constant(net)
        if k is not None:return mask if k else 0
        if net in cache:return cache[net]
        c,port=drivers[net]; p=c['ports']; kind=c['type']
        if kind=='GTP_INV':
            cache[net]=mask^ev(p['I']); return cache[net]
        m=re.fullmatch(r"\d+'([bh])([0-9a-fA-F_]+)",p['INIT']); assert m
        init=int(m[2].replace('_',''),2 if m[1]=='b' else 16)
        if kind=='GTP_LUT6CARRY':
            ins=[ev(p[f'I{i}']) for i in range(5)]
            a,b=lut(init&0xffffffff,ins),lut(init>>32,ins)
            assert p['I5_TO_LUT'] in ('"TRUE"','"FALSE"') and p['I5_TO_CARRY'] in ('"TRUE"','"FALSE"')
            z=mux(ev(p['CIN']) if p['I5_TO_LUT']=='"FALSE"' else ev(p['I5']),b,a)
            co=mux(a,ev(p['CIN']),ev(p['I5']) if p['I5_TO_CARRY']=='"TRUE"' else b)
            value=co if port=='COUT' else z
        else:
            match=re.fullmatch(r'GTP_LUT([1-6])(D)?',kind); assert match,kind
            width=5 if port=='Z5' else int(match[1])
            value=lut(init,[ev(p[f'I{i}']) for i in range(width)])
        cache[net]=value; return value
    def eq(bits,n):
        result=mask
        for i,b in enumerate(bits):result &= b if (n>>i)&1 else mask^b
        return result
    state=[values[f'mstate[{i}]'] for i in range(3)]
    states=[eq(state,i) for i in range(8)]
    idx=[values[f'read_index[{i}]'] for i in range(5)]
    carry=mask; inc=[]
    for b in idx:inc.append(b^carry); carry &= b
    equal=mask
    for i,b in enumerate(inc):equal &= mask^(b^values[f'memory_req_beats[{i}]'])
    # Original SV extends the addition for comparison to unsized +1: 31+1
    # cannot equal a 5-bit request length. Preserve the carry-out explicitly.
    equal &= mask^carry
    change0=states[0]&(values['request_sync']^values['response_toggle'])
    change1=states[1]&values['memory_req_ready']
    change3=states[3]&(values['cancel_sync']|(values['memory_w_ready']&equal))
    change5=states[5]&(mask^(values['free_sync']^values['response_toggle']))
    completion=(states[2]|states[3]|states[4])&values['memory_done']
    if guarded_board:
        # Each arbitrary parent event is constrained only by the independently
        # proved actual guard. This covers every possible parent behavior and
        # establishes state-code meanings without assuming net names match RTL.
        cache.update({'N240_0':mask^values['memory_rst_n'],
            'N254':completion,'N588':change1,
            r'\core/fabric/dma/N490_3':states[3]&(mask^values['cancel_sync'])&values['memory_w_ready']})
    expected=[]
    for i,b in enumerate(state):
        out=mux(change0,mask if (1>>i)&1 else 0,b)
        out=mux(change1,mask if (2>>i)&1 else 0,out)
        load=mux(values['cancel_sync'],mask if (4>>i)&1 else 0,mask if (3>>i)&1 else 0)
        out=mux(states[2],load,out)
        out=mux(change3,mask if (4>>i)&1 else 0,out)
        out=mux(change5,0,out)
        out=mux(completion,mask if (5>>i)&1 else 0,out)
        expected.append(out&values['memory_rst_n'])
    # The RTL rejects zero/>16 beat descriptors before issuing a DDR request.
    # SEND is reachable only before the accepted count reaches that length.
    # Do not require optimizer don't-care behavior for impossible transactions.
    beats=[values[f'memory_req_beats[{i}]'] for i in range(5)]
    legal_send=0
    for length in range(1,17):
        earlier=0
        for index in range(length):earlier |= eq(idx,index)
        legal_send |= eq(beats,length)&earlier
    domain=(states[0]|states[1]|states[2]|states[4]|states[5]|(states[3]&legal_send))
    domain |= mask^values['memory_rst_n']
    for i,p in ff.items():
        actual=mux(ev(p['CE']),ev(p['D']),state[i]) & (mask^ev(p['C']))
        diff=(actual^expected[i])&domain
        if diff:
            at=(diff&-diff).bit_length()-1
            raise ValueError('State mismatch bit '+str(i)+': '+str({n:(at>>j)&1 for j,n in enumerate(names)}))
    return dict(passed=True,vm_sha256=sha(path),leaf_module=name,
        assignments=count,checked_assignments=domain.bit_count(),
        semantics='All legal FSM states and binary inputs; SEND requires 1..16 beats and index<length; reset checked for every code',
        parent_predicates=parent_guards,
        scope='State-code and ownership-control proof; parent arbiter events are conservative free inputs, not full arbiter equivalence',
        original_state_encoding_verified=True,physical_signoff=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm',type=Path,required=True); parser.add_argument('--leaf',action='store_true')
    parser.add_argument('--guarded-board',action='store_true',help='Prove actual hierarchy predicate guards before abstract event audit')
    args=parser.parse_args()
    print(json.dumps(audit(args.vm,args.leaf,args.guarded_board),indent=2))
