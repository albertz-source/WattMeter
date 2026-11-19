//
//  CSystemPower.h
//  WattMeter
//
//  免 root 的系统功率数据采集：
//   1) AppleSMC 用户客户端（PSTR / PDTR / PD0R 等 flt 功率键）
//   2) IORegistry: AppleSmartBattery（电池电压/电流、适配器参数、PowerTelemetryData）
//   3) IOPS: 电池电量、充放电状态、剩余时间、当前供电源
//
//  所有函数都可以从任意后台线程调用。
//

#ifndef CSYSTEMPOWER_H
#define CSYSTEMPOWER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SPReading {
    /* ---- 电池 / 供电状态（IOPS + IORegistry） ---- */
    int32_t batteryInstalled;     // 是否有内置电池（台式机为 0）
    int32_t externalConnected;    // 是否接着电源
    int32_t isCharging;
    int32_t isCharged;

    /* ---- AppleSmartBattery.PowerTelemetryData（约 20s 才刷新一次，仅作兜底/取损耗） ---- */
    int32_t telemetryAvailable;
    double  systemPowerIn_mW;         // 适配器 -> 系统
    double  systemLoad_mW;            // 系统负载
    double  batteryPower_mW;          // 电池功率（符号含义随机型，仅作兜底）
    double  adapterEfficiencyLoss_mW; // 适配器/充电电路损耗估计
    double  systemVoltageIn_mV;       // 适配器输入电压（遥测，约 20 秒刷新）
    double  systemCurrentIn_mA;       // 适配器输入电流（遥测，约 20 秒刷新）

    /* ---- AppleSmartBattery.AdapterDetails ---- */
    int32_t adapterKnown;
    double  adapterRatedWatts;    // 适配器额定功率
    double  adapterVoltage_mV;
    double  adapterCurrent_mA;
    char    adapterName[128];

    /* ---- USB-C 对外供电分轨（D1..D4，逐通道） ---- */
    int32_t portRailCount;
    double  portRailPower_W[4];

    /* ---- 适配器输入电压 / 电流（SMC VD0R / ID0R） ---- */
    int32_t smcHasInputRails;
    double  smcInputVoltage_V;
    double  smcInputCurrent_A;

    /* ---- 电池电气量（AppleSmartBattery） ---- */
    double  batteryVoltage_mV;
    double  batteryAmperage_mA;   // 有符号：Apple 约定负值=放电
    double  socPercent;           // 0-100，-1 表示未知
    double  timeRemainingMinutes; // <0 表示未知/不限
    char    powerSourceState[32]; // "AC Power" / "Battery Power" / "Unknown"

    /* ---- 芯片分项功率（W，读不到为 NaN；来自 IOReport Energy Model） ---- */
    int32_t cpuPowerAvailable;
    int32_t gpuPowerAvailable;
    int32_t anePowerAvailable;
    int32_t dramPowerAvailable;
    double  cpuPowerW;
    double  gpuPowerW;
    double  anePowerW;
    double  dramPowerW;

    /* ---- 温度（°C，读不到为 NaN） ---- */
    double  cpuTempC;      // Tp* 集群传感器取最大；Intel 回退 TC0P/TC0D
    double  gpuTempC;      // Tg0D / Tg0B / Tg0P，Intel TG0P
    double  ssdTempC;      // TH0x / TH0a..TH0p
    double  batteryTempC;  // TB0T / TB1T
    double  platformTempC; // Ts0P / Ts1P / TsOP

    /* ---- 风扇（F0Ac / F0Mn / F0Mx） ---- */
    int32_t fanAvailable;
    int32_t fanCount;        /* 识别到的风扇数量（0..4） */
    double  fanRPM;          /* 多风扇时取最大值 */
    double  fanMinRPM;
    double  fanMaxRPM;
    double  fanTargetRPM;

    /* ---- 分项功率（笔记本机型可用） ---- */
    int32_t displayAvailable;     // 内置屏幕背光是否可读
    double  displayPower_W;       // SMC PDBR / PBwo / PBLR
    int32_t portTelemetryAvailable;
    double  portPower_W;          // PowerOutDetails 汇总（对外供电，W）

    /* ---- AppleSMC ---- */
    int32_t smcAvailable;
    int32_t smcHasSystemPower;      // PSTR
    int32_t smcHasAdapterPower;     // PDTR
    int32_t smcHasDesktopInputPower;// PD0R（台式机 DC 输入）
    double  smcSystemPower_W;
    double  smcAdapterPower_W;
    double  smcDesktopInputPower_W;
} SPReading;

typedef struct SPReader SPReader;

/* 创建/销毁读取器（内部会保持 AppleSMC 连接与 AppleSmartBattery 服务句柄） */
SPReader *sp_reader_create(void);
void      sp_reader_destroy(SPReader *reader);

/* 采集一次。返回 0 表示成功（部分字段可能缺失）。 */
int32_t sp_reader_read(SPReader *reader, SPReading *out);

/* 读取任意 SMC flt 键；返回 0 表示成功。用于扩展/调试。 */
int32_t sp_reader_read_smc_float(SPReader *reader, const char *key, double *out);

/* 该 SMC 键是否存在且为 flt 类型；返回 1/0。 */
int32_t sp_reader_smc_key_exists(SPReader *reader, const char *key);

/* 把所有风扇相关 SMC 键（F*）的名称、类型、数值写入缓冲区，供诊断使用。
   返回写入的字节数（不含结尾 0）。 */
int32_t sp_reader_dump_fan_keys(SPReader *reader, char *buffer, int32_t size);

/* 导出 IOReport 能耗通道（诊断 CPU/GPU/ANE/DRAM 读数用）。 */
int32_t sp_reader_dump_energy_channels(SPReader *reader, char *buffer, int32_t size);

#ifdef __cplusplus
}
#endif

#endif /* CSYSTEMPOWER_H */
