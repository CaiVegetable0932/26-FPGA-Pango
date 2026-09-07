"""Start the local Web control panel; no third-party runtime dependencies."""
import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"src"))
from pango_video.web_server import LocalServer

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Pango local video workbench")
    parser.add_argument("--port",type=int,default=8765)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("invalid HTTP port")
    server = LocalServer(args.port)
    print(f"Pango Web UI: http://127.0.0.1:{server.server_port}",flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.session.stop()
        server.server_close()
