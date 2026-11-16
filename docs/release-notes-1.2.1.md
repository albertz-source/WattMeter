# WattMeter 1.2.1

## Fix

- **The app now runs on macOS 13 and later** (previously it refused to launch on anything below
  macOS 27 with “this version of the application cannot be used with this version of macOS”).
  The binary was built without a deployment target, so its minimum system version was recorded as
  the build machine's macOS version.
- **Universal binary**: arm64 + x86_64, so it also runs on Intel Macs.

## Battery visibility

- When a battery is installed it is **always** shown on the flow diagram: on the right while charging
  or idle on AC, on the left while supplying (including hybrid and battery-only modes).
- Battery-only mode now animates the flow as well; the battery → machine link keeps its moving dots
  even if the total power reading is momentarily unavailable.

## Verification

```
$ lipo -info WattMeter.app/Contents/MacOS/WattMeter
Architectures in the fat file: WattMeter, are: x86_64 arm64

$ vtool -show-build WattMeter.app/Contents/MacOS/WattMeter
  platform MACOS   minos 13.0    (arm64)
  platform MACOS   minos 13.0    (x86_64)
```

Tested on macOS 27 (Apple Silicon); the deployment target is 13.0, so macOS 13 / 14 / 15 are
supported. Build with `MIN_OS=13.0 ./scripts/build.sh` (default) or `ARCHS="arm64"` for a faster
single-architecture build.
