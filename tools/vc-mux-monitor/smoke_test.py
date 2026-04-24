#!/usr/bin/env python3
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def frame(payload: dict) -> bytes:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body


def run_mock_mux(socket_path: str) -> None:
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(socket_path)
        server.listen(1)
        conn, _ = server.accept()
        with conn:
            time.sleep(0.15)
            conn.sendall(
                frame(
                    {
                        "jsonrpc": "2.0",
                        "method": "notifications/message",
                        "params": {"level": "info", "data": "vc-mux routed"},
                    }
                )
            )
            time.sleep(0.05)


def wait_for_socket(socket_path: str) -> bool:
    deadline = time.time() + 3
    while not os.path.exists(socket_path):
        if time.time() > deadline:
            return False
        time.sleep(0.01)
    return True


def run_direct_monitor_smoke(monitor: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="vc-mux-monitor-") as tmp:
        socket_path = str(Path(tmp) / "mux.sock")
        thread = threading.Thread(target=run_mock_mux, args=(socket_path,), daemon=True)
        thread.start()

        if not wait_for_socket(socket_path):
            print("mock mux did not create socket", file=sys.stderr)
            return 1

        result = run_monitor(monitor, socket_path)
        return validate_monitor_output(result, "notifications/message")


def run_vc_mux_smoke(monitor: Path, mux: Path, mock_server: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="vc-mux-monitor-") as tmp:
        socket_path = str(Path(tmp) / "mux.sock")
        mux_process = subprocess.Popen(
            [
                str(mux),
                "--socket",
                socket_path,
                "--max-active-clients",
                "8",
                "--cmd",
                str(mock_server),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        try:
            if not wait_for_socket(socket_path):
                print("vc-mux did not create socket", file=sys.stderr)
                return 1

            monitor_process = subprocess.Popen(
                [
                    str(monitor),
                    "--socket",
                    socket_path,
                    "--headless",
                    "--once",
                    "--timeout",
                    "5",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            ready, _, _ = select.select([monitor_process.stdout], [], [], 5)
            if not ready:
                monitor_process.kill()
                stdout, stderr = monitor_process.communicate()
                print(stdout, end="")
                print(stderr, end="", file=sys.stderr)
                print("monitor did not connect before timeout", file=sys.stderr)
                return 1
            first_line = monitor_process.stdout.readline()
            time.sleep(0.15)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as trigger:
                trigger.connect(socket_path)
                trigger.sendall(
                    frame(
                        {
                            "jsonrpc": "2.0",
                            "id": 7,
                            "method": "fanout",
                            "params": {},
                        }
                    )
                )
                trigger.recv(4096)

            stdout, stderr = monitor_process.communicate(timeout=6)
            result = subprocess.CompletedProcess(
                monitor_process.args,
                monitor_process.returncode,
                first_line + stdout,
                stderr,
            )
            return validate_monitor_output(result, "server/notice")
        finally:
            mux_process.terminate()
            try:
                mux_process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                mux_process.kill()
                mux_process.communicate()


def run_monitor(monitor: Path, socket_path: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(monitor),
            "--socket",
            socket_path,
            "--headless",
            "--once",
            "--timeout",
            "3",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def validate_monitor_output(result: subprocess.CompletedProcess[str], expected_method: str) -> int:
    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return result.returncode

    events = []
    for line in result.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass

    if not any(event.get("state") == "active" for event in events):
        print(result.stdout, end="")
        print("monitor did not report active state", file=sys.stderr)
        return 1

    if not any(event.get("method") == expected_method for event in events):
        print(result.stdout, end="")
        print(f"monitor did not report notification method {expected_method}", file=sys.stderr)
        return 1

    print(result.stdout, end="")
    return 0


def main() -> int:
    if len(sys.argv) not in (2, 4):
        print(
            "usage: smoke_test.py <path-to-vc-mux-monitor> [<path-to-vc-mux> <path-to-vc-mux-mock-server>]",
            file=sys.stderr,
        )
        return 2

    monitor = Path(sys.argv[1])
    if not monitor.exists():
        print(f"monitor binary does not exist: {monitor}", file=sys.stderr)
        return 2

    if len(sys.argv) == 4:
        mux = Path(sys.argv[2])
        mock_server = Path(sys.argv[3])
        if not mux.exists():
            print(f"vc-mux binary does not exist: {mux}", file=sys.stderr)
            return 2
        if not mock_server.exists():
            print(f"mock server binary does not exist: {mock_server}", file=sys.stderr)
            return 2
        return run_vc_mux_smoke(monitor, mux, mock_server)

    return run_direct_monitor_smoke(monitor)


if __name__ == "__main__":
    raise SystemExit(main())
