"""Independent PC–F4 MCU_POSE_V2 owner; protocol source: MCU branch 22452f36.

Serial transactions are serialized with the control lease worker. A connection
never homes or moves automatically; invalid angles remain null in snapshots.

Manual control covers gantry XYZ, gimbal pitch/yaw and axis-3 stop. Axis-3
calibration stays in the field tool (`mcu/firmware/longmenjia/tools`), so the
legacy text channel here is deliberately limited to the emergency stop.
"""
import copy
import math
import os
import secrets
import struct
import threading
import time
import mcu_pose_v2 as wire


class MCURejected(ValueError):
    """Keep firmware BUSY distinct from a broken transport or invalid context."""
    def __init__(self, result, detail):
        self.result = result
        names = {2:'BUSY',3:'BAD_LENGTH',4:'RANGE',5:'BAD_CONTEXT',6:'UNSUPPORTED',7:'NOT_READY',8:'CONFLICT',9:'FAULT',10:'STALE'}
        super().__init__(f'MCU 拒绝：{names.get(result, result)}，detail={detail}')


class MCUControl:
    def __init__(self, serial_factory=None):
        self.factory = serial_factory
        self.lock = threading.RLock()
        self.serial = None
        self.seq = 0
        self.boot = 0
        self.session = 0
        self.buffer = bytearray()
        self.stop = threading.Event()
        self.thread = None
        self.snapshot = dict(connected=False, angles=None, error=None)
        self.zero_pending = None
        self.query_after = 0
        self.event_received = 0
        self.event_acked = 0
        self.own_motions = set()
        # Bounded NOTICE history: only the emergency stop consumes it today.
        self.notices = []

    def status(self):
        """Return cached feedback only; no HTTP status request takes the UART."""
        with self.lock:
            result = copy.deepcopy(self.snapshot)
            result['age_ms'] = round((time.monotonic() - result.pop('_received', time.monotonic())) * 1000)
            if result['age_ms'] > 1000:
                result['angles'] = None
            result['recent_notices'] = [dict(item) for item in self.notices[-5:]]
            return result

    def _packet(self, cmd, extra=b'', raw=False):
        """Allocate one transaction; retransmission must reuse these exact bytes."""
        if self.seq >= 65535:
            raise ValueError('MCU 请求序号耗尽，请在停止运动后重新连接')
        self.seq += 1
        payload = extra if raw else wire.context(self.boot, self.session) + extra
        return self.seq, wire.encode(cmd, self.seq, payload)

    def _frames(self):
        """Recover framed traffic across partial reads and CRC failures."""
        self.buffer.extend(self.serial.read(2048))
        while len(self.buffer) >= 8:
            start = self.buffer.find(b'\x55\xaa')
            if start < 0:
                self.buffer[:] = self.buffer[-1:]
                return
            if start:
                del self.buffer[:start]
            if len(self.buffer) < 8:
                return
            size = struct.unpack_from('<H', self.buffer, 6)[0]
            if self.buffer[2] != 2 or size > 1024:
                del self.buffer[0]
                continue
            if len(self.buffer) < size + 10:
                return
            try:
                frame = wire.decode(bytes(self.buffer[:size + 10]))
            except ValueError:
                del self.buffer[0]
                continue
            del self.buffer[:size + 10]
            yield frame

    def _event(self, body):
        """Consume only this session's ordered events, including old task replay.

        ACK happens after the active request, never recursively inside a receive
        callback. Replayed events are drained but cannot complete a new motion.
        """
        if len(body) != 40:
            raise ValueError('MCU EVENT 长度错误')
        boot, session, event_id = struct.unpack_from('<QII', body)
        if (boot, session) != (self.boot, self.session):
            return
        if not event_id or event_id <= self.event_received:
            return
        # OPEN can replay a queue whose oldest retained ID is greater than one.
        if self.event_received and event_id != self.event_received + 1:
            raise ValueError('MCU 事件序号不连续，请重新连接并检查事件溢出')
        self.event_received = event_id
        motion, kind, result, config, fault, mask, state = struct.unpack_from('<IHHIHBB', body, 24)
        event = dict(event_id=event_id, motion_id=motion, type=kind, result=result,
                     config_version=config, fault_code=fault, mask=mask, motion_state=state)
        self.snapshot['last_event'] = event
        if motion in self.own_motions and kind != 1:
            self.own_motions.discard(motion)
            last = self.snapshot.get('last_command', {})
            if last.get('motion_id') == motion:
                success = kind in (2, 4) and result == 0 and fault == 0
                self.snapshot['last_command'] = dict(last, status='completed' if success else 'failed',
                    event=event, message='MCU 已报告运动完成；请核对实际反馈角度' if success else
                    f'MCU 运动未完成：事件 {kind}，结果 {result}，故障 {fault}')

    def _notice(self, body):
        """Keep asynchronous LEGACY text that belongs to this session.

        NOTICE replies use the firmware's latest motion id as their sequence,
        so they must never be matched against the request sequence.
        """
        message = wire.notice(body)
        if (message['boot_id'], message['session_id']) != (self.boot, self.session):
            return
        self.notices.append(dict(id=len(self.notices) + 1, text=message['text'],
                                 received_ms=round(time.monotonic() * 1000)))
        del self.notices[:-20]
        self.snapshot['last_notice'] = self.notices[-1]

    def _zero_reply(self, seq, body):
        """Route the delayed final zero response independently of current seq."""
        pending = self.zero_pending
        if not pending or seq != pending['seq']:
            return False
        data, result = self._reply(0x4a, body)
        if result != 0 or len(data) != 12:
            raise ValueError('MCU 零位最终应答格式错误')
        config, pitch, yaw = struct.unpack('<Iii', data)
        self.zero_pending = None
        self.snapshot['zero_operation'] = dict(status='completed', config_version=config,
            pitch_mdeg=pitch, yaw_mdeg=yaw, message='姿态零位登记完成')
        return True

    def _reply(self, cmd, body):
        """Validate the reply identity before accepting results or data."""
        if len(body) < 16:
            raise ValueError('MCU 应答长度错误')
        boot, session, request, result, detail = struct.unpack_from('<QIBBH', body)
        if request != cmd or (cmd != 0x40 and (boot, session) != (self.boot, self.session)):
            raise ValueError('MCU 应答身份不匹配，请重新连接')
        if result not in (0, 1):
            raise MCURejected(result, detail)
        if cmd == 0x40:
            self.boot = boot
        return body[16:], result

    def _exchange(self, cmd, extra=b'', raw=False):
        """Retry a short transaction while dispatching events and zero results."""
        seq, packet = self._packet(cmd, extra, raw)
        for _ in range(2):
            self.serial.write(packet)
            deadline = time.monotonic() + 0.20
            while time.monotonic() < deadline:
                for kind, reply_seq, body in self._frames():
                    if kind == 0x90:
                        self._event(body)
                        continue
                    if kind == 0x91:
                        self._notice(body)
                        continue
                    if kind != 0x80:
                        continue
                    if self.zero_pending and reply_seq == self.zero_pending['seq']:
                        try:
                            self._zero_reply(reply_seq, body)
                        except MCURejected as error:
                            self.zero_pending = None
                            self.snapshot['zero_operation'] = dict(status='failed', message=str(error))
                        continue
                    if reply_seq == seq:
                        return self._reply(cmd, body)
        self.buffer.clear()
        raise OSError('MCU 应答超时；请检查独立 F4 串口及固件版本')

    def _ack_events(self):
        """Confirm received events; defer BUSY without losing the pending ACK."""
        if self.event_received <= self.event_acked:
            return
        event_id = self.event_received
        try:
            data, _ = self._exchange(0x49, struct.pack('<I', event_id))
        except MCURejected as error:
            if error.result == 2:
                return
            raise
        if len(data) != 4 or struct.unpack('<I', data)[0] != event_id:
            raise ValueError('MCU 事件确认编号不匹配')
        self.event_acked = event_id

    def _request(self, cmd, extra=b'', raw=False):
        """Complete short transactions and then drain the latest received event."""
        try:
            return self._exchange(cmd, extra, raw)
        finally:
            if self.session and cmd not in (0x40, 0x41):
                self._ack_events()

    def _read(self):
        """Coalesce manual/background queries inside the firmware's 100 ms limit."""
        if time.monotonic() < self.query_after:
            return
        self.query_after = time.monotonic() + 0.12
        try:
            data, _ = self._request(0x44)
        except MCURejected as error:
            if error.result == 2:
                return
            raise
        state = wire.state(data)
        if (state['boot_id'], state['session_id']) != (self.boot, self.session):
            raise ValueError('MCU 状态上下文已改变')
        self.motion = max(getattr(self, 'motion', 0), state['motion_id'])
        self.snapshot.update(angles=dict(pitch=None if state['pitch_mdeg'] is None else state['pitch_mdeg']/1000,
                                        yaw=None if state['yaw_mdeg'] is None else state['yaw_mdeg']/1000),
                             state=state, _received=time.monotonic(), error=None)

    def connect(self, port, reserved_port=None):
        """Open only an explicitly selected separate UART and validate V2 identity."""
        if not isinstance(port, str) or not port or len(port) > 512:
            raise ValueError('请选择 MCU 串口')
        if reserved_port and os.path.realpath(port) == os.path.realpath(reserved_port):
            raise ValueError('MCU 必须使用独立串口，不能占用 FPGA 串口')
        self.close()
        with self.lock:
            try:
                if self.factory is None:
                    import serial
                    factory = serial.Serial
                else:
                    factory = self.factory
                options = dict(port=port, baudrate=115200, timeout=0.01, write_timeout=0.2)
                if os.name != 'nt':
                    options['exclusive'] = True
                # Configure modem lines before opening to match the MCU tools.
                # Factory peers retain the same simple injection interface.
                if self.factory is None:
                    options.pop('port')
                    self.serial = factory(port=None, **options)
                    self.serial.dtr = False
                    self.serial.rts = False
                    self.serial.port = port
                    self.serial.open()
                else:
                    self.serial = factory(**options)
                self.seq = 0
                self.boot = self.session = 0
                self.zero_pending = None
                self.query_after = 0
                self.event_received = self.event_acked = 0
                self.own_motions.clear()
                self.buffer.clear()
                info, _ = self._request(0x40, raw=True)
                if len(info) != 48 or struct.unpack_from('<H', info, 14)[0] != 0x4d32:
                    raise ValueError('不是 MCU_POSE_V2 设备')
                self.session = secrets.randbelow(0xffffffff) + 1
                opened, _ = self._request(0x41, struct.pack('<IQI', self.session, self.boot, 0), raw=True)
                if len(opened) != 8:
                    raise ValueError('OPEN 应答长度错误')
                self.motion = struct.unpack_from('<I', opened, 4)[0]
                self.snapshot = dict(connected=True, port=port, device_id=str(struct.unpack_from('<Q', info)[0]),
                                     boot_id=str(self.boot), angles=None, error=None)
                # Disable unsolicited PC STATE traffic; GET_STATUS itself renews
                # the lease and obtains fresh validity/source flags every 200 ms.
                self._request(0x43, struct.pack('<HH', 0, 0))
                self._read()
                self.stop = threading.Event()
                self.thread = threading.Thread(target=self._poll, daemon=True)
                self.thread.start()
            except Exception:
                if self.serial:
                    self.serial.close()
                self.serial = None
                self.snapshot.update(connected=False, angles=None)
                raise
        return self.status()

    def _poll(self):
        """Keep the control lease alive without depending on browser timers."""
        # Keep this worker bound to its original lifetime even if another HTTP
        # request reconnects while an old transaction is finishing.
        worker_stop = self.stop
        while not worker_stop.wait(0.20):
            with self.lock:
                if worker_stop.is_set() or not self.serial:
                    return
                try:
                    self._poll_once()
                except MCURejected as error:
                    # BUSY is flow control, not a disconnected UART. The next
                    # scheduled iteration keeps renewal/query traffic bounded.
                    if error.result == 2:
                        continue
                    self._disconnect(str(error))
                    return
                except Exception as error:
                    self._disconnect(str(error))
                    return

    def _poll_once(self):
        """Renew before servicing slow operations or rate-limited telemetry."""
        self._request(0x4c)
        self._advance_zero()
        self._read()

    def _advance_zero(self):
        """Retry the same pending zero transaction without blocking lease traffic."""
        pending = self.zero_pending
        if not pending:
            return
        now = time.monotonic()
        if now - pending['started'] > 16:
            self.zero_pending = None
            self.snapshot['zero_operation'] = dict(status='unknown',
                message='零位最终应答超时，结果未知；请读取状态核对后再操作')
        elif now - pending['sent'] >= 0.5:
            self.serial.write(pending['packet'])
            pending['sent'] = now

    def _disconnect(self, error=None):
        """Preserve unfinished-operation uncertainty when the channel closes."""
        if self.zero_pending:
            self.snapshot['zero_operation'] = dict(status='unknown', message='连接已断开，零位登记结果未知')
            self.zero_pending = None
        if self.serial:
            self.serial.close()
        self.serial = None
        self.snapshot.update(connected=False, angles=None, error=error)

    def _next_motion(self):
        """Allocate one motion id and claim its event before any write."""
        if self.motion >= 0xffffffff:
            raise ValueError('运动编号耗尽')
        self.motion += 1
        self.own_motions.add(self.motion)
        self.snapshot['last_command'] = dict(motion_id=self.motion, status='pending',
                                             message='等待 MCU 接受指令')
        return self.motion

    def _gimbal_targets(self, data):
        """Validate ±60° gimbal targets and require a ≥3° net change per axis.

        The bus servos ignore a single command whose net change is below their
        dead zone (measured floor ≈2.3°, see firmware/longmenjia/WIRING_CHECK.md)
        while the firmware still reports MOTION_DONE. Comparing against fresh
        feedback is the only reliable gate, so a missing or stale reading blocks
        the command instead of guessing a position.
        """
        received = self.snapshot.get('_received')
        fresh = received is not None and time.monotonic() - received <= 1.0
        current = self.snapshot.get('angles') or {}
        targets = []
        for key in ('pitch', 'yaw'):
            value = data.get(key)
            if type(value) not in (int, float) or not math.isfinite(value) or not -60 <= value <= 60:
                raise ValueError('pitch/yaw 必须为 -60° 到 +60° 的有限数值')
            target = int(round(value * 1000))
            if not fresh or current.get(key) is None:
                raise ValueError(f'{key} 当前角度反馈不可用，请先读取有效反馈再下发')
            delta = abs(target - int(round(current[key] * 1000)))
            if delta < 3000:
                raise ValueError(f'{key} 单次变化 {delta / 1000:.3f}° 小于 3°；'
                                 '低于舵机死区会被吞掉，请把目标改为至少相差 3°')
            targets.append(target)
        return targets

    def _gantry_targets(self, data):
        """Validate 0..100% site coordinates and return firmware axis order.

        Firmware logical axes are 1/2/3 = site X / site Z (dual-motor gantry) /
        site Y (cantilever extension); the operator-facing order stays X/Y/Z.
        """
        micro = []
        for key in ('x', 'y', 'z'):
            value = data.get(key)
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 100:
                raise ValueError('龙门架 x/y/z 必须为 0..100 的行程百分比')
            micro.append(int(round(value * 1_000_000)))
        rpm = data.get('rpm')
        if type(rpm) is not int or not 1 <= rpm <= 60:
            raise ValueError('速度必须为 1..60 RPM 的整数')
        x, y, z = micro
        return x, z, y, rpm

    def _submit_motion(self, cmd, body, label):
        """Send one absolute motion; acceptance must never read as arrival."""
        motion = struct.unpack_from('<I', body)[0]
        try:
            response, result = self._request(cmd, body)
        except Exception:
            self.own_motions.discard(motion)
            self.snapshot['last_command'] = dict(motion_id=motion, status='unknown',
                message='未确认运动指令结果，请核对 MCU 状态')
            raise
        if len(response) != 4 or struct.unpack('<I', response)[0] != motion:
            raise ValueError('运动应答编号不匹配')
        if self.snapshot['last_command']['status'] == 'pending':
            self.snapshot['last_command'] = dict(motion_id=motion, result=result,
                status='accepted',
                message=f'{label}指令已接受；请观察实际反馈，接受不代表到位')

    def _submit_confirm(self):
        """Declare the current physical position as the X/Y/Z zero (0x51)."""
        response, _ = self._request(0x51, wire.confirm_body(wire.GANTRY_MASK))
        if len(response) != 4:
            raise ValueError('零点确认应答格式错误')
        config = struct.unpack('<I', response)[0]
        self.snapshot['manual_zero'] = dict(config_version=config,
            message='已把当前位置声明为三轴零点；随后需回正并登记姿态零位')

    def _submit_stop(self):
        """Stop axis 3 through the only firmware path and report its text.

        `stop 3` exists only as LEGACY text. A lost reply is retried with the
        same sequence number, so STALE means the firmware already consumed it:
        the stop most likely applied and the lease must not be dropped.
        """
        self._next_motion()
        try:
            response, _ = self._request(0x50, wire.legacy_body(self.motion, 'stop 3'))
        except MCURejected as error:
            if error.result == 10:
                self.snapshot['last_command'] = dict(motion_id=self.motion, status='unknown',
                    message='急停回执丢失（STALE），请核对设备是否已停止')
                return
            self._stop_fallback(error)
            return
        except Exception as error:
            self._stop_fallback(error)
            return
        text = response.decode('ascii', 'replace').strip()
        self.snapshot['last_command'] = dict(motion_id=self.motion, status='completed',
            message=f'急停 stop 3 已下发；MCU 回执：{text or "（空）"}')

    def _stop_fallback(self, error):
        """Stop lease renewal when an explicit stop cannot be confirmed.

        Dropping the heartbeats lets the firmware's 1 s control lease expire and
        stop every axis, which is the documented fallback for this board.
        """
        self._disconnect(f'急停未获确认（{error}）；已停止续租，MCU 将在 1 秒租约到期后全轴停止')
        self.stop.set()
        self.snapshot['last_command'] = dict(motion_id=getattr(self, 'motion', 0), status='unknown',
            message='急停未获确认，已改用停止续租兜底')

    def action(self, action, data):
        """Submit explicit relative-zero absolute targets, never auto-home on errors."""
        with self.lock:
            if not self.serial:
                raise ValueError('请先连接 MCU')
            if action == 'read':
                self._read()
            elif action == 'zero':
                if self.zero_pending:
                    raise ValueError('姿态零位正在登记，请等待最终结果')
                seq, packet = self._packet(0x4a)
                self.serial.write(packet)
                self.zero_pending = dict(seq=seq, packet=packet, started=time.monotonic(), sent=time.monotonic())
                self.snapshot['zero_operation'] = dict(status='pending',
                    message='姿态零位登记中，约需 5 秒；正在等待 MCU 最终结果')
            elif action == 'stop':
                # The emergency stop must stay reachable in every state, including
                # a pending zero registration and a latched fault; the firmware
                # accepts `stop 3` without the motion interlock.
                self._submit_stop()
            elif action in ('move', 'home', 'gantry', 'confirm'):
                if self.zero_pending:
                    raise ValueError('姿态零位正在登记，请等待最终结果')
                self.snapshot.pop('zero_operation', None)
                if action == 'move':
                    pitch, yaw = self._gimbal_targets(data)
                    body = wire.move_body(self._next_motion(), wire.GIMBAL_MASK,
                                          (0, 0, 0, pitch, yaw))
                    self._submit_motion(0x46, body, '云台定位')
                elif action == 'gantry':
                    x, z, y, rpm = self._gantry_targets(data)
                    body = wire.move_body(self._next_motion(), wire.GANTRY_MASK,
                                          (x, z, y, 0, 0), (rpm, rpm, rpm, 0))
                    self._submit_motion(0x46, body, '龙门架定位')
                elif action == 'home':
                    self._submit_motion(0x48, wire.home_body(self._next_motion()),
                                        '云台回正')
                elif action == 'confirm':
                    self._submit_confirm()
            else:
                raise ValueError('未知 MCU 操作')
        return self.status()

    def close(self):
        """Revoke polling and close this owner only; disconnect stops lease renewal."""
        self.stop.set()
        if self.thread and self.thread is not threading.current_thread():
            self.thread.join(1)
        with self.lock:
            self._disconnect()
