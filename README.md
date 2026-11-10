# Disk Watch

A small macOS background app and reusable Swift library for discovering external
physical disks and cards in a MacBook's built-in SD reader. macOS 13 or later.

## Run the app

On a Mac with Xcode command-line tools:

```sh
sh scripts/build-app.sh
open dist/DiskWatch.app
```

The app opens a 340-point-wide window with compact disk rows. Each row shows the
physical disk capacity and overall fullness of its formatted storage. Hover over
(or click) a disk for detected link speed, SD card type, used/free space, and BSD
name. Missing information is explicitly marked unavailable. The menu-bar icon
reopens the window; closing the window keeps background monitoring running.

**Eject All** captures the currently detected disks, unmounts every volume on each
whole disk, then ejects it. A spinner and count show progress. If a disk is busy,
the direct build identifies its process holders and attempts to save and close
affected documents. If the same application still blocks ejection, it attempts to
save its remaining documents and quit that application. Failed saves stop escalation;
unsupported or inaccessible applications remain open. Busy or refused disks stay
listed with an error and available process details. macOS may request Automation
permission for each application. Newly attached disks are not added
to an operation already underway, and registry identity is checked before acting. Choose
**Start at login** to register it with macOS; the menu reports pending approval
and links to Login Items settings. Move the app to its permanent location before
enabling login startup. **Quit Disk Watch** stops monitoring until the next launch.
This is a per-user background process, not a root/system daemon; it does not run
before login or after logout. The app reconciles its inventory after sleep.

The build script produces a direct-distribution app with the Apple Events
entitlement, using an ad-hoc signing identity by default. This build supports
process diagnosis and application automation. For a sandboxed build, run
`sh scripts/build-app.sh --sandboxed`; disk discovery, capacity, and normal ejection
remain available, but process inspection and application automation are restricted
by the sandbox. Set `DISK_WATCH_SIGNING_IDENTITY` for your own signing identity.
Distribution signing, notarization, an App Store archive, and physical-device
qualification are separate from this development build.

## Reuse the library

`DiskDiscovery` contains the public `Disk` value type and `DiskMonitor`. It uses
Foundation, IOKit, and Disk Arbitration, without AppKit or SwiftUI. Add this package in Xcode or SwiftPM.
Create and use the monitor on the main actor, retain it for the life of the service,
and service the main run loop. For example, inside a main-actor app/service owner:

```swift
let monitor = DiskMonitor()
monitor.onChange = { [weak monitor] in
    guard let monitor else { return }
    if let error = monitor.lastError {
        print("Last snapshot is stale:", error)
    } else {
        print(monitor.disks)
    }
}
try monitor.start()
// Keep the process and its main run loop alive. Call monitor.stop() on shutdown.
```

`start()` is idempotent; an initial snapshot includes devices already connected.
Changes are delivered on the main actor. A failed refresh retains the previous
snapshot and reports `lastError`. `stop()` clears the snapshot and unregisters
notifications. Registry IDs identify one attachment, not a disk across reconnects.

The included headless adapter uses exactly the same library:

```sh
swift run disk-watch --once   # One JSON array
swift run disk-watch          # JSON lines: initial snapshot, then changed snapshots
swift run disk-watch diagnose # JSON process-holder reports; no application control
swift run disk-watch eject-all # Save/close blockers as needed, then eject captured disks
```

The continuous mode remains running until SIGINT/SIGTERM. Consumers must read
stdout continuously; errors are reported on stderr. Discovery remains IOKit-based. `DiskUsageReader` maps registry media to native
filesystem counters off the main thread. It needs no diskutil subprocess or
file-content permission. GUI details refresh every 30
seconds, on disk changes, on wake, and on manual refresh.

The built app also includes `Contents/MacOS/disk-watch` for headless use. Ejection
writes a JSON result array to stdout and progress events to stderr, returning zero
only when every target's removal is verified. GUI and CLI ejection requests are
serialized per user within the same build mode. Automation never force-quits an
application or force-unmounts a disk. Unsaved documents encountered during quit
are saved under `~/Library/Application Support/DiskWatch/Recovered Work/` when the
application supports saving there. Unsupported save commands or denied Automation
permissions produce a failure report; they do not authorize discarding work.

## Headless triggers

The GUI and command line share `MacEjectionService` and its staged coordinator.
After installing the direct app in Applications, invoke:

```sh
/Applications/DiskWatch.app/Contents/MacOS/DiskWatch --eject-all
```

A button or script can run this directly. An iPhone Shortcut can use **Run Script
over SSH** to invoke it on the Mac, and Siri can run that named Shortcut. The Mac
must have a logged-in user session and Remote Login configured for that user.
macOS Automation approvals must be established for the calling context before
unattended use. The command opens no Disk Watch window, emits progress and results
as JSON, and returns nonzero if any target remains unresolved. End-to-end iPhone
and Siri triggering still requires qualification on the receiving Mac.

## Discovery policy

IOKit matching and termination notifications watch whole `IOMedia` instances.
Both notification iterators are drained to arm them before the initial scan.
Each notification reconciles the inventory. Disk attachment detection is event-driven; the GUI separately refreshes metadata every 30 seconds. A physical
`IOBlockStorageDevice` ancestor supplies Apple's protocol characteristics.

| Registry facts | Result |
| --- | --- |
| Whole physical medium, external connection | Included, even if not marked removable |
| Whole physical medium, internal Secure Digital connection | Included as built-in SD reader |
| Internal SSD or other internal non-SD storage | Excluded |
| Partition, nested media, synthesized volume, virtual interface | Excluded |
| Empty reader, zero-size media, missing BSD name, ambiguous location | Excluded |

One physical medium is listed once, regardless of partition count. Discovery does
not depend on mounting or filesystem readability. Discovery and capacity queries do not open disk contents or mount media.
Ejection uses Disk Arbitration only after an explicit Eject All action or command; it never
force-unmounts, formats, or escalates privileges.
Unknown registry layouts are not silently classified as external; older readers
that do not report `Secure Digital` require a captured fixture and explicit support.

## Validation

```sh
swift test -Xswiftc -warnings-as-errors
sh scripts/build-app.sh --sandboxed
dist/DiskWatch.app/Contents/MacOS/DiskWatch --smoke-test
python3 scripts/check-sandbox.py
sh scripts/build-app.sh
dist/DiskWatch.app/Contents/MacOS/DiskWatch --smoke-test
```

Tests cover selection policy, initial discovery, add/remove reconciliation,
duplicate notifications, restart, stale callbacks, error recovery, and native
notification setup/teardown. An integration test uses a temporary 1 MiB RAM disk
to exercise real arrival/removal callbacks and virtual-media exclusion. A disposable APFS image tests capacity accounting and unmount/ejection through
real Disk Arbitration callbacks, including a separately signed sandboxed probe.
The same checks run against exFAT. Busy-disk tests verify refusal while a file is
open and successful ejection after it closes. Coordinator tests cover cancellation,
failed saves, fresh process identities, and newly appearing holders.
CI also runs the sandboxed executable and verifies the headless process stays alive until
SIGTERM/SIGINT, then shuts down cleanly. Synthetic
fixtures and CI startup checks do not establish real hardware coverage.

CI opts into a disposable TextEdit session with `DISK_WATCH_AUTOMATION_TESTS=1`.
A CI-only Accessibility helper approves the normal consent dialog only when it
names the hosted CI agent and TextEdit; it never changes the TCC database. The
native test verifies targeted document saving, preservation of an unrelated open
document, recovery of untitled work, and saved bytes after app exit. This test is
skipped by default on personal Macs; opt in only in a disposable GUI session.
It qualifies TextEdit, not every application's scripting support.

Successful Swift workflow runs provide a `DiskWatch-macOS` artifact containing
the direct development app and a `native-ui-previews` artifact containing example
window renders. The app artifact uses an ad-hoc signature and is not notarized.

Before accepting a build on a Mac, verify:

1. Launch with a USB SSD and SD card already inserted; compare with
   `diskutil list physical`. Internal SSDs must be absent from the app.
2. Attach and remove USB storage, a Thunderbolt/NVMe enclosure, and a card in the
   built-in slot. Repeat with multiple partitions and unmounted media.
3. Leave the menu closed during changes, then check it; repeat while it is open.
4. Sleep/wake with devices connected, then disconnect/reconnect them.
5. Enable startup, log out/in, confirm the process runs; disable startup and repeat.
6. Mount a disk image and verify it does not appear as a physical disk.
7. In a disposable session, test Eject All with saved and modified documents on a
   test disk, including denied Automation permission and an unsupported application.
   Confirm saved contents, failure reporting, and preservation of unrelated apps.

Apple references: [matching notifications](https://developer.apple.com/documentation/iokit/1514362-ioserviceaddmatchingnotification),
[storage protocol characteristics](https://github.com/apple-oss-distributions/IOStorageFamily/blob/main/IOStorageProtocolCharacteristics.h),
and [login startup](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).


## Disk details

- USB speed uses the nearest USB device's reported operational speed. USB host and
  legacy device speed enumerations are decoded separately. A parent hub's faster
  speed is never substituted for the disk's link.
- PCIe reports the endpoint's link status as GT/s per lane and lane count. This is
  not a Thunderbolt cable rate or measured storage throughput. Other storage port
  rates are shown only when the driver supplies `Controller Characteristics.Port Speed`.
- SD/MMC type comes directly from `Card Characteristics.Card Type`. Card capacity,
  names, and reader capability are never used to infer SDHC/SDXC/UHS classifications.
- Fullness is `(formatted capacity - free space) / formatted capacity`. APFS pools
  are counted once, regardless of volume count. Ambiguous topology, inconsistent
  shared-pool counters, missing mounted filesystem data, and invalid counters
  produce an explicit unavailable state. Physical capacity is shown separately.
  Kernel counters may be cached; the displayed timestamp is when they were read,
  not a promise that the filesystem has refreshed them. Quota-limited volumes and
  multi-device storage need further hardware qualification.
- `DiskUsageReader` and `DiskEjector` are reusable public library services. Usage
  samples include timestamps. Eject All returns a result for each targeted disk.

CI renders the real native compact view into `native-ui-previews` artifacts with
explicit example data. These images demonstrate layout, not hardware detection.
Hardware verification must also compare reported USB/PCIe rates and SD types with
System Information, compare capacity with Disk Utility, and exercise safe/busy
whole-disk ejection from the sandboxed app.
