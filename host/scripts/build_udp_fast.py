"""Build the optional local Linux RAW batch parser without installing system files."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess

HOST = Path(__file__).resolve().parents[1]


def main():
    """Bind the built module to its source/binary hashes and native architecture."""
    if platform.system() != "Linux":
        raise SystemExit("Linux only; other platforms retain the Python receiver")
    source = HOST / "src/pango_video/raw_batch.c"
    folder = HOST / "build/udp-fast"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / "libpango_raw_batch.so"
    temporary = folder / "libpango_raw_batch.next.so"
    command = ["cc", "-std=c11", "-O3", "-Wall", "-Wextra", "-Werror", "-fPIC", "-shared",
               str(source), "-lz", "-o", str(temporary)]
    subprocess.run(command, check=True, timeout=60)
    temporary.replace(target)
    manifest = dict(machine=platform.machine(), source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                    binary_sha256=hashlib.sha256(target.read_bytes()).hexdigest(), command=command,
                    compiler=subprocess.check_output(["cc", "--version"], text=True).splitlines()[0],
                    abi=1)
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
