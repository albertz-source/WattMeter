# WattMeter 1.5.0

A native macOS menu-bar power monitor: live power (adapter input by default), adapter vs battery
split, CPU / GPU / ANE / DRAM power, temperatures, fan speed, and a Sankey-style power-flow diagram.

## New

### Disk read / write throughput

Disk activity is now sampled once per second, from the IORegistry `IOBlockStorageDriver`
`Statistics` counters (`Bytes (Read)` / `Bytes (Write)`, cumulative since boot):

- **read / write throughput** in MB/s — the per-second delta of those counters
- **volume free space** of the boot volume, with the used percentage
- **cumulative read / written since boot**
- physical disks are summed (internal SSD + external drives); mounted disk images are excluded

Where it shows up:

- **Menu bar panel**: a new strip under the temperature chips — `read 11.4 MB/s`, `write 3.4 MB/s`,
  `free 420.3 GB · used 58%`. The panel grew from 720 to 750 pt.
- **Main window**: a “Disk I/O” card under the charts.
- **Menu bar tooltip**: read / write rates and free space.

### Diagnostics

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --disk
```

prints the number of disks, the 1-second read / write rates, the since-boot totals and the boot
volume capacity.

## Also included since 1.2.2

Everything from 1.3.x and 1.4.0: menu bar shows adapter input (metric switchable), self-healing
status item, battery health with full-charge / design capacity and cycle count, split line-chart
Y domain, About window, flow diagram with CPU / GPU / ANE / DRAM branches, English-primary UI with
Chinese available, launch at login, macOS 13+ universal binary.

## Requirements

- **macOS 13 or later** (macOS 13 / 14 / 15 and newer)
- **Apple Silicon (M-series) or Intel Mac** — universal binary (`arm64` + `x86_64`)
- No root, no kernel extension, no network access; the app only reads IOKit / SMC

## Install

1. Download **WattMeter-1.5.0.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

### 新增：磁盘读写速率

磁盘状态每秒采样一次，数据来自 IORegistry 的 `IOBlockStorageDriver` → `Statistics`
（`Bytes (Read)` / `Bytes (Write)`，开机以来的累计字节数）：

- **读写速率**（MB/s）：累计计数器的每秒增量
- **启动卷可用空间**与已用百分比
- **本次开机累计读写量**
- 多块物理磁盘求和（内置 SSD + 外接硬盘），挂载的磁盘映像（DMG）会被排除

显示位置：

- **菜单栏面板**：温度条下方新增一条 —— `读 11.4 MB/s`、`写 3.4 MB/s`、`可用 420.3 GB · 已用 58%`，
  面板高度 720 → 750；
- **主窗口**：图表下方新增「磁盘读写」卡片；
- **菜单栏 tooltip**：读写速率与可用空间。

### 诊断命令

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --disk
```

输出磁盘数量、1 秒窗口的读写速率、开机累计读写量，以及启动卷容量。

### 同时包含 1.2.2 以来的全部更新

包括 1.3.x 与 1.4.0 的全部内容：菜单栏默认显示电源输入并可切换口径、状态项自愈、电池健康度
（满充 / 设计容量与循环次数）、折线图 Y 轴同时覆盖两条曲线、关于窗口、流向图 CPU / GPU / ANE /
DRAM 分项、界面以英文为主可切中文、登录时启动、macOS 13+ 通用二进制。
