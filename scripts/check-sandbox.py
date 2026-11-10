"""Exercise the production library inside the actual app sandbox, no root."""
import pathlib
import plistlib
import re
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, timeout=90)


run("swift", "build", "--product", "SandboxProbe")
binary = pathlib.Path(run("swift", "build", "--show-bin-path").decode().strip()) / "SandboxProbe"
run("codesign", "--force", "--sign", "-", "--entitlements", "Resources/DiskWatch.entitlements", str(binary))
with tempfile.TemporaryDirectory() as folder:
    source = pathlib.Path(folder) / "source"
    source.mkdir()
    (source / ".metadata_never_index").touch()
    path = str(pathlib.Path(folder) / "test.dmg")
    run("hdiutil", "create", "-srcfolder", str(source), "-size", "128m", "-fs", "APFS", "-volname", "SandboxProbe", path)
    attached = plistlib.loads(run("hdiutil", "attach", "-plist", "-nobrowse", path))
    device = next(item["dev-entry"] for item in attached["system-entities"]
                  if re.fullmatch(r"/dev/disk\d+", item.get("dev-entry", "")))
    try:
        subprocess.run([str(binary), device.removeprefix("/dev/")], check=True, timeout=60)
    finally:
        subprocess.run(["hdiutil", "detach", device], check=False, timeout=30)
