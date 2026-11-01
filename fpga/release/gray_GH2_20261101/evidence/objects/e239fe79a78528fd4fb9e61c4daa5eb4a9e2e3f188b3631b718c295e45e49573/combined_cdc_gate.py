"""Bind a constraint-only BE revision to prior functional proof and audit CDC application."""
import json
import re
from pathlib import Path
from combined_candidate_gate import read, sha, functional_review
from combined_candidate_gate import wait_and_verify as wait_original


def verify_revision(fpga,candidate,proof_candidate):
    """Allow exactly the reviewed FDC change; all RTL remains byte identical."""
    expected=fpga/'build/reader_full_chunks_20261031/BE_working_candidate'
    if proof_candidate!=expected or not candidate.is_relative_to(fpga/'build'):
        raise ValueError('Unexpected candidate/proof location')
    original=read(proof_candidate/'sources.json');current=read(candidate/'sources.json')
    if set(original)!=set(current):raise ValueError('Source set changed')
    if not all(sha(candidate/'source'/n)==h for n,h in current.items()):
        raise ValueError('Revised candidate source drift')
    changed=[n for n in original if original[n]!=current[n]]
    if changed!=['constraints/video_system/clocks_cdc.fdc']:
        raise ValueError('Revision must change only clocks_cdc.fdc')
    result=functional_review(fpga)
    result.update(physical_candidate=str(candidate),proof_candidate=str(proof_candidate),
        constraint_only_revision=True,changed=changed,physical_manifest_sha256=sha(candidate/'sources.json'))
    return result


def wait_and_verify(fpga,out,publish,stop,candidate,proof_candidate):
    """Reuse bounded predecessor ownership checks, then validate the new FDC snapshot."""
    review=verify_revision(fpga,candidate,proof_candidate)
    (out/'constraint_revision_precheck.json').write_text(json.dumps(review,indent=2))
    retired=read(fpga/'build/gray_candidates_native_20261031/BE_after_BCD/state.json')
    if retired.get('candidates') or retired['status']!='FAILED' or retired.get('error')!='Stop requested while waiting':
        raise RuntimeError('Previous BE waiter did not close without native execution')
    wait_original(fpga,out,publish,stop)
    review=verify_revision(fpga,candidate,proof_candidate)
    (out/'constraint_revision_finalcheck.json').write_text(json.dumps(review,indent=2))


def review_cdc(syn,mapping,out):
    """Require actual MAP loading and inspect the repaired asynchronous first hop."""
    dmr=(mapping/'device_map/pango_video_system.dmr').read_text(errors='replace')
    snr=(syn/'synthesize/pango_video_system.snr').read_text(errors='replace')
    fdc=(mapping/'source/constraints/video_system/clocks_cdc.fdc').read_text()
    new_commands=[line.strip() for line in fdc.splitlines() if line.startswith('set_') and 'camera_input.paused_meta' in line]
    commands_present=len(new_commands)==2 and all(command in dmr for command in new_commands)
    # No broad second-stage false-path exception may be added by this repair.
    original=Path(__file__).resolve().parents[1]/'build/reader_full_chunks_20261031/BE_working_candidate/source/constraints/video_system/clocks_cdc.fdc'
    before={line.strip() for line in original.read_text().splitlines() if line.startswith('set_')}
    after={line.strip() for line in fdc.splitlines() if line.startswith('set_')}
    only_exact_commands=(after-before)==set(new_commands) and not (before-after)
    downstream_unexcepted=not any('paused_sync' in command for command in new_commands)
    blocks=re.split(r'(?=Startpoint\s*:)',snr)
    bad=[block[:350] for block in blocks if 'Endpoint    : camera_input/paused_meta/D' in block
         and re.search(r'Path Type\s*: min',block) and 'Slack (VIOLATED)' in block]
    text=dmr+snr+(mapping/'console.log').read_text(errors='replace')+(syn/'console.log').read_text(errors='replace')
    result={'map_loaded_exact_two_commands':commands_present,'only_exact_commands_added':only_exact_commands,
            'no_downstream_paused_sync_exception':downstream_unexcepted,'no_STA3015':'STA-3015' not in text,
            'reported_bad_first_hop_min_paths':bad,'commands':new_commands,
            'report_limit':'Synthesis reported paths only; not routed STA signoff',
            'dmr_sha256':sha(mapping/'device_map/pango_video_system.dmr'),'snr_sha256':sha(syn/'synthesize/pango_video_system.snr')}
    result['passed']=commands_present and only_exact_commands and downstream_unexcepted and result['no_STA3015'] and not bad
    (out/'cdc_constraint_review.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise RuntimeError('New camera CDC constraint verification failed')
