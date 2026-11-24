# WattMeter 1.7.1

A native macOS menu-bar power monitor: live power (adapter input by default), adapter vs battery
split, CPU / GPU / ANE / DRAM power, temperatures, fan speed, battery health, disk / SSD SMART,
memory, network and a Sankey-style power-flow diagram.

## New

### Memory usage

Read with `host_statistics64` (same source as Activity Monitor):

- **used %** = (App + Wired + Compressed) ÷ physical memory
- **used / total** in binary units, so a 16 GB Mac reads `16.0 GB`
- swap usage when swap is in use

### Network: one row per connection

Every **connected** interface is listed separately, not merged into a single number — a MacBook with
Ethernet and Wi-Fi shows both:

```
en0  1.0 Gb/s   ↓ 374 KB/s  ↑ 449 KB/s
en1  346 Mb/s   ↓ 135 KB/s  ↑ 19 KB/s
Since boot      ↓ 256 MB    ↑ 5.3 GB
```

Per interface: **link speed** (Ethernet / Wi-Fi PHY rate from `if_baudrate`), **download / upload
rate** (per-second delta of the kernel's 64-bit counters) and the **type** (Wi-Fi vs Ethernet, from
`IOUserNetworkWLAN` on Apple Silicon and `IO80211Interface` on Intel). The aggregate since-boot
in / out is shown on its own line, and the tooltip lists every interface with its own totals.

Only `en*` interfaces with an address are counted; VPN (`utun*`), AirDrop (`awdl0`, `llw0`) and
bridges are excluded so traffic is not double-counted.

Where it shows up:

- **Menu bar panel**: RAM chip plus one chip per connection (`en0 1.0 Gb/s`, `en1 346 Mb/s`) and a
  line with the aggregate rates and since-boot traffic (panel 800 → 816 pt).
- **Main window**: “Memory / network” card with one row per interface.
- **Menu bar tooltip**: every interface with rates and totals.
- **About → Copy diagnostics** includes memory, network and SSD sections.

### Diagnostics

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --system
```

prints memory (with App / Wired / Compressed / swap), every connected interface with link speed,
1-second rates and since-boot totals.

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

1. Download **WattMeter-1.7.1.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

### 新增：内存使用率

用 `host_statistics64` 读取（与活动监视器同源）：使用率 =（App + Wired + Compressed）÷ 物理内存；
已用 / 总量用 1024 进制显示（16 GB 机型显示 `16.0 GB`）；有交换区时显示交换用量。

### 新增：网络按「每种连接方式」分别显示

不再把所有网卡合并成一个数字 —— 同时接了以太网和 Wi-Fi 的 MacBook 会分别列出来：

```
en0  1.0 Gb/s   ↓ 374 KB/s  ↑ 449 KB/s
en1  346 Mb/s   ↓ 135 KB/s  ↑ 19 KB/s
开机以来        ↓ 256 MB    ↑ 5.3 GB
```

每个接口显示：**连接速率**（以太网 / Wi-Fi 的 `if_baudrate`）、**下载 / 上传速率**
（内核 64 位计数器的每秒增量）、**类型**（Apple Silicon 走 `IOUserNetworkWLAN`、Intel 走
`IO80211Interface` 判断 Wi-Fi）。开机以来的累计流量单独一行，tooltip 里每个接口都有各自的累计量。

只统计「已连接（有地址）的 en* 接口」；VPN（`utun*`）、AirDrop（`awdl0` / `llw0`）、桥接接口不计入，
避免重复计数。

显示位置：

- **菜单栏面板**：内存徽章 + 每种连接一个徽章（`en0 1.0 Gb/s`、`en1 346 Mb/s`），下面一行是合计速率
  与开机以来的流量（面板 800 → 816）；
- **主窗口**：「内存 / 网络」卡片，每个接口一行；
- **菜单栏 tooltip**：逐接口列出速率与累计；
- **关于 → 复制诊断信息**：包含内存、网络、SSD 三部分。

### 诊断命令

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --system
```

输出内存（App / Wired / Compressed / 交换）、每个已连接接口的连接速率、1 秒速率与开机以来流量。

### 同时包含 1.2.2 以来的全部更新

包括 1.3.x–1.6.0 的全部内容：菜单栏默认显示电源输入并可切换口径、状态项自愈、电池健康度、
磁盘读写速率、SSD SMART、折线图 Y 轴同时覆盖两条曲线、关于窗口、流向图 CPU / GPU / ANE / DRAM
分项、界面以英文为主可切中文、登录时启动、macOS 13+ 通用二进制。
