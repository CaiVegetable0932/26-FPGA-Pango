"""Audit source closure and native results, without simulating or programming."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--stage", choices=("compile", "all"), default="all")
parser.add_argument("--started")
args = parser.parse_args()
build = root / "build/pango_video_top"
catalog = json.loads((root / "config/ip_catalog.json").read_text(encoding="utf-8"))
board = json.loads((root / "config/board.json").read_text(encoding="utf-8"))
issues, ips, inputs = [], [], set()
rtl_paths = sorted((root / "rtl").rglob("*.v"))
rtl = "\n".join(p.read_text(encoding="utf-8") for p in rtl_paths)
inputs.update(rtl_paths)
for spec in catalog["ips"]:
    # A source-backed vendor PLL replaces the legacy generated single-output
    # IP. Audit its active top-level instantiation and include its source hash.
    if "rtl_replacement" in spec:
        replacement = spec["rtl_replacement"]
        source = root / replacement["source"]
        top = (root / "rtl/board/pango_video_top.v").read_text(encoding="utf-8")
        instances = re.findall(r"\b" + re.escape(replacement["module"]) + r"\s+(\w+)\s*\(", top)
        if not source.is_file() or not instances:
            issues.append("Active HDMI PLL source or instance missing")
        else:
            inputs.add(source)
        ips.append(dict(name=replacement["module"], instances=instances,
                        source_count=1, origin="board-vendor RTL", purpose=spec["purpose"]))
        continue
    path = root / "ip" / spec["name"] / (spec["name"] + ".idf")
    if not path.is_file():
        issues.append(f"Missing IDF: {path}")
        continue
    doc = ET.parse(path)
    inputs.add(path)
    for key, value in dict(family="Logos2", device="PG2L100H", package="FBG676", speedgrade="-6").items():
        if doc.findtext("header/" + key) != value:
            issues.append(f"{spec['name']}: target mismatch: {key}")
    sources = []
    for item in doc.findall("file_list/source/file"):
        source = (path.parent / item.attrib["pathname"]).resolve()
        if not source.is_relative_to(root) or not source.is_file():
            issues.append(f"Missing or external dependency: {source}")
        else:
            sources.append(source.relative_to(root).as_posix())
            inputs.add(source)
    if not sources: issues.append(f"{spec['name']}: empty source manifest")
    instances = re.findall(r"\b" + re.escape(spec["name"]) + r"\s+(\w+)\s*\(", rtl)
    if not instances: issues.append(f"{spec['name']}: not instantiated")
    generation_path = path.parent / "generate.log"
    generation_log = generation_path.read_text(encoding="utf-8-sig", errors="replace") if generation_path.is_file() else ""
    generated = "Done: 0 error(s), 0 warning(s)" in generation_log
    if not generated: issues.append(f"{spec['name']}: native generation not clean")
    ips.append(dict(name=spec["name"], instances=instances, source_count=len(sources),
                    native_generation_clean=generated, purpose=spec["purpose"]))

pattern = re.compile(r"define_attribute\s+\{p:([^}]+)\}\s+\{PAP_IO_LOC\}\s+\{([^}]+)\}")
pins = {}
for name in ("ddr_board_pins.fdc", "board_pins.fdc"):
    for port, pin in pattern.findall((root / "constraints" / name).read_text(encoding="utf-8")):
        if port in pins: issues.append(f"Duplicate port constraint: {port}")
        pins[port] = pin
expected = {}
for section in ("ddr_pins", "pins"):
    for name, value in board[section].items():
        if isinstance(value, list): expected.update({f"{name}[{i}]": pin for i,pin in enumerate(value)})
        else: expected[name] = value
if pins != expected: issues.append("Active pin constraints differ from board.json")
if len(pins.values()) != len(set(pins.values())): issues.append("Physical pin collision")
if pattern.search((root / "constraints/ddr_native.fdc").read_text(encoding="utf-8")):
    issues.append("Unexpected native default DDR pin constraints")

project = root / "project/pango_video_top/pango_video_top.pds"
project_text = project.read_text(encoding="utf-8")
if '(_option prj_impl_dir (_string "../../build/pango_video_top"))' not in project_text:
    issues.append("Project implementation directory is not the agreed fpga/build location")
project_sources = re.findall(r'\(_(?:file|ip|ip_source_item)\s+"([^"]+)"', project_text)
for value in project_sources:
    resolved = (project.parent / value.replace("\\", "/")).resolve()
    if not resolved.is_relative_to(root) or not resolved.is_file():
        issues.append(f"Invalid project file dependency: {value}")

inputs.update((root / "config").rglob("*.json"))
inputs.update((root / "config").rglob("*.hex"))
inputs.update((root / "config/ip_seeds").glob("*.idf"))
inputs.update((root / "constraints").glob("*.fdc"))
inputs.update((root / "constraints").glob("*.rcf"))
inputs.add(root / "ip/ddr3_controller/pnr/ddr3_controller.rcf")
if '../../constraints/routing.rcf' not in project_text:
    issues.append("Combined native DDR / HDMI routing constraints are not loaded")
routing_path = root / "constraints/routing.rcf"
routing_text = routing_path.read_text(encoding="utf-8") if routing_path.is_file() else ""
route_commands = []
for route_source in (root / "ip/ddr3_controller/pnr/ddr3_controller.rcf", root / "constraints/hdmi_reset.rcf"):
    for line in route_source.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("def_route "):
            route_commands.append(line.strip())
            if line.strip() not in routing_text:
                issues.append(f"Missing priority routing command: {line.strip()}")
inputs.add(root / "project/pango_video_top/pango_video_top.tcl")
inputs.update(p for p in (root / "scripts").iterdir() if p.suffix in (".py", ".ps1", ".tcl"))
manifest = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(inputs)}

stage_files = dict(compile="compile/cmr.db", synthesize="synthesize/snr.db", dev_map="device_map/dmr.db",
                   pnr="place_route/prr.db", report_timing="report_timing/rtr.db",
                   gen_netlist="generate_netlist/pango_video_top_sim.v",
                   gen_bit_stream="generate_bitstream/pango_video_top.sbit", report_power="report_power/pango_video_top.ppr")
if args.stage == "compile": stage_files = {"compile": stage_files["compile"]}
since = datetime.fromisoformat(args.started).timestamp() if args.started else 0
stages = {}
for name, value in stage_files.items():
    path = build / value
    passed = path.is_file() and path.stat().st_size > 0 and path.stat().st_mtime >= since
    stage_log = path.parent / "run.log"
    stage_text = stage_log.read_text(encoding="utf-8", errors="replace") if stage_log.is_file() else ""
    stage_errors = re.findall(r"(?m)^E:.*|^.*IPSpecCheck:.*(?:error|must).*$", stage_text)
    if stage_errors: issues.extend(f"{name}: {e}" for e in stage_errors)
    stages[name] = dict(artifact=value, fresh_and_present=passed,
                        native_error_count=len(stage_errors), native_warning_count=len(re.findall(r"(?m)^W:", stage_text)))
    if not passed: issues.append(f"Missing/stale {name} artifact: {value}")
console = (build / f"{args.stage}_console.log").read_text(encoding="utf-8-sig", errors="replace")
errors = re.findall(r"(?m)^E:.*|^.*IPSpecCheck:.*(?:error|must).*$", console)
issues.extend(errors)
native_read = f"Analyzing project file '{project.as_posix()}'." in console
if not native_read: issues.append("No evidence of native .pds reader invocation")
if args.stage == "all":
    pnr_text = (build / "place_route/run.log").read_text(encoding="utf-8", errors="replace")
    for command in route_commands:
        net = command.removeprefix("def_route -prior_net ").strip("{}")
        if not any(net in line and "def_route -prior_net" in line and "successfully" in line
                   for line in pnr_text.splitlines()):
            issues.append(f"Priority route was not executed successfully: {net}")
timing_path = build / "report_timing/pango_video_top.rtr"
timing_text = timing_path.read_text(encoding="utf-8", errors="replace") if timing_path.is_file() else ""
timing_summary = re.search(r"Design Summary\s*:\s*([^\r\n]+)", timing_text)
timing_summary = timing_summary.group(1).strip() if timing_summary else "unavailable"
internal_timing_passed = bool(re.fullmatch(r"All Constraints (?:Met|Satisfied)\.?", timing_summary, re.IGNORECASE))
if args.stage == "all" and not internal_timing_passed:
    issues.append(f"Internal static timing is not closed: {timing_summary}")
clocks, timing_worst = {}, {}
if args.stage == "all":
    clock_row = re.compile(r"^\s*(\S+)\s+([\d.]+)\s+\{([\d.]+)\s+([\d.]+)\}\s+(.+?)\s+(\d+)\s+(\d+)\s+\{(.+)\}\s*$", re.M)
    for name, period, rise, fall, kind, clock_loads, other_loads, source in clock_row.findall(timing_text):
        clocks[name] = dict(period_ns=float(period), waveform_ns=[float(rise), float(fall)],
                            kind=kind.strip(), clock_loads=int(clock_loads), source=source.strip())
    expected_periods = dict(ref_clk=8.0, clk_27m=1000/27, sys_clk=10.0, proc_clk=1000/150,
                            tx_clk=8.0, rx_clk=8.0, serial_clk=1000/371.25,
                            pixel_clk=1000/74.25, ddrphy_sysclk=8.0)
    for name, expected_period in expected_periods.items():
        if name not in clocks or abs(clocks[name]["period_ns"] - expected_period) > 0.001:
            issues.append(f"Missing or incorrect native clock period: {name}")
    pixel = clocks.get("pixel_clk", {})
    # The proven PLL supplies one source; main retains its native I/O divider
    # so serial and parallel IOL clock networks have an explicit shared phase.
    if (pixel.get("kind") != "Generated (serial_clk)" or
        not pixel.get("source", "").startswith("u_hdmi_pixel_div/") or
        not pixel.get("clock_loads", 0)):
        issues.append("Pixel clock is not the loaded native divider child of serial_clk")
    serial = clocks.get("serial_clk", {})
    if (serial.get("kind") != "Generated (clk_27m)" or
        not serial.get("source", "").startswith("u_video_pll/") or
        not serial.get("source", "").endswith("/CLKOUT1")):
        issues.append("Serial clock is not the coherent HDMI PLL CLKOUT1")
    if pixel:
        duty = (pixel["waveform_ns"][1] - pixel["waveform_ns"][0]) / pixel["period_ns"]
        if abs(duty - 0.4) > 0.0001:
            issues.append("Native /5 pixel clock duty cycle is not 40 percent")
    row = re.compile(r"^\s*(\S+)\s+(\S+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s*$", re.M)
    sections = re.finditer(r"^(Setup|Hold|Recovery|Removal) Summary\((Slow|Fast) Corner\):\s*(.*?)^=+", timing_text, re.M | re.S)
    for section in sections:
        values = row.findall(section[3])
        if not values: continue
        key = section[1].lower() + "_" + section[2].lower()
        timing_worst[key] = dict(worst_slack_ns=min(float(v[2]) for v in values),
                                 failing_endpoints=sum(int(v[4]) for v in values))
        if timing_worst[key]["worst_slack_ns"] < 0 or timing_worst[key]["failing_endpoints"]:
            issues.append(f"Timing summary contains failures: {key}")
    if len(timing_worst) != 8:
        issues.append("Incomplete slow/fast setup/hold/recovery/removal summaries")
if args.stage == "all":
    bitstream = build / stage_files["gen_bit_stream"]
    bitstream_hash = hashlib.sha256(bitstream.read_bytes()).hexdigest() if bitstream.is_file() else None
else:
    bitstream_hash = None
summary = dict(checked_at=datetime.now().astimezone().isoformat(),
               branch=subprocess.check_output(["git", "branch", "--show-current"], cwd=root, text=True).strip(),
               target=catalog["target"], pds=catalog["pds"], native_pds_read=native_read,
               ip_count=len(ips), ips=ips, constrained_ports=len(pins), stages=stages,
               internal_timing_passed=internal_timing_passed if args.stage == "all" else None,
               timing_summary=timing_summary if args.stage == "all" else None,
               clocks=clocks if args.stage == "all" else None,
               timing_worst=timing_worst if args.stage == "all" else None,
               bitstream_sha256=bitstream_hash,
               flow_passed=not issues, issues=issues,
               hardware_tested=False, programmed=False, external_io_timing_signed_off=False,
               bitstream_approved_for_programming=False)
(build / "input_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
(build / f"{args.stage}_audit.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps({k:v for k,v in summary.items() if k != "ips"}, indent=2, ensure_ascii=False))
raise SystemExit(0 if not issues else 1)
