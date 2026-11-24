# WattMeter 1.4.0

A native macOS menu-bar power monitor: live power (adapter input by default), adapter vs battery
split, CPU / GPU / ANE / DRAM power, temperatures, fan speed, and a Sankey-style power-flow diagram.

## New

### Battery health: full-charge / design capacity and cycle count

The battery card now shows the pack's health, read straight from the IORegistry
`AppleSmartBattery` node — the same source `ioreg` uses, no root and no extra permissions:

| Value | IORegistry key |
| --- | --- |
| Design capacity | `DesignCapacity` |
| Full-charge capacity | `AppleRawMaxCapacity` (fallback `NominalChargeCapacity`, then legacy `MaxCapacity`) |
| Health | full-charge ÷ design, e.g. 5640 / 6075 = **93%** |
| Cycle count | `CycleCount` |
| Design cycle limit | `DesignCycleCount9C` |
| Health / condition text | IOPS `BatteryHealth` / `BatteryHealthCondition` |

Where it shows up:

- **Menu bar panel**: a new “Battery health” row (`5640 / 6075 mAh · 213 cycles`), the panel grew from
  680 to 720 pt to fit it.
- **Main window**: the battery card has the same row.
- **Menu bar tooltip**: health percentage and cycle count.
- **About → Copy diagnostics** and `--battery` now include the capacity / cycle lines.

On a desktop (no battery) the row reads “No internal battery”; machines whose firmware does not
report capacities show “Capacity not reported” instead of a wrong number.

### Diagnostics

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --battery-keys
```

prints every `AppleSmartBattery` key related to capacity / cycles / health, so it is easy to check
whether a machine reports these values.

## Also included since 1.2.2

Everything from 1.3.x: menu bar shows adapter input and can switch metric (wall estimate / system
power / battery power), self-healing status item, split line-chart Y domain, About window, flow
diagram with CPU / GPU / ANE / DRAM branches and a single hub per side, English-primary UI with
Chinese available, launch at login, macOS 13+ universal binary.

## Requirements

- **macOS 13 or later** (macOS 13 / 14 / 15 and newer)
- **Apple Silicon (M-series) or Intel Mac** — universal binary (`arm64` + `x86_64`)
- No root, no kernel extension, no network access; the app only reads IOKit / SMC

## Install

1. Download **WattMeter-1.4.0.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

### 新增：电池健康度（满充容量 / 设计容量）与循环次数

电池卡片现在直接读 IORegistry 的 `AppleSmartBattery` 节点（和 `ioreg` 同一个数据源，不需要
root，也不需要任何额外权限）：

| 数值 | 对应键 |
| --- | --- |
| 设计容量 | `DesignCapacity` |
| 满充容量 | `AppleRawMaxCapacity`（回退 `NominalChargeCapacity`，再回退旧机型的 `MaxCapacity`） |
| 健康度 | 满充 ÷ 设计，例如 5640 / 6075 = **93%** |
| 循环次数 | `CycleCount` |
| 设计循环上限 | `DesignCycleCount9C` |
| 健康 / 状态文案 | IOPS `BatteryHealth` / `BatteryHealthCondition` |

显示位置：

- **菜单栏面板**：新增「电池健康」一行（`5640 / 6075 mAh · 213 次`），面板高度从 680 调整到 720；
- **主窗口**：电池卡片同样新增这一行；
- **菜单栏 tooltip**：健康度百分比与循环次数；
- **关于 → 复制诊断信息** 与 `--battery` 也会输出容量 / 循环信息。

台式机（无电池）显示「本机无内置电池」；固件不报容量的机型显示「系统未提供容量数据」，
不会显示错误的数字。

### 诊断命令

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --battery-keys
```

会列出 `AppleSmartBattery` 中与容量 / 循环 / 健康相关的全部键值，方便确认某台机器是否上报这些数据。

### 同时包含 1.2.2 以来的全部更新

包括 1.3.x 的全部内容：菜单栏默认显示电源输入并可切换口径、状态项自愈、折线图 Y 轴同时覆盖
两条曲线、关于窗口、流向图 CPU / GPU / ANE / DRAM 分项与左右单一枢纽、界面以英文为主可切中文、
登录时启动、macOS 13+ 通用二进制。
