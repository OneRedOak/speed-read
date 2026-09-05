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


@unittest.skipUnless(
    importlib.util.find_spec("numpy"), "numpy not installed"
)
class TrimEdgeSilenceTests(unittest.TestCase):
    SAMPLE_RATE = 24000

    def _segment(self, lead_s, speech_s, trail_s):
        import numpy as np

        lead = np.zeros(int(lead_s * self.SAMPLE_RATE), dtype=np.float32)
        speech = np.full(int(speech_s * self.SAMPLE_RATE), 0.5, dtype=np.float32)
        trail = np.zeros(int(trail_s * self.SAMPLE_RATE), dtype=np.float32)
        return np.concatenate([lead, speech, trail])

    def test_trims_edges_keeping_pad(self):
        audio = self._segment(0.4, 1.0, 0.6)
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        expected = (1.0 + 2 * server.TRIM_PAD_SECONDS) * self.SAMPLE_RATE
        self.assertAlmostEqual(trimmed.size, expected, delta=2)

    def test_short_edges_left_alone(self):
        audio = self._segment(0.02, 1.0, 0.02)
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        self.assertEqual(trimmed.size, audio.size)

    def test_all_silent_segment_untouched(self):
        import numpy as np

        audio = np.zeros(6000, dtype=np.float32)
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        self.assertEqual(trimmed.size, 6000)

    def test_empty_segment_untouched(self):
        import numpy as np

        audio = np.zeros(0, dtype=np.float32)
        self.assertEqual(server._trim_edge_silence(audio, self.SAMPLE_RATE).size, 0)

    def test_quiet_speech_trims_relative_to_peak(self):
        audio = self._segment(0.4, 1.0, 0.6) * 0.01
        trimmed = server._trim_edge_silence(audio, self.SAMPLE_RATE)
        expected = (1.0 + 2 * server.TRIM_PAD_SECONDS) * self.SAMPLE_RATE
        self.assertAlmostEqual(trimmed.size, expected, delta=2)


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


class OutputVersionTests(unittest.TestCase):
    def test_successful_response_identifies_live_output_semantics(self):
        import json
        import tempfile
        from unittest.mock import patch, Mock

        conn = Mock()
        request = json.dumps({"token": "test", "text": "test", "voice": "bf_lily"}).encode()
        with tempfile.NamedTemporaryFile() as audio:
            audio.write(b"audio")
            audio.flush()
            with patch.object(server, "AUTH_TOKEN", "test"), \
                    patch.object(server, "_read_request_line", return_value=request), \
                    patch.object(server, "_client_gone", return_value=False), \
                    patch.object(server, "generate_audio", return_value=audio.name), \
                    patch.object(server, "_release_model_scratch"), patch.object(server, "log"):
                server.handle_client(conn)
        response = json.loads(conn.sendall.call_args.args[0])
        self.assertEqual(response["status"], "ok")
        self.assertEqual(response["output_version"], "kokoro-82M-t2")


class GenerationFailureTests(unittest.TestCase):
    def test_exhausted_workarounds_fail_instead_of_returning_silence(self):
        import sys
        from unittest.mock import patch, Mock

        model = Mock()
        model.generate.side_effect = ValueError("[broadcast_shapes] secret text")
        # This path must raise before any array operations, so it can be
        # verified without downloading numpy or the actual voice model.
        with patch.object(server, "model", model), patch.object(server, "log"), \
                patch.dict(sys.modules, {"numpy": Mock()}):
            with self.assertRaisesRegex(RuntimeError, "^local synthesis workaround exhausted$"):
                server._generate_segments("fragment", "bf_lily", 1, "b", None)
        self.assertEqual(model.generate.call_count, 4)

    def test_unrelated_model_errors_are_not_retried(self):
        import sys
        from unittest.mock import patch, Mock

        model = Mock()
        model.generate.side_effect = ValueError("unrelated")
        with patch.object(server, "model", model), \
                patch.dict(sys.modules, {"numpy": Mock()}):
            with self.assertRaises(ValueError):
                server._generate_segments("fragment", "bf_lily", 1, "b", None)
        self.assertEqual(model.generate.call_count, 1)


if __name__ == "__main__":
    unittest.main()
