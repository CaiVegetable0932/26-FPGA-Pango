"""Prepare an isolated token-generation redundancy probe; never modify live RTL."""
from pathlib import Path
import datetime
import hashlib
import json
import shutil


def sha(path):
    """Bind copied source and evidence to their exact bytes."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Copy current D, changing only the candidate's internal redundant payload."""
    fpga = Path(__file__).resolve().parents[1]
    parent = fpga / "build/full_integration_20261013"
    frozen = parent / "delay_20261014_171555/source/rtl/memory"
    prior = parent / "ord_20261014_1705"
    run = parent / ("token_gen_probe_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
    run.mkdir(exist_ok=False)
    assert sha(frozen / "frame_pool_bank.sv") == "37f5830798d3a5ad57987401a862a1221cbb7cbb13278e6d3dca20b714e5131e"
    for variant in ("baseline", "candidate"):
        target = run / variant / "source"
        target.mkdir(parents=True, exist_ok=False)
        for original in (prior / "candidate/source").glob("*.sv"):
            if original.name != "frame_pool_bank_order_reference.sv":
                shutil.copy2(original, target / original.name)
        for name in ("frame_pool_bank.sv", "frame_manager_pkg.sv", "frame_manager_layout.vh", "frame_manager.sv", ):
            shutil.copy2(frozen / name, target / name)
    candidate = run / "candidate/source/frame_pool_bank.sv"
    code = candidate.read_text()
    # Only this internal identity cache is removed. Public generation guards,
    # complete tickets, ownership, counters and saturation remain byte-identical.
    assert code.count("token_gen") == 3
    code = code.replace(" reg [31:0] token_gen[0:TXNS-1];\n", "")
    code = code.replace(" && token_gen[t]==generation[a]", "")
    code = code.replace("    token_gen[token_number]<=cmd[`FM_CMD_ISSUE_GEN];\n", "")
    code = code.replace(" // 64-bit completion ticket reuse also changes ticket within the same slot generation.", """ // A busy token keeps its slot busy until retirement: ISSUE verifies the public
 // generation, and inflight prevents release/reallocation. Thus an internal
 // token-generation copy is redundant for all reachable states. The original
 // public generation checks and 64-bit ticket/ABA fences remain mandatory.
 // Cancel waits for drain; quarantine holds both slot and token controls.
 // A final COMPLETE still counts in this edge's pre-state, delaying reuse.""")
    code = code.replace(" // Transaction identity payload is written atomically with token_busy and is", " // Transaction slot/owner payload is written atomically with token_busy and is")
    code = code.replace(" // them while idle. Stale slot/generation/owner data cannot survive as valid.", " // them while idle. Slot ownership cannot recycle while a token is busy;\n // stale slot/owner payload is masked by token_busy and overwritten on ISSUE.")
    assert "token_gen" not in code
    candidate.write_text(code, encoding="utf-8", newline="\n")
    # The copied cold-reset poison fixture retains checks on all remaining
    # payloads. Its old white-box assignment to the removed field cannot
    # elaborate; remove that assignment only, not any public assertion.
    bench = run / "candidate/source/tb_frame_manager.sv"
    test = bench.read_text()
    assert test.count("   dut.banks[SRC].pool.token_gen[n]='x;\n") == 1
    test = test.replace("   dut.banks[SRC].pool.token_gen[n]='x;\n", "")
    test = test.replace("  for(n=0;n<8;n=n+1) begin\n   dut.banks[SRC].pool.token_slot[n]='x;", "  // Candidate has no generation payload cache; poison both remaining token\n  // payloads, retaining every original reset/public-response assertion.\n  for(n=0;n<8;n=n+1) begin\n   dut.banks[SRC].pool.token_slot[n]='x;")
    bench.write_text(test, encoding="utf-8", newline="\n")
    # The differential reference is current D with a module rename only. It is
    # deliberately not the earlier absolute-order reference from the old probe.
    baseline = run / "baseline/source/frame_pool_bank.sv"
    reference = baseline.read_text().replace("module frame_pool_bank #(", "module frame_pool_bank_token_reference #(", 1)
    (run / "candidate/source/frame_pool_bank_token_reference.sv").write_text(reference, encoding="utf-8", newline="\n")
    shutil.copy2(Path(__file__), run / "prepare_probe.py")
    record = {
        "source_build": str(frozen.parent.parent), "harness_source": str(prior),
        "baseline_bank_sha256": sha(baseline), "candidate_bank_sha256": sha(candidate),
        "live_modified": False, "frozen_builds_modified": False, "pds_started": False,
        "hardware_tested": False, "board_routed": False,
        "sources": {v: {p.name: sha(p) for p in sorted((run / v / "source").iterdir())}
                    for v in ("baseline", "candidate")}}
    (run / "preparation.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"run": str(run), "baseline": record["baseline_bank_sha256"], "candidate": record["candidate_bank_sha256"]}), flush=True)


if __name__ == "__main__":
    main()
