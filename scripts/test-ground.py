#!/usr/bin/env python3
"""Loopback Sumo, including Qt keyboard input on a private virtual display."""
import argparse
import ctypes
import importlib.util
import json
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

spec = importlib.util.spec_from_file_location("air_test", pathlib.Path(__file__).with_name("test-integration.py"))
air = importlib.util.module_from_spec(spec)
spec.loader.exec_module(air)

class Sumo(air.Controller):
    def __init__(self, jpeg, no_ack=False):
        super().__init__([])
        self.jpeg, self.no_ack = jpeg, no_ack
        self.commands, self.video_acks = [], 0
        self.ready = threading.Event()
        self.last_video_enabled = False
        self.product = None
        self.pause_telemetry = False
    def start(self):
        def discover(connection):
            data = b""
            while True:
                piece = connection.recv(8192)
                assert piece, "Discovery peer closed"
                data += piece
                try:
                    request = json.loads(data)
                    break
                except json.JSONDecodeError:
                    continue
            self.client = ("127.0.0.1", request["d2c_port"])
            response = json.dumps({"status": 0, "c2d_port": self.udp.getsockname()[1],
                "arstream_fragment_size": 1000, "arstream_fragment_maximum_number": 128,
                "arstream_max_ack_interval": -1 if self.no_ack else 10}).encode() + b"\0"
            connection.sendall(response[:8]); time.sleep(0.02); connection.sendall(response[8:])
        self.launch(lambda: self.serve(self.discovery, discover))
        self.launch(self.telemetry)
        self.launch(self.video)
    def telemetry(self):
        seq, previous = 0, 0
        while not self.stop.is_set():
            if self.client and not self.pause_telemetry and time.monotonic() - previous > 0.2:
                previous = time.monotonic(); seq = (seq + 1) % 256
                self.udp.sendto(air.frame(4, 126, seq, bytes([0, 5, 1, 0, 74])) +
                                air.frame(2, 127, seq, bytes([3, 11, 4, 0, 5])) +
                                air.frame(2, 0, seq, b"pingtest"), self.client)
                if self.product is not None:
                    self.udp.sendto(air.frame(2, 127, (seq + 128) % 256,
                        bytes([4, 3, 1, 0]) + struct.pack("<I", 2) + b"Test product\0" + struct.pack("<H", self.product)), self.client)
            try:
                data, peer = self.udp.recvfrom(65536)
            except socket.timeout:
                continue
            kind, buffer, sequence, size = struct.unpack_from("<BBBI", data)
            assert size == len(data)
            payload = data[7:]
            if kind == 4 and buffer == 11:
                self.requests.add(payload)
                self.udp.sendto(air.frame(1, 139, sequence, bytes([sequence])), peer)
                if payload[:4] == bytes([3, 18, 0, 0]):
                    self.last_video_enabled = bool(payload[4])
                    if payload[4]: self.video_ready.set()
                self.ready.set()
            if kind == 2 and buffer == 10:
                assert len(payload) == 7 and payload[:4] == bytes([3, 0, 0, 0]), payload
                flag, speed, turn = struct.unpack("Bbb", payload[4:])
                assert max(abs(speed), abs(turn)) <= 30
                assert bool(flag) == bool(speed or turn)
                self.commands.append((time.monotonic(), speed, turn))
            if kind == 2 and buffer == 13:
                assert len(payload) == 18
                self.video_acks += 1
            if kind == 1 and buffer == 254: self.acks += 1
            if kind == 2 and buffer == 1: self.pongs += 1
    def video(self):
        number, sequence = 65534, 0
        while not self.stop.is_set():
            if not self.video_ready.wait(0.1): continue
            pieces = [self.jpeg[i:i+1000] for i in range(0, len(self.jpeg), 1000)]
            order = list(range(len(pieces)))
            if len(order) > 1: order[0], order[1] = order[1], order[0]
            for i in order:
                sequence = (sequence + 1) % 256
                payload = struct.pack("<HBBB", number, 0, i, len(pieces)) + pieces[i]
                self.udp.sendto(air.frame(3, 125, sequence, payload), self.client)
            number = (number + 1) % 65536
            self.stop.wait(1 / 20)

class Keyboard:
    def __init__(self):
        self.x = ctypes.CDLL("libX11.so.6")
        self.xt = ctypes.CDLL("libXtst.so.6")
        self.x.XOpenDisplay.argtypes = [ctypes.c_char_p]; self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.display = self.x.XOpenDisplay(None)
        assert self.display
        self.x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]; self.x.XDefaultRootWindow.restype = ctypes.c_ulong
        self.root = self.x.XDefaultRootWindow(self.display)
        self.x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
            ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
        self.x.XCreateSimpleWindow.restype = ctypes.c_ulong
        self.x.XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x.XDestroyWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.other = self.x.XCreateSimpleWindow(self.display, self.root, 1250, 0, 100, 100, 0, 0, 0)
        self.x.XMapWindow(self.display, self.other)
        self.x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
        self.x.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
        self.x.XFree.argtypes = [ctypes.c_void_p]
        self.x.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        self.x.XFlush.argtypes = [ctypes.c_void_p]
        self.x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]; self.x.XKeysymToKeycode.restype = ctypes.c_uint
        self.xt.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.xt.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        self.xt.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.x.XTranslateCoordinates.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
            ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong)]
        self.x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.window = None
        for _ in range(30):
            root, parent, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_uint()
            children = ctypes.POINTER(ctypes.c_ulong)()
            self.x.XQueryTree(self.display, self.root, ctypes.byref(root), ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
            for i in range(count.value):
                name = ctypes.c_char_p()
                if self.x.XFetchName(self.display, children[i], ctypes.byref(name)) and name.value:
                    # Qt also creates a hidden selection-owner window named after
                    # the application. Focus only the actual visible main window.
                    if name.value in ("Parrot Lab · Linux".encode(), "Parrot Lab · Linux".encode("latin-1")):
                        self.window = children[i]
                    self.x.XFree(name)
            if children: self.x.XFree(children)
            if self.window: break
            time.sleep(0.1)
        assert self.window, "No Parrot Lab window"
        self.focus(self.window)
    def focus(self, window):
        self.x.XSetInputFocus(self.display, window, 1, 0); self.x.XFlush(self.display); time.sleep(0.15)
    def key(self, symbol, down):
        code = self.x.XKeysymToKeycode(self.display, symbol)
        self.xt.XTestFakeKeyEvent(self.display, code, int(down), 0); self.x.XFlush(self.display)
    def tap(self, symbol):
        self.key(symbol, True); time.sleep(0.04); self.key(symbol, False); time.sleep(0.15)
    def mouse(self, x, y, down):
        root_x, root_y, child = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
        self.x.XTranslateCoordinates(self.display, self.window, self.root, x, y,
            ctypes.byref(root_x), ctypes.byref(root_y), ctypes.byref(child))
        self.xt.XTestFakeMotionEvent(self.display, -1, root_x.value, root_y.value, 0)
        self.xt.XTestFakeButtonEvent(self.display, 1, int(down), 0); self.x.XFlush(self.display)
    def close(self):
        self.x.XDestroyWindow(self.display, self.other)
        self.x.XCloseDisplay(self.display)
    def close_window(self):
        class Data(ctypes.Union):
            _fields_ = [("b", ctypes.c_char * 20), ("s", ctypes.c_short * 10), ("l", ctypes.c_long * 5)]
        class ClientMessage(ctypes.Structure):
            _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", Data)]
        class Event(ctypes.Union):
            _fields_ = [("client", ClientMessage), ("padding", ctypes.c_long * 24)]
        self.x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        self.x.XInternAtom.restype = ctypes.c_ulong
        self.x.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(Event)]
        event = Event(); event.client.type = 33; event.client.display = self.display
        event.client.window = self.window; event.client.format = 32
        event.client.message_type = self.x.XInternAtom(self.display, b"WM_PROTOCOLS", 0)
        event.client.data.l[0] = self.x.XInternAtom(self.display, b"WM_DELETE_WINDOW", 0)
        self.x.XSendEvent(self.display, self.window, 0, 0, ctypes.byref(event)); self.x.XFlush(self.display)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--desktop", action="store_true")
    parser.add_argument("--no-video-ack", action="store_true")
    parser.add_argument("--sc2-controls", action="store_true")
    parser.add_argument("--window-close", action="store_true")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if args.desktop and not os.environ.get("DISPLAY"):
        os.execvp("xvfb-run", ["xvfb-run", "-a", "-s", "-screen 0 1440x1000x24", "env",
                  "QT_QPA_PLATFORM=xcb", "QT_STYLE_OVERRIDE=Fusion", sys.executable, *sys.argv])
    if args.sc2_controls:
        assert args.desktop, "--sc2-controls requires --desktop"
        test_sc2_controls(args.binary)
        return
    with tempfile.TemporaryDirectory(prefix="parrotlab-sumo-") as temp:
        directory = pathlib.Path(temp)
        if args.desktop:
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x480",
                "-frames:v", "1", "-c:v", "mjpeg", "-threads", "1", "-q:v", "5", str(directory / "source.jpg")], check=True)
            jpeg = (directory / "source.jpg").read_bytes()
        else: jpeg = b"\xff\xd8example\xff\xd9"
        sumo = Sumo(jpeg, args.no_video_ack); sumo.start()
        archive = directory / "capture.mjpeg"
        screenshot = args.output or directory / "ground.png"
        command = [str(args.binary.resolve()), "--ground", "--host", "127.0.0.1", "--connect", "--video",
                   "--discovery-port", str(sumo.discovery.getsockname()[1]), "--archive", str(archive),
                   "--media-dir", str(directory),
                   "--duration", "12" if args.desktop else "3"]
        command += ["--screenshot", str(screenshot)] if args.desktop else ["--headless"]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert sumo.ready.wait(5)
            if args.desktop:
                time.sleep(0.5)
                keyboard = Keyboard()
                def recent_neutral():
                    assert sumo.commands and sumo.commands[-1][1:] == (0, 0), sumo.commands[-5:]
                    cutoff = time.monotonic() - 0.2
                    assert all(c[1:] == (0, 0) for c in sumo.commands if c[0] > cutoff)
                assert not sumo.commands, "Unarmed viewer must not take drive authority"
                keyboard.tap(0xffc3) # F6: arm
                keyboard.key(ord('w'), True); time.sleep(0.4)
                assert any(c[1] == 30 for c in sumo.commands), "Forward input not sent"
                keyboard.key(ord('w'), False); time.sleep(0.35); recent_neutral()
                # Save the actual decoded image through the visible Qt button,
                # not a screenshot or a direct call to the bridge.
                keyboard.mouse(670, 115, True); time.sleep(0.04)
                keyboard.mouse(670, 115, False); time.sleep(0.2)
                snapshots = [p for p in directory.glob("*.png") if p != screenshot]
                assert len(snapshots) == 1, "Save PNG button did not create a frame capture"
                dimensions = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                    "-show_entries", "stream=width,height", "-of", "csv=p=0", str(snapshots[0])], text=True).strip()
                assert dimensions == "640,480", dimensions
                keyboard.mouse(260, 175, True); time.sleep(0.35)
                assert sumo.commands[-1][1] == 30, "On-screen forward hold did not drive"
                keyboard.mouse(10, 10, False); time.sleep(0.35); recent_neutral()
                keyboard.key(ord('a'), True); time.sleep(0.35)
                assert any(c[2] == -30 for c in sumo.commands), "Turn input not sent"
                keyboard.tap(0x20); time.sleep(0.3); recent_neutral() # stop while A held
                keyboard.key(ord('a'), False)
                keyboard.tap(0xffc3); keyboard.key(ord('w'), True); time.sleep(0.3)
                keyboard.focus(keyboard.other); time.sleep(0.3); recent_neutral()
                keyboard.focus(keyboard.window); time.sleep(0.3); recent_neutral() # no auto-arm
                keyboard.key(ord('w'), False)
                keyboard.tap(0xffc3); keyboard.key(ord('w'), True); time.sleep(0.3)
                assert sumo.commands[-1][1] == 30
                sumo.pause_telemetry = True; time.sleep(1.35); recent_neutral()
                sumo.pause_telemetry = False; time.sleep(0.4); recent_neutral()
                keyboard.key(ord('w'), False)
                keyboard.tap(0xffc3); keyboard.key(ord('w'), True); time.sleep(0.3)
                assert sumo.commands[-1][1] == 30
                # Exercise both normal window closing and signal-driven shutdown.
                if args.window_close: keyboard.close_window()
                else: process.terminate()
                keyboard.key(ord('w'), False); keyboard.close()
            # Window close must actually exit, not merely wait for --duration.
            output, error = process.communicate(timeout=2 if args.window_close else 16)
            print(output)
            assert process.returncode == 0, error
            time.sleep(0.1)
            if args.desktop: assert sumo.commands and sumo.commands[-1][1:] == (0, 0)
            else: assert not sumo.commands, "Headless mode sent drive commands"
            assert bytes([0, 4, 0, 0]) in sumo.requests
            assert bytes([4, 6, 0, 0]) not in sumo.requests
            assert bytes([3, 18, 0, 0, 1]) in sumo.requests
            assert not sumo.last_video_enabled
            assert sumo.acks >= 2 and sumo.pongs >= 2
            assert sumo.video_acks == 0 if args.no_video_ack else sumo.video_acks >= 2
            saved = archive.read_bytes()
            assert saved and saved == jpeg * (len(saved) // len(jpeg))
            if args.desktop:
                assert screenshot.stat().st_size > 10000, error
                import re
                match = re.search(r"Displayed frames: (\d+)", output)
                assert match and int(match[1]) >= 30
                subprocess.run(["ffmpeg", "-v", "error", "-f", "mjpeg", "-i", str(archive), "-f", "null", "-"], check=True)
            assert not sumo.errors, sumo.errors
            print("PASS: Sumo discovery, telemetry, MJPEG, video ACK negotiation, archive, neutral shutdown" +
                  (", keyboard/mouse drive, release/stop/focus-loss/stale-link, Qt desktop/frame PNG capture" if args.desktop else ", no headless motion"))
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=5)
            sumo.close()

def test_sc2_controls(binary):
    sumo = Sumo(b""); sumo.start()
    process = subprocess.Popen([str(binary.resolve()), "--ground-sc2", "--host", "127.0.0.1", "--connect",
        "--discovery-port", str(sumo.discovery.getsockname()[1]), "--duration", "10"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    keyboard = None
    try:
        assert sumo.ready.wait(5); time.sleep(0.4)
        keyboard = Keyboard()
        keyboard.tap(0xffc3); keyboard.key(ord('w'), True); time.sleep(0.3)
        assert not sumo.commands, "SC2 allowed drive before identifying a Sumo"
        keyboard.key(ord('w'), False)
        sumo.product = 0x0902; time.sleep(0.4)
        keyboard.tap(0xffc3); keyboard.key(ord('w'), True); time.sleep(0.35)
        assert sumo.commands and sumo.commands[-1][1] == 30, "Confirmed Sumo did not drive"
        sumo.product = 0x090c; time.sleep(0.5)
        assert sumo.commands[-1][1:] == (0, 0), "Changing SC2 product did not stop drive"
        sumo.product = 0x0902; time.sleep(0.5)
        assert sumo.commands[-1][1:] == (0, 0), "Product reconnect automatically re-armed"
        keyboard.key(ord('w'), False)
        assert bytes([4, 6, 0, 0]) in sumo.requests
        assert not any(p[:4] == bytes([3, 18, 0, 0]) for p in sumo.requests), "SC2 used direct Sumo video path"
        process.terminate(); output, error = process.communicate(timeout=5)
        assert process.returncode == 0, error
        print(output)
        print("PASS: SC2 product-confirmation gate, ground commands, stop on product change, no automatic re-arm")
    finally:
        if keyboard: keyboard.close()
        if process.poll() is None: process.terminate(); process.communicate(timeout=5)
        sumo.close()

if __name__ == "__main__": main()
