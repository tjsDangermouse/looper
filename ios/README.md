# Looper iOS and watchOS app

This directory contains the iPhone app, its Apple Watch companion, and the
shared `LooperKit` Swift package. It depends on the route service only through
the versioned [Loop API contract](../route-service/contracts/loop-api/v1.md).

## Layout

| Path | Purpose |
| --- | --- |
| `Looper/` | iPhone application and its Xcode project. |
| `Looper/LooperWatch/` | Watch application target. |
| `LooperKit/` | Swift package containing shared models, networking, guidance, and tests. |
| `Shared/` | Phone/Watch connectivity code compiled into both app targets. |
| `Looper/project.yml` | XcodeGen source of truth for the Xcode project. |

## Build and test

Open `Looper/Looper.xcodeproj` in Xcode, choose the `Looper` scheme, and run
on an iOS 17+ simulator or device. The Watch target is embedded by that scheme.

`LooperKit` can be checked independently from this directory:

```bash
cd LooperKit
swift test
```

The production API base is a build setting named `LOOPER_API_BASE`, declared
in `Looper/project.yml` and exposed through the app's Info.plist. Change it per
configuration or environment; do not hard-code a host in Swift source.

If regenerating the project with XcodeGen, commit the resulting project changes
alongside its `project.yml` change.
