"""Reproduce byte-protocol review against the frozen MCU commit and current RTL.

Hardware hooks and time inputs are synthetic. All generated data and logs stay
under mcu/build; no firmware, FPGA implementation, or downloaded snapshot changes.
"""
from pathlib import Path
import binascii
import hashlib
import json
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[2]
RUN = ROOT / "mcu/build/protocol-review-22452f3"
UP = RUN / "upstream/mcu"
RTL = [ROOT / ("fpga/rtl/control/" + n + ".sv") for n in
       ("mcu_readonly_client", "uart_v2_parser", "pose_frame_selector")]
TB = ROOT / "fpga/sim/tb_mcu_22452f3_review.sv"
ICARUS = ROOT / "fpga/build/ov5640_pwm_20261012/tools/iverilog/app/bin"


def execute(name, args):
    """Provide valid stdin for Windows Icarus and preserve every process log."""
    result = subprocess.run([str(a) for a in args], cwd=RUN, input=b"",
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (RUN / (name + ".log")).write_bytes(result.stdout)
    if result.returncode:
        raise RuntimeError(f"{name} exit={result.returncode}: {result.stdout.decode(errors='replace')}")
    print(name, "PASS", flush=True)


def frame(command, seq, payload):
    """Independent expected request codec, including little-endian CRC trailer."""
    body = struct.pack("<BBHH", 2, command, seq, len(payload)) + payload
    return b"\x55\xaa" + body + struct.pack("<H", binascii.crc_hqx(body, 0xffff))


def main():
    # Verify every extracted file against the requested Git tree, independently
    # of the review harness. This proves provenance without replacing live MCU.
    commit = "22452f36dae80ebac5b5386a60a2e92481862b0e"
    listing = subprocess.check_output(["git", "ls-tree", "-rz", commit, "mcu"], cwd=ROOT)
    blobs = {}
    for record in listing.split(b"\0"):
        if record:
            metadata, path = record.split(b"\t", 1)
            blobs[path.decode("utf-8")] = metadata.split()[2].decode()
    verified = 0
    normalized = []
    for path in UP.rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            blob = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
            expected_blob = blobs[path.relative_to(UP.parent).as_posix()]
            if blob != expected_blob:
                # Git archive follows the repository's Windows text attributes.
                # Accept only a proven CRLF-to-LF transformation, never other edits.
                canonical = data.replace(b"\r\n", b"\n")
                normalized_blob = hashlib.sha1(b"blob " + str(len(canonical)).encode() + b"\0" + canonical).hexdigest()
                assert normalized_blob == expected_blob, path
                normalized.append(path.relative_to(UP.parent).as_posix())
            verified += 1
    (RUN / "upstream_verification.json").write_text(json.dumps(dict(
        commit=commit, verified_files=verified, crlf_normalized_files=normalized), indent=2), encoding="utf-8")
    sources = list((UP / "firmware/common").glob("*.[ch]")) + [
        UP / "firmware/longmenjia/Core/Src/f4_link.c", UP / "config/pose_config.h",
        *RTL, TB, *list((RUN / "harness").glob("*")), Path(__file__)]
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    (RUN / "sources.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
    execute("peer_compile", [shutil.which("gcc"), "-std=c11", "-O0", "-Wall", "-Wextra",
            "-I" + str(RUN / "harness"), "-I" + str(UP / "firmware/common"),
            "-I" + str(UP / "firmware/longmenjia/Core/Inc"), RUN / "harness/peer.c",
            UP / "firmware/common/wire.c", "-o", RUN / "peer.exe"])
    execute("peer", [RUN / "peer.exe"])
    execute("rtl_compile", [ICARUS / "iverilog.exe", "-g2012", "-s", "tb_mcu_22452f3_review",
            "-o", RUN / "review.vvp", TB, *RTL])
    execute("rtl", [ICARUS / "vvp.exe", RUN / "review.vvp"])
    context = struct.pack("<QI", 11, 100)
    expected = [frame(0x40, 1, b""), frame(0x41, 2, struct.pack("<IQI", 100, 11, 0)),
                frame(0x42, 3, context), frame(0x43, 4, context + struct.pack("<HH", 200, 0)),
                frame(0x45, 5, context + struct.pack("<IQ", 1, 1000000))]
    observed = [bytes.fromhex(s) for s in (RUN / "rtl_requests.hex").read_text().splitlines()]
    assert observed == expected + [frame(0x49, 6, context + struct.pack("<I", 1))] + expected
    assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    result = dict(mcu_commit="22452f36dae80ebac5b5386a60a2e92481862b0e",
                  upstream_files_verified=verified,
                  wire_handshake_state_event=True, outbound_exact_frames=11,
                  source_hashes_intact=True, reconnect_event_deadlock_reproduced=True,
                  unapproved_pose_rejected=True, synthetic_approved_fresh_pose_accepted=True,
                  mcu_valid_100ms_pose_rejected_by_fpga=True, hardware_tested=False)
    (RUN / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
