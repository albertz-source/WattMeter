# WattMeter 1.3.3

A native macOS menu-bar power monitor: live power (adapter input by default), adapter vs battery
split, CPU / GPU / ANE / DRAM power, temperatures, fan speed, and a Sankey-style power-flow diagram.

## Fixed

### The menu bar number no longer disappears

The status item used to size itself by measuring the text once per second and then writing that
width into `statusItem.length`. If the system reset the button's font — switching displays, changing
appearance, an external monitor being plugged in, the menu bar re-laying itself out — the digits no
longer fitted the hard-coded width and were clipped away, so the menu bar showed a number-less item
while the process kept running.

The status item is now sized by AppKit (`variableLength`), the font is re-applied on every update,
the title never goes empty (a metric without a value falls back to system power instead of blanking),
and a watchdog recreates the status item if the system removes it (menu bar space, display changes,
full-screen transitions).

Two related fixes:

- **App Nap** is held off while sampling (`.userInitiatedAllowingIdleSystemSleep`), so the number no
  longer freezes when no window is open. Idle system sleep is still allowed.
- The last good number is kept through a single failed read instead of flashing `—W`.

### Diagnostics for the menu bar

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --diag           # status item state + text per metric
/Applications/WattMeter.app/Contents/MacOS/WattMeter --menubar-test   # text for every metric
/Applications/WattMeter.app/Contents/MacOS/WattMeter --menubar-log    # log every update to /tmp/wattmeter-menubar.log
```

## Changed

### The menu bar shows the input power

The number is now **adapter input power** (what the machine actually draws from the power supply)
instead of system power. On a MacBook this includes the power going into the battery while charging;
when running on battery there is no input, so it falls back to system power.

Right-click the menu bar item → **菜单栏显示 / Menu bar shows** to pick a different metric:

| Metric | Meaning |
| --- | --- |
| 电源输入 (default) | adapter DC input — includes charging power |
| 墙插估算 | wall estimate (DC input + adapter loss) |
| 整机功耗 | system power (AppleSMC `PSTR`) |
| 电池功率 | net battery power, `+` charging / `−` discharging |

The choice is remembered. The tooltip lists all values, including input voltage × current.

## Also included since 1.2.2

- **About window**, flow diagram with CPU / GPU / ANE / DRAM branches and a single hub per side,
  split line-chart Y domain (1.3.2), always-visible battery port, English-primary UI with Chinese
  available, launch at login, macOS 13+ universal binary.

## Requirements

- **macOS 13 or later** (macOS 13 / 14 / 15 and newer)
- **Apple Silicon (M-series) or Intel Mac** — universal binary (`arm64` + `x86_64`)
- No root, no kernel extension, no network access; the app only reads IOKit / SMC

## Install

1. Download **WattMeter-1.3.3.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

### 修复：菜单栏数字偶尔消失

以前每秒按字体手算一次文字宽度写进 `statusItem.length`。一旦系统把按钮字形重置（切换显示器、
换外观、插拔外接屏、菜单栏重排），按旧字体算出来的宽度就装不下数字，数字被裁掉——表现就是
菜单栏没有数字、进程却还在。

现在宽度交给 AppKit 自己量（`variableLength`），每次刷新都重新设置字体，标题永远不会变成空
（某个口径没数值时回退到整机功耗），并且加了看门狗：状态项被系统摘掉（菜单栏空间不足、显示器
变化、全屏切换）会自动重建。另外：

- 采样期间阻止 **App Nap**（`.userInitiatedAllowingIdleSystemSleep`），没有窗口时数字也不会冻住，
  系统空闲休眠照常允许；
- 单次读取失败时保留上一个数字，不再闪一下「—W」。

诊断命令：`--diag`（状态项状态 + 各口径文字）、`--menubar-test`（各口径文字）、
`--menubar-log`（每次刷新写入 `/tmp/wattmeter-menubar.log`）。

### 变更：菜单栏改显示输入功率

菜单栏数字现在是**电源输入功率**（机器从电源实际拿到的功率），而不是整机功耗。笔记本充电时
包含充进电池的那部分；纯电池供电时没有输入，自动回退显示整机功耗。

右键菜单 →「菜单栏显示」可以切换：电源输入（默认）/ 墙插估算 / 整机功耗 / 电池功率（`+` 充电、
`−` 放电），选择会被记住。tooltip 里仍然列出全部数值（含输入电压 × 电流）。

### 同时包含 1.2.2 以来的全部更新

- 关于窗口；流向图 CPU / GPU / ANE / DRAM 分项、左右各单一枢纽；折线图 Y 轴同时覆盖两条曲线
  （1.3.2）；电池端口常驻；界面以英文为主可切中文；登录时启动；macOS 13+ 通用二进制。
