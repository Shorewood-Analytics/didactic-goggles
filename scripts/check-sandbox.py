"""Exercise the production library inside the actual app sandbox, no root."""
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile


def run(*args):
    return subprocess.check_output(args, timeout=90)


run("swift", "build", "--product", "SandboxProbe")
binary = pathlib.Path(run("swift", "build", "--show-bin-path").decode().strip()) / "SandboxProbe"
bundle = pathlib.Path("dist/SandboxProbe.app").resolve()
executable = bundle / "Contents/MacOS/SandboxProbe"
executable.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(binary, executable)
info = plistlib.loads(pathlib.Path("Resources/Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.shorewoodanalytics.DiskWatch.SandboxProbe", CFBundleExecutable="SandboxProbe")
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
run("codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", "Resources/DiskWatch.entitlements", str(bundle))
run("codesign", "--verify", "--strict", str(bundle))
for filesystem in ("APFS", "ExFAT"):
    with tempfile.TemporaryDirectory() as folder:
        source = pathlib.Path(folder) / "source"
        source.mkdir()
        (source / ".metadata_never_index").touch()
        path = str(pathlib.Path(folder) / "test.dmg")
        if filesystem == "APFS":
            run("hdiutil", "create", "-srcfolder", str(source), "-size", "128m", "-fs", filesystem, "-volname", "SandboxProbe", path)
        else:
            run("hdiutil", "create", "-size", "512m", "-layout", "MBRSPUD", "-fs", filesystem, "-volname", "SandboxProbe", path)
        attached = plistlib.loads(run("hdiutil", "attach", "-plist", "-nobrowse", path))
        device = next(item["dev-entry"] for item in attached["system-entities"]
                      if re.fullmatch(r"/dev/disk\d+", item.get("dev-entry", "")))
        try:
            subprocess.run([str(executable), device.removeprefix("/dev/")], check=True, timeout=60)
        except subprocess.CalledProcessError:
            subprocess.run(["/usr/bin/log", "show", "--last", "2m", "--style", "compact", "--predicate", 'process == "SandboxProbe"'], check=False, timeout=30)
            raise
        finally:
            subprocess.run(["hdiutil", "detach", device], check=False, timeout=30)
