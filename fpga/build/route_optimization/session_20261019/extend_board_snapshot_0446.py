"""Extend the existing board builder in place; explicit experimental mode never routes."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
p=ROOT/'fpga/scripts/build_video_system.py';text=p.read_text(encoding='utf-8')
changes=[
('    options = parser.parse_args()\n',"    options = parser.parse_args()\n    if options.experimental_proc150 and (not options.rtl_snapshot or options.stage not in ('compile','synthesize','dev_map')):\n        parser.error('experimental processing board supports explicit-snapshot compile/SYN/MAP only')\n"),
("    fpga = Path(__file__).resolve().parents[1]\n","""    fpga = Path(__file__).resolve().parents[1]
    # A frozen candidate is a review input, never an alternative release gate.
    origin=options.rtl_snapshot.resolve() if options.rtl_snapshot else fpga
    if options.rtl_snapshot:
        if not origin.is_relative_to(fpga/'build'):raise ValueError('Candidate must be frozen under fpga/build')
        expected=json.loads((origin.parent/'sources.json').read_text())
        if not all(hashlib.sha256((origin/n).read_bytes()).hexdigest()==h for n,h in expected.items()):
            raise ValueError('Candidate source closure drift')
    ips=['video_pll','ddr3_controller']+(['sys_pll'] if options.experimental_proc150 else [])
"""),
("for path in sorted((fpga / 'rtl' / group).glob('*')):","for path in sorted((origin / 'rtl' / group).glob('*')):"),
("names.append(path.relative_to(fpga).as_posix())","names.append(path.relative_to(origin).as_posix())"),
("              'tmds_serializer.v', 'video_memory_core.sv', 'pango_video_system.sv']]\n","              'tmds_serializer.v', 'video_memory_core.sv', 'pango_video_system.sv']]\n    if options.experimental_proc150:names.append('rtl/board/processing_domain_reset.sv')\n"),
("                   'constraints/placement.fdc', 'constraints/routing.rcf']\n","                   'constraints/placement.fdc', 'constraints/routing.rcf']\n    if options.experimental_proc150:constraints.append('constraints/video_system/processing_cdc.fdc')\n"),
('shutil.copyfile(fpga / name, dest)','shutil.copyfile(origin / name, dest)'),
("shutil.copytree(fpga / 'ip' / name, source / 'ip' / name)","shutil.copytree(origin / 'ip' / name, source / 'ip' / name)"),
("shutil.copytree(fpga / 'config', source / 'config')","shutil.copytree(origin / 'config', source / 'config')"),
("    result = {'stage': options.stage, 'native_exit': process.returncode, 'errors': errors, 'snapshot_intact': intact,\n","    result = {'stage': options.stage, 'native_exit': process.returncode, 'errors': errors, 'snapshot_intact': intact,\n              'rtl_snapshot':str(options.rtl_snapshot) if options.rtl_snapshot else None,\n              'experimental_proc150':options.experimental_proc150,\n")]
for old,new in changes:
    assert text.count(old)==1,old;text=text.replace(old,new)
old="for name in ['video_pll', 'ddr3_controller']:";assert text.count(old)==2
text=text.replace(old,'for name in ips:')
p.write_text(text,encoding='utf-8',newline='\n')
