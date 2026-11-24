# WattMeter 1.7.0

A native macOS menu-bar power monitor: live power (adapter input by default), adapter vs battery
split, CPU / GPU / ANE / DRAM power, temperatures, fan speed, battery health, disk / SSD SMART
figures, and a Sankey-style power-flow diagram. **New in 1.7.0: memory, network and link speed.**

## New

### Memory usage

Read with `host_statistics64` (the same source as Activity Monitor):

- **used %** = (App + Wired + Compressed) ÷ physical memory
- **used / total** in binary units, so a 16 GB Mac reads `16.0 GB` (not 17.2 GB)
- swap usage when swap is in use

### Network throughput, link speed and since-boot traffic

Sampled from the kernel's 64-bit interface counters (`sysctl NET_RT_IFLIST2`), only for `en*`
interfaces (Ethernet / Wi-Fi) so VPN, AirDrop and bridge interfaces do not double-count:

- **download / upload rate** — per-second delta of the counters
- **link speed** — `if_baudrate` of the active interface, e.g. `1.0 Gb/s`, `346 Mb/s` on Wi-Fi
- **since-boot traffic** — cumulative in / out since the last boot
- the primary interface name (`en0` / `en1`) is shown in the main window

Where it shows up:

- **Menu bar panel**: a new chip row under the disk line — `RAM 48%`, `↓ 374 KB/s`,
  `↑ 260 KB/s`, `1.0 Gb/s` (panel 770 → 800 pt).
- **Main window**: a “Memory / network” card in the sidebar — RAM % with used/total, network rates,
  link speed and since-boot totals.
- **Menu bar tooltip**: memory and network lines.

### Diagnostics

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --system
```

prints memory (with App / Wired / Compressed / swap breakdown), the 1-second network rates, the link
speed, the primary interface and the since-boot traffic.

## Also included since 1.2.2

Everything from 1.3.x–1.6.0: menu bar shows adapter input (metric switchable), self-healing status
item, battery health with full-charge / design capacity and cycle count, disk throughput, SSD SMART
lifetime writes / reads / health, split line-chart Y domain, About window, flow diagram with
CPU / GPU / ANE / DRAM branches, English-primary UI with Chinese available, launch at login,
macOS 13+ universal binary.

## Requirements

- **macOS 13 or later** (macOS 13 / 14 / 15 and newer)
- **Apple Silicon (M-series) or Intel Mac** — universal binary (`arm64` + `x86_64`)
- No root, no kernel extension, no network access; the app only reads IOKit / SMC / sysctl

## Install

1. Download **WattMeter-1.7.0.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

### 新增：内存使用率

用 `host_statistics64` 读取（与活动监视器同源）：

- **使用率** =（App + Wired + Compressed）÷ 物理内存
- **已用 / 总量**用 1024 进制显示，16 GB 的机器显示 `16.0 GB`（不是 17.2 GB）
- 有交换区时显示交换用量

### 新增：网络速率、连接速率、开机以来流量

来自内核的 64 位接口计数器（`sysctl NET_RT_IFLIST2`），只统计 `en*`（以太网 / Wi-Fi），
避免 VPN、AirDrop、桥接接口重复计数：

- **下载 / 上传速率**：计数器每秒增量
- **连接速率**：活动接口的 `if_baudrate`，例如 `1.0 Gb/s`，Wi-Fi 上是 `346 Mb/s`
- **开机以来流量**：本次开机至今的累计流入 / 流出
- 主用接口名（`en0` / `en1`）在主窗口里显示

显示位置：

- **菜单栏面板**：磁盘条下方新增一行徽章 —— `RAM 48%`、`↓ 374 KB/s`、`↑ 260 KB/s`、`1.0 Gb/s`
  （面板 770 → 800）；
- **主窗口**：侧栏新增「内存 / 网络」卡片 —— 内存使用率与已用/总量、网络速率、连接速率、
  开机以来流量；
- **菜单栏 tooltip**：内存与网络两行。

### 诊断命令

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --system
```

输出内存（含 App / Wired / Compressed / 交换明细）、1 秒窗口的网络速率、连接速率、主用接口，
以及开机以来的累计流量。

### 同时包含 1.2.2 以来的全部更新

包括 1.3.x–1.6.0 的全部内容：菜单栏默认显示电源输入并可切换口径、状态项自愈、电池健康度、
磁盘读写速率、SSD SMART 累计读写与健康度、折线图 Y 轴同时覆盖两条曲线、关于窗口、
流向图 CPU / GPU / ANE / DRAM 分项、界面以英文为主可切中文、登录时启动、macOS 13+ 通用二进制。
