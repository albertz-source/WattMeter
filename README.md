# WattMeter

**English** · [简体中文](README.zh-CN.md)

A native macOS menu-bar power monitor. It shows real-time system power, how much of it comes from the power adapter versus the battery, plus fan speed — as a power-flow diagram and as time-series charts.

- Swift + SwiftUI + Swift Charts, no third-party dependencies
- **No root, no kernel extension, no network access** — read-only IOKit/SMC access
- Builds with the macOS Command Line Tools alone (Xcode not required)

| Menu bar panel (charging) | Panel (battery) | Main window |
| --- | --- | --- |
| ![panel](docs/preview-panel.png) | ![battery](docs/preview-panel-battery.png) | ![window](docs/preview-window.png) |

*(Screenshots are rendered off-screen by `wattmeter-snapshot` from built-in demo data — no screen-recording permission needed.)*

---

## 1. What it shows

| Requirement | Implementation |
| --- | --- |
| Total power | Menu bar shows live system power; the panel shows a large readout from AppleSMC `PSTR` |
| Where the power comes from | A Sankey-style flow diagram (adapter / battery on the left, system in the middle, four branches on the right) plus an adapter-vs-battery share bar |
| Visualisation | Flow diagram; stacked area chart (adapter vs battery, 1 / 5 / 15 min); line chart of total power and net battery power in the main window |

Also included: adapter DC input and rated wattage, estimated wall power, battery percentage and time remaining, fan RPM, CPU / GPU / SSD / battery / platform temperatures, display backlight power, USB-C output power, and session energy (Wh).

---

## 2. Data sources

| Source | API / keys | Typical refresh | Notes |
| --- | --- | --- | --- |
| Total system power | AppleSMC `PSTR` | sub-second | whole-system rail |
| Adapter DC input | AppleSMC `PDTR`, `PD0R` | sub-second | `PD0R` exists on desktop Macs |
| Battery power | `AppleSmartBattery` voltage × amperage | ~1 s | sign normalised by charge state |
| Battery state / % / time left | IOKit `IOPowerSources` | event-driven | |
| Adapter rating & name | `AdapterDetails` | on plug/unplug | |
| Fallback telemetry | `PowerTelemetryData` | **≈20 s** | `SystemLoad` / `SystemPowerIn`, adapter loss |
| Fan | AppleSMC `F0Ac`, `F0Mn`, `F0Mx` | sub-second | `flt` or `fpe2` payloads |
| Display backlight | AppleSMC `PDBR` / `PBwo` / `PBLR` | sub-second | only on Macs with an internal display |
| USB-C output | AppleSMC `D1..D4 JV×JI`, else `PowerOutDetails` | sub-second | charging input channel is excluded |
| Component temperatures | AppleSMC `Tp*` (CPU), `Tg0*` (GPU), `TH0*` (SSD), `TB0*` (battery), `Ts0P` (platform) | sub-second | keys vary by model; unavailable components show “—” |

Two practical rules:

1. **Real-time values must come from SMC.** `PowerTelemetryData` only refreshes about every 20 seconds, so it is used as a fallback (and for the adapter-loss estimate), never for the live readout.
2. **Battery values come from IOPS/IORegistry.** SMC battery keys differ between models, so battery power is derived from voltage × amperage and the direction is normalised by the charging state.

> References: `PSTR` is AppleSMC's “System Total Rail” ([chromium `smc_internal_types_mac.h`](https://chromium.googlesource.com/chromium/src/+/d3c3c840981b951410572e950c8497befdabff05/components/power_metrics/smc_internal_types_mac.h)); `PDTR` is adapter DC input and `PowerTelemetryData` refreshes slowly ([mactop fallback notes](https://github.com/vladkens/macmon/blob/850812f405c2e4180d03a31cf3f77674f9d9520e/docs/plans/20261111-mactop-fallbacks.md)); `Energy Model` in IOReport is unreliable on macOS 27, so it is not used.

---

## 3. Power model

Let:

- `load` = AppleSMC `PSTR` (total system power, W)
- `input` = AppleSMC `PDTR` / `PD0R` (adapter DC input, W)
- `loss` = `PowerTelemetryData.AdapterEfficiencyLoss` (W)

Split across the load:

```
adapter → load   = min(input, load)
battery → load   = max(0, load - input)      // weak charger + high load
charging power   = max(0, input - load)
wall estimate    ≈ input + loss             // fallback: input / 0.9
```

Net battery power (positive = charging, negative = discharging):

```
P_battery = Voltage(mV) × Amperage(mA) / 1e6
direction is normalised with IsCharging / ExternalConnected
system component = total − display − ports
```

Two engineering details:

1. **Sampling skew.** `PSTR` lags one SMC sweep behind `PDTR`; subtracting them directly produces phantom ±0.7 W “battery power”. Desktop Macs are forced to 100% adapter, and laptops use a 0.7 W dead band.
2. **Graceful fallback.** If the SMC keys are missing, the reader falls back to `PowerTelemetryData` and labels the source in the UI.

---

## 4. Architecture

```
AppleSMC (PSTR/PDTR/PD0R, F0Ac, PDBR, D1..D4) ─┐
AppleSmartBattery (V/I, AdapterDetails,         ├─> CSystemPower (C, IOKit, no root)
  PowerTelemetryData)                           │        │
IOPS (state, percent, time left) ───────────────┘        ▼
                                              WattMeterCore (Swift)
                                              ├─ PowerReader   raw → watts + split
                                              ├─ PowerSampler  1 Hz background sampling
                                              ├─ HistoryBuffer 1 h ring buffer, Wh integration
                                              └─ PowerStore    @Published state (main thread)
                                                        │
                                    WattMeterUI (SwiftUI + Swift Charts)
                                                        │
                     AppKit menu bar: NSStatusItem("12.3W") + NSPopover + main window
```

```
wattmeter/
├── Package.swift                 # SwiftPM manifest (for Xcode users)
├── Makefile
├── scripts/
│   ├── build.sh                  # clang + swiftc build (no Xcode needed)
│   ├── make-icon.sh              # generate Resources/WattMeter.icns
│   └── package-dmg.sh            # build a drag-to-Applications DMG
├── Resources/Info.plist          # LSUIElement = true (no Dock icon)
├── Sources/
│   ├── CSystemPower/             # SMC user client + IORegistry + IOPS
│   ├── WattMeterCore/            # models, power model, sampler, history
│   ├── WattMeterUI/              # dark panel, flow diagram, charts, main window
│   ├── WattMeter/                # AppKit menu-bar app
│   ├── wattprobe/                # CLI probe for checking data sources
│   └── wattmeter-snapshot/       # off-screen renderer for screenshots
└── docs/preview-*.png
```

- Sampling runs on a background queue (`DispatchSourceTimer`, 1 Hz, 120 ms leeway); a sample costs well under a millisecond
- No shell calls and no `powermetrics` (which requires root)

---

## 5. UI design

The visual language is inspired by [PowerLens](https://github.com/kinghhhin-design/power), a similar open-source menu-bar power monitor; the time-series charts are our addition.

| Element | Detail |
| --- | --- |
| Panel | 400 × 666 pt dark frosted glass (`NSVisualEffectView` with `.popover` material, behind-window, darkAqua) |
| Accents | mint `#6EE0C2` (power), amber `#F5C273` (battery), blue `#7DB0FA` (system), purple `#BA9CF5` (adapter/ports) |
| Type | SF Rounded; 31 pt light primary readout, 19 pt medium row values, 9–10 pt captions |
| Flow diagram | 364 × 180: source on the left, Mac in the middle, four branches on the right (system / display / ports / battery). Rounded bezier links with gradient, glow and dots flowing **from source to load**. Link width is fixed at 14 pt so the diagram does not jitter when readings change |
| Temperatures | CPU / GPU / SSD / battery chips in the panel; a full temperature card in the main window. Values turn amber above 65 °C and red above 80 °C |
| Charts | Stacked area of adapter vs battery, plus a total/net-battery line chart in the main window |
| Main window | 1020 × 820 pt (scrollable if the user shrinks it): flow diagram, stacked area chart, line chart, and adapter / battery / temperature cards |
| Menu bar | Monospaced digits, width auto-fitted, detailed tooltip, single-instance guard |

Charging, discharging, battery standby and no-battery desktops each get a different diagram layout; branches without telemetry are dimmed instead of being hidden.

---

## 6. Build & run

Requirements: macOS 13+, Command Line Tools (`xcode-select --install`). Xcode is not required.

```bash
git clone https://github.com/albertz-source/WattMeter.git
cd WattMeter

./scripts/build.sh                 # or: ./scripts/build.sh debug
open dist/WattMeter.app            # menu-bar app, no Dock icon

./scripts/package-dmg.sh           # build a drag-to-Applications DMG
./.build/bin/wattprobe             # CLI probe, 10 samples at 1 s
./.build/bin/wattprobe --keys      # list candidate SMC keys for your model
./.build/bin/wattmeter-snapshot --view dashboard --state charging --out docs/preview-panel.png
```

Self-checks:

```bash
dist/WattMeter.app/Contents/MacOS/WattMeter --selftest   # sample for 3.5 s and print
dist/WattMeter.app/Contents/MacOS/WattMeter --diag       # verify the status item exists
```

The DMG (created by `scripts/package-dmg.sh`) contains `WattMeter.app`, an `Applications` shortcut and a short install note: open it, drag the app to Applications, eject.

> Why not SwiftPM: `swift build` needs writable user-level caches and sandbox permission for manifest compilation, which fails in restricted environments. `scripts/build.sh` calls `clang`/`swiftc` directly and keeps all caches inside the project. On a normal machine with Xcode, `swift build` works too.

### Distribution

- The bundled build is **ad-hoc signed**; on another Mac, right-click → Open, or `xattr -dr com.apple.quarantine /Applications/WattMeter.app`
- For public distribution, sign with a Developer ID and notarise:
  ```bash
  codesign --deep --force --options runtime --sign "Developer ID Application: ..." dist/WattMeter.app
  xcrun notarytool submit dist/WattMeter-<version>.dmg --keychain-profile "AC_PASSWORD" --wait
  xcrun stapler staple dist/WattMeter-<version>.dmg
  ```
- App Sandbox is not supported (SMC user-client and IORegistry access are blocked in a sandbox), so this app is not suitable for the Mac App Store

---

## 7. Verify on your own Mac

```bash
./.build/bin/wattprobe --keys   # which SMC power/fan/backlight keys your model exposes
./.build/bin/wattprobe 20 1     # 20 samples, one per second
```

If `PSTR` / `PDTR` are missing on your model, the app falls back to `PowerTelemetryData` (marked “System telemetry” in the UI). On fanless Macs the fan row shows “—”.

---

## 8. Limitations

1. **Wall power is an estimate.** `PDTR` is DC input after AC/DC conversion; the app adds the system-reported adapter loss. Expect a 5–15% difference from a wall meter.
2. **Laptop battery sign convention** is normalised from the charging state; it is worth a quick cross-check with macOS's own battery information on a MacBook.
3. On Intel Macs `PSTR`/`PDTR` usually exist; if not, the app falls back to IOPS voltage/current plus telemetry.
4. No persistence, CSV export, notifications or login item yet.
5. Builds are ad-hoc signed, not notarised.
6. Sub-system power (CPU / GPU / ANE / DRAM) via IOReport is not implemented.
7. Temperature keys differ between models: GPU and battery temperatures are not exposed on every Mac (desktop Macs have no battery sensor), and those rows then show “—”.

---

## 9. Roadmap

- [ ] IOReport / PMP sub-system breakdown (CPU / GPU / ANE / DRAM), with SMC fallback on macOS 27
- [ ] Verify and calibrate on more MacBook models
- [ ] CSV / JSON export, history persistence, daily energy cost
- [ ] Login item (`SMAppService`), threshold notifications, low-battery alert
- [ ] Developer ID signing, notarisation and a DMG release workflow

---

## 10. References

- [PowerLens — visual language reference](https://github.com/kinghhhin-design/power)
- [mactop fallback notes (PSTR/PDTR/PD0R semantics, Energy Model on macOS 27)](https://github.com/vladkens/macmon/blob/850812f405c2e4180d03a31cf3f77674f9d9520e/docs/plans/20261111-mactop-fallbacks.md)
- [chromium `smc_internal_types_mac.h` (TotalPower = PSTR)](https://chromium.googlesource.com/chromium/src/+/d3c3c840981b951410572e950c8497befdabff05/components/power_metrics/smc_internal_types_mac.h)
- [wattop — PDTR input power and slow telemetry in practice](https://crates.io/crates/wattop)
- Apple IOKit `IOPowerSources.h` / `IOPSKeys.h`, `AppleSmartBattery` IORegistry node
