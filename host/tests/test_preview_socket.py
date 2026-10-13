"""RFC framing, allocation bounds and masked credit controls without hardware."""
import io
from struct import pack
import unittest

from pango_video.preview_socket import accept_key, read_message, write_message, Duplex, SocketProtocolError


def masked(payload, opcode=1, fin=True):
    """Fixture client frames use a deterministic four-byte mask."""
    mask=b"abcd";count=len(payload)
    header=bytes(((0x80 if fin else 0)|opcode,0x80|count)) if count<126 else bytes(((0x80 if fin else 0)|opcode,0xfe))+pack("!H",count)
    return header+mask+bytes(value^mask[i%4] for i,value in enumerate(payload))


class SocketTests(unittest.TestCase):
    def test_rfc_handshake_known_vector_and_bad_key(self):
        headers={"Upgrade":"websocket","Connection":"keep-alive, Upgrade", "Sec-WebSocket-Version":"13",
                 "Sec-WebSocket-Key":"dGhlIHNhbXBsZSBub25jZQ=="}
        self.assertEqual(accept_key(headers),"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        for changed in ({"Sec-WebSocket-Key":"bad"},{"Sec-WebSocket-Version":"12"},{"Connection":"close"}):
            with self.assertRaises(SocketProtocolError):accept_key(dict(headers,**changed))

    def test_fragments_with_ping_and_close_do_not_corrupt_credit(self):
        reader=io.BytesIO(masked(b"{",fin=False)+masked(b"ping",opcode=9)+masked(b"}",opcode=0))
        writer=io.BytesIO()
        self.assertEqual(read_message(Duplex(reader,writer)),"{}")
        self.assertEqual(writer.getvalue(),b"\x8a\x04ping")
        writer=io.BytesIO()
        self.assertIsNone(read_message(Duplex(io.BytesIO(masked(b"",opcode=8)),writer)))
        self.assertEqual(writer.getvalue(),b"\x88\x00")

    def test_unmasked_oversized_truncated_and_bad_continuation_rejected(self):
        for payload in (b"\x81\x02{}",masked(b"a"*4097),masked(b"x",opcode=0),
                        masked(b"x",opcode=9,fin=False),masked(b"\xff")):
            with self.assertRaises((SocketProtocolError,UnicodeDecodeError)):
                read_message(Duplex(io.BytesIO(payload),io.BytesIO()))
        with self.assertRaises(EOFError):read_message(Duplex(io.BytesIO(masked(b"x")[:-1]),io.BytesIO()))

    def test_output_lengths_are_complete_and_unmasked(self):
        for size,head in ((2,b"\x82\x02"),(126,b"\x82\x7e\x00\x7e"),(65536,b"\x82\x7f"+pack("!Q",65536))):
            stream=io.BytesIO();write_message(stream,2,b"a"*size)
            self.assertEqual(stream.getvalue(),head+b"a"*size)
