"""Generate internal packed field offsets from the single authoritative SV types.

ADS 2022.2 can parse packed structs but can spend excessive time inferring wide
descriptor updates. The core uses equivalent vectors; these generated offsets
preserve the typed integration/TB contract without maintaining a second schema.
"""
from pathlib import Path
import re


def generate() -> None:
    """Accept only the explicit field grammar used by frame_manager_pkg.sv."""
    root = Path(__file__).resolve().parents[1]
    source = root / "rtl/memory/frame_manager_pkg.sv"
    records: dict[str, list[tuple[str, int]]] = {}
    widths: dict[str, int] = {}
    for body, name in re.findall(r"typedef struct packed \{(.*?)\}\s*(\w+);", source.read_text(encoding="utf-8"), re.S):
        fields = []
        for raw in body.splitlines():
            line = raw.split("//")[0].strip()
            if not line:
                continue
            match = re.fullmatch(r"logic\s*(?:\[([^:]+):([^\]]+)\])?\s*([^;]+);", line)
            if match:
                if match[1]:
                    # Only integer widths or the declared descriptor-width
                    # expression are allowed; never execute arbitrary source.
                    expr = match[1].replace("META_BITS", str(widths["frame_meta_t"])) if "META_BITS" in match[1] else match[1]
                    if not re.fullmatch(r"\d+(?:\*\d+)?-\d+|\d+", expr):
                        raise ValueError(f"Unsupported field width: {line}")
                    factors, minus, tail = expr.partition("-")
                    high = 1
                    for value in factors.split("*"):
                        high *= int(value)
                    high -= int(tail) if minus else 0
                    width = high - int(match[2]) + 1
                else:
                    width = 1
                fields.extend((field.strip(), width) for field in match[3].split(","))
            elif line == "frame_meta_t meta;":
                fields.append(("meta", widths["frame_meta_t"]))
            else:
                raise ValueError(f"Unsupported field declaration: {line}")
        records[name] = fields
        widths[name] = sum(width for _, width in fields)
    if set(records) != {"frame_meta_t", "frame_cmd_t", "frame_rsp_t"}:
        raise ValueError("Missing or extra interface record")
    lines = ["// Purpose: generated internal packed offsets; regenerate with", "// fpga/scripts/generate_frame_manager_layout.py. Source: frame_manager_pkg.sv.", "// These offsets are not a UART/UDP encoding.", "`ifndef FRAME_MANAGER_LAYOUT_VH", "`define FRAME_MANAGER_LAYOUT_VH"]
    for name, prefix in [("frame_meta_t", "META"), ("frame_cmd_t", "CMD"), ("frame_rsp_t", "RSP")]:
        lines.append(f"`define FM_{prefix}_BITS {widths[name]}")
        offset = widths[name]
        for field, width in records[name]:
            offset -= width
            lines.append(f"`define FM_{prefix}_{field.upper()} {offset} +: {width}")
    lines.append("`endif")
    target = root / "rtl/memory/frame_manager_layout.vh"
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"FRAME_LAYOUT_GENERATED {widths}")


if __name__ == "__main__":
    generate()
