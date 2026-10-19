"""Exclude only the deliberately changed, uninstantiated board parent from unit binding."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
p=ROOT/'fpga/scripts/probe_processing_domain_mapping.py';text=p.read_text(encoding='utf-8')
old='        for name,h in hashes.items():\n'
new=old+'''            # This two-clock integration parent is not instantiated by the
            # isolated processing top. Its deliberate adapter change is
            # verified separately in the full parent simulation/board MAP.
            if name=='video_memory_core.sv':continue
'''
assert text.count(old)==1;text=text.replace(old,new)
old='             top=args.top,\n';assert text.count(old)==1
text=text.replace(old,old+"             shared_input_excluded_parent=['video_memory_core.sv'],\n")
p.write_text(text,encoding='utf-8',newline='\n')
