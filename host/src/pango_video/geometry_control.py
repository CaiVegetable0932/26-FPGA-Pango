"""Encode lens parameters and upload them; never perform a live PC image warp.

The optional FPGA endpoint must advertise capability 0x80. UART CRC, sequence,
epoch/session and atomic frame activation remain separate verification layers.
The caller owns/releases the UART; this module never opens Flash or edits IPs.
"""
from dataclasses import dataclass
from math import cos, isfinite, radians, sin, tan
import struct
import time


class GeometryError(ValueError):
    """Explicit parameter/protocol failure; no silently substituted profile."""


@dataclass(frozen=True)
class GeometryProfile:
    """One immutable, fixed-size board camera/output profile, not calibration proof."""
    words: tuple
    model: int = 2
    enhance: bool = True
    width: int = 1920
    height: int = 1080

    @classmethod
    def from_preset(cls, preset, *, rotation_deg=0, enhance=True):
        """Scale K to source pixels and compose inverse virtual camera rays.

        This matches OpenCV's four-coefficient fish-eye model, not Brown p1/p2.
        Rotation is an explicit in-plane setting; MCU angles are metadata only.
        """
        if not isinstance(preset, dict):
            raise GeometryError("preset 必须是参数对象")
        p = preset.get("parameters", preset)
        if not isinstance(p, dict):
            raise GeometryError("parameters 必须是参数对象")
        if p.get("model") != "fisheye_equidistant":
            raise GeometryError("只接受 fisheye_equidistant 四系数参数")
        def number(name):
            value = p.get(name)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not isfinite(value):
                raise GeometryError("缺失或无效参数：" + name)
            return float(value)
        width, height = number("reference_width"), number("reference_height")
        fx, fy = number("fx")*1920/width if width > 0 else 0, number("fy")*1080/height if height > 0 else 0
        # Pixel centers must follow the canonical browser sourcePoint mapping,
        # including when the calibration reference raster is resized.
        cx = (number("cx")+.5)*1920/width-.5 if width > 0 else 0
        cy = (number("cy")+.5)*1080/height-.5 if height > 0 else 0
        fov = number("output_fov_deg")
        if min(width, height, fx, fy) <= 0 or max(fx, fy) > 4096 or max(abs(cx), abs(cy)) > 4096:
            raise GeometryError("图像尺寸、焦距或主点超出 FPGA 配置范围")
        if not 1 <= fov <= 170 or not isfinite(rotation_deg) or abs(rotation_deg) > 360:
            raise GeometryError("输出 FOV/旋转角无效；透视输出不能直接覆盖 200°")
        f = 1920/(2*tan(radians(fov)/2))
        c, s = cos(radians(rotation_deg)), sin(radians(rotation_deg))
        affine = (c/f, s/f, -(c*959.5+s*539.5)/f,
                  -s/f, c/f, (s*959.5-c*539.5)/f)
        coefficients = tuple(number(k) for k in ("k1", "k2", "k3", "k4"))
        if max(map(abs, coefficients)) > 1 or max(map(abs, affine)) > 4:
            raise GeometryError("系数/仿射参数超出固定点安全范围")
        values = (*affine, *coefficients, fx, fy, cx, cy)
        words = tuple(round(v*(1 << (26 if i < 10 else 16))) for i, v in enumerate(values))
        if any(not -(1 << 31) <= w < (1 << 31) for w in words):
            raise GeometryError("参数固定点溢出")
        return cls(words=words, enhance=enhance)


class GeometryClient:
    """One session-bound uploader, with readback and measured activation polling."""
    def __init__(self, uart, *, clock=time.monotonic, sleep=time.sleep):
        self.uart, self.clock, self.sleep = uart, clock, sleep
        caps = uart.exchange(1)
        if len(caps) != 32 or caps[0] or caps[1] != 1 or not int.from_bytes(caps[24:28], "little") & 0x80:
            raise GeometryError("当前固件未开放 FPGA 矫正参数接口；不能向旧位流写入")
        self.epoch, self.session = struct.unpack_from("<QI", caps, 4)
        if not self.epoch or not self.session or not caps[2] & 1:
            raise GeometryError("请先在 host 启动板卡链路，获得有效 epoch/session")
        self.prefix = struct.pack("<QI", self.epoch, self.session)
        self.capabilities = int.from_bytes(caps[24:28], "little")

    def _command(self, cmd, extra=b""):
        """Accept only matching common identity, including duplicate ACKs."""
        reply = self.uart.exchange(cmd, self.prefix+extra)
        if len(reply) != 32 or reply[1] != cmd or struct.unpack_from("<QI", reply, 4) != (self.epoch, self.session):
            raise GeometryError("矫正回复上下文变化，请重新查询板卡")
        if reply[0] not in (0, 1):
            raise GeometryError(f"FPGA 拒绝命令 0x{cmd:02x}，返回码 {reply[0]}")
        return reply[20:32]

    def read(self, index, bank=1):
        """Read exact word/diagnostic and version, not preview-derived values."""
        idx, value, version = struct.unpack("<III", self._command(0x34, struct.pack("<II", index, bank)))
        if idx != index:
            raise GeometryError("参数回读索引不匹配")
        return value, version

    def status(self):
        """Return applied version and its first source frame identity."""
        version, frame = struct.unpack("<IQ", self._command(0x33))
        return dict(version=version, applied_source_frame_id=frame)

    def performance(self):
        """Read result publication counters without changing the running board.

        UART words are not an atomic snapshot. Bracket the completed identity
        with publication counts, and leave it null if a result changed. Index
        18 is a RUNNING frame timer, never the last completed frame duration.
        """
        begin = self.clock()
        first, version = self.read(22)
        counter_time = self.clock()
        values = {22: first}
        versions = {version}
        for index in (18, 19, 20, 21, 23, 24, 25, 32, 33):
            values[index], read_version = self.read(index)
            versions.add(read_version)
        last, end_version = self.read(22)
        versions.add(end_version)
        coherent = first == last and len(versions) == 1
        faults = values[21] & 0x1fe
        # The independent DVP monitor counts physical VSYNC boundaries even
        # when capture rejects a frame. Its 16-bit counter and separate sample
        # time must never be substituted for the geometry result counter.
        dvp = dict(dvp_frame_count=None,dvp_counter_time=None,
                   dvp_low_lines=None,dvp_high_lines=None,dvp_min_width=None,dvp_max_width=None,
                   capture_rejected=None,capture_overflows=None)
        if self.capabilities & 0x40:
            frames,low,minimum,maximum,high,state,format_version = struct.unpack('<5HBB',self._command(7))
            if format_version != 1:
                raise GeometryError('DVP 监测快照版本未知')
            dvp_time = self.clock()
            clocks,rejected,overflows = struct.unpack('<III',self._command(8))
            dvp.update(dvp_frame_count=frames,dvp_counter_time=dvp_time,dvp_low_lines=low,
                       dvp_high_lines=high,dvp_min_width=minimum,dvp_max_width=maximum,
                       capture_state=state,camera_clock_count=clocks,
                       capture_rejected=rejected,capture_overflows=overflows)
        return dict(epoch=str(self.epoch), session=self.session,
                    counter_time=counter_time, read_seconds=self.clock()-begin,
                    result_published=first, result_published_after=last,
                    running_frame_cycles=values[18], cache_hits=values[19], cache_misses=values[20],
                    fault_bits=faults, process_state=(values[21] >> 9) & 7,
                    completed_identity_coherent=coherent,
                    completed_source_frame_id=str(values[24] | values[25] << 32) if coherent else None,
                    completed_epoch=str(values[32] | values[33] << 32) if coherent else None,
                    completed_parameter_version=values[23] if coherent else None,
                    parameter_version=version if len(versions) == 1 else None,
                    configured_memory_clock_hz=125000000, hardware_image_verified=False,**dvp)

    def upload(self, profile, *, version=None, timeout=10):
        """BEGIN/14 WORDs/readback/COMMIT, then wait for frame-boundary use.

        A staged ACK is not success: timeout reports pending/not-applied instead
        of silently accepting a version without any complete input frames.
        Retrying an explicit version is idempotent; mismatched active words fail.
        """
        # Purpose: preflight the complete payload before BEGIN, so a caller
        # using explicit fixed-point words cannot leave a half-written shadow.
        if (len(profile.words) != 14 or type(profile.model) is not int or
                profile.model not in (0, 1, 2) or type(profile.enhance) is not bool or
                (profile.width, profile.height) != (1920, 1080) or
                any(type(w) is not int or not -(1 << 31) <= w < (1 << 31) for w in profile.words)):
            raise GeometryError("固件仅支持 1920×1080、14 个固定点参数")
        current = self.status()["version"]
        if not isfinite(timeout) or timeout <= 0:
            raise GeometryError("等待激活时间必须为正的有限秒数")
        if version is None:
            version = current+1
        if type(version) is not int or not 1 <= version <= 0xffffffff or version < current:
            raise GeometryError("参数版本必须递增且不得回绕")
        if version != current:
            flags, shadow_version = self.read(14, bank=0)
            # Purpose: resume a timed-out committed upload without rewriting
            # the immutable table being built or awaiting the next frame.
            resumed = shadow_version == version and flags & 0x18
            if not resumed:
                self._command(0x30, struct.pack("<IBBHHH", version, profile.model, int(profile.enhance), profile.width, profile.height, 0))
                for i, word in enumerate(profile.words):
                    self._command(0x31, struct.pack("<IIi", version, i, word))
            for i, word in enumerate(profile.words):
                value, read_version = self.read(i, bank=0)
                if value != word & 0xffffffff or read_version != version:
                    raise GeometryError("影子参数回读与下发值不一致")
            self._command(0x32, struct.pack("<I", version))
        deadline = self.clock()+timeout
        while True:
            state = self.status()
            if state["version"] == version:
                for i, word in enumerate(profile.words):
                    value, active_version = self.read(i)
                    if value != word & 0xffffffff or active_version != version:
                        raise GeometryError("活动参数不一致：版本冲突或正在切换")
                flags, active_version = self.read(14)
                if active_version != version or (flags & 7) != (profile.model | (int(profile.enhance) << 2)):
                    raise GeometryError("活动模型/增强设置与期望不一致")
                return dict(state, epoch=str(self.epoch), session=self.session,
                            parameters_verified=True, processing_location="fpga",
                            hardware_image_verified=False, words=list(profile.words),
                            source_frame_id=None, pairing_status="unverified")
            flags, _ = self.read(14, bank=0)
            if state["version"] > version:
                raise GeometryError("其他上传者已激活更新版本，请重新核对参数")
            if flags & 0x20:
                raise GeometryError("FPGA 径向表构建失败，已保留上一活动参数")
            if self.clock() >= deadline:
                raise GeometryError("参数已暂存但尚未激活：检查完整摄像头帧；不代表图像验证通过")
            self.sleep(.05)
