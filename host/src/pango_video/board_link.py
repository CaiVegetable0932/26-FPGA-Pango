"""Cross-platform RAW8 commissioning; one owner for UART and UDP startup.

CP2102 boot/CAPS/OPEN/STATUS and capability-checked geometry/view controls share
one UART owner. Boot endpoints are immutable until board reset, so warm resume
requires the exact saved epoch and endpoints. No OS or board firmware change.
"""
from copy import deepcopy
from contextlib import contextmanager
import ipaddress
import json
from pathlib import Path
import secrets
import struct
import subprocess
import sys
import threading
import time

from .raw8_boot import crc16, metadata
from .web_session import SessionError
from .geometry_control import GeometryClient, GeometryProfile
from .board_view import BoardViewClient

# The documented direct-link baseline. A reset discovers its real NIC/MAC
# and the saved CP2102 identity; it never writes OS addresses or USB settings.
ETHERNET_DEFAULTS = dict(source_ip="192.168.80.3", source_mac="02:00:00:00:00:01",
                         peer_port=50000, source_port=50001)
DEFAULT_PEER_IP = "192.168.80.2"


def interfaces():
    """Read actual local IPv4/MAC pairs; never substitute a guessed peer MAC."""
    if sys.platform == "win32":
        script = ('[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); '
                  '@(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { '
                  '$a=Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue; '
                  'if($a.Status -eq "Up") { [pscustomobject]@{name=$a.Name; '
                  'ip=$_.IPAddress; prefix=$_.PrefixLength; mac=$a.MacAddress} } }) | ConvertTo-Json -Compress')
        result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                                capture_output=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            raise SessionError("无法枚举网卡，请检查 Windows 网络服务")
        rows = json.loads(result.stdout.decode("utf-8-sig") or "[]")
        if isinstance(rows, dict):
            rows = [rows]
    else:
        # Query all address families so iproute2 retains link-layer MAC fields;
        # its IPv4-only output omits them on Jetson. Filter IPv4 rows below.
        result = subprocess.run(["ip", "-j", "address", "show", "up"],
                                capture_output=True, text=True, timeout=10, check=True)
        rows = [dict(name=item["ifname"], ip=a["local"], prefix=a["prefixlen"], mac=item.get("address", ""))
                for item in json.loads(result.stdout) for a in item.get("addr_info", []) if a["family"] == "inet"]
    return [dict(row, mac=row["mac"].replace("-", ":").lower()) for row in rows
            if row.get("mac") and not ipaddress.ip_address(row["ip"]).is_loopback]


def serial_ports():
    """Enumerate only CP2102 bridges; ambiguity must be resolved in the UI."""
    try:
        from serial.tools import list_ports
    except ImportError as error:
        raise SessionError("缺少 pyserial：用启动 host 的 Python 安装 host/requirements-device.txt") from error
    return [dict(port=p.device, serial=p.serial_number or "", label=p.description)
            for p in list_ports.comports() if (p.vid, p.pid) == (0x10c4, 0xea60)]


class Uart:
    """Bounded CRC/sequence-checked transactions with DTR and RTS disabled."""
    def __init__(self, port):
        import serial
        self.link = serial.Serial(port=None, baudrate=115200, timeout=.1, write_timeout=1)
        self.link.dtr = self.link.rts = False
        self.link.port = port
        self.link.open()
        self.sequence = 0
        self.records = []

    def close(self):
        self.link.close()

    def exchange(self, command, payload=b""):
        """Resynchronize on 55AA and ignore corrupt/stale replies until timeout."""
        self.sequence = self.sequence % 65535 + 1
        body = struct.pack("<BBHH", 1, command, self.sequence, len(payload)) + payload
        wire = b"\x55\xaa" + body + struct.pack("<H", crc16(body))
        self.link.reset_input_buffer()
        self.link.write(wire)
        pending = bytearray()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            pending.extend(self.link.read(42))
            while len(pending) >= 42:
                candidate = bytes(pending[:42])
                if (candidate[:3] == b"\x55\xaa\x01" and candidate[3] in (0x80, 0x81)
                        and struct.unpack_from("<HH", candidate, 4) == (self.sequence, 32)
                        and candidate[9] == command
                        and crc16(candidate[2:40]) == int.from_bytes(candidate[40:], "little")):
                    self.records.append(dict(request=wire.hex(), reply=candidate.hex()))
                    return candidate[8:40]
                del pending[0]
        self.records.append(dict(request=wire.hex(), error="reply_timeout"))
        raise SessionError("UART 2 秒内无有效回复：检查所选 CP2102、板卡供电及固件；未发送新配置")


def atomic_json(path, data):
    """Persist recoverable commissioning intent before sending its boot bytes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


class BoardLink:
    """Asynchronous startup coordinator; ready means a fresh complete UDP frame."""
    def __init__(self, session, *, inventory=interfaces, ports=serial_ports, uart=Uart):
        self.session = session
        self.root = session.root
        self.inventory, self.ports, self.uart = inventory, ports, uart
        self.path = self.root / "config" / "board-link.json"
        self.boot_path = self.root / "config" / "board-link-boot.json"
        self.lock = threading.RLock()
        # Startup, parameter uploads and metadata reads share one UART owner.
        # Keep this separate from the short-lived UI state lock.
        self.uart_lock = threading.Lock()
        self.cancel = threading.Event()
        self.thread = None
        self.state = dict(phase="idle", message="首次使用请选择板卡网卡和 CP2102，然后启动链路", busy=False)
        # A damaged preference must leave the workbench usable for recovery.
        self.profile = {}
        try:
            if self.path.exists():
                saved = json.loads(self.path.read_text(encoding="utf-8"))
                if not isinstance(saved, dict):
                    raise ValueError("配置不是 JSON 对象")
                self.profile = saved
        except (OSError, ValueError) as error:
            self.state.update(phase="error", message="启动配置读取失败，请重新选择设备：" + str(error))

    def status(self):
        with self.lock:
            value = deepcopy(self.state)
            value["profile"] = dict(self.profile)
        # Expose a live control transaction to all lifecycle/API clients so
        # none can replace the receiver while the UART operation is in flight.
        value["busy"] = value["busy"] or self.uart_lock.locked()
        # Never keep a stale ready badge after stream loss or board power-off.
        session = self.session.status()
        config = session.get("config", {})
        live = (session["signal"] == "live" and config.get("source_mode") == "hardware_unverified"
                and str(config.get("stream_epoch")) == value.get("epoch"))
        if value["phase"] == "ready" and not live:
            value.update(phase="waiting", message="视频已停止更新，请检查板卡或点击重新启动链路")
        elif value["phase"] == "waiting" and not value["busy"] and live:
            value.update(phase="ready", message="网口已收到完整视频帧；可预览、保存和标定")
        return value

    def reserved_port(self):
        """Resolve FPGA UART ownership by USB identity after port renumbering."""
        with self.lock:
            profile = dict(self.profile)
        serial = profile.get("serial_number")
        if not serial:
            # Legacy profiles have no stable identity; retain their port guard.
            return profile.get("port")
        matches = [p for p in self.ports() if p.get("serial") == serial]
        if len(matches) > 1:
            raise SessionError("FPGA CP2102 身份不唯一，请重新选择板卡串口")
        # An absent FPGA cannot own a recycled ttyUSB number. Enumeration errors
        # propagate instead of bypassing protection when identity is unknown.
        return matches[0]["port"] if matches else None

    def devices(self):
        result = dict(interfaces=[], ports=[], errors=[])
        for key, fn in (("interfaces", self.inventory), ("ports", self.ports)):
            try:
                result[key] = fn()
            except Exception as error:
                result["errors"].append(str(error))
        return result

    def _set(self, phase, message, **values):
        with self.lock:
            self.state.update(phase=phase, message=message, **values)

    def start(self, profile=None):
        """One request launches a worker; repeated clicks do not race UART/UDP."""
        with self.lock:
            if self.thread and self.thread.is_alive():
                return self.status()
            if self.uart_lock.locked():
                raise SessionError("板卡 UART 控制正在进行，暂不能重启链路")
            selected = dict(self.profile if profile is None else profile)
            allowed = {"port", "interface", "source_ip", "source_mac", "peer_port", "source_port", "auto_start", "serial_number"}
            if set(selected) - allowed or not all(isinstance(selected.get(k), str) and selected[k]
                                                for k in ("port", "interface", "source_ip", "source_mac")):
                raise SessionError("请先选择 CP2102、网卡和板卡 IPv4/MAC")
            for key, default in (("peer_port", 50000), ("source_port", 50001)):
                selected.setdefault(key, default)
                if type(selected[key]) is not int or not 1 <= selected[key] <= 65535:
                    raise SessionError("UDP 端口须在 1～65535")
            selected.setdefault("auto_start", False)
            if type(selected["auto_start"]) is not bool:
                raise SessionError("auto_start 必须是布尔值")
            self.cancel.clear()
            self._set("checking", "正在核对网卡和串口…", busy=True, board=None)
            self.thread = threading.Thread(target=self._run, args=(selected,), name="board-startup", daemon=True)
            self.thread.start()
            return self.status()

    def reset_ethernet(self):
        """Restore only Ethernet defaults and restart this receiver asynchronously.

        Resolve physical devices before disturbing a live session. Warm boards
        must still pass the existing immutable endpoint/epoch check in _run.
        HDMI belongs to the browser and is never opened/closed by this action.
        """
        with self.lock:
            if self.thread and self.thread.is_alive():
                raise SessionError("板卡启动中，请等待完成再重置以太网")
            ports = self.ports()
            serial = self.profile.get("serial_number")
            if serial:
                ports = [p for p in ports if p.get("serial") == serial]
            elif len(ports) > 1:
                ports = [p for p in ports if p["port"] == self.profile.get("port")]
            if len(ports) != 1:
                raise SessionError("默认以太网重连需要唯一的已选 CP2102，请检查连接并选择设备")
            cards = [n for n in self.inventory() if n["ip"] == DEFAULT_PEER_IP and
                     ipaddress.ip_address(ETHERNET_DEFAULTS["source_ip"]) in
                     ipaddress.ip_network(f'{n["ip"]}/{n["prefix"]}', strict=False)]
            if len(cards) != 1:
                raise SessionError("未找到唯一的默认直连网卡（192.168.80.2，须与 192.168.80.3 同网段）；请核对系统网卡配置")
            profile = dict(ETHERNET_DEFAULTS, port=ports[0]["port"],
                           serial_number=ports[0].get("serial", ""), interface=cards[0]["name"],
                           auto_start=self.profile.get("auto_start", False))
            return self.start(profile)

    def stop(self):
        """Cancel only this service's startup/receiver; release serial in finally."""
        self.cancel.set()
        worker = self.thread
        if worker and worker is not threading.current_thread():
            worker.join(timeout=20)
            if worker.is_alive():
                raise SessionError("设备检查正在结束，请稍后再试")
        if not self.uart_lock.acquire(blocking=False):
            raise SessionError("板卡 UART 控制正在进行，请等待后停止链路")
        try:
            self.session.stop()
            self._set("stopped", "已停止本网口接收，板卡启动配置保持不变", busy=False)
        finally:
            self.uart_lock.release()
        return self.status()

    def _check_cancel(self):
        if self.cancel.is_set():
            raise SessionError("启动已取消")

    def _run(self, profile):
        """Serialize the entire commissioning session against live controls."""
        with self.uart_lock:
            self._run_locked(profile)

    def probe_boot(self):
        """Read CAPS on the uniquely saved bridge without writing boot or parameters.

        A USB bridge may exist with the FPGA unpowered. Only a validated UART
        response proves running logic; serial enumeration alone is not enough.
        """
        if not self.uart_lock.acquire(blocking=False):
            raise SessionError("板卡 UART 正忙，后台探测稍后重试")
        uart = None
        try:
            with self.lock:
                profile = dict(self.profile)
            choices = [p for p in self.ports() if
                       (p.get("serial") == profile["serial_number"] if profile.get("serial_number")
                        else p["port"] == profile.get("port"))]
            if len(choices) != 1:
                raise SessionError("等待唯一的已保存 CP2102；请先完成一次板卡连接配置")
            uart = self.uart(choices[0]["port"])
            reply = uart.exchange(1)
            if len(reply) != 32 or reply[1] != 1:
                raise SessionError("FPGA 探测回复长度/命令无效")
            cold = reply[0] == 6 and reply[20:24] == b"RAW8"
            epoch, session = struct.unpack_from("<QI", reply, 4)
            if not cold and (reply[0] != 0 or not epoch):
                raise SessionError("FPGA 未返回当前 RAW8 冷/热启动入口")
            return dict(cold=cold, epoch=epoch, session_id=session,
                        capabilities=int.from_bytes(reply[24:28], "little"))
        finally:
            try:
                if uart is not None:
                    uart.close()
            finally:
                self.uart_lock.release()

    @contextmanager
    def control_session(self, *, view=False):
        """Bind a unique saved CP2102 to the live epoch without restarting UDP.

        A nonblocking lock returns an explicit busy error. The same open UART
        stays owned across upload, polling and repeated metadata reads.
        """
        if not self.uart_lock.acquire(blocking=False):
            raise SessionError("板卡 UART 正忙，请等待当前操作完成")
        uart = None
        try:
            with self.lock:
                profile, state = dict(self.profile), dict(self.state)
            if state.get("busy") or state.get("phase") not in ("ready", "waiting") or not state.get("epoch"):
                raise SessionError("请先启动板卡链路；当前没有可用的板端会话")
            live = self.session.status().get("config", {})
            if live.get("source_mode") != "hardware_unverified" or str(live.get("stream_epoch")) != state["epoch"]:
                raise SessionError("当前接收会话与板卡 epoch 不匹配")
            choices = [p for p in self.ports() if
                       (p.get("serial") == profile["serial_number"] if profile.get("serial_number")
                        else p["port"] == profile.get("port"))]
            if len(choices) != 1:
                raise SessionError("找不到唯一的已选 CP2102；请检查连接")
            uart = self.uart(choices[0]["port"])
            client = (BoardViewClient if view else GeometryClient)(uart)
            if str(client.epoch) != state["epoch"] or client.session != state.get("session_id"):
                raise SessionError("板卡 epoch/session 已变化，请重新启动链路")
            yield client
        finally:
            try:
                if uart is not None:
                    uart.close()
            finally:
                self.uart_lock.release()

    def geometry(self, data=None):
        """Expose the existing checked uploader, not a software correction path."""
        if data is not None:
            if set(data)-{"preset", "rotation_deg", "enhance", "version"} or "preset" not in data:
                raise SessionError("几何请求需要 preset；仅接受 rotation_deg/enhance/version")
            profile = GeometryProfile.from_preset(data["preset"], rotation_deg=data.get("rotation_deg", 0),
                                                  enhance=data.get("enhance", True))
        with self.control_session() as client:
            if data is not None:
                return client.upload(profile, version=data.get("version"))
            return dict(client.status(), epoch=str(client.epoch), session=client.session,
                        capabilities=client.capabilities, processing_location="fpga",
                        source_frame_id=None, pairing_status="unverified", hardware_image_verified=False)

    def view_status(self):
        """Read coherent HDMI mode under the shared UART lock, without overlays."""
        with self.control_session(view=True) as client:
            return client.view_status()

    def performance(self):
        """Serialize read-only throughput diagnostics with all UART controls."""
        with self.control_session() as client:
            return client.performance()

    def view(self, data):
        """Apply view-only changes in the running board session."""
        if set(data)-{"mode", "markers", "diameter", "revision"} or not {"mode", "markers"} <= set(data):
            raise SessionError("显示请求需要 mode/markers；仅接受 diameter/revision")
        with self.control_session(view=True) as client:
            return client.configure(**data)

    def markers(self):
        """Return FPGA-computed coordinates from one coherent metadata bank."""
        with self.control_session(view=True) as client:
            return client.markers()

    def _run_locked(self, profile):
        uart = None
        started = False
        report = dict(profile=profile, hardware_acceptance="not_performed")
        try:
            ports = self.ports()
            # Follow a saved unique USB serial when Linux/Windows renumbers ports.
            choices = [p for p in ports if p.get("serial") == profile["serial_number"]] if profile.get("serial_number") else [p for p in ports if p["port"] == profile["port"]]
            if len(choices) != 1:
                raise SessionError("所选 CP2102 已移除或端口变化，请刷新设备后重选")
            profile["port"] = choices[0]["port"]
            profile["serial_number"] = choices[0].get("serial", "")
            cards = [n for n in self.inventory() if n["name"] == profile["interface"]]
            source = ipaddress.IPv4Address(profile["source_ip"])
            cards = [n for n in cards if source in ipaddress.IPv4Network(f'{n["ip"]}/{n["prefix"]}', strict=False)]
            if len(cards) != 1:
                raise SessionError("网卡未连接、没有 IPv4 或板卡 IP 不在同一子网；请在系统网络设置中配置后刷新")
            card = cards[0]
            network = ipaddress.IPv4Network(f'{card["ip"]}/{card["prefix"]}', strict=False)
            if source in (ipaddress.IPv4Address(card["ip"]), network.network_address, network.broadcast_address):
                raise SessionError("板卡 IP 不能等于本机 IP、网络地址或广播地址")
            boot, config = metadata(secrets.randbits(64) or 1, profile["source_mac"], card["mac"],
                                    str(source), card["ip"], profile["source_port"], profile["peer_port"], enhanced_output=True)
            self._check_cancel()
            self._set("uart", "正在查询板卡冷启动状态…")
            uart = self.uart(profile["port"])
            probe = uart.exchange(1)
            cold = probe[0] == 6 and probe[20:24] == b"RAW8"
            if not cold:
                if probe[0] != 0 or not int.from_bytes(probe[4:12], "little"):
                    raise SessionError("板卡未返回 RAW8 启动入口或有效会话，请核对固件")
                # FPGA cannot read back endpoint configuration. Only a persisted
                # identical tuple plus live epoch permits warm resume after host restart.
                previous = json.loads(self.boot_path.read_text(encoding="utf-8")) if self.boot_path.exists() else {}
                keys = ("source_mac", "peer_mac", "source_ip", "peer_ip", "source_port", "peer_port")
                if (previous.get("epoch") != int.from_bytes(probe[4:12], "little") or
                        any(previous.get(k) != boot[k] for k in keys)):
                    raise SessionError("板卡已锁定其他启动配置。请冷启动板卡后重试；不会覆盖运行中的 epoch")
                boot, config = metadata(previous["epoch"], *(boot[k] for k in keys), enhanced_output=True)
            self._check_cancel()
            # Stop only the receiver owned by this WebSession, bind before boot,
            # and save intent before transmission so ACK loss can be recovered.
            self.session.stop()
            self._set("receiver", "正在绑定板卡网卡并启动 UDP 接收…")
            self.session.start(config=config, auto_mock=False)
            started = True
            atomic_json(self.boot_path, boot)
            with self.lock:
                self.profile = profile
            atomic_json(self.path, profile)
            if cold:
                self._set("commissioning", "正在通过 UART 配置地址和本轮 epoch…")
                self._check_cancel()
                ack = uart.exchange(0x71, bytes.fromhex(boot["command_hex"])[8:40])
                if ack[0] != 0 or ack[20:24] != b"RAW8" or int.from_bytes(ack[4:12], "little") != boot["epoch"]:
                    raise SessionError("RAW8 启动 ACK 校验失败；请点击重试查询实际状态")
                self.cancel.wait(.05)  # UART mux needs the documented 24-bit idle guard.
                self._check_cancel()
                probe = uart.exchange(1)
            if probe[0] != 0 or int.from_bytes(probe[4:12], "little") != boot["epoch"]:
                raise SessionError("启动后 epoch 不匹配，请检查是否发生板卡复位")
            session_id = int.from_bytes(probe[12:16], "little") or 1
            payload = struct.pack("<QI", boot["epoch"], session_id)
            if not int.from_bytes(probe[12:16], "little"):
                if uart.exchange(2, payload)[0] not in (0, 1):
                    raise SessionError("状态会话打开失败")
            self._set("waiting", "地址配置完成，等待相机完整帧…", epoch=str(boot["epoch"]), session_id=session_id)
            deadline = time.monotonic() + 12
            flags = 0
            while time.monotonic() < deadline:
                self._check_cancel()
                reply = uart.exchange(3, payload)
                if reply[0] != 0 or int.from_bytes(reply[4:12], "little") != boot["epoch"]:
                    raise SessionError("板卡会话已变化，请点击重新启动链路")
                flags = int.from_bytes(reply[20:24], "little")
                board = dict(sensor_ready=bool(flags & 256), frame_published=bool(flags & 512),
                             hdmi_underflow=bool(flags & 1024), core_fault=bool(flags & 128),
                             phy_ready=bool(flags & 2), link_ready=bool(flags & 4), flags=flags)
                self._set("waiting", "等待网口完整帧…", board=board)
                if self.session.status()["signal"] == "live":
                    self._set("ready", "网口已收到完整视频帧；可预览、保存和标定", board=board)
                    break
                if self.cancel.wait(.5):
                    self._check_cancel()
            else:
                status = self.session.status()
                packets = status.get("metrics", {}).get("counters", {}).get("datagrams_received", 0)
                detail = ("板端 PHY 未就绪或网线链路未建立" if not flags & 4 else
                          "摄像头未就绪，请检查直插连接与冷启动" if not flags & 256 else
                          "摄像头未发布帧，请检查 DDR/采集链路" if not flags & 512 else
                          "未收到 UDP 包，请检查所选网卡、网线和防火墙" if not packets else
                          "已收到 UDP 但没有完整帧，请检查接收缓冲、丢包及来源配置")
                self._set("waiting", detail + "；接收保持运行，可点击重试")
            report.update(boot=boot, result=self.status())
        except Exception as error:
            if started:
                self.session.stop()
            report["error"] = str(error)
            self._set("error", str(error))
        finally:
            try:
                if uart:
                    report["uart"] = uart.records
                    uart.close()
                # Retain each commissioning transcript; retries must not erase evidence.
                name = "board-link-" + time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3) + ".json"
                atomic_json(self.root / "reports" / name, report)
            except OSError as error:
                self._set("error", "启动日志或串口释放失败：" + str(error))
            finally:
                self._set(self.state["phase"], self.state["message"], busy=False)
