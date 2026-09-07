#!/usr/bin/env python3
"""Verify the visible air → direct Sumo → SC2 Sumo → air palette on Xvfb."""
import ctypes
import importlib.util
import os
import pathlib
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("ground_test", pathlib.Path(__file__).with_name("test-ground.py"))
ground = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ground)

def main():
    if not os.environ.get("DISPLAY"):
        os.execvp("xvfb-run", ["xvfb-run", "-a", "-s", "-screen 0 1440x1000x24", "env",
            "GSK_RENDERER=cairo", "GDK_BACKEND=x11", "GTK_A11Y=none", sys.executable, *sys.argv])
    process = subprocess.Popen([str(pathlib.Path(sys.argv[1]).resolve()), "--duration", "10"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    keyboard = None
    try:
        keyboard = ground.Keyboard()
        x = keyboard.x
        x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
            ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
        x.XGetImage.restype = ctypes.c_void_p
        x.XGetPixel.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        x.XGetPixel.restype = ctypes.c_ulong
        x.XDestroyImage.argtypes = [ctypes.c_void_p]
        def background():
            sample = x.XGetImage(keyboard.display, keyboard.window, 10, 10, 1, 1, ctypes.c_ulong(-1), 2)
            assert sample, "Cannot capture window background"
            try: return x.XGetPixel(sample, 0, 0) & 0xffffff
            finally: x.XDestroyImage(sample)
        time.sleep(0.7)
        assert background() == 0x0b1116, hex(background())
        for expected in [0x180f09, 0x180f09, 0x0b1116]:
            keyboard.mouse(760, 117, True); time.sleep(0.05)
            keyboard.mouse(760, 117, False); time.sleep(0.7)
            assert background() == expected, f"Expected {expected:06x}, got {background():06x}"
        process.terminate()
        output, error = process.communicate(timeout=5)
        assert process.returncode == 0, error
        assert "Theme parser error" not in error, error
        print("PASS: live blue-to-brown theme switch for both ground routes and restoration to air")
    finally:
        if keyboard: keyboard.close()
        if process.poll() is None: process.terminate(); process.communicate(timeout=5)

if __name__ == "__main__": main()
