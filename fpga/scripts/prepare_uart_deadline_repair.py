"""Freeze an equivalent modulo32 deadline comparison for the UART parser.

Precompute the first-byte deadline and wrap bit once. Arrival-time and waiting
checks then use parallel comparisons rather than subtraction followed by a
comparison. No parser state, service edge or video timing is changed.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes


def main():
    """Retain the exact old parser and change only its deadline arithmetic."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):raise ValueError('Frozen candidate required')
    before=json.loads((base/'sources.json').read_text())
    if hashes(base/'source')!=before:raise ValueError('Baseline inputs changed')
    name='rtl/control/uart_v2_parser.sv';content=(base/'source'/name).read_text()
    changes=[
      (' reg [7:0] q;reg [31:0] qt,first_us;', ''' reg [7:0] q;reg [31:0] qt,first_us;
 // Precompute the modulo32 deadline at the same edge as first_us. When the
 // interval wraps, its complement lies between deadline and first_us;
 // otherwise expiration is outside [first_us,deadline). This preserves even
 // backward timestamps and the exact >= boundary of unsigned age arithmetic.
 // Unusual negative/wider parameter overrides retain the original expression.
 localparam USE_DEADLINE=(TIMEOUT_US>=0 && TIMEOUT_US<=64'h00000000ffffffff);
 localparam [31:0] TIMEOUT_LOW32=TIMEOUT_US;
 reg [31:0] deadline_us;reg deadline_wrap;
 wire [32:0] first_deadline_sum={1'b0,qt}+{1'b0,TIMEOUT_LOW32};
 wire arrival_expired=USE_DEADLINE ?
  (deadline_wrap ? (qt>=deadline_us && qt<first_us) : (qt>=deadline_us || qt<first_us)) :
  ((qt-first_us)>=TIMEOUT_US);
 wire waiting_expired=USE_DEADLINE ?
  (deadline_wrap ? (now_us[31:0]>=deadline_us && now_us[31:0]<first_us) :
                   (now_us[31:0]>=deadline_us || now_us[31:0]<first_us)) :
  ((now_us[31:0]-first_us)>=TIMEOUT_US);'''),
      ('offset<=0;q<=0;qt<=0;first_us<=0;', 'offset<=0;q<=0;qt<=0;first_us<=0;deadline_us<=0;deadline_wrap<=0;'),
      ('expired_wait<=offset!=0 && (now_us[31:0]-first_us)>=TIMEOUT_US;',
       'expired_wait<=offset!=0 && waiting_expired;'),
      ("first_us<=qt;crc<=16'hffff;", "first_us<=qt;deadline_us<=first_deadline_sum[31:0];deadline_wrap<=first_deadline_sum[32];crc<=16'hffff;"),
      ('end else if((qt-first_us)>=TIMEOUT_US) begin','end else if(arrival_expired) begin')]
    for old,new in changes:
        if content.count(old)!=1:raise ValueError('Unexpected parser baseline: '+old)
        content=content.replace(old,new,1)
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('uart_deadline_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    shutil.copyfile(base/'source'/name,run/'original_uart_v2_parser.sv')
    (run/'source'/name).write_text(content)
    after=hashes(run/'source')
    if set(after)!=set(before) or {n for n in before if before[n]!=after[n]}!={name}:
        raise ValueError('Unexpected composition change')
    (run/'sources.json').write_text(json.dumps(after,indent=2)+'\n')
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),changed=[name],
        parser_latency_changed=False,deadline_us_default=30000,modulo_bits=32,
        functional_pass=False,differential_required=True,full_model_required=True,
        native_synthesis_started=False,routed=False,programmed=False),indent=2)+'\n')
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__=='__main__':
    main()
