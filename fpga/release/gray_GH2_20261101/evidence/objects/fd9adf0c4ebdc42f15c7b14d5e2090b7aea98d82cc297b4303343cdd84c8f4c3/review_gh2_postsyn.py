"""Supplement the preserved GH2 SYN gate with structural predicate proof.

No PDS execution or old-artifact writes. --write publishes one new review;
verify_review() reads that review and checks every frozen dependency again.
Fault injection uses in-memory VM copies, never the actual SYN or RTL files.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import sys

from evaluate_g_candidate import frozen_sources,read,sha
from review_gh2_functional import functional_proof
from review_gh2_netlist import topology_inspector,TOPOLOGY_HELPER
from review_g_netlist import inspect_syn,compare,EXPECTED_DE
from audit_gh2_fsm_semantics import audit
from audit_gh2_parent_guards import inspect as inspect_guards


FPGA=Path(__file__).resolve().parents[1]
ROOT=FPGA/'build/gh2_integration_20261101'
OUT=ROOT/'post_syn_review_20261101'
STATUS='GH2_SYN_RAM_FSM_CE_VERIFIED_MAP_ALLOWED'
SCRIPT_NAMES=('audit_gh2_parent_guards.py','audit_gh2_fsm_semantics.py','review_gh2_postsyn.py')


def require(value,message):
    """Keep supplement identity checks active independently of assert settings."""
    if not value:raise ValueError(message)


def encoded(value):
    """The same deterministic bytes are hashed before writing their proof file."""
    return json.dumps(value,indent=2).encode('utf-8')


def json_sha(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def source_identity():
    """Bind the stopped original SYN, its exact VM and the fresh GH2 function proof."""
    require(not sys.flags.optimize,'Reused auditors require active Python assertions')
    state=read(ROOT/'native/state.json')
    require(state['status']=='SYN_GATE_NEEDS_REVIEW' and state['synthesis_wrapper_exit']==0,
            'Expected original successful SYN stopped at semantic gate')
    require('mapping' not in state and state['active_wrapper_pid'] is None,'Original driver must remain stopped before MAP')
    manifest,functional=functional_proof(ROOT/'candidate')
    require(state['functional']==functional and state['sources_sha256']==functional['sources_sha256'],'Function proof changed')
    syn=Path(state['synthesis']);result=read(syn/'result.json')
    require(frozen_sources(syn)==manifest,'SYN/candidate327 mismatch')
    require(result['native_exit']==0 and not result['errors'] and result['snapshot_intact'] and result['stage']=='synthesize',
            'Actual SYN did not complete successfully')
    bindings=dict(read(ROOT/'native/scripts.json'))
    bindings.update(state['completed_artifacts_sha256']['synthesis'])
    bindings.update({str(ROOT/'native/state.json'):sha(ROOT/'native/state.json'),
        str(ROOT/'native/netlist_review/review.json'):sha(ROOT/'native/netlist_review/review.json'),
        str(Path(functional['path'])):functional['sha256'],str(ROOT/'candidate/sources.json'):functional['sources_sha256']})
    for name,digest in bindings.items():require(sha(Path(name))==digest,'Original bound input changed: '+name)
    bindings.update({str(FPGA/'scripts'/n):sha(FPGA/'scripts'/n) for n in SCRIPT_NAMES})
    bindings[str(TOPOLOGY_HELPER)]=sha(TOPOLOGY_HELPER)
    return syn,manifest,functional,bindings


class MemoryVM:
    """Provide only file-like reads to auditors for an explicit fault fixture."""
    def __init__(self,name,content):self.name=name;self.content=content
    def read_text(self,*args,**kwargs):return self.content
    def read_bytes(self):return self.content.encode('utf-8')
    def __str__(self):return 'in-memory-fault:'+self.name


def modules_from(content):
    return {m[1]:m[0] for m in re.finditer(r'(?m)^module\s+(\w+)\s.*?endmodule',content,re.S)}


def alter_cell_port(block,name,port,value):
    """Mutate one known actual primitive pin; ambiguous fixtures are rejected."""
    matches=list(re.finditer(r'(?m)^\s*GTP_\w+\s+/\*\s*\\?'+re.escape(name)+r'\s*\*/.*?;',block,re.S))
    require(len(matches)==1,'Fault fixture primitive must be unique: '+name)
    cell=matches[0][0]
    changed,count=re.subn(r'(\.'+re.escape(port)+r'\s*\()[^()]*(\))',lambda m:m[1]+value+m[2],cell)
    require(count==1 and changed!=cell,'Fault fixture port missing/unchanged')
    return block[:matches[0].start()]+changed+block[matches[0].end():]


def alter_child_port(block,child,port,transform):
    """Mutate a parsed escaped hierarchy port without replacing unrelated nets."""
    found=list(re.finditer(r'(?m)^\s+(\w+)\s+'+re.escape(child)+r'\s*\((.*?)\);',block,re.S))
    require(len(found)==1,'Fault fixture child ambiguous')
    body=found[0][2]
    pattern=r'(\.'+re.escape(port)+r'\s*\()([^()]*)(\))'
    changed,count=re.subn(pattern,lambda m:m[1]+transform(m[2])+m[3],body)
    require(count==1 and changed!=body,'Fault fixture hierarchy port unchanged')
    offset=found[0].start(2)
    return block[:offset]+changed+block[found[0].end(2):]


def negative_tests(vm,parent_proof,ram):
    """Reject decoder, cross-hierarchy, read-CE and FSM faults on actual GH2."""
    content=vm.read_text();modules=modules_from(content);out=[]
    context_module={}
    current='pango_video_system'
    for child in ('core','fabric'):
        m=re.search(r'(?m)^\s+(\w+)\s+'+child+r'\s*\(',modules[current]);require(m is not None,'Missing fixture hierarchy')
        current=m[1];context_module[child]=current
    core_name=context_module['core'];fabric_name=context_module['fabric']
    proc_name=re.search(r'(?m)^\s+(\w+)\s+processor\s*\(',modules[core_name])[1]
    bridge_name=re.search(r'(?m)^\s+(\w+)\s+result_bridge\s*\(',modules[proc_name])[1]
    ready=next(g for g in parent_proof['guards'] if g['leaf_port']=='N588')
    decoders=[v['cell'] for k,v in ready['cone'].items() if k!=ready['net']]
    require(len(decoders)==1,'Expected one actual intermediate N588 decoder for injection')
    decoder=decoders[0]

    def expect_rejected(label,changed,checker):
        altered=dict(modules);altered.update(changed)
        try:checker(altered)
        except (AssertionError,ValueError,KeyError) as error:
            out.append(dict(case=label,rejected=True,error_type=type(error).__name__,reason=str(error),
                mutated_modules_sha256={n:hashlib.sha256(v.encode()).hexdigest() for n,v in changed.items()}))
        else:raise ValueError('Fault was not rejected: '+label)

    # Set bit0 as well as bit1: parent readiness may now assert in IDLE.
    literal=decoder['ports']['INIT'];match=re.fullmatch(r"64'b([01]{64})",literal);require(match is not None,'Unexpected decoder literal')
    bad_init="64'b"+format(int(match[1],2)|1,'064b')
    expect_rejected('intermediate_decoder_INIT_adds_IDLE',
        {fabric_name:alter_cell_port(modules[fabric_name],decoder['name'],'INIT',bad_init)},inspect_guards)

    def swapped_bus(expression):
        require(expression.strip().startswith('{'),'Expected explicit actual mstate bus connection')
        bits=expression.strip()[1:-1].split(',');require(len(bits)==3,'Expected three actual state bits')
        bits[1],bits[2]=bits[2],bits[1]
        return '{'+','.join(bits)+'}'
    expect_rejected('cross_parent_mstate_bit_swap',
        {core_name:alter_child_port(modules[core_name],'fabric',r'\core/processor/result_bridge/mstate',swapped_bus)},inspect_guards)
    expect_rejected('bridge_ready_guard_connected_to_completion_guard',
        {proc_name:alter_child_port(modules[proc_name],'result_bridge','N588',lambda _:r'\result_bridge/N254 ')},inspect_guards)

    def as_vm(changed,name):
        replacement=content
        for module,body in changed.items():
            if body!=modules[module]:replacement=replacement.replace(modules[module],body,1)
        return MemoryVM(name,replacement)
    ce_net=ram['parameters'][0]['ports']['CEB']
    ce_cells=[c['cell'] for c in ram['read_ce_truth']['cone'].values() if c.get('cell')]
    # The topology record identifies the actual decoder cell, not its RTL name.
    require(len(ce_cells)==1,'Expected one actual read-CE LUT')
    expect_rejected('read_CE_constant_zero_INIT',
        {bridge_name:alter_cell_port(modules[bridge_name],ce_cells[0],'INIT',"64'b"+'0'*64)},
        lambda changed:topology_inspector()(as_vm(changed,'read_CE_constant_zero_INIT')))
    expect_rejected('FSM_state_bit1_D_stuck_zero',
        {bridge_name:alter_cell_port(modules[bridge_name],'mstate[1]','D',"1'b0")},
        lambda changed:audit(as_vm(changed,'FSM_state_bit1_D_stuck_zero'),guarded_board=True))
    # Renaming an internal wire together with its real connection is harmless;
    # accepting this fixture demonstrates independence from PDS's numeric name.
    local=decoder['ports']['Z'];renamed=modules[fabric_name].replace(local,'gh2_test_decoder_renamed')
    require(renamed!=modules[fabric_name],'Rename fixture did not change input')
    renamed_proof=inspect_guards(dict(modules,**{fabric_name:renamed}))
    require(renamed_proof['passed'],'Benign intermediate rename rejected')
    return dict(passed=True,vm_sha256=sha(vm),negative_case_count=len(out),all_negative_cases_rejected=True,
        cases=out,positive_case=dict(name='internal_decoder_rename_only',passed=True),
        original_VM_written=False,physical_signoff=False)


def collect():
    """Pure computation from frozen inputs; returns independent proof objects."""
    syn,manifest,functional,bindings=source_identity()
    vm=syn/'synthesize/pango_video_system_syn.vm'
    ram=topology_inspector()(vm)
    fsm=audit(vm,guarded_board=True)
    require(ram['passed'] and fsm['passed'] and fsm['parent_predicates']['passed'],'Actual GH2 RAM/FSM proof incomplete')
    ds=read(FPGA/'build/DE_optimization_20261031/native/state.json')
    de_candidate=FPGA/'build/DE_optimization_20261031/candidate'
    baseline=inspect_syn(Path(ds['synthesis']),frozen_sources(de_candidate))
    for bank,groups in EXPECTED_DE.items():
        for group,count in groups.items():
            actual=baseline['banks'][bank]['groups'][group]
            require(actual['retained_ff_count']==count and actual['branch_count']==1,'DE CE baseline changed')
    current=inspect_syn(syn,manifest);comparison=compare(baseline,current)
    require(comparison['retained_payload_metadata_coverage_equal'] and comparison['four_enables_replication_visible'],
            'Actual GH2 CE branch or payload coverage failed')
    tests=negative_tests(vm,fsm['parent_predicates'],ram)
    ram.update(vm=str(vm),vm_sha256=sha(vm),status='BOARD_RAM_AND_STATE_SEMANTICS_VERIFIED',
        independent_fsm_review_sha256=json_sha(fsm),physical_signoff=False)
    ce=dict(baseline=baseline,current=current,comparison=comparison,physical_signoff=False,
        limit='Actual local FF CE loads and extra local input loads; not a global fanout guarantee.')
    proofs={'board_ram_mapping_gate.json':ram,'fsm_semantics.json':fsm,'ce_review.json':ce,'negative_tests.json':tests}
    bindings.update({str(OUT/name):json_sha(value) for name,value in proofs.items()})
    report=dict(status=STATUS,passed=True,synthesis=str(syn),candidate=str(ROOT/'candidate'),
        source_count=327,sources_sha256=functional['sources_sha256'],functional=functional,vm_sha256=sha(vm),
        synthesis_result_sha256=sha(syn/'result.json'),evidence_sha256=bindings,
        original_gate_preserved=str(ROOT/'native/netlist_review/review.json'),
        reason='The old H2 guard whitelist cut the actual GH2 intermediate decoder _N225468. This supplement follows all local combinational connections through actual input/FF boundaries.',
        proof_scope='Actual GH2 RAM topology, guarded FSM encoding/ownership and CE replication, not complete arbiter equivalence or physical timing.',
        physical_signoff=False,routing_started=False,promoted=False)
    return report,proofs


def verify_review():
    """Pure read-only identity verification of the published supplement."""
    report=read(OUT/'review.json')
    require(report['status']==STATUS and report['passed'],'Post-SYN supplement not passed')
    syn,manifest,functional,bindings=source_identity()
    require(report['synthesis']==str(syn) and report['functional']==functional and
        report['sources_sha256']==functional['sources_sha256'],'Published supplement input mismatch')
    for name,digest in bindings.items():require(report['evidence_sha256'].get(name)==digest,'Supplement source binding mismatch: '+name)
    for name,digest in report['evidence_sha256'].items():require(sha(Path(name))==digest,'Supplement evidence changed: '+name)
    ram=read(OUT/'board_ram_mapping_gate.json');fsm=read(OUT/'fsm_semantics.json');ce=read(OUT/'ce_review.json');tests=read(OUT/'negative_tests.json')
    require(ram['passed'] and fsm['passed'] and fsm['parent_predicates']['passed'] and
        ram['vm_sha256']==fsm['vm_sha256']==ce['current']['vm_sha256']==report['vm_sha256']==sha(syn/'synthesize/pango_video_system_syn.vm'),
        'Proofs do not bind the same actual GH2 VM')
    require(ram['independent_fsm_review_sha256']==sha(OUT/'fsm_semantics.json'),'RAM/FSM proof binding changed')
    require(ce['comparison']['retained_payload_metadata_coverage_equal'] and ce['comparison']['four_enables_replication_visible'],
        'Published CE proof incomplete')
    require(tests['passed'] and tests['all_negative_cases_rejected'] and tests['negative_case_count']==5 and
        len(tests['cases'])==5 and all(c['rejected'] for c in tests['cases']),'Fault-injection proof incomplete')
    return report


def main():
    """Publish exclusively in a new directory, preserving the original stop."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true')
    args=parser.parse_args()
    if args.write:require(not OUT.exists(),'Supplement already exists; use verify_review() without rewriting')
    report,proofs=collect()
    if args.write:
        OUT.mkdir(exist_ok=False)
        for name,value in proofs.items():(OUT/name).write_bytes(encoded(value))
        report['checked_at']=datetime.now().astimezone().isoformat()
        (OUT/'review.json').write_bytes(encoded(report));verify_review()
    print(json.dumps(dict(status=report['status'],passed=report['passed'],vm_sha256=report['vm_sha256'],
        FSM_checked_assignments=proofs['fsm_semantics.json']['checked_assignments'],
        negative_case_count=proofs['negative_tests.json']['negative_case_count'],
        written_to=str(OUT/'review.json') if args.write else None),indent=2))


if __name__=='__main__':main()
