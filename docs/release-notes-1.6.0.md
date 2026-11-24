# WattMeter 1.6.0

A native macOS menu-bar power monitor: live power (adapter input by default), adapter vs battery
split, CPU / GPU / ANE / DRAM power, temperatures, fan speed, and a Sankey-style power-flow diagram.

## New

### SSD SMART: lifetime writes, lifetime reads and health

The drive's own NVMe SMART/health log (log page `0x02`) is now read directly — no root, no helper
tool. The app goes through the same private interface `smartctl` uses (`NVMeSMARTLib.plugin`,
`IONVMeSMARTInterface::GetLogPage`), so it works as a normal user:

| Value | Source |
| --- | --- |
| Lifetime written | `Data Units Written` × 512,000 bytes |
| Lifetime read | `Data Units Read` × 512,000 bytes |
| Health | 100% − `Percentage Used` |
| Available spare / threshold | `Available Spare`, `Available Spare Threshold` |
| Power-on hours / power cycles / unsafe shutdowns | SMART log |
| NVMe temperature | SMART log |

On the development Mac (APPLE SSD AP0256Z): **61.05 TB read, 31.79 TB written, 98% health**
(2% of rated life used), 1237 power-on hours, 2889 power cycles — the same numbers `smartctl -a`
reports.

Where it shows up:

- **Menu bar panel**: a second disk line under the read/write chips —
  `SSD written 31.79 TB · read 61.05 TB · Health 98%` (panel 750 → 770 pt).
- **Main window**: the “Disk I/O” card gains chips for lifetime written / read / health.
- **Menu bar tooltip**: adds the SSD line.
- **About → Copy diagnostics** and `--battery` include the SSD line.

Only shown when the boot disk is an NVMe drive that exposes SMART; on SATA or external-only setups
the line is hidden instead of guessing.

### Diagnostics

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --ssd    # model, health, lifetime read/write, power data
/Applications/WattMeter.app/Contents/MacOS/WattMeter --disk   # rates + volume capacity
```

## Also included since 1.2.2

Everything from 1.3.x–1.5.0: menu bar shows adapter input (metric switchable), self-healing status
item, battery health with full-charge / design capacity and cycle count, disk read / write
throughput, split line-chart Y domain, About window, flow diagram with CPU / GPU / ANE / DRAM
branches, English-primary UI with Chinese available, launch at login, macOS 13+ universal binary.

## Requirements

- **macOS 13 or later** (macOS 13 / 14 / 15 and newer)
- **Apple Silicon (M-series) or Intel Mac** — universal binary (`arm64` + `x86_64`)
- No root, no kernel extension, no network access; the app only reads IOKit / SMC

## Install

1. Download **WattMeter-1.6.0.dmg** and open it.
2. Drag **WattMeter.app** into Applications, eject.
3. First launch: right-click → Open (ad-hoc signed), or
   `xattr -dr com.apple.quarantine /Applications/WattMeter.app`

## 简体中文

### 新增：SSD SMART —— 累计写入量、累计读取量、健康度

现在直接读取 NVMe 的 SMART / 健康日志（log page `0x02`），**不需要 root、不依赖第三方工具**。
走的是和 `smartctl` 相同的私有接口（`NVMeSMARTLib.plugin` 的
`IONVMeSMARTInterface::GetLogPage`），普通用户即可读取：

| 数值 | 来源 |
| --- | --- |
| 累计写入量 | `Data Units Written` × 512,000 字节 |
| 累计读取量 | `Data Units Read` × 512,000 字节 |
| 健康度 | 100% − `Percentage Used` |
| 可用备用块 / 阈值 | `Available Spare`、`Available Spare Threshold` |
| 通电小时 / 上电次数 / 异常断电次数 | SMART 日志 |
| NVMe 温度 | SMART 日志 |

开发机实测（APPLE SSD AP0256Z）：**累计读取 61.05 TB、累计写入 31.79 TB、健康度 98%**
（寿命已用 2%），通电 1237 小时、上电 2889 次 —— 与 `smartctl -a` 的数值一致。

显示位置：

- **菜单栏面板**：磁盘读写徽章下方新增一行 ——
  `SSD 累计写入 31.79 TB · 累计读取 61.05 TB · 健康度 98%`（面板 750 → 770）；
- **主窗口**：「磁盘读写」卡片新增累计写入 / 累计读取 / 健康度三个徽章；
- **菜单栏 tooltip**：增加 SSD 一行；
- **关于 → 复制诊断信息** 与 `--battery` 也会输出 SSD 信息。

只有启动盘是支持 SMART 的 NVMe 时才会显示；SATA 或纯外接盘的机器直接隐藏，不做猜测。

### 诊断命令

```bash
/Applications/WattMeter.app/Contents/MacOS/WattMeter --ssd    # 型号、健康度、累计读写、通电数据
/Applications/WattMeter.app/Contents/MacOS/WattMeter --disk   # 读写速率与卷容量
```

### 同时包含 1.2.2 以来的全部更新

包括 1.3.x–1.5.0 的全部内容：菜单栏默认显示电源输入并可切换口径、状态项自愈、电池健康度、
磁盘读写速率、折线图 Y 轴同时覆盖两条曲线、关于窗口、流向图 CPU / GPU / ANE / DRAM 分项、
界面以英文为主可切中文、登录时启动、macOS 13+ 通用二进制。
