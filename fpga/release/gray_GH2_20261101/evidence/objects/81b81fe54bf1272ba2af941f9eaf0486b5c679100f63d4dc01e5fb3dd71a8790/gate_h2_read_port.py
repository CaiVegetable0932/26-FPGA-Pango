"""Read-only, fail-closed full-board H2 RAM mapping gate before MAP.

Behavioral ownership proof and structural clock/CE proof remain distinct.
Unknown VM forms require review; no constraint/source changes are attempted.
"""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cells(block):
    """Retain primitive parameters as well as ports, including attributed RAM."""
    pattern = r'(?m)^\s*(?:\(\*[^\n]*?\*\)\s*)?(GTP_\w+)\s+/\*\s*(.*?)\s*\*/(.*?);'
    result = [dict(type=m[1], name=m[2].strip().lstrip('\\'),
        ports={p:v.strip() for p,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',m[3])})
        for m in re.finditer(pattern,block,re.S)]
    if len(result) != len(re.findall(r'\bGTP_\w+\s+/\*',block)):
        raise ValueError('Unrecognized primitive form; manual review needed')
    return result


def instance(block, name):
    """Resolve one actual hierarchy connection, never assume RTL module names."""
    found = list(re.finditer(r'(?m)^\s+(\w+)\s+'+re.escape(name)+r'\s*\((.*?)\);',block,re.S))
    if len(found) != 1:
        raise ValueError('Missing/ambiguous instance '+name)
    match = found[0]
    return match[1], {p:v.strip() for p,v in re.findall(r'\.(\w+)\s*\(([^()]*)\)',match[2])}


def bus(expression):
    """This VM exposes expanded single-bit concatenations; reject other syntax."""
    if not expression.startswith('{') or not expression.endswith('}'):
        raise ValueError('Expected expanded RAM bus')
    return [token.strip() for token in expression[1:-1].split(',')]


def constant(signal):
    if signal in ("1'b0", "1'h0", '0'):return 0
    if signal in ("1'b1", "1'h1", '1'):return 1
    return None


def enable_truth(primitive_cells, enable, memory_clock):
    """Evaluate actual LUT INITs for all binary FSM codes, without trusting names.

    Only the three original memory-clock state FFs and constants are admitted
    as leaves. FSM recoding or another primitive type stops for manual review.
    """
    drivers={}; states={}; cone={}
    for cell in primitive_cells:
        ports=cell['ports']
        # Carry-only primitives often leave Z disconnected; an empty port is
        # not a shared driven net and must not create a false multi-driver.
        if ports.get('Z'):
            if ports['Z'] in drivers:raise ValueError('Multiple combinational drivers')
            drivers[ports['Z']]=cell
        match=re.fullmatch(r'mstate\[(\d+)\]',cell['name'])
        if match and cell['type'].startswith('GTP_DFF'):
            if ports.get('CLK') != memory_clock:raise ValueError('State clock differs from RAM read clock')
            states[ports['Q']]=int(match[1])
    if sorted(states.values()) != [0,1,2]:
        raise ValueError('FSM encoding is not the original three-bit form; review needed')
    def evaluate(net, code, visiting):
        value=constant(net)
        if value is not None:return value
        if net in states:return (code>>states[net])&1
        if net in visiting or net not in drivers:
            raise ValueError('Read CE cone has an unknown/non-state leaf: '+net)
        cell=drivers[net]; match=re.fullmatch(r'GTP_LUT([1-6])',cell['type'])
        if not match:raise ValueError('Read CE cone needs unsupported primitive: '+cell['type'])
        count=int(match[1]); ports=cell['ports']
        init=re.fullmatch(r"(\d+)'([bh])([0-9a-fA-F]+)",ports.get('INIT',''))
        if not init or int(init[1]) != 1<<count:raise ValueError('Invalid/unknown LUT truth table')
        inputs=[ports['I'+str(i)] for i in range(count)]
        index=sum(evaluate(pin,code,visiting|{net})<<i for i,pin in enumerate(inputs))
        cone[net]=dict(cell=cell['name'],type=cell['type'],init=ports['INIT'],inputs=inputs)
        return (int(init[3],2 if init[2]=='b' else 16)>>index)&1
    values=[evaluate(enable,code,set()) for code in range(8)]
    expected=[0,0,1,1,0,0,0,0]
    return dict(passed=values==expected, states=states, values_for_codes_0_to_7=values,
        expected=expected, code_meaning={'2':'M_LOAD','3':'M_SEND'}, cone=cone,
        limitation='Requires original binary mstate bit identity; recoded or unknown forms stop before MAP.')


def inspect_board_vm(path):
    """Require the board result bridge to implement one owned synchronous read."""
    text=path.read_text(errors='strict')
    modules={m[1]:m[0] for m in re.finditer(r'(?m)^module\s+(\w+)\s.*?endmodule',text,re.S)}
    if len(re.findall(r'(?m)^\s+\w+\s+result_bridge\s*\(',text))!=1:
        raise ValueError('Expected exactly one board result_bridge')
    top=modules['pango_video_system']; name='pango_video_system'; chain=[]
    for child in ('core','processor','result_bridge'):
        next_name,ports=instance(modules[name],child)
        chain.append(dict(parent=name,instance=child,module=next_name,ports=ports)); name=next_name
    block=modules[name]; primitive_cells=cells(block)
    def top_net(net):
        for item in reversed(chain):
            if net not in item['ports']:raise ValueError('Clock is not a transparent hierarchy port: '+net)
            net=item['ports'][net]
        return net
    ram=[c for c in primitive_cells if c['type']=='GTP_DRM36K_E1']
    if len(ram)!=4 or any(c['type'].startswith('GTP_DRM') and c not in ram for c in primitive_cells):
        raise ValueError('Expected four DRM36K_E1 cells, no alternative payload memory')
    outputs=[]; parameters=[]
    for cell in ram:
        p=cell['ports']
        if any(p.get(k)!=v for k,v in {'RAM_MODE':'"SIMPLE_DUAL_PORT"','DATA_WIDTH_A':'72',
            'DATA_WIDTH_B':'72','DOA_REG':'0','DOB_REG':'0','WEB':"1'b0"}.items()):
            raise ValueError('Unexpected SDP width/register/mode configuration')
        if constant(p['CEB']) is not None or not p['CEB']:
            raise ValueError('Read CEB is constant; ownership gate absent')
        if constant(p['WEA']) is not None:
            raise ValueError('Write enable is constant')
        for address in ('ADDRA','ADDRB'):
            tokens=bus(p[address]);dynamic=[x for x in tokens if constant(x) is None]
            if len(tokens)!=16 or len(dynamic)!=4 or len(set(dynamic))!=4:
                raise ValueError('Payload address is not a 16-word port')
        outputs.extend(bus(p['DOA']));outputs.extend(bus(p['DOB']))
        parameters.append(dict(cell=cell['name'],ports={k:p[k] for k in
            ('RAM_MODE','DATA_WIDTH_A','DATA_WIDTH_B','DOA_REG','DOB_REG','CLKA','CLKB','CEA','CEB','WEA','WEB','ADDRA','ADDRB','DOA','DOB')}))
    for key in ('CLKA','CLKB','CEB','ADDRA','ADDRB','WEA'):
        if len({c['ports'][key] for c in ram})!=1:
            raise ValueError('RAM slices disagree on '+key)
    p=ram[0]['ports']; write_clock=top_net(p['CLKA']); read_clock=top_net(p['CLKB'])
    _,ddr=instance(top,'I_ips_ddr_top')
    if write_clock!='processing_clk' or read_clock!=ddr.get('core_clk') or read_clock!='ddr_clk':
        raise ValueError('RAM clocks do not resolve to processing/DDR core clocks')
    expected={f'memory_w_data[{i}]' for i in range(256)}|{f'memory_w_strb[{i}]' for i in range(32)}
    if set(outputs)!=expected or any(n!=1 for n in Counter(outputs).values()):
        raise ValueError('Cannot prove all 288 data/strobe outputs directly from SDP; inspect aliases/optimization')
    fabric=[c['name'] for c in primitive_cells if c['type'].startswith('GTP_DFF') and
            (c['name'].startswith('payload') or 'read_q' in c['name'])]
    if fabric or 'read_q' in block:
        raise ValueError('Fabric payload word/read_q remains; old first-hop cannot be retired')
    truth=enable_truth(primitive_cells,p['CEB'],p['CLKB'])
    if not truth['passed']:
        raise ValueError('Read CEB does not equal M_LOAD or M_SEND in actual LUT truth table')
    return dict(passed=True,board_instance='core/processor/result_bridge',leaf_module=name,
        ram_count=4,parameters=parameters,read_ce_truth=truth,
        resolved_write_clock=write_clock,resolved_read_clock=read_clock,
        data_strobe_output_bits=len(outputs),no_fabric_payload_or_read_q=True,
        limitation='SYN structural mapping proof, not MAP/PnR timing or physical collision signoff')


def review(syn,out):
    """Write pass/needs-review evidence before the caller can consider MAP."""
    path=syn/'synthesize/pango_video_system_syn.vm'
    record=dict(passed=False,status='NEEDS_REVIEW',vm=str(path),physical_signoff=False)
    try:
        record['vm_sha256']=sha(path)
        record.update(inspect_board_vm(path))
        # State bit names do not establish preserved encoding. Retain the
        # topology evidence but require an independent transition audit before
        # MAP; a parser-only match must never authorize the retired exception.
        record.update(passed=False, status='NEEDS_REVIEW',
            reason='RAM topology checked; actual FSM transition semantics require independent review')
    except (KeyError,ValueError,FileNotFoundError) as error:
        record['reason']=str(error)
    (out/'board_ram_mapping_gate.json').write_text(json.dumps(record,indent=2),encoding='utf-8')
    return record
