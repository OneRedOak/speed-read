import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "sr_tts_server", ROOT / "daemon" / "sr_tts_server.py"
)
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


class FakeConnection:
    def __init__(self, chunks):
        self.chunks = list(chunks)
        self.timeout = None

    def settimeout(self, timeout):
        self.timeout = timeout

    def recv(self, _size):
        return self.chunks.pop(0) if self.chunks else b""


class RequestReaderTests(unittest.TestCase):
    def test_rejects_oversized_line_even_when_newline_arrives_with_it(self):
        conn = FakeConnection([b"x" * (server.MAX_REQUEST_BYTES + 1) + b"\n"])
        with self.assertRaises(server.RequestTooLarge):
            server._read_request_line(conn)

    def test_returns_only_first_request_line(self):
        conn = FakeConnection([b'{"token":"a"}\nignored'])
        self.assertEqual(server._read_request_line(conn), b'{"token":"a"}')


class IdleWatchdogTests(unittest.TestCase):
    def test_active_client_blocks_idle_exit(self):
        original_time = server.last_request_time
        original_active = server.active_clients
        try:
            server.last_request_time = 0
            server.active_clients = 1
            should_exit, _, active = server._idle_state(server.IDLE_TIMEOUT + 1)
            self.assertFalse(should_exit)
            self.assertEqual(active, 1)

            server.active_clients = 0
            should_exit, _, _ = server._idle_state(server.IDLE_TIMEOUT + 1)
            self.assertTrue(should_exit)
        finally:
            server.last_request_time = original_time
            server.active_clients = original_active


if __name__ == "__main__":
    unittest.main()
