"""Optional integration check for the preserved loopback cleanup contract."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import subprocess
import tempfile
from threading import Thread


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("verifier", type=Path)
    parser.add_argument("speech_model", type=Path)
    args = parser.parse_args()
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, value):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(200, {"data": []})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body["model"] == "fixture" and body["temperature"] == 0
            assert body["max_tokens"] == 1024 and body["reasoning_effort"] == "none"
            text = body["messages"][-1]["content"]
            requests.append(text)
            if "original draft" in text:
                self.reply(503, {"error": "intentional fixture failure"})
                return
            if "not merge" in text:
                cleaned = "We should merge this branch today."
            elif "run the tests" in text:
                cleaned = "Please run the tests."
            else:
                cleaned = "Hello there."
            self.reply(200, {"choices": [{"message": {"content": cleaned}}]})

    first = ("we should not merge this branch today " * 6).strip() + "."
    cases = [
        {"id": "mixed-fallback", "source": first + " um please run the tests.", "replacements": []},
        {"id": "server-failure", "source": "keep our original draft today.", "replacements": []},
        {"id": "recovered", "source": "um hello there.", "replacements": []},
    ]
    server = HTTPServer(("127.0.0.1", 0), Handler)
    worker = Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="dictate-external-check-") as directory:
            config = Path(directory) / "config.toml"
            config.write_text("[speech]\nmodel = " + json.dumps(str(args.speech_model.resolve())) +
                              '\n[cleanup]\nurl = "http://localhost:' + str(server.server_port) +
                              '/v1"\nname = "fixture"\nreasoning_effort = "none"\n')
            fixture = Path(directory) / "cases.json"
            fixture.write_text(json.dumps({"cases": cases}))
            result = subprocess.run([str(args.verifier.resolve()), str(config), "--cleanup-fixtures", str(fixture)],
                                    capture_output=True, text=True, timeout=30, check=True)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
        outputs = {row["id"]: row for row in rows if row["event"] == "cleanup"}
        assert outputs["mixed-fallback"]["text"] == first + " Please run the tests."
        assert outputs["mixed-fallback"]["used"]
        assert outputs["server-failure"]["text"] == cases[1]["source"]
        assert not outputs["server-failure"]["used"]
        assert outputs["recovered"]["text"] == "Hello there." and outputs["recovered"]["used"]
        assert len(requests) == 4
        print(json.dumps({"passed": True, "requests": len(requests), "events": rows}, indent=2))
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)


if __name__ == "__main__":
    main()
