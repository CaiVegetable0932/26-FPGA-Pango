"""Synthetic calibration chart transported through the real PRAW UDP encoder."""
import argparse
import json
import socket
import time
from pathlib import Path

from .cli import load_config
from .protocol import packetize


def calibration_raw(width, height, bayer_code):
    """Color bars, grayscale ramp and checkerboard; never a camera image."""
    layouts = {1:(0,1,1,2), 2:(1,0,2,1), 3:(1,2,0,1), 4:(2,1,1,0)}
    layout = layouts[bayer_code]
    colors = [(220,220,220),(226,205,40),(42,194,193),(47,190,79),
              (205,55,174),(222,57,64),(51,83,205),(28,31,35)]
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(0, width, 2):
            if y < height//5:
                rgb = colors[min(7, x*8//width)]
            elif x < width*2//3:
                gray = 200 if ((x//64)+(y//64))%2 else 38
                rgb = (gray,gray,gray)
            else:
                level = 25 + (y-height//5)*205//max(1, height-height//5)
                rgb = (level,level,level)
            row.extend((rgb[layout[(y%2)*2]], rgb[layout[(y%2)*2+1]]))
        rows.append(bytes(row[:width]))
    return b"".join(rows)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=18000)
    parser.add_argument("--fps", type=float, default=30)
    args = parser.parse_args(argv)
    config = load_config(args.config)
    import ipaddress
    if config["source_mode"] != "mock" or not all(ipaddress.IPv4Address(config[k]).is_loopback for k in ("bind_ip","peer_ip")):
        raise ValueError("demo sender requires loopback mock configuration")
    if not 1 <= args.frames <= 108000 or not 1 <= args.fps <= 30:
        raise ValueError("invalid demo duration or rate")
    width, height = config["width"], config["height"]
    template = calibration_raw(width, height, config["bayer_code"])
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
        sender.bind((config["peer_ip"], config["peer_port"]))
        started = time.monotonic()
        for frame_id in range(args.frames):
            pixels = bytearray(template)
            marker = (frame_id*8) % max(1, width-4)
            for y in range(height//5, height):
                pixels[y*width+marker:y*width+marker+min(4,width-marker)] = bytes([240])*min(4,width-marker)
            encoded = list(packetize(pixels, stream_epoch=config["stream_epoch"], frame_id=frame_id,
                width=width, height=height, bayer_code=config["bayer_code"], descriptor_id=1))
            for index, data in enumerate(encoded):
                remaining = started + (frame_id+index/len(encoded))/args.fps-time.monotonic()
                if remaining > 0:
                    time.sleep(remaining)
                sender.sendto(data, (config["bind_ip"], config["port"]))
        print(json.dumps(dict(source_mode="mock", frames=args.frames, elapsed=time.monotonic()-started)), flush=True)
