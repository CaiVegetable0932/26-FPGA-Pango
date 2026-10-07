"""FPGA view control and coherent marker readback; never compute marker rays."""
import struct

from .geometry_control import GeometryClient, GeometryError


class MarkerPending(GeometryError):
    """No complete coherent HDMI display snapshot yet; never a success result."""


class BoardViewClient(GeometryClient):
    """Use the caller's serialized UART session for CAPS 0x100 extensions."""
    def __init__(self, uart, **kwargs):
        super().__init__(uart, **kwargs)
        if not self.capabilities & 0x100:
            raise GeometryError("当前固件未开放 FPGA 显示/标记接口（CAPS 0x100）")

    def markers(self, *, attempts=3):
        """Bracket all 20 records with identical metadata and reply versions.

        A moving bank is retried in full, never merged or replaced by host math.
        READ's version field is the HDMI-displayed parameter version, distinct
        from view revision. Index 6 bit 0 is ready; other bits indicate failure.
        """
        for _ in range(attempts):
            before = [self.read(i, bank=2) for i in range(7)]
            records = [[self.read(16+5*i+j, bank=2) for j in range(5)] for i in range(20)]
            after = [self.read(i, bank=2) for i in range(7)]
            versions = {version for _, version in before+after+sum(records, [])}
            if before != after or len(versions) != 1:
                continue
            magic, revision, packed, param_version, mask, generation, status = [v for v, _ in before]
            if magic != 0x4d4b5231:
                raise GeometryError("FPGA 标记元数据 magic 无效")
            if versions != {param_version}:
                raise GeometryError("FPGA 标记回复版本与 HDMI 参数版本不一致")
            # The RTL publishes ready=1; mapping/LUT/model errors set bits
            # 1/2/3. Reset values (status=0, generation=0) cannot prove display.
            if status & ~1:
                raise GeometryError(f"FPGA 标记计算失败或状态不支持：0x{status:08x}")
            if status != 1 or generation == 0:
                raise MarkerPending("FPGA 尚无已显示且就绪的标记快照")
            flags, diameter = packed & 0xff, packed >> 8
            if flags & ~3 or not 4 <= diameter <= 32 or mask & ~0xfffff:
                raise GeometryError("FPGA 显示元数据保留位或直径无效")
            points = []
            for i, record in enumerate(records):
                source, x, y, rgb, visible = [v for v, _ in record]
                if visible & ~1 or rgb & ~0xffffff or bool(visible) != bool(mask & (1 << i)):
                    raise GeometryError("FPGA 标记记录与可见掩码不一致")
                sx, sy = source & 0xffff, source >> 16
                if sx >= 1920 or sy >= 1080:
                    raise GeometryError("FPGA 标记源像素超出 1920×1080")
                signed = lambda word: word-(1 << 32) if word & (1 << 31) else word
                points.append(dict(id=i+1, source=[sx, sy],
                                   destination=[signed(x)/4096, signed(y)/4096],
                                   color=f"#{rgb:06x}", visible=bool(visible)))
            return dict(epoch=str(self.epoch), session=self.session, revision=revision,
                        flags=flags, mode="original" if flags & 1 else "corrected",
                        markers=bool(flags & 2), diameter=diameter, generation=generation,
                        displayed_param_version=param_version, visibility_mask=mask,
                        status=status, points=points, source_width=1920, source_height=1080,
                        processing_location="fpga", metadata_verified=True,
                        source_frame_id=None, pairing_status="unverified", hardware_image_verified=False)
        raise MarkerPending("FPGA 标记 revision/generation 正在变化，未获得一致快照")

    def configure(self, *, mode, markers, diameter=10, revision=None, timeout=5):
        """Acknowledge only after the requested view appears in coherent readback."""
        if mode not in ("original", "corrected") or type(markers) is not bool:
            raise GeometryError("mode 须为 original/corrected，markers 须为布尔值")
        if type(diameter) is not int or not 4 <= diameter <= 32:
            raise GeometryError("标记直径必须为 4～32 整数像素")
        # An initial/reset or failed marker table must not prevent recovery to
        # original mode. Only use the revision word before sending a view command.
        current, _ = self.read(1, bank=2)
        if revision is None:
            revision = current+1
        if type(revision) is not int or not 1 <= revision <= 0xffffffff or revision < current:
            raise GeometryError("显示 revision 必须递增且不得回绕")
        flags = int(mode == "original") | (int(markers) << 1)
        requested, applied, packed = struct.unpack("<III", self._command(
            0x35, struct.pack("<III", revision, flags, diameter)))
        if requested != revision or applied > revision or packed & ~0x3f03 or not 4 <= packed >> 8 <= 32:
            raise GeometryError("FPGA 显示回复 revision/保留位无效")
        deadline = self.clock()+timeout
        while True:
            try:
                state = self.markers()
            except MarkerPending:
                if self.clock() >= deadline:
                    raise GeometryError("显示请求尚未应用或快照不一致；不代表 HDMI 图像验证成功")
                self.sleep(.05)
                continue
            if state["revision"] == revision:
                if (state["flags"], state["diameter"]) != (flags, diameter):
                    raise GeometryError("FPGA 已应用显示设置与请求不一致")
                return dict(state, requested_revision=revision, applied_revision=revision)
            if state["revision"] > revision:
                raise GeometryError("其他客户端已更新显示 revision")
            if self.clock() >= deadline:
                raise GeometryError("显示请求尚未应用；不代表 HDMI 图像验证成功")
            self.sleep(.05)
