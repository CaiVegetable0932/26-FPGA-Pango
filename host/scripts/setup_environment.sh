#!/bin/sh
# Prepare the reviewed Ubuntu 22.04 ARM64 host runtime without replacing
# NVIDIA's system Python or using an elevated package installer.
set -eu
pango_script_dir=$(cd -P -- "$(dirname -- "$0")" >/dev/null && pwd)
pango_host=$(cd -P -- "$pango_script_dir/.." >/dev/null && pwd)
pango_environment="$pango_host/build/environment"
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != aarch64 ]; then
    printf '%s\n' 'This environment profile is for Ubuntu 22.04 Linux ARM64.' >&2
    exit 2
fi
for pango_tool in curl tar sha256sum apt-get dpkg-deb; do
    command -v "$pango_tool" >/dev/null 2>&1 || { printf '%s\n' "Missing prerequisite: $pango_tool" >&2; exit 2; }
done
mkdir -p "$pango_environment/tools" "$pango_environment/downloads" "$pango_environment/bin" "$pango_environment/node" "$pango_environment/system"

# Pin the installer binary and verify its official archive hash before running.
pango_uv="$pango_environment/tools/uv"
if [ ! -x "$pango_uv" ]; then
    pango_uv_archive="$pango_environment/downloads/uv-0.12.22-aarch64.tar.gz"
    curl -fL --retry 2 --connect-timeout 15 --max-time 180 https://github.com/astral-sh/uv/releases/download/0.12.22/uv-aarch64-unknown-linux-gnu.tar.gz -o "$pango_uv_archive"
    printf '%s  %s\n' 6f66a14e8239871fb477f9746c941fedfa77e8fe28a8bc7c07e1dc7f53a66712 "$pango_uv_archive" | sha256sum -c -
    tar -xzf "$pango_uv_archive" --strip-components=1 -C "$pango_environment/tools"
fi
if [ ! -x "$pango_environment/python/cpython-3.12.13-linux-aarch64-gnu/bin/python3.12" ]; then
    "$pango_uv" --no-cache python install 3.12.13 --install-dir "$pango_environment/python" --no-bin
fi
if [ ! -x "$pango_environment/venv/bin/python" ]; then
    "$pango_uv" --no-cache venv --seed --python "$pango_environment/python/cpython-3.12.13-linux-aarch64-gnu/bin/python3.12" "$pango_environment/venv"
fi
# uv's generated ignore files conflict with the repository's two-directory
# ignore policy. Remove only those installer-created files with known content.
"$pango_environment/venv/bin/python" -I -B -c '
from pathlib import Path
import sys
for folder in ("python", "venv"):
    path = Path(sys.argv[1]) / folder / ".gitignore"
    if path.is_file() and path.read_text().strip() in ("*", "**"):
        path.unlink()
' "$pango_environment"
"$pango_uv" --no-cache pip install --python "$pango_environment/venv/bin/python" -r "$pango_host/config/environment-linux-arm64.lock.txt"

# Node is solely a frontend test tool. Its archive hash is from nodejs.org's
# SHASUMS256.txt for v22.23.3, not an unverified third-party package mirror.
if [ ! -x "$pango_environment/node/bin/node" ]; then
    pango_node_archive="$pango_environment/downloads/node-v22.23.3-linux-arm64.tar.xz"
    curl -fL --retry 2 --connect-timeout 15 --max-time 180 https://nodejs.org/dist/v22.23.3/node-v22.23.3-linux-arm64.tar.xz -o "$pango_node_archive"
    printf '%s  %s\n' a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f "$pango_node_archive" | sha256sum -c -
    tar -xJf "$pango_node_archive" --strip-components=1 -C "$pango_environment/node"
fi
if [ ! -f "$pango_environment/downloads/node-SHASUMS256.txt" ]; then
    curl -fL --retry 2 --connect-timeout 15 --max-time 90 https://nodejs.org/dist/v22.23.3/SHASUMS256.txt -o "$pango_environment/downloads/node-SHASUMS256.txt"
fi

# Match the existing Ubuntu multimedia libraries. Extract official packages
# locally instead of replacing Jetson's FFmpeg package selection and CUDA stack.
if [ ! -x "$pango_environment/system/usr/bin/ffmpeg" ] || [ ! -x "$pango_environment/system/usr/bin/v4l2-ctl" ]; then
    (cd "$pango_environment/downloads" && apt-get download ffmpeg=7:4.4.2-0ubuntu0.22.04.1 libavdevice58=7:4.4.2-0ubuntu0.22.04.1 libpostproc55=7:4.4.2-0ubuntu0.22.04.1 v4l-utils=1.22.1-2build1 libv4l2rds0=1.22.1-2build1)
    for pango_package in "$pango_environment"/downloads/*.deb; do
        dpkg-deb -x "$pango_package" "$pango_environment/system"
    done
fi
for pango_capture_tool in ffmpeg ffprobe v4l2-ctl; do
    ln -sfn ../../../scripts/run_capture_tool.sh "$pango_environment/bin/$pango_capture_tool"
done
ln -sfn ../node/bin/node "$pango_environment/bin/node"
export PLAYWRIGHT_BROWSERS_PATH="$pango_environment/browsers"
"$pango_environment/venv/bin/python" -B -m playwright install chromium
printf '%s\n' 'Host software installed. Start with: sh host/scripts/start_web.sh'
printf '%s\n' 'For hardware prerequisites, run configure_linux_system.sh through local administrator authentication.'
