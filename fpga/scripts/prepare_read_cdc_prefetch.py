"""Create the isolated II=1 variant without touching the display read bridge."""
from pathlib import Path
import hashlib,json

def prefetch(text):
    replacements={
      'module dma_read_cdc(':'module dma_read_cdc_prefetch(',
      'always @(posedge client_clk)if(cstate==C_LOAD)read_q<=payload[read_index[3:0]];':
      '''// The complete burst is immutable before client delivery. Read the
 // following word on the same edge that accepts the current registered word;
 // a stalled consumer retains read_q and its index, with no RAM collision.
 always @(posedge client_clk)
  if(cstate==C_LOAD)read_q<=payload[read_index[3:0]];
  else if(r_valid && r_ready && !r_last)read_q<=payload[read_index[3:0]+1'b1];''',
      "else begin read_index<=read_index+1'b1;cstate<=C_LOAD;end":
      "else begin read_index<=read_index+1'b1;cstate<=C_OUTPUT;end"}
    for old,new in replacements.items():
        if text.count(old)!=1:raise ValueError('Unexpected read bridge: '+old)
        text=text.replace(old,new)
    return text

def main():
    fpga=Path(__file__).resolve().parents[1];original=fpga/'rtl/memory/dma_read_cdc.sv'
    destination=fpga/'experiments/proc150/rtl/dma_read_cdc_prefetch.sv'
    if destination.exists():raise ValueError('Preserve existing experimental source')
    destination.write_text(prefetch(original.read_text(encoding='utf-8')),encoding='utf-8',newline='\n')
    (destination.parent/'read_cdc_prefetch_origin.json').write_text(json.dumps(dict(
        original=str(original),original_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),
        destination_sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
        production_changed=False,cycle_equivalent=False,burst_protocol_unchanged=True),indent=2))
    print(destination)

if __name__=='__main__':main()
