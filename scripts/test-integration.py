#!/usr/bin/env python3
"""Local SC2 emulator: split TCP replies, Telnet IAC, ARNetwork ACK/pong and RTP.

No real controller is contacted. Supply the compiled binary as the first arg.
With --desktop, also verify GTK/GStreamer decode and screenshot under Xvfb.
"""
import argparse
import contextlib
import json
import pathlib
import socket
import struct
import subprocess
import tempfile
import threading
import time


def frame(kind, buffer, sequence, payload):
    return struct.pack("<BBBI", kind, buffer, sequence, 7 + len(payload)) + payload


def tcp_server():
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen()
    server.settimeout(0.2)
    return server


def split_nals(data):
    import re
    return [n for n in re.split(b"\x00\x00\x00?\x01", data) if n]


def access_units(nals):
    units, current = [], []
    for nal in nals:
        if nal[0] & 31 == 9 and current:
            units.append(current)
            current = []
        current.append(nal)
    if current:
        units.append(current)
    return units


class Controller:
    def __init__(self, units):
        self.telnet, self.discovery, self.restream = [tcp_server() for _ in range(3)]
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(("127.0.0.1", 0))
        self.udp.settimeout(0.1)
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.bind(("127.0.0.1", 0))
        self.video_port = probe.getsockname()[1]
        probe.close()
        self.stop = threading.Event()
        self.video_ready = threading.Event()
        self.client = None
        self.acks, self.pongs, self.requests = 0, 0, set()
        self.units, self.errors, self.threads = units, [], []

    def launch(self, func):
        def worker():
            try:
                func()
            except Exception as error:
                if not self.stop.is_set():
                    self.errors.append(repr(error))
        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        self.threads.append(thread)

    def serve(self, server, action):
        while not self.stop.is_set():
            try:
                connection, _ = server.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(3)
                action(connection)

    def start(self):
        def telnet(connection):
            connection.recv(8192)
            connection.sendall(bytes([255, 251]))
            time.sleep(0.02)
            connection.sendall(bytes([1]))
            while not self.stop.wait(0.2):
                connection.sendall(b"rssi_mpp:-42, rssi:-48, state:LANDED, altitude:21.5, latitude:38.1, longitude:21.7, roll:0.1, pitch:-0.2, yaw:1.5\r\n")
        def discovery(connection):
            data = b""
            while True:
                data += connection.recv(8192)
                try:
                    request = json.loads(data)
                    break
                except json.JSONDecodeError:
                    continue
            self.client = ("127.0.0.1", request["d2c_port"])
            response = json.dumps({"status": 0, "c2d_port": self.udp.getsockname()[1]}).encode() + b"\0"
            for chunk in (response[:7], response[7:]):
                connection.sendall(chunk)
                time.sleep(0.04)
        def restream(connection):
            request = connection.recv(8192)
            assert b"GET /video HTTP/1.1" in request
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/sdp\r\n\r\n")
            time.sleep(0.1)
            connection.sendall(f"m=video {self.video_port} RTP/AVP 96\r\n".encode())
            time.sleep(0.1)
            connection.sendall(b"a=rtpmap:96 H264/90000\r\n")
            self.video_ready.set()
        self.launch(lambda: self.serve(self.telnet, telnet))
        self.launch(lambda: self.serve(self.discovery, discovery))
        self.launch(lambda: self.serve(self.restream, restream))
        self.launch(self.telemetry)
        self.launch(self.video)

    def telemetry(self):
        seq, previous = 0, 0
        while not self.stop.is_set():
            if self.client and time.monotonic() - previous > 0.2:
                previous = time.monotonic()
                seq = (seq + 1) % 256
                self.udp.sendto(frame(4, 126, seq, bytes([0, 5, 1, 0, 74])) +
                                frame(2, 0, seq, b"pingtest"), self.client)
            try:
                data, peer = self.udp.recvfrom(65536)
            except socket.timeout:
                continue
            kind, buffer, sequence, size = struct.unpack_from("<BBBI", data)
            assert size == len(data)
            if kind == 4 and buffer == 11:
                self.requests.add(data[7:])
                self.udp.sendto(frame(1, 139, sequence, bytes([sequence])), peer)
            if kind == 1 and buffer == 254:
                self.acks += 1
            if kind == 2 and buffer == 1 and data[7:] == b"pingtest":
                self.pongs += 1

    def video(self):
        while not self.video_ready.wait(0.1):
            if self.stop.is_set():
                return
        time.sleep(0.25)
        seq, timestamp = 65530, 0xffff0000
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            while not self.stop.is_set():
                for unit in self.units:
                    for index, nal in enumerate(unit):
                        if len(nal) <= 1000:
                            packets = [nal]
                        else:
                            chunks = [nal[n:n + 998] for n in range(1, len(nal), 998)]
                            packets = [bytes([(nal[0] & 0xe0) | 28, (nal[0] & 31) |
                                       (0x80 if n == 0 else 0) | (0x40 if n == len(chunks) - 1 else 0)]) + chunk
                                       for n, chunk in enumerate(chunks)]
                        for fragment_index, payload in enumerate(packets):
                            marker = index == len(unit) - 1 and fragment_index == len(packets) - 1
                            header = struct.pack("!BBHII", 0x80, 96 | (0x80 if marker else 0), seq, timestamp, 1)
                            udp.sendto(header + payload, ("127.0.0.1", self.video_port))
                            seq = (seq + 1) % 65536
                    timestamp = (timestamp + 3000) % (1 << 32)
                    if self.stop.wait(1 / 30):
                        return

    def close(self):
        self.stop.set()
        for thread in self.threads:
            thread.join(timeout=3)
        for sock in (self.telnet, self.discovery, self.restream, self.udp):
            sock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--desktop", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    with tempfile.TemporaryDirectory(prefix="parrotlab-integration-") as temp:
        directory = pathlib.Path(temp)
        if args.desktop:
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                "testsrc2=size=640x360:rate=30", "-t", "1", "-c:v", "libx264", "-preset", "ultrafast",
                "-tune", "zerolatency", "-x264-params", "aud=1:keyint=30:repeat-headers=1", "-f", "h264", str(directory / "source.h264")], check=True)
            units = access_units(split_nals((directory / "source.h264").read_bytes()))
        else:
            units = [[b"\x65\x01\x02\x03"]]
        controller = Controller(units)
        controller.start()
        archive = directory / "capture.h264"
        screenshot = args.output or directory / "desktop.png"
        command = [binary, "--host", "127.0.0.1", "--connect", "--video", "--duration", "5",
            "--telnet-port", str(controller.telnet.getsockname()[1]),
            "--discovery-port", str(controller.discovery.getsockname()[1]),
            "--restream-port", str(controller.restream.getsockname()[1]),
            "--video-port", str(controller.video_port), "--archive", str(archive)]
        if args.desktop:
            command = ["xvfb-run", "-a", "-s", "-screen 0 1280x900x24",
                       "env", "GSK_RENDERER=cairo", "GDK_BACKEND=x11"] + command + ["--screenshot", str(screenshot)]
        else:
            command += ["--headless"]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        finally:
            controller.close()
        print(result.stdout)
        if result.returncode:
            print(result.stderr)
            print("Emulator errors:", controller.errors)
        assert result.returncode == 0, result.stderr
        assert controller.acks >= 2, "No telemetry acknowledgements"
        assert controller.pongs >= 2, "No ping replies"
        assert {bytes([0, 4, 0, 0]), bytes([4, 6, 0, 0])} <= controller.requests
        assert archive.exists() and archive.stat().st_size > 0, "No H.264 archived"
        if args.desktop:
            assert screenshot.exists() and screenshot.stat().st_size > 10000
            import re
            match = re.search(r"Displayed frames: (\d+)", result.stdout)
            assert match and int(match[1]) >= 30, "Video did not decode/present"
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(archive), "-f", "null", "-"], check=True)
        else:
            assert "74%" in result.stdout and "21.5 m" in result.stdout, "Telemetry was not reduced"
            expected = b"\0\0\0\1\x65\1\2\3"
            content = archive.read_bytes()
            assert content == expected * (len(content) // len(expected)), "Archive changed NAL bytes"
        print(f"PASS: discovery, Telnet, state requests, {controller.acks} ACKs, {controller.pongs} pongs, RTP, archive" +
              (", GTK screenshot and H.264 decode" if args.desktop else ""))


if __name__ == "__main__":
    main()
