#!/usr/bin/env python3
"""Failure-path checks using temporary files and loopback sockets only."""
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

binary = str(pathlib.Path(sys.argv[1]).resolve())

def run(*args):
    return subprocess.run([binary, *args], capture_output=True, text=True, timeout=10)

for options in (("--duration", "nan"), ("--video-port", "65536"),
                ("--demo", "--video"), ("--host", "not-an-address"),
                ("--headless", "--screenshot", "unused.png")):
    assert run(*options).returncode == 2, options

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as occupied:
    occupied.bind(("127.0.0.1", 0))
    port = str(occupied.getsockname()[1])
    result = run("--headless", "--listen", "--video-port", port, "--duration", "0.2")
    assert result.returncode == 2 and "Socket error" in result.stderr

with tempfile.TemporaryDirectory(prefix="parrotlab-errors-") as directory:
    path = pathlib.Path(directory) / "capture.h264"
    path.write_bytes(b"existing recording must survive")
    result = run("--headless", "--listen", "--video-port", port,
                 "--archive", str(path), "--duration", "0.2")
    assert result.returncode == 2 and "Cannot create archive" in result.stderr
    assert path.read_bytes() == b"existing recording must survive"

with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
    server.settimeout(5)
    errors = []
    def unsupported_video():
        try:
            connection, _ = server.accept()
            with connection:
                connection.recv(8192)
                connection.sendall(f"HTTP/1.1 200 OK\r\n\r\nm=video {port} RTP/AVP 96\r\n".encode())
                time.sleep(0.15)
                connection.sendall(b"a=rtpmap:96 JPEG/90000\r\n")
        except Exception as error:
            errors.append(error)
    worker = threading.Thread(target=unsupported_video)
    worker.start()
    result = run("--headless", "--video", "--host", "127.0.0.1", "--video-port", port,
                 "--restream-port", str(server.getsockname()[1]), "--duration", "3")
    worker.join(timeout=6)
    assert not errors, errors
    assert result.returncode == 1 and "No H.264 SDP" in result.stderr, result

print("PASS: invalid options, busy UDP port, archive preservation, split unsupported SDP")
