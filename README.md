# Disk Watch

A small macOS background app and reusable Swift library for discovering external
physical disks and cards in a MacBook's built-in SD reader. macOS 13 or later.

## Run the app

On a Mac with Xcode command-line tools:

```sh
sh scripts/build-app.sh
open dist/DiskWatch.app
```

The menu-bar app starts monitoring immediately and stays running while its menu
is closed. Its menu shows whole disks, sizes, transports, and BSD names. Choose
**Start at login** to register it with macOS; the menu reports pending approval
and links to Login Items settings. Move the app to its permanent location before
enabling login startup. **Quit Disk Watch** stops monitoring until the next launch.
This is a per-user background process, not a root/system daemon; it does not run
before login or after logout. The app reconciles its inventory after sleep.

The build script signs the app with the App Sandbox entitlement, using an ad-hoc
identity by default. Set `DISK_WATCH_SIGNING_IDENTITY` for your own signing identity.
Distribution signing, notarization, an App Store archive, and physical-device
qualification are separate from this development build.

## Reuse the library

`DiskDiscovery` contains the public `Disk` value type and `DiskMonitor`. It uses
Foundation and IOKit, without AppKit or SwiftUI. Add this package in Xcode or SwiftPM.
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
```

The continuous mode remains running until SIGINT/SIGTERM. Consumers must read
stdout continuously; errors are reported on stderr. Neither adapter invokes a
shell or `diskutil` to discover disks.

## Discovery policy

IOKit matching and termination notifications watch whole `IOMedia` instances.
Both notification iterators are drained to arm them before the initial scan.
Each notification reconciles the inventory; there is no polling timer. A physical
`IOBlockStorageDevice` ancestor supplies Apple's protocol characteristics.

| Registry facts | Result |
| --- | --- |
| Whole physical medium, external connection | Included, even if not marked removable |
| Whole physical medium, internal Secure Digital connection | Included as built-in SD reader |
| Internal SSD or other internal non-SD storage | Excluded |
| Partition, nested media, synthesized volume, virtual interface | Excluded |
| Empty reader, zero-size media, missing BSD name, ambiguous location | Excluded |

One physical medium is listed once, regardless of partition count. Discovery does
not depend on mounting or filesystem readability. No disk contents are opened,
and no mount, eject, formatting, permission, or privileged operation is performed.
Unknown registry layouts are not silently classified as external; older readers
that do not report `Secure Digital` require a captured fixture and explicit support.

## Validation

```sh
swift test -Xswiftc -warnings-as-errors
sh scripts/build-app.sh
dist/DiskWatch.app/Contents/MacOS/DiskWatch --smoke-test
```

Tests cover selection policy, initial discovery, add/remove reconciliation,
duplicate notifications, restart, stale callbacks, error recovery, and native
notification setup/teardown. CI also runs the sandboxed executable. Synthetic
fixtures and CI startup checks do not establish real hardware coverage.

Before accepting a build on a Mac, verify:

1. Launch with a USB SSD and SD card already inserted; compare with
   `diskutil list physical`. Internal SSDs must be absent from the app.
2. Attach and remove USB storage, a Thunderbolt/NVMe enclosure, and a card in the
   built-in slot. Repeat with multiple partitions and unmounted media.
3. Leave the menu closed during changes, then check it; repeat while it is open.
4. Sleep/wake with devices connected, then disconnect/reconnect them.
5. Enable startup, log out/in, confirm the process runs; disable startup and repeat.
6. Mount a disk image and verify it does not appear as a physical disk.

Apple references: [matching notifications](https://developer.apple.com/documentation/iokit/1514362-ioserviceaddmatchingnotification),
[storage protocol characteristics](https://github.com/apple-oss-distributions/IOStorageFamily/blob/main/IOStorageProtocolCharacteristics.h),
and [login startup](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).
