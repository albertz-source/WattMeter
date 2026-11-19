# WattMeter 1.3.0

A native macOS menu-bar power monitor: live system power, adapter vs battery split, **CPU / GPU /
ANE / DRAM power**, temperatures, fan speed, and a Sankey-style power-flow diagram.

## What's new

### Chip power breakdown in the flow diagram

The flow diagram's right side now expands the system branch into **CPU / GPU / ANE**, next to
display and ports:

```
adapter ─┐                 ┌─ CPU 4.2 W
         ├─▶ Mac ─▶ system ─┼─ GPU 6.1 W
battery ─┘                 └─ ANE 0.3 W
```

Power is read from the private **IOReport** framework, following
[mactop](https://github.com/metaspartan/mactop):

- merge `Energy Model` + `Energy Counters` + `GPU Stats` + `CPU Stats` + `AMC Stats`
- convert each channel's energy delta to watts using its unit label (`mJ` / `uJ` / `nJ`)
- classify channels: whole-CPU totals preferred over per-cluster energy, GPU `GPU Energy` with a
  `GPU` alias, ANE/DRAM per-block counters with aggregate fallbacks
- **PMP fallback**: when macOS 27 gates the Energy Model CPU counters (they read 0), CPU watts come
  from the PMP per-cluster power histograms (`PACC*` / `EACC*` / `MACC*`, residency-weighted bins)
- DRAM falls back to SMC `PZD*` keys; channels that exist but read 0 are shown as `0.00 W`

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --chips   # dump the energy channels
```

### Notes

- On macOS 27 the Energy Model CPU/DRAM counters are gated (they stay at 0 unless an entitled
  sampler runs). CPU is then taken from the PMP histograms (M5/M6 class chips); DRAM falls back to
  SMC. macOS 26 and older report all four directly.
- Everything from 1.2.2 is included: macOS 13+ universal build, always-visible battery port,
  fan-key discovery, battery-machine fixes and diagnostics.

## Install

1. Download **WattMeter-1.3.0.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

- 流向图右侧的「系统」现在细分为 **CPU / GPU / ANE**，与屏幕、接口并列。
- 数据来自私有 IOReport（`Energy Model`，并合并 `GPU Stats` / `CPU Stats` / `AMC Stats`），
  按通道单位换算成功率；CPU 优先整 CPU 通道，DRAM 可回退 SMC `PZD*`。
- macOS 27 会门控 Energy Model 的 CPU/DRAM 计数器（显示「—」），macOS 26 及更早版本正常。
- 同时包含 1.2.2 的全部修复：macOS 13+ 通用二进制、电池常驻、风扇键自动发现、MacBook 电池适配。
