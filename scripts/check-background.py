"""Verify that the real headless monitor persists and handles both stop signals."""

import json
import pathlib
import signal
import subprocess

binary_dir = subprocess.check_output(
    ["swift", "build", "--show-bin-path"], text=True
).strip()
binary = pathlib.Path(binary_dir) / "disk-watch"

for stop_signal in (signal.SIGTERM, signal.SIGINT):
    process = subprocess.Popen(
        [str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    try:
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        else:
            raise AssertionError("Background watcher exited without a stop signal")

        process.send_signal(stop_signal)
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 0, (process.returncode, stderr)
        assert not stderr, stderr
        records = [json.loads(line) for line in stdout.splitlines()]
        assert records and all(isinstance(record, list) for record in records), stdout
        print(f"Background watcher stayed running and exited cleanly on {stop_signal.name}.")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
