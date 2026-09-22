"""Prepare local IP Compiler inputs from the installed, read-only IP catalog.

Only parameter inputs are assembled here. PDS ip_generate owns HDL generation,
source manifests, constraints and its saved IDF representation.
"""
import argparse
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET
from copy import deepcopy


def configure_pll(values, clock):
    # Purpose: explicit board profiles must obey UG041001 p33 GPLL PFD/bandwidth
    # limits, not just output-frequency arithmetic. The legacy profiles remain
    # unchanged until individually reviewed; only opted-in profiles are emitted.
    if "bandwidth" in clock:
        pfd = float(clock["input_mhz"])  # This generator fixes IDIV to one below.
        bandwidth = clock["bandwidth"]
        allowed = ("HIGH",) if 40 < pfd <= 450 else ("LOW", "OPTIMIZED")
        if not 10 <= pfd <= 450 or bandwidth not in allowed:
            raise ValueError(f"Illegal GPLL PFD/bandwidth: {pfd} MHz / {bandwidth}")
        values["BANDWIDTH"] = values["BANDWIDTH_advancedPage"] = bandwidth
    values.update(MODE_CFG="1", CLKIN_FREQ=str(clock["input_mhz"]),
                  CLKIN_FREQ_advancedPage=str(clock["input_mhz"]),
                  CLKIN_FREQ_basicPage=str(clock["input_mhz"]),
                  INTERNAL_FB="CLKOUTF", FB_advancedPage="7", FB_basicPage="7",
                  STATIC_RATIOI="1", STATIC_RATIOM="1",
                  STATIC_RATIOI_advancedPage="1", STATIC_RATIOM_advancedPage="1",
                  RST_INNER_EN="FALSE", RST_INNER_EN_advancedPage="FALSE")
    # Purpose: board PLLs may expose a real reset input; legacy IPs preserve
    # their existing no-reset configuration unless explicitly requested.
    if clock.get("reset", False):
        for suffix in ("", "_advancedPage", "_basicPage"):
            values[f"RST_INNER_EN{suffix}"] = "TRUE"
    ratios = {int(k): v for k, v in clock["dividers"].items()}
    for i in range(9):
        enabled = "TRUE" if i in clock["outputs"] else "FALSE"
        ratio = ratios.get(i, 24)
        for suffix in ("", "_advancedPage", "_basicPage"):
            values[f"CLKOUT{i}_EN{suffix}"] = enabled
        values[f"STATIC_RATIO{i}"] = str(ratio)
        values[f"STATIC_RATIO{i}_advancedPage"] = str(int(ratio))
        if i in (0, 7):
            values[f"STATIC_FRAC{i}_advancedPage"] = str(round((ratio % 1) * 8))
        values[f"STATIC_DUTY{i}"] = str(max(2, int(ratio)))
        values[f"CLKOUT{i}_REQ_DUTY_advancedPage"] = str(max(2, int(ratio)))
        values[f"CLKOUT{i}_SYN_EN"] = "FALSE"
    return values


def make_pins(spec, values):
    """IDF symbol metadata; generated HDL and templates still belong to PDS."""
    pins = ET.Element("pin_list")
    entries = []
    model = spec["model"].split("/")[-1]
    def port(name, direction, width=1):
        entries.append((name, direction, int(width)))
    if model == "ipm2l_fifo":
        if values["FIFO_TYPE"] == "ASYN_FIFO":
            for n in ("wr_clk", "wr_rst", "rd_clk", "rd_rst"): port(n, "input")
        else:
            for n in ("clk", "rst"): port(n, "input")
        for n in ("wr_en", "rd_en"): port(n, "input")
        port("wr_data", "input", values["WR_DATA_WIDTH"])
        port("rd_data", "output", values["RD_DATA_WIDTH"])
        for n in ("wr_full", "rd_empty", "almost_full", "almost_empty"): port(n, "output")
        for n, p in (("wr_water_level", "WR_DEPTH_WIDTH"), ("rd_water_level", "RD_DEPTH_WIDTH")):
            if values.get("FULL_WL_EN" if n.startswith("wr") else "EMPTY_WL_EN") in ("true", "1"):
                port(n, "output", int(values[p]) + 1)
    elif model == "ipm2l_pll":
        port("clkin1", "input")
        # Match the optional native reset port in the generated symbol metadata.
        if spec["clocks"].get("reset", False): port("rst", "input")
        for i in spec["clocks"]["outputs"]: port(f"clkout{i}", "output")
        port("lock", "output")
    elif model == "ipm2l_sdpram":
        for n in ("wr_clk", "wr_rst", "wr_en", "rd_clk", "rd_rst"): port(n, "input")
        for n, p in (("wr_addr", "WR_ADDR_WIDTH"), ("wr_data", "WR_DATA_WIDTH"), ("rd_addr", "RD_ADDR_WIDTH")):
            port(n, "input", values[p])
        port("rd_data", "output", values["RD_DATA_WIDTH"])
    elif model == "ipm2l_dpram":
        for side in ("a", "b"):
            for n in ("clk", "wr_en", "rst"): port(f"{side}_{n}", "input")
            port(f"{side}_addr", "input", values[f"{side.upper()}_ADDR_WIDTH"])
            port(f"{side}_wr_data", "input", values[f"{side.upper()}_DATA_WIDTH"])
            port(f"{side}_rd_data", "output", values[f"{side.upper()}_DATA_WIDTH"])
    elif model == "ipm2l_rom":
        for n in ("clk", "rst"): port(n, "input")
        port("addr", "input", values["ADDR_WIDTH"])
        port("rd_data", "output", values["DATA_WIDTH"])
    elif model in ("ipm2l_mult", "ipm2l_multadd", "ipm2l_multacc"):
        for n in ("clk", "rst", "ce"): port(n, "input")
        for suffix in (("0", "1") if model == "ipm2l_multadd" else ("",)):
            port(f"a{suffix}", "input", values["ASIZE"])
            port(f"b{suffix}", "input", values["BSIZE"])
        width = int(values["ASIZE"]) + int(values["BSIZE"]) + (1 if model == "ipm2l_multadd" else 0)
        if model == "ipm2l_multacc":
            width = int(values["PSIZE"])
            port("acc_init", "input", width)
            port("reload", "input")
        port("p", "output", width)
    for name, direction, width in entries:
        pin = ET.SubElement(pins, "pin")
        for key, value in dict(name=name, text=name, dir=direction, pos="left" if direction == "input" else "right").items():
            ET.SubElement(pin, key).text = value
        if width > 1:
            ET.SubElement(pin, "msb").text = str(width - 1)
            ET.SubElement(pin, "lsb").text = "0"
    return pins


def prepare(spec, install, root):
    index_path = install / spec["model"] / "index.xml"
    catalog = ET.parse(index_path).getroot()
    instance = spec["name"]
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", instance):
        raise ValueError(f"Invalid IP instance name: {instance}")
    target = root / "ip" / instance
    if not target.resolve().is_relative_to((root / "ip").resolve()):
        raise ValueError("IP output must remain inside fpga/ip")
    target.mkdir(parents=True, exist_ok=True)
    ip = ET.Element("ip_inst")
    header = ET.SubElement(ip, "header")
    for name in ("vendor", "id", "display_name", "name", "version"):
        ET.SubElement(header, name).text = catalog.findtext(f"header/{name}")
    for name, value in dict(instance=instance, family="Logos2", device="PG2L100H",
                            package="FBG676", speedgrade="-6").items():
        ET.SubElement(header, name).text = value
    ET.SubElement(header, "generator", version="2022.2-SP6.4", build="146967").text = "IP Compiler"
    values = {p.findtext("name"): p.findtext("default", "")
              for p in catalog.findall("param_list/param")}
    if spec.get("seed"):
        seed = ET.parse(root.parent / spec["seed"])
        values.update({p.findtext("name"): p.findtext("value", "")
                       for p in seed.findall("param_list/param")})
        # The headless catalog has no dynamic CA-pad enum items. These GUI-only
        # fields are not the board pin authority. A separate, checked FDC is
        # loaded by the main project; native timing, placement and RCF remain.
        for param in catalog.findall("param_list/param"):
            if param.findtext("name", "").startswith("PAD_"):
                values[param.findtext("name")] = param.findtext("default", "")
    unknown = set(spec.get("params", {})) - set(values)
    if unknown:
        raise ValueError(f"{instance}: unknown parameters {unknown}")
    values.update({k: str(v) for k, v in spec.get("params", {}).items()})
    if spec.get("clocks"):
        configure_pll(values, spec["clocks"])
    params = ET.SubElement(ip, "param_list")
    for name, value in values.items():
        item = ET.SubElement(params, "param")
        ET.SubElement(item, "name").text = name
        ET.SubElement(item, "value").text = value
    pins = make_pins(spec, values)
    if spec.get("seed"):
        pins = deepcopy(seed.find("pin_list"))
        if pins.find("pin[name='ref_clk']") is None:
            item = ET.SubElement(pins, "pin")
            for k, v in dict(name="ref_clk", text="ref_clk", dir="input", pos="left").items():
                ET.SubElement(item, k).text = v
    ip.append(pins)
    synth = ET.SubElement(ip, "synthesis")
    ET.SubElement(synth, "script").text = "set_option -vlog_std v2001"
    ET.SubElement(synth, "script").text = "set_option -disable_io_insertion 1"
    files = ET.SubElement(ip, "file_list")
    ET.SubElement(files, "output")
    ET.SubElement(files, "source")
    ET.indent(ip, space="    ")
    ET.ElementTree(ip).write(target / f"{instance}.idf", encoding="UTF-8", xml_declaration=True)
    return target / f"{instance}.idf"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--pds", default="E:/PDS_Pangu/PDS_2022.2-SP6.4")
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    (root / "config/gamma_identity.hex").write_text(
        "\n".join(f"{i % 256:02x}" for i in range(512)) + "\n", encoding="ascii")
    config = json.loads((root / "config/ip_catalog.json").read_text(encoding="utf-8"))
    for spec in config["ips"]:
        if not args.only or spec["name"] in args.only:
            print(prepare(spec, Path(args.pds), root))
