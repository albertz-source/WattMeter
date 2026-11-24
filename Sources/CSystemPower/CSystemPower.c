//
//  CSystemPower.c
//  WattMeter
//
//  实现见 CSystemPower.h 顶部说明。
//

#include "CSystemPower.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <dlfcn.h>

/* ------------------------------------------------------------------ */
/* AppleSMC                                                            */
/* ------------------------------------------------------------------ */

#define SMC_KERNEL_INDEX   2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9
#define SMC_KEY_FLT       0x666c7420u /* 'flt ' */
#define SMC_KEY_FPE2      0x66706532u /* 'fpe2'：无符号 16 位 / 4 */
#define SMC_KEY_SP78      0x73703738u /* 'sp78'：有符号 16 位 / 256 */

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved[1];
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t   key;
    SMCVers    vers;
    SMCPLimit  pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t    result;
    uint8_t    status;
    uint8_t    data8;
    uint32_t   data32;
    uint8_t    bytes[32];
} SMCKeyData;

#define SP_MAX_CPU_KEYS 48
#define SP_MAX_GPU_KEYS 32
#define SP_MAX_SSD_KEYS 24

/* ---- IOReport（私有框架）动态加载：用于 CPU / GPU / ANE / DRAM 分项功率 ---- */
typedef struct {
    void *handle;
    CFMutableDictionaryRef (*copyChannels)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
    CFMutableDictionaryRef (*createSubscription)(void *, CFMutableDictionaryRef,
                                                 CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    CFDictionaryRef (*createSamples)(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*createSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    CFStringRef (*channelName)(CFDictionaryRef);
    CFStringRef (*channelGroup)(CFDictionaryRef);
    CFStringRef (*channelSubGroup)(CFDictionaryRef);
    CFStringRef (*channelUnit)(CFDictionaryRef);
    int64_t (*simpleValue)(CFDictionaryRef, int);
    int (*stateCount)(CFDictionaryRef);
    CFStringRef (*stateName)(CFDictionaryRef, int);
    int64_t (*stateResidency)(CFDictionaryRef, int);
    void (*mergeChannels)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    int cpuFromPMP;   /* macOS 27 门控 Energy Model CPU 后固定使用 PMP */
    CFMutableDictionaryRef subscription;
    CFMutableDictionaryRef subscribed;
    CFDictionaryRef previous;
    double previousTime;
    int ready;
} SPIOReport;

struct SPReader {
    io_service_t  smcService;
    io_connect_t  smcConnection;
    int           smcReady;
    /* 温度键随机型不同，启动时枚举一次并缓存 */
    char cpuKeys[SP_MAX_CPU_KEYS][5];
    int  cpuKeyCount;
    char gpuKeys[SP_MAX_GPU_KEYS][5];
    int  gpuKeyCount;
    char ssdKeys[SP_MAX_SSD_KEYS][5];
    int  ssdKeyCount;
    /* 风扇键：不同机型命名/类型不同，也做一次枚举 */
    char fanKeys[64][5];       /* 所有 F 开头键（诊断用） */
    int  fanKeyCount;
    char fanActualKeys[4][5];  /* F?Ac 实际转速 */
    int  fanActualCount;
    char fanTargetKeys[4][5];  /* F?Tg 目标转速 */
    int  fanTargetCount;
    char fanMinKeys[4][5];     /* F?Mn */
    int  fanMinCount;
    char fanMaxKeys[4][5];     /* F?Mx */
    int  fanMaxCount;
    SPIOReport io;
};

static kern_return_t smc_call(io_connect_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, SMC_KERNEL_INDEX,
                                     in, sizeof(SMCKeyData),
                                     out, &outSize);
}

static uint32_t smc_str2key(const char *s) {
    uint32_t k = 0;
    for (int i = 0; i < 4; i++) {
        k = (k << 8) | (uint8_t)s[i];
    }
    return k;
}

/* 读取键的元信息；返回 0 成功 */
static int smc_key_info(io_connect_t conn, const char *key,
                        uint32_t *dataType, uint8_t *dataSize) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = smc_str2key(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS) return -1;
    if (out.result != 0) return -2;
    if (dataType) *dataType = out.keyInfo.dataType;
    if (dataSize) *dataSize = out.keyInfo.dataSize;
    return 0;
}

/* 读取键的原始字节；返回 0 成功 */
static int smc_read_raw(io_connect_t conn, const char *key,
                        uint8_t *bytes, uint8_t size) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = smc_str2key(key);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS) return -1;
    if (out.result != 0) return -2;
    memcpy(bytes, out.bytes, size);
    return 0;
}

/* 读取 flt 键，单位 W。返回 0 成功 */
static int smc_read_flt(io_connect_t conn, const char *key, double *value) {
    uint32_t type = 0;
    uint8_t  size = 0;
    if (smc_key_info(conn, key, &type, &size) != 0) return -1;
    if (type != SMC_KEY_FLT || size != 4) return -2;
    uint8_t raw[4] = {0, 0, 0, 0};
    if (smc_read_raw(conn, key, raw, 4) != 0) return -3;
    float f = 0;
    memcpy(&f, raw, sizeof f);
    if (!(f == f) || f < -1000.0f || f > 1000.0f) return -4; /* NaN / 明显异常 */
    *value = (double)f;
    return 0;
}

/* 通用数值读取：支持 flt / fpe2 / sp78。返回 0 成功。 */
static int smc_read_number(io_connect_t conn, const char *key, double *value) {
    uint32_t type = 0;
    uint8_t  size = 0;
    if (smc_key_info(conn, key, &type, &size) != 0) return -1;
    if (size == 0 || size > 32) return -2;
    uint8_t raw[32] = {0};
    if (smc_read_raw(conn, key, raw, size) != 0) return -3;
    if (type == SMC_KEY_FLT && size == 4) {
        float f = 0;
        memcpy(&f, raw, sizeof f);
        *value = (double)f;
    } else if (type == SMC_KEY_FPE2 && size == 2) {
        *value = (double)(((uint16_t)raw[0] << 8) | raw[1]) / 4.0;
    } else if (type == SMC_KEY_SP78 && size == 2) {
        int16_t v = (int16_t)(((uint16_t)raw[0] << 8) | raw[1]);
        *value = (double)v / 256.0;
    } else {
        return -4;
    }
    if (!(*value == *value)) return -5; /* NaN */
    return 0;
}

/* 读一个温度键；不可读或超出合理范围返回 NAN */
static double smc_read_temp(io_connect_t conn, const char *key) {
    double v = 0;
    if (smc_read_number(conn, key, &v) != 0) return NAN;
    if (!(v > -20.0 && v < 150.0)) return NAN;
    return v;
}

/* 依次尝试多个键，返回第一个可读的温度 */
static double smc_first_temp(io_connect_t conn, const char *const *keys, int count) {
    for (int i = 0; i < count; i++) {
        double v = smc_read_temp(conn, keys[i]);
        if (!isnan(v)) return v;
    }
    return NAN;
}

/* 取多个键中的最高温度 */
static double smc_max_temp(io_connect_t conn, const char *const *keys, int count) {
    double best = NAN;
    for (int i = 0; i < count; i++) {
        double v = smc_read_temp(conn, keys[i]);
        if (isnan(v)) continue;
        if (isnan(best) || v > best) best = v;
    }
    return best;
}

/* 风扇数值解码：兼容 flt / fpe2 / sp78 / ui16 / ui8 / si16 */
static int smc_read_fan_value(io_connect_t conn, const char *key, double *value) {
    uint32_t type = 0;
    uint8_t  size = 0;
    if (smc_key_info(conn, key, &type, &size) != 0) return -1;
    if (size == 0 || size > 32) return -2;
    uint8_t raw[32] = {0};
    if (smc_read_raw(conn, key, raw, size) != 0) return -3;

    if (type == SMC_KEY_FLT && size == 4) {
        float f = 0;
        memcpy(&f, raw, 4);
        *value = (double)f;
    } else if (type == SMC_KEY_FPE2 && size == 2) {
        *value = (double)(((uint16_t)raw[0] << 8) | raw[1]) / 4.0;
    } else if (type == SMC_KEY_SP78 && size == 2) {
        *value = (double)((int16_t)(((uint16_t)raw[0] << 8) | raw[1])) / 256.0;
    } else if (type == 0x75693136 && size == 2) {   /* 'ui16'，大端 */
        *value = (double)(((uint16_t)raw[0] << 8) | raw[1]);
    } else if (type == 0x75693820 && size == 1) {   /* 'ui8 ' */
        *value = (double)raw[0];
    } else if (type == 0x73693136 && size == 2) {   /* 'si16'，大端有符号 */
        *value = (double)((int16_t)(((uint16_t)raw[0] << 8) | raw[1]));
    } else {
        return -4;
    }
    if (!(*value == *value)) return -5;
    return 0;
}

/* 读取 SMC 键总数（#KEY） */
static int smc_key_count(io_connect_t conn) {
    uint32_t type = 0;
    uint8_t  size = 0;
    if (smc_key_info(conn, "#KEY", &type, &size) != 0 || size != 4) return -1;
    uint8_t raw[4] = {0};
    if (smc_read_raw(conn, "#KEY", raw, 4) != 0) return -1;
    uint32_t n = ((uint32_t)raw[0] << 24) | ((uint32_t)raw[1] << 16)
               | ((uint32_t)raw[2] << 8) | raw[3];
    if (n == 0 || n > 4096) return -1;
    return (int)n;
}

/* 按索引取键名（GET_KEY_BY_INDEX） */
static int smc_key_at(io_connect_t conn, int index, char out[5]) {
    SMCKeyData in, outData;
    memset(&in, 0, sizeof in);
    memset(&outData, 0, sizeof outData);
    in.data8 = 8;
    in.data32 = (uint32_t)index;
    if (smc_call(conn, &in, &outData) != KERN_SUCCESS || outData.result != 0) return -1;
    uint32_t k = outData.key;
    out[0] = (char)(k >> 24);
    out[1] = (char)((k >> 16) & 0xff);
    out[2] = (char)((k >> 8) & 0xff);
    out[3] = (char)(k & 0xff);
    out[4] = 0;
    return 0;
}

static void add_temp_key(char (*list)[5], int *count, int max, const char *key) {
    if (*count >= max) return;
    memcpy(list[*count], key, 5);
    (*count)++;
}

/* 启动时枚举 SMC 键，找出 CPU（Tp*）、GPU（Tg*）、SSD（TH0*）温度传感器。
   不同机型后缀不一样（例如 M2 是 Tg0e/f/m/n/q/r），所以不能写死。 */
static void discover_temp_keys(SPReader *r) {
    if (r->smcReady) {
        int n = smc_key_count(r->smcConnection);
        for (int i = 0; i < n; i++) {
            char k[5];
            if (smc_key_at(r->smcConnection, i, k) != 0) continue;
            if (k[0] == 'F' && r->fanKeyCount < 64) {
                memcpy(r->fanKeys[r->fanKeyCount++], k, 5);
                if (k[2] == 'A' && (k[3] == 'c' || k[3] == 'C')) {
                    add_temp_key(r->fanActualKeys, &r->fanActualCount, 4, k);
                } else if (k[2] == 'T' && k[3] == 'g') {
                    add_temp_key(r->fanTargetKeys, &r->fanTargetCount, 4, k);
                } else if (k[2] == 'M' && k[3] == 'n') {
                    add_temp_key(r->fanMinKeys, &r->fanMinCount, 4, k);
                } else if (k[2] == 'M' && k[3] == 'x') {
                    add_temp_key(r->fanMaxKeys, &r->fanMaxCount, 4, k);
                }
                continue;
            }
            if (k[0] != 'T') continue;
            if (k[1] == 'p') {
                add_temp_key(r->cpuKeys, &r->cpuKeyCount, SP_MAX_CPU_KEYS, k);
            } else if (k[1] == 'g') {
                add_temp_key(r->gpuKeys, &r->gpuKeyCount, SP_MAX_GPU_KEYS, k);
            } else if (k[1] == 'H' && k[2] == '0') {
                add_temp_key(r->ssdKeys, &r->ssdKeyCount, SP_MAX_SSD_KEYS, k);
            }
        }
    }
    /* 固定兜底：Intel 机型用大写 TC/TG，部分机型 SSD 键大小写不同 */
    if (r->cpuKeyCount == 0) {
        static const char *intel[] = {"TC0P", "TC0D", "TC0E", "TC0F", "TC0H"};
        for (int i = 0; i < 5; i++) add_temp_key(r->cpuKeys, &r->cpuKeyCount, SP_MAX_CPU_KEYS, intel[i]);
    }
    if (r->gpuKeyCount == 0) {
        static const char *intel[] = {"Tg0D", "Tg0B", "Tg0P", "Tg0V", "TG0P", "TG0D"};
        for (int i = 0; i < 6; i++) add_temp_key(r->gpuKeys, &r->gpuKeyCount, SP_MAX_GPU_KEYS, intel[i]);
    }
    if (r->fanActualCount == 0) {
        /* 枚举失败时退回常见键名 */
        static const char *fixedActual[] = {"F0Ac", "F0AC", "F1Ac", "F1AC"};
        static const char *fixedTarget[] = {"F0Tg", "F1Tg"};
        static const char *fixedMin[] = {"F0Mn", "F1Mn"};
        static const char *fixedMax[] = {"F0Mx", "F1Mx"};
        for (int i = 0; i < 2; i++) {
            add_temp_key(r->fanActualKeys, &r->fanActualCount, 4, fixedActual[i]);
            add_temp_key(r->fanTargetKeys, &r->fanTargetCount, 4, fixedTarget[i]);
            add_temp_key(r->fanMinKeys, &r->fanMinCount, 4, fixedMin[i]);
            add_temp_key(r->fanMaxKeys, &r->fanMaxCount, 4, fixedMax[i]);
        }
    }
    if (r->ssdKeyCount == 0) {
        static const char *fixed[] = {"TH0x", "TH0a", "TH0b", "TH0c", "TH0d", "TH0e", "TH0f", "TH0P"};
        for (int i = 0; i < 8; i++) add_temp_key(r->ssdKeys, &r->ssdKeyCount, SP_MAX_SSD_KEYS, fixed[i]);
    }
}

static double max_temp_from_keys(io_connect_t conn, char keys[][5], int count) {
    double best = NAN;
    for (int i = 0; i < count; i++) {
        double v = smc_read_temp(conn, keys[i]);
        if (isnan(v)) continue;
        if (isnan(best) || v > best) best = v;
    }
    return best;
}

static double first_temp_from_keys(io_connect_t conn, char keys[][5], int count) {
    for (int i = 0; i < count; i++) {
        double v = smc_read_temp(conn, keys[i]);
        if (!isnan(v)) return v;
    }
    return NAN;
}

/* ------------------------------------------------------------------ */
/* CoreFoundation 辅助                                                  */
/* ------------------------------------------------------------------ */

static int cf_bool(CFDictionaryRef d, CFStringRef k, int fallback) {
    if (!d) return fallback;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    }
    return fallback;
}

/* 读取有符号电流：某些机型把 32 位补码存成无符号数（如 4294966296 表示 -1000） */
static double cf_signed_number(CFDictionaryRef d, CFStringRef k) {
    if (!d) return 0;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID()) return 0;
    int64_t value = 0;
    if (!CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &value)) return 0;
    if (value > INT32_MAX && value <= (int64_t)UINT32_MAX) {
        return (double)(int32_t)(uint32_t)value;
    }
    return (double)value;
}

static double cf_double(CFDictionaryRef d, CFStringRef k, double fallback) {
    if (!d) return fallback;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
        double x = fallback;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &x)) return x;
    }
    return fallback;
}

static CFDictionaryRef cf_dict(CFDictionaryRef d, CFStringRef k) {
    if (!d) return NULL;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (v && CFGetTypeID(v) == CFDictionaryGetTypeID()) return (CFDictionaryRef)v;
    return NULL;
}

static void cf_string(CFDictionaryRef d, CFStringRef k, char *buf, size_t len) {
    if (!buf || len == 0) return;
    buf[0] = '\0';
    if (!d) return;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)v, buf, (CFIndex)len, kCFStringEncodingUTF8);
    }
}

/* ------------------------------------------------------------------ */
/* 磁盘 I/O：IOBlockStorageDriver.Statistics（累计字节数）               */
/* ------------------------------------------------------------------ */

static void read_disk_stats(SPReading *r) {
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOBlockStorageDriver"), &iter) != KERN_SUCCESS) {
        return;
    }

    int count = 0;
    double readBytes = 0, writeBytes = 0, readOps = 0, writeOps = 0;
    io_service_t svc = 0;
    while ((svc = IOIteratorNext(iter))) {
        /* 排除磁盘映像（挂载 DMG 会产生一个虚拟磁盘），只统计真实磁盘 */
        int isImage = 0;
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(svc, kIOServicePlane, &parent) == KERN_SUCCESS) {
            CFTypeRef chars = IORegistryEntryCreateCFProperty(parent, CFSTR("Device Characteristics"),
                                                             kCFAllocatorDefault, 0);
            if (chars && CFGetTypeID(chars) == CFDictionaryGetTypeID()) {
                char product[128] = {0};
                cf_string((CFDictionaryRef)chars, CFSTR("Product Name"), product, sizeof product);
                if (strstr(product, "Disk Image") != NULL || strstr(product, "DiskImage") != NULL) {
                    isImage = 1;
                }
            }
            if (chars) CFRelease(chars);
            IOObjectRelease(parent);
        }

        if (!isImage) {
            CFTypeRef stats = IORegistryEntryCreateCFProperty(svc, CFSTR("Statistics"),
                                                             kCFAllocatorDefault, 0);
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                CFDictionaryRef d = (CFDictionaryRef)stats;
                readBytes  += cf_double(d, CFSTR("Bytes (Read)"), 0.0);
                writeBytes += cf_double(d, CFSTR("Bytes (Write)"), 0.0);
                readOps    += cf_double(d, CFSTR("Operations (Read)"), 0.0);
                writeOps   += cf_double(d, CFSTR("Operations (Write)"), 0.0);
                count++;
            }
            if (stats) CFRelease(stats);
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);

    if (count > 0) {
        r->diskAvailable = 1;
        r->diskCount = count;
        r->diskReadBytes = readBytes;
        r->diskWriteBytes = writeBytes;
        r->diskReadOps = readOps;
        r->diskWriteOps = writeOps;
    }
}

/* ------------------------------------------------------------------ */
/* AppleSmartBattery (IORegistry)                                      */
/* ------------------------------------------------------------------ */

static void read_smart_battery(SPReading *r) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSmartBattery"));
    if (!svc) return;

    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS) {
        IOObjectRelease(svc);
        return;
    }
    IOObjectRelease(svc);
    if (!props) return;

    r->batteryInstalled = cf_bool(props, CFSTR("BatteryInstalled"), 0);
    r->externalConnected = cf_bool(props, CFSTR("ExternalConnected"), 0);
    r->isCharging = cf_bool(props, CFSTR("IsCharging"), 0);
    r->isCharged = cf_bool(props, CFSTR("IsCharged"), 0);

    r->batteryVoltage_mV = cf_double(props, CFSTR("Voltage"), 0.0);
    r->batteryAmperage_mA = cf_signed_number(props, CFSTR("Amperage"));
    if (r->batteryAmperage_mA == 0.0) {
        /* InstantAmperage 更新更快，但某些机型没有 */
        r->batteryAmperage_mA = cf_signed_number(props, CFSTR("InstantAmperage"));
    }

    /* 容量 / 健康度 / 循环次数 */
    r->batteryDesignCapacity_mAh = cf_double(props, CFSTR("DesignCapacity"), -1.0);
    double fullCharge = cf_double(props, CFSTR("AppleRawMaxCapacity"), -1.0);
    if (fullCharge <= 0) {
        fullCharge = cf_double(props, CFSTR("NominalChargeCapacity"), -1.0);
    }
    if (fullCharge <= 0) {
        /* 老机型（Intel）的 MaxCapacity 是 mAh，Apple Silicon 上是百分比 */
        double legacyMax = cf_double(props, CFSTR("MaxCapacity"), -1.0);
        if (legacyMax > 200) fullCharge = legacyMax;
    }
    r->batteryFullChargeCapacity_mAh = fullCharge;
    r->batteryCycleCount = (int32_t)cf_double(props, CFSTR("CycleCount"), -1.0);
    r->batteryDesignCycleCount = (int32_t)cf_double(props, CFSTR("DesignCycleCount9C"), -1.0);
    if (r->batteryDesignCapacity_mAh > 100 && r->batteryFullChargeCapacity_mAh > 100 &&
        r->batteryFullChargeCapacity_mAh < 40000) {
        r->batteryCapacityAvailable = 1;
    }

    /* 适配器信息 */
    CFDictionaryRef adapter = cf_dict(props, CFSTR("AdapterDetails"));
    if (adapter) {
        double watts = cf_double(adapter, CFSTR("Watts"), 0.0);
        double volts = cf_double(adapter, CFSTR("Voltage"), 0.0);
        double amps  = cf_double(adapter, CFSTR("Current"), 0.0);
        char   name[128];
        cf_string(adapter, CFSTR("Name"), name, sizeof name);
        if (watts > 0 || name[0] != '\0') {
            r->adapterKnown = 1;
            r->adapterRatedWatts = watts;
            r->adapterVoltage_mV = volts;
            r->adapterCurrent_mA = amps;
            snprintf(r->adapterName, sizeof r->adapterName, "%s", name);
        }
    }

    /* 对外供电接口（PowerOutDetails，笔记本 / 带 USB-C 供电的机型） */
    {
        CFTypeRef po = CFDictionaryGetValue(props, CFSTR("PowerOutDetails"));
        if (po && CFGetTypeID(po) == CFArrayGetTypeID() && !r->portTelemetryAvailable) {
            CFArrayRef arr = (CFArrayRef)po;
            CFIndex n = CFArrayGetCount(arr);
            if (n > 0) {
                r->portTelemetryAvailable = 1;
                double sum = 0;
                for (CFIndex i = 0; i < n; i++) {
                    CFTypeRef item = CFArrayGetValueAtIndex(arr, i);
                    if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
                    /* PowerOutDetails.Watts 的单位是 mW，和 AdapterDetails.Watts 不同 */
                    double watts = cf_double((CFDictionaryRef)item, CFSTR("Watts"), -1);
                    if (watts > 0 && watts < 240000) sum += watts / 1000.0;
                }
                r->portPower_W = sum;
            }
        }
    }

    /* PowerTelemetryData（Apple Silicon；约 20 秒刷新一次） */
    CFDictionaryRef pt = cf_dict(props, CFSTR("PowerTelemetryData"));
    if (pt) {
        double inW  = cf_double(pt, CFSTR("SystemPowerIn"), -1.0);
        double load = cf_double(pt, CFSTR("SystemLoad"), -1.0);
        if (inW >= 0 || load >= 0) {
            r->telemetryAvailable = 1;
            r->systemPowerIn_mW = inW < 0 ? 0 : inW;
            r->systemLoad_mW = load < 0 ? 0 : load;
            r->batteryPower_mW = cf_double(pt, CFSTR("BatteryPower"), 0.0);
            r->adapterEfficiencyLoss_mW = cf_double(pt, CFSTR("AdapterEfficiencyLoss"), 0.0);
            r->systemVoltageIn_mV = cf_double(pt, CFSTR("SystemVoltageIn"), 0.0);
            r->systemCurrentIn_mA = cf_double(pt, CFSTR("SystemCurrentIn"), 0.0);
        }
    }

    CFRelease(props);
}

/* ------------------------------------------------------------------ */
/* IOPS（电池电量 / 状态 / 剩余时间 / 当前供电源）                      */
/* ------------------------------------------------------------------ */

static void read_iops(SPReading *r) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();      /* owned */
    if (info) {
        CFArrayRef sources = IOPSCopyPowerSourcesList(info); /* owned */
        if (sources) {
            CFIndex n = CFArrayGetCount(sources);
            for (CFIndex i = 0; i < n; i++) {
                CFTypeRef ps = CFArrayGetValueAtIndex(sources, i);
                CFDictionaryRef desc = IOPSGetPowerSourceDescription(info, ps);
                if (!desc) continue;

                CFStringRef type = (CFStringRef)CFDictionaryGetValue(desc, CFSTR(kIOPSTypeKey));
                int isBattery = type && CFGetTypeID(type) == CFStringGetTypeID() &&
                                CFStringCompare(type, CFSTR(kIOPSInternalBatteryType), 0) == kCFCompareEqualTo;

                if (!isBattery) continue;

                r->batteryInstalled = 1;

                CFStringRef state = (CFStringRef)CFDictionaryGetValue(desc, CFSTR(kIOPSPowerSourceStateKey));
                if (state && CFGetTypeID(state) == CFStringGetTypeID()) {
                    if (CFStringCompare(state, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo) {
                        r->externalConnected = 1;
                        snprintf(r->powerSourceState, sizeof r->powerSourceState, "%s", "AC Power");
                    } else if (CFStringCompare(state, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo) {
                        r->externalConnected = 0;
                        snprintf(r->powerSourceState, sizeof r->powerSourceState, "%s", "Battery Power");
                    }
                }

                CFBooleanRef charging = (CFBooleanRef)CFDictionaryGetValue(desc, CFSTR(kIOPSIsChargingKey));
                if (charging && CFGetTypeID(charging) == CFBooleanGetTypeID()) {
                    r->isCharging = CFBooleanGetValue(charging) ? 1 : 0;
                }
                CFBooleanRef charged = (CFBooleanRef)CFDictionaryGetValue(desc, CFSTR(kIOPSIsChargedKey));
                if (charged && CFGetTypeID(charged) == CFBooleanGetTypeID()) {
                    r->isCharged = CFBooleanGetValue(charged) ? 1 : 0;
                }

                double cur = cf_double(desc, CFSTR(kIOPSCurrentCapacityKey), -1.0);
                double max = cf_double(desc, CFSTR(kIOPSMaxCapacityKey), -1.0);
                if (cur >= 0 && max > 0) {
                    r->socPercent = cur / max * 100.0;
                }

                /* 电池健康度文案（"Good" / "Fair" / "Poor"，以及 "Service Battery" 等） */
                cf_string(desc, CFSTR(kIOPSBatteryHealthKey), r->batteryHealth, sizeof r->batteryHealth);
                cf_string(desc, CFSTR(kIOPSBatteryHealthConditionKey),
                          r->batteryHealthCondition, sizeof r->batteryHealthCondition);
                break;
            }
            CFRelease(sources);
        }
        CFRelease(info);
    }

    /* 供电源类型（兜底） */
    CFStringRef provider = IOPSGetProvidingPowerSourceType(NULL);
    if (provider && CFGetTypeID(provider) == CFStringGetTypeID()) {
        if (CFStringCompare(provider, CFSTR(kIOPSACPowerValue), 0) == kCFCompareEqualTo) {
            r->externalConnected = 1;
            if (r->powerSourceState[0] == '\0') {
                snprintf(r->powerSourceState, sizeof r->powerSourceState, "%s", "AC Power");
            }
        } else if (CFStringCompare(provider, CFSTR(kIOPSBatteryPowerValue), 0) == kCFCompareEqualTo) {
            r->externalConnected = 0;
            if (r->powerSourceState[0] == '\0') {
                snprintf(r->powerSourceState, sizeof r->powerSourceState, "%s", "Battery Power");
            }
        }
    }

    /* 剩余时间：IOPSGetTimeRemainingEstimate 返回秒，-1 未知 / -2 不限 */
    CFTimeInterval remaining = IOPSGetTimeRemainingEstimate();
    if (remaining > 0) {
        r->timeRemainingMinutes = remaining / 60.0;
    } else {
        r->timeRemainingMinutes = remaining; /* -1 / -2 原样保留 */
    }
}

/* ------------------------------------------------------------------ */
/* 对外 API                                                            */
/* ------------------------------------------------------------------ */

static void ioreport_init(SPReader *reader) {
    SPIOReport *io = &reader->io;
    memset(io, 0, sizeof *io);
    io->handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!io->handle) return;

    io->copyChannels = (CFMutableDictionaryRef (*)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t))
        dlsym(io->handle, "IOReportCopyChannelsInGroup");
    io->createSubscription = (CFMutableDictionaryRef (*)(void *, CFMutableDictionaryRef,
                                                         CFMutableDictionaryRef *, uint64_t, CFTypeRef))
        dlsym(io->handle, "IOReportCreateSubscription");
    io->createSamples = (CFDictionaryRef (*)(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef))
        dlsym(io->handle, "IOReportCreateSamples");
    io->createSamplesDelta = (CFDictionaryRef (*)(CFDictionaryRef, CFDictionaryRef, CFTypeRef))
        dlsym(io->handle, "IOReportCreateSamplesDelta");
    io->channelName = (CFStringRef (*)(CFDictionaryRef))dlsym(io->handle, "IOReportChannelGetChannelName");
    io->simpleValue = (int64_t (*)(CFDictionaryRef, int))dlsym(io->handle, "IOReportSimpleGetIntegerValue");
    io->channelGroup = (CFStringRef (*)(CFDictionaryRef))dlsym(io->handle, "IOReportChannelGetGroup");
    io->channelUnit = (CFStringRef (*)(CFDictionaryRef))dlsym(io->handle, "IOReportChannelGetUnitLabel");
    io->channelSubGroup = (CFStringRef (*)(CFDictionaryRef))dlsym(io->handle, "IOReportChannelGetSubGroup");
    io->stateCount = (int (*)(CFDictionaryRef))dlsym(io->handle, "IOReportStateGetCount");
    io->stateName = (CFStringRef (*)(CFDictionaryRef, int))dlsym(io->handle, "IOReportStateGetNameForIndex");
    io->stateResidency = (int64_t (*)(CFDictionaryRef, int))dlsym(io->handle, "IOReportStateGetResidency");
    io->mergeChannels = (void (*)(CFDictionaryRef, CFDictionaryRef, CFTypeRef))
        dlsym(io->handle, "IOReportMergeChannels");

    if (!io->copyChannels || !io->createSubscription || !io->createSamples ||
        !io->createSamplesDelta || !io->channelName || !io->simpleValue) {
        return;
    }

    /* 合并多个分组（mactop 的做法）：Energy Model 是主源，
       GPU Stats / CPU Stats / AMC Stats 提供不同系统的补充通道。 */
    CFMutableDictionaryRef merged = NULL;
    const char *groups[] = {"Energy Model", "Energy Counters", "GPU Stats", "CPU Stats", "AMC Stats",
                             "PMP", "PMP0", "PMP1", "PMP2", "PMP3"};
    for (int i = 0; i < 10; i++) {
        CFStringRef group = CFStringCreateWithCString(NULL, groups[i], kCFStringEncodingUTF8);
        CFMutableDictionaryRef ch = io->copyChannels(group, NULL, 0, 0, 0);
        CFRelease(group);
        if (!ch) continue;
        if (!merged) {
            merged = ch;
        } else if (io->mergeChannels) {
            io->mergeChannels(merged, ch, NULL);
            CFRelease(ch);
        } else {
            CFRelease(ch);
        }
    }
    if (!merged) return;

    CFMutableDictionaryRef subscribed = NULL;
    CFMutableDictionaryRef subscription = io->createSubscription(NULL, merged, &subscribed, 0, NULL);
    CFRelease(merged);
    if (!subscription) return;
    io->subscription = subscription;
    io->subscribed = subscribed;
    io->ready = 1;
}

static void ioreport_release(SPReader *reader) {
    SPIOReport *io = &reader->io;
    if (io->previous) CFRelease(io->previous);
    if (io->subscribed) CFRelease(io->subscribed);
    if (io->handle) dlclose(io->handle);
    memset(io, 0, sizeof *io);
}

/* 根据 IOReport 的单位标签把能量增量换算成瓦（mactop 的 energyToWatts） */
static double energy_to_watts(int64_t energy, CFStringRef unitRef, double durationSeconds) {
    if (durationSeconds <= 0.05) return NAN;
    double rate = (double)energy / durationSeconds;
    char unit[32] = {0};
    if (unitRef) {
        CFStringGetCString(unitRef, unit, sizeof unit, kCFStringEncodingUTF8);
        for (int i = 0; unit[i]; i++) {
            if (unit[i] == ' ') unit[i] = '\0';
        }
    }
    if (strcmp(unit, "mJ") == 0) {
        rate /= 1e3;
    } else if (strcmp(unit, "uJ") == 0) {
        rate /= 1e6;
    } else if (strcmp(unit, "nJ") == 0) {
        rate /= 1e9;
    } else {
        /* 单位标签缺失：按数量级自适应，取第一个合理的（<=600W） */
        double candidates[3] = {rate / 1e9, rate / 1e6, rate / 1e3};
        rate = NAN;
        for (int i = 0; i < 3; i++) {
            if (candidates[i] >= 0.0 && candidates[i] <= 600.0) { rate = candidates[i]; break; }
        }
        if (isnan(rate)) return NAN;
    }
    if (!(rate >= 0.0) || rate > 600.0) return NAN;
    return rate;
}

/* PMP 分组名：PMP、PMP0、PMP1 …（M5/M6 用 per-die 分组） */
static int is_pmp_group(const char *grp) {
    if (strncmp(grp, "PMP", 3) != 0) return 0;
    for (const char *p = grp + 3; *p; p++) {
        if (*p < '0' || *p > '9') return 0;
    }
    return 1;
}

/* PMP "Energy" 子组里的 CPU 簇功率直方图：PACC / PACC0 / MACC1 / EACC0 SRAM */
static int is_pmp_cpu_power_channel(const char *sub, const char *chn) {
    if (strcmp(sub, "Energy") != 0) return 0;
    size_t len = strlen(chn);
    if (len < 4) return 0;
    if (strncmp(chn + 1, "ACC", 3) != 0) return 0;
    const char *p = chn + 4;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == '\0') return 1;
    return strcmp(p, " SRAM") == 0;
}

/* 直方图按 residency 加权平均；skipLowest 时第一档按 0 计（空闲簇常驻低档） */
static double state_bin_average(SPIOReport *io, CFDictionaryRef item, int skipLowest) {
    if (!io->stateCount || !io->stateResidency || !io->stateName) return 0;
    int n = io->stateCount(item);
    if (n <= 0 || n > 64) return 0;
    double bins[64];
    int64_t residency[64];
    for (int i = 0; i < n; i++) {
        char buf[32] = {0};
        CFStringRef name = io->stateName(item, i);
        if (name) CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8);
        bins[i] = atof(buf);              /* "2W" -> 2, "0.250W" -> 0.25 */
        residency[i] = io->stateResidency(item, i);
    }
    int64_t total = 0;
    double weighted = 0;
    for (int i = 0; i < n; i++) {
        total += residency[i];
        if (skipLowest && i == 0) continue;
        weighted += bins[i] * (double)residency[i];
    }
    return total > 0 ? weighted / (double)total : 0;
}

static int name_contains(const char *haystack, const char *needle) {
    return strstr(haystack, needle) != NULL;
}

/* SMC DRAM 功率兜底（PZD1..PZD9，macOS 27 上 Energy Model 的 DRAM 被 gated） */
static double smc_dram_power(io_connect_t conn) {
    double total = 0;
    int found = 0;
    for (int i = 1; i <= 9; i++) {
        char key[8];
        snprintf(key, sizeof key, "PZD%d", i);
        double v = 0;
        if (smc_read_number(conn, key, &v) == 0 && v >= 0 && v < 200) {
            total += v;
            found = 1;
        }
    }
    return found ? total : NAN;
}

static void ioreport_read(SPReader *reader, SPReading *out) {
    SPIOReport *io = &reader->io;
    if (!io->ready) return;

    CFDictionaryRef current = io->createSamples(io->subscription, io->subscribed, NULL);
    if (!current) return;
    double now = CFAbsoluteTimeGetCurrent();

    if (io->previous) {
        double dt = now - io->previousTime;
        CFDictionaryRef delta = io->createSamplesDelta(io->previous, current, NULL);
        if (delta) {
            CFArrayRef array = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
            CFIndex count = array ? CFArrayGetCount(array) : 0;

            double cpuTotal = 0, cpuTyped = 0;
            double gpuNamed = 0, gpuAlias = 0;
            double aneBlock = 0, aneNamed = 0;
            double dramBlock = 0, dramNamed = 0;
            /* PMP CPU 直方图：同一 group/channel 只取一次，避免合并订阅重复计数 */
            struct { char grp[16]; char chn[64]; double value; } pmpCpu[32];
            int pmpCpuCount = 0;

            for (CFIndex i = 0; i < count; i++) {
                CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(array, i);
                if (!channel) continue;
                char grp[64] = {0};
                if (io->channelGroup) {
                    CFStringRef group = io->channelGroup(channel);
                    if (group) CFStringGetCString(group, grp, sizeof grp, kCFStringEncodingUTF8);
                    int isEnergyGroup = strcmp(grp, "Energy Model") == 0 ||
                                        strcmp(grp, "Energy Counters") == 0;
                    if (!isEnergyGroup && !is_pmp_group(grp)) continue;
                }
                CFStringRef name = io->channelName(channel);
                if (!name) continue;
                char chn[128] = {0};
                if (!CFStringGetCString(name, chn, sizeof chn, kCFStringEncodingUTF8)) continue;

                CFStringRef unit = io->channelUnit ? io->channelUnit(channel) : NULL;
                double watts = energy_to_watts(io->simpleValue(channel, 0), unit, dt);
                if (isnan(watts)) continue;

                /* CPU：先分簇（ECPU/PCPU/MCPU…），再总 CPU Energy，二者不叠加 */
                if (name_contains(chn, "ECPU Energy") || name_contains(chn, "PCPU Energy") ||
                    name_contains(chn, "MCPU Energy") || name_contains(chn, "eCPUs Energy") ||
                    name_contains(chn, "pCPUs Energy") || name_contains(chn, "mCPUs Energy")) {
                    cpuTyped += watts;
                    out->cpuPowerAvailable = 1;
                } else if (name_contains(chn, "CPU Energy")) {
                    cpuTotal += watts;
                    out->cpuPowerAvailable = 1;
                } else if (strcmp(chn, "GPU Energy") == 0) {
                    gpuNamed += watts;
                    out->gpuPowerAvailable = 1;
                } else if (strcmp(chn, "GPU") == 0) {
                    gpuAlias += watts;
                    out->gpuPowerAvailable = 1;
                } else if (name_contains(chn, "ANE") || name_contains(chn, "NPU") ||
                           name_contains(chn, "Neural") || name_contains(chn, "ane")) {
                    if (name_contains(chn, "Energy")) aneNamed += watts; else aneBlock += watts;
                    out->anePowerAvailable = 1;
                } else if (strncmp(chn, "DRAM", 4) == 0) {
                    if (name_contains(chn, "Energy")) dramNamed += watts; else dramBlock += watts;
                    out->dramPowerAvailable = 1;
                } else if (is_pmp_group(grp)) {
                    char sub[64] = {0};
                    if (io->channelSubGroup) {
                        CFStringRef sg = io->channelSubGroup(channel);
                        if (sg) CFStringGetCString(sg, sub, sizeof sub, kCFStringEncodingUTF8);
                    }
                    if (is_pmp_cpu_power_channel(sub, chn) &&
                        io->stateCount && io->stateCount(channel) > 1) {
                        double w = state_bin_average(io, channel, 1);
                        out->cpuPowerAvailable = 1;
                        if (w > 0.001 && pmpCpuCount < 32) {
                            int seen = 0;
                            for (int k = 0; k < pmpCpuCount; k++) {
                                if (strcmp(pmpCpu[k].grp, grp) == 0 &&
                                    strcmp(pmpCpu[k].chn, chn) == 0) {
                                    if (w > pmpCpu[k].value) pmpCpu[k].value = w;
                                    seen = 1;
                                    break;
                                }
                            }
                            if (!seen) {
                                snprintf(pmpCpu[pmpCpuCount].grp, sizeof pmpCpu[pmpCpuCount].grp, "%s", grp);
                                snprintf(pmpCpu[pmpCpuCount].chn, sizeof pmpCpu[pmpCpuCount].chn, "%s", chn);
                                pmpCpu[pmpCpuCount].value = w;
                                pmpCpuCount++;
                            }
                        }
                    }
                }
            }

            double pmpCpuW = 0;
            for (int k = 0; k < pmpCpuCount; k++) pmpCpuW += pmpCpu[k].value;

            double cpu = cpuTotal > 0 ? cpuTotal : cpuTyped;
            if (cpu <= 0.001 && pmpCpuW > 0.001) io->cpuFromPMP = 1;
            if (io->cpuFromPMP && pmpCpuW > 0.001) cpu = pmpCpuW;
            double gpu = gpuNamed > 0 ? gpuNamed : gpuAlias;
            double ane = aneBlock > 0 ? aneBlock : aneNamed;
            double dram = dramBlock > 0 ? dramBlock : dramNamed;

            out->cpuPowerW = cpu;
            out->gpuPowerW = gpu;
            out->anePowerW = ane;
            if (dram > 0.001) {
                out->dramPowerW = dram;
            } else {
                double smcDram = smc_dram_power(reader->smcConnection);
                if (!isnan(smcDram) && smcDram > 0.001) out->dramPowerW = smcDram;
            }

            CFRelease(delta);
        }
    }

    if (io->previous) CFRelease(io->previous);
    io->previous = current;
    io->previousTime = now;
}

SPReader *sp_reader_create(void) {
    SPReader *reader = (SPReader *)calloc(1, sizeof(SPReader));
    if (!reader) return NULL;

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSMC"));
    if (svc) {
        io_connect_t conn = 0;
        if (IOServiceOpen(svc, mach_task_self(), 0, &conn) == KERN_SUCCESS) {
            reader->smcService = svc;
            reader->smcConnection = conn;
            reader->smcReady = 1;
        } else {
            IOObjectRelease(svc);
        }
    }
    discover_temp_keys(reader);
    ioreport_init(reader);
    return reader;
}

void sp_reader_destroy(SPReader *reader) {
    if (!reader) return;
    ioreport_release(reader);
    if (reader->smcReady) {
        IOServiceClose(reader->smcConnection);
        IOObjectRelease(reader->smcService);
    }
    free(reader);
}

int32_t sp_reader_read_smc_float(SPReader *reader, const char *key, double *out) {
    if (!reader || !reader->smcReady || !key || !out) return -1;
    return smc_read_flt(reader->smcConnection, key, out) == 0 ? 0 : -1;
}

int32_t sp_reader_smc_key_exists(SPReader *reader, const char *key) {
    if (!reader || !reader->smcReady || !key) return 0;
    uint32_t type = 0;
    if (smc_key_info(reader->smcConnection, key, &type, NULL) != 0) return 0;
    return type == SMC_KEY_FLT ? 1 : 0;
}

static void format_fan_key_line(io_connect_t conn, const char *key, char *line, size_t lineSize) {
    uint32_t type = 0;
    uint8_t  ksize = 0;
    if (smc_key_info(conn, key, &type, &ksize) != 0) {
        snprintf(line, lineSize, "%-4s  （读不到 keyInfo，键可能不存在）\n", key);
        return;
    }
    uint8_t raw[32] = {0};
    smc_read_raw(conn, key, raw, ksize);
    char typeStr[5] = {
        (char)(type >> 24), (char)((type >> 16) & 0xff),
        (char)((type >> 8) & 0xff), (char)(type & 0xff), 0
    };
    char hex[3 * 16 + 4] = {0};
    int hexUsed = 0;
    int shown = ksize > 16 ? 16 : ksize;
    for (int b = 0; b < shown; b++) {
        hexUsed += snprintf(hex + hexUsed, sizeof hex - (size_t)hexUsed, "%02x", raw[b]);
    }
    double value = 0;
    int ok = smc_read_fan_value(conn, key, &value);
    if (ok == 0) {
        snprintf(line, lineSize, "%-4s type='%s' size=%d raw=%s  value=%.2f\n",
                 key, typeStr, ksize, hex, value);
    } else {
        snprintf(line, lineSize, "%-4s type='%s' size=%d raw=%s  （无法解码 err=%d）\n",
                 key, typeStr, ksize, hex, ok);
    }
}

int32_t sp_reader_dump_fan_keys(SPReader *reader, char *buffer, int32_t size) {
    if (!reader || !reader->smcReady || !buffer || size <= 1) return 0;
    buffer[0] = '\0';
    int used = 0;
    for (int i = 0; i < reader->fanKeyCount; i++) {
        char line[256];
        format_fan_key_line(reader->smcConnection, reader->fanKeys[i], line, sizeof line);
        int len = (int)strlen(line);
        if (used + len >= size - 1) break;
        memcpy(buffer + used, line, (size_t)len);
        used += len;
        buffer[used] = '\0';
    }

    /* 枚举不到的候选键也直接试一下（某些机型会隐藏风扇键） */
    static const char *candidates[] = {"F0Ac", "F0AC", "F1Ac", "F1AC"};
    for (int c = 0; c < 4; c++) {
        int already = 0;
        for (int i = 0; i < reader->fanKeyCount; i++) {
            if (strcmp(reader->fanKeys[i], candidates[c]) == 0) { already = 1; break; }
        }
        if (already) continue;
        char line[256];
        format_fan_key_line(reader->smcConnection, candidates[c], line, sizeof line);
        /* 键完全不存在时只提示一行，避免噪音 */
        if (strstr(line, "读不到 keyInfo") != NULL) {
            snprintf(line, sizeof line, "%-4s  （未枚举到，直接读取失败）\n", candidates[c]);
        }
        int len = (int)strlen(line);
        if (used + len >= size - 1) break;
        memcpy(buffer + used, line, (size_t)len);
        used += len;
        buffer[used] = '\0';
    }
    return used;
}

/* 把 AppleSmartBattery 的容量 / 循环 / 健康相关键值格式化成文本 */
static int battery_key_interesting(const char *key) {
    return strstr(key, "Capacity") || strstr(key, "Cycle") ||
           strstr(key, "Health") || strstr(key, "Design") ||
           strstr(key, "Nominal");
}

int32_t sp_reader_dump_battery_keys(char *buffer, int32_t size) {
    if (!buffer || size <= 1) return 0;
    buffer[0] = '\0';
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSmartBattery"));
    if (!svc) {
        snprintf(buffer, (size_t)size, "没有 AppleSmartBattery（台式机 / 无电池）\n");
        return (int32_t)strlen(buffer);
    }
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
        IOObjectRelease(svc);
        snprintf(buffer, (size_t)size, "读取 AppleSmartBattery 属性失败\n");
        return (int32_t)strlen(buffer);
    }
    IOObjectRelease(svc);

    CFIndex n = CFDictionaryGetCount(props);
    if (n <= 0) {
        CFRelease(props);
        return 0;
    }
    const void **keys = malloc(sizeof(void *) * (size_t)n);
    const void **vals = malloc(sizeof(void *) * (size_t)n);
    int used = 0;
    if (keys && vals) {
        CFDictionaryGetKeysAndValues(props, keys, vals);
        for (CFIndex i = 0; i < n; i++) {
            if (!keys[i] || CFGetTypeID(keys[i]) != CFStringGetTypeID()) continue;
            char key[160];
            if (!CFStringGetCString((CFStringRef)keys[i], key, sizeof key, kCFStringEncodingUTF8)) continue;
            if (!battery_key_interesting(key)) continue;

            char line[256];
            CFTypeRef v = vals[i];
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                long long iv = 0;
                if (CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &iv)) {
                    snprintf(line, sizeof line, "%-28s = %lld\n", key, iv);
                } else {
                    snprintf(line, sizeof line, "%-28s = (number)\n", key);
                }
            } else if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
                char text[128] = {0};
                CFStringGetCString((CFStringRef)v, text, sizeof text, kCFStringEncodingUTF8);
                snprintf(line, sizeof line, "%-28s = \"%s\"\n", key, text);
            } else if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
                snprintf(line, sizeof line, "%-28s = %s\n", key,
                         CFBooleanGetValue((CFBooleanRef)v) ? "true" : "false");
            } else {
                continue;
            }
            int len = (int)strlen(line);
            if (used + len >= size - 1) break;
            memcpy(buffer + used, line, (size_t)len);
            used += len;
            buffer[used] = '\0';
        }
    }
    free(keys);
    free(vals);
    CFRelease(props);
    return used;
}

int32_t sp_reader_dump_energy_channels(SPReader *reader, char *buffer, int32_t size) {
    if (!reader || !buffer || size <= 1) return 0;
    SPIOReport *io = &reader->io;
    buffer[0] = '\0';
    if (!io->ready) {
        snprintf(buffer, (size_t)size, "IOReport 未初始化\n");
        return (int32_t)strlen(buffer);
    }
    CFDictionaryRef s1 = io->createSamples(io->subscription, io->subscribed, NULL);
    if (!s1) return 0;
    usleep(500000);
    CFDictionaryRef s2 = io->createSamples(io->subscription, io->subscribed, NULL);
    if (!s2) { CFRelease(s1); return 0; }
    CFDictionaryRef delta = io->createSamplesDelta(s1, s2, NULL);
    CFRelease(s1);
    CFRelease(s2);
    if (!delta) return 0;

    int used = 0;
    CFArrayRef array = (CFArrayRef)CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    CFIndex count = array ? CFArrayGetCount(array) : 0;
    for (CFIndex i = 0; i < count && used < size - 2; i++) {
        CFDictionaryRef channel = (CFDictionaryRef)CFArrayGetValueAtIndex(array, i);
        if (!channel) continue;
        char grp[64] = {0}, chn[128] = {0}, unit[32] = {0};
        CFStringRef g = io->channelGroup ? io->channelGroup(channel) : NULL;
        if (g) CFStringGetCString(g, grp, sizeof grp, kCFStringEncodingUTF8);
        if (strcmp(grp, "Energy Model") != 0 && strcmp(grp, "Energy Counters") != 0) continue;
        CFStringRef n = io->channelName(channel);
        if (n) CFStringGetCString(n, chn, sizeof chn, kCFStringEncodingUTF8);
        CFStringRef u = io->channelUnit ? io->channelUnit(channel) : NULL;
        if (u) CFStringGetCString(u, unit, sizeof unit, kCFStringEncodingUTF8);
        int64_t raw = io->simpleValue(channel, 0);
        double watts = energy_to_watts(raw, u, 0.5);
        char line[256];
        snprintf(line, sizeof line, "%-4s %-24s unit=%-4s raw=%-14lld watts=%.4f\n",
                 grp[0] ? "EM" : "?", chn, unit[0] ? unit : "-", (long long)raw,
                 isnan(watts) ? -1.0 : watts);
        int len = (int)strlen(line);
        if (used + len >= size - 1) break;
        memcpy(buffer + used, line, (size_t)len);
        used += len;
        buffer[used] = '\0';
    }
    CFRelease(delta);
    return used;
}

int32_t sp_reader_read(SPReader *reader, SPReading *out) {
    if (!reader || !out) return -1;

    memset(out, 0, sizeof(SPReading));
    out->cpuPowerW = NAN;
    out->gpuPowerW = NAN;
    out->anePowerW = NAN;
    out->dramPowerW = NAN;
    out->cpuTempC = NAN;
    out->gpuTempC = NAN;
    out->ssdTempC = NAN;
    out->batteryTempC = NAN;
    out->platformTempC = NAN;
    out->socPercent = -1.0;
    out->timeRemainingMinutes = -1.0;
    out->batteryDesignCapacity_mAh = -1.0;
    out->batteryFullChargeCapacity_mAh = -1.0;
    out->batteryCycleCount = -1;
    out->batteryDesignCycleCount = -1;
    snprintf(out->powerSourceState, sizeof out->powerSourceState, "%s", "Unknown");

    /* SMC */
    if (reader->smcReady) {
        out->smcAvailable = 1;
        double v = 0;

        if (smc_read_flt(reader->smcConnection, "PSTR", &v) == 0) {
            out->smcHasSystemPower = 1;
            out->smcSystemPower_W = v;
        }
        if (smc_read_flt(reader->smcConnection, "PDTR", &v) == 0) {
            out->smcHasAdapterPower = 1;
            out->smcAdapterPower_W = v;
        }
        if (smc_read_flt(reader->smcConnection, "PD0R", &v) == 0) {
            out->smcHasDesktopInputPower = 1;
            out->smcDesktopInputPower_W = v;
        }

        /* 适配器输入电压 / 电流：VD0R × ID0R = PDTR（实测完全一致） */
        {
            double railV = 0, railI = 0;
            if (smc_read_number(reader->smcConnection, "VD0R", &railV) == 0
                && railV > 0.1 && railV < 30.0
                && smc_read_number(reader->smcConnection, "ID0R", &railI) == 0
                && railI >= 0 && railI < 20.0) {
                out->smcHasInputRails = 1;
                out->smcInputVoltage_V = railV;
                out->smcInputCurrent_A = railI;
            }
        }

        /* USB-C 对外供电通道：D1..D4 的电压 × 电流（PowerLens 同款做法） */
        double railSum = 0;
        int    railsAnswered = 0;
        out->portRailCount = 0;
        for (int ch = 1; ch <= 4; ch++) {
            char vkey[8], akey[8];
            snprintf(vkey, sizeof vkey, "D%dJV", ch);
            snprintf(akey, sizeof akey, "D%dJI", ch);
            double volts = 0, amps = 0;
            if (smc_read_flt(reader->smcConnection, vkey, &volts) == 0
                && smc_read_flt(reader->smcConnection, akey, &amps) == 0) {
                railsAnswered = 1;
                if (volts >= 0 && volts <= 60 && amps >= 0 && amps <= 12) {
                    double w = volts * amps;
                    if (w <= 150) {
                        railSum += w;
                        if (out->portRailCount < 4) {
                            out->portRailPower_W[out->portRailCount++] = w;
                        }
                    }
                }
            }
        }
        if (railsAnswered) {
            out->portTelemetryAvailable = 1;
            out->portPower_W = railSum;
        }

        /* 温度：各组件分开读，读不到的保持 NaN */
        {
            static const char *const batteryKeys[] = {"TB0T", "TB1T", "TB2T"};
            static const char *const platformKeys[] = {"Ts0P", "Ts1P", "TsOP", "TA0P"};

            out->cpuTempC = max_temp_from_keys(reader->smcConnection,
                                               reader->cpuKeys, reader->cpuKeyCount);
            out->gpuTempC = max_temp_from_keys(reader->smcConnection,
                                               reader->gpuKeys, reader->gpuKeyCount);
            out->ssdTempC = first_temp_from_keys(reader->smcConnection,
                                                 reader->ssdKeys, reader->ssdKeyCount);
            out->batteryTempC = smc_first_temp(reader->smcConnection, batteryKeys, 3);
            out->platformTempC = smc_first_temp(reader->smcConnection, platformKeys, 4);
        }

        /* 芯片分项功率（IOReport） */
        out->cpuPowerW = NAN;
        out->gpuPowerW = NAN;
        out->anePowerW = NAN;
        out->dramPowerW = NAN;
        ioreport_read(reader, out);

        /* 风扇：所有 F?Ac 取最大值，F?Mn / F?Mx / F?Tg 取第一或最大 */
        {
            double best = NAN, target = NAN, mn = NAN, mx = NAN;
            int count = 0;
            for (int i = 0; i < reader->fanActualCount; i++) {
                double rpm = 0;
                if (smc_read_fan_value(reader->smcConnection, reader->fanActualKeys[i], &rpm) == 0
                    && rpm >= 0 && rpm <= 20000) {
                    count++;
                    if (isnan(best) || rpm > best) best = rpm;
                }
            }
            for (int i = 0; i < reader->fanTargetCount; i++) {
                double v = 0;
                if (smc_read_fan_value(reader->smcConnection, reader->fanTargetKeys[i], &v) == 0
                    && v >= 0 && v <= 20000) { target = v; break; }
            }
            for (int i = 0; i < reader->fanMinCount; i++) {
                double v = 0;
                if (smc_read_fan_value(reader->smcConnection, reader->fanMinKeys[i], &v) == 0
                    && v >= 0 && v <= 20000) { mn = v; break; }
            }
            for (int i = 0; i < reader->fanMaxCount; i++) {
                double v = 0;
                if (smc_read_fan_value(reader->smcConnection, reader->fanMaxKeys[i], &v) == 0
                    && v >= 0 && v <= 20000) { mx = v; break; }
            }
            if (!isnan(best)) {
                out->fanAvailable = 1;
                out->fanCount = count;
                out->fanRPM = best;
                out->fanTargetRPM = target;
                out->fanMinRPM = mn;
                out->fanMaxRPM = mx;
            }
        }

        /* 内置屏幕背光：不同机型用不同键 */
        const char *displayKeys[] = {"PDBR", "PBwo", "PBLR"};
        for (int i = 0; i < 3; i++) {
            if (smc_read_flt(reader->smcConnection, displayKeys[i], &v) == 0
                && v >= 0 && v < 100) {
                out->displayAvailable = 1;
                out->displayPower_W = v;
                break;
            }
        }
    }

    /* 平台数据 */
    read_smart_battery(out);
    read_disk_stats(out);
    read_iops(out);

    return 0;
}
