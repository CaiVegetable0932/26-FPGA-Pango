"""Small loopback WebSocket credit channel; no extensions or video relay."""
import base64
import hashlib
from struct import pack, unpack


class SocketProtocolError(ValueError):
    pass


def accept_key(headers):
    """Validate the RFC 6455 handshake before upgrading the HTTP connection."""
    if headers.get("Upgrade", "").lower() != "websocket" or "upgrade" not in {
            token.strip().lower() for token in headers.get("Connection", "").split(",")}:
        raise SocketProtocolError("invalid WebSocket upgrade")
    if headers.get("Sec-WebSocket-Version") != "13":
        raise SocketProtocolError("unsupported WebSocket version")
    key = headers.get("Sec-WebSocket-Key", "")
    try:
        if len(base64.b64decode(key, validate=True)) != 16:
            raise ValueError()
    except ValueError as error:
        raise SocketProtocolError("invalid WebSocket key") from error
    return base64.b64encode(hashlib.sha1((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()).decode()


def write_message(stream, opcode, payload=b""):
    """Server frames are unmasked and complete; do not cut a preview mid-frame."""
    size = len(payload)
    header = bytes((0x80|opcode,size)) if size<126 else bytes((0x80|opcode,126))+pack("!H",size) if size<=65535 else bytes((0x80|opcode,127))+pack("!Q",size)
    stream.write(header)
    stream.write(payload)


def read_message(stream, limit=4096):
    """Require masking, bound allocation and support small fragmented credits."""
    def exact(size):
        value=stream.read(size)
        if len(value)!=size:
            raise EOFError("WebSocket closed during message")
        return value
    parts=[];size=0;started=False
    while True:
        first, second = exact(2)
        fin, opcode = bool(first&0x80), first&15
        if first&0x70 or not second&0x80:
            raise SocketProtocolError("WebSocket extensions/unmasked input rejected")
        count=second&127
        if count==126:
            count=unpack("!H",exact(2))[0]
            if count<126:
                raise SocketProtocolError("noncanonical frame length")
        elif count==127:
            count=unpack("!Q",exact(8))[0]
            if count<65536 or count>>63:
                raise SocketProtocolError("invalid 64-bit frame length")
        if opcode>=8:
            if not fin or count>125 or opcode not in (8,9,10):
                raise SocketProtocolError("invalid control frame")
        elif opcode not in (0,1) or (opcode==0)!=started or size+count>limit or len(parts)>=128:
            raise SocketProtocolError("invalid or oversized preview credit")
        mask=exact(4);payload=bytes(value^mask[i%4] for i,value in enumerate(exact(count)))
        if opcode==8:
            if len(payload)==1:
                raise SocketProtocolError("invalid close payload")
            write_message(stream=stream,opcode=8,payload=payload)
            return None
        if opcode==9:
            # HTTP handlers pass a duplex adapter so pong uses the write side.
            write_message(stream,10,payload);continue
        if opcode==10:
            continue
        parts.append(payload);size+=count;started=True
        if fin:
            return b"".join(parts).decode("utf-8",errors="strict")


class Duplex:
    """Use the existing buffered HTTP reader and unbuffered socket writer."""
    def __init__(self, reader, writer):
        self.reader,self.writer=reader,writer
    def read(self, size):
        return self.reader.read(size)
    def write(self, value):
        return self.writer.write(value)
