import Foundation
import Combine

/// 应用语言
public enum AppLanguage: String, CaseIterable, Identifiable {
    case zh = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    /// 语言自身的名称（不翻译）
    public var nativeName: String {
        switch self {
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    /// 用在切换按钮上的短标签
    public var shortLabel: String {
        switch self {
        case .zh: return "中"
        case .en: return "EN"
        }
    }
}

/// 轻量级本地化：英文界面通过「中文原文 → 英文」字典翻译，
/// 中文就是字典的 key 本身。这样视图代码里可以继续写中文，读起来也更直观。
public final class Localization: ObservableObject {
    public static let shared = Localization()

    private static let defaultsKey = "wattmeter.language"

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let parsed = AppLanguage(rawValue: saved) {
            language = parsed
        } else {
            // 首次启动跟随系统语言
            let preferred = Locale.preferredLanguages.first ?? "en"
            language = preferred.hasPrefix("zh") ? .zh : .en
        }
    }

    /// 供 --lang 参数 / 预览渲染强制指定
    public func setLanguage(_ value: AppLanguage) {
        language = value
    }

    public func toggle() {
        language = (language == .zh) ? .en : .zh
    }

    public func t(_ zh: String) -> String {
        guard language == .en else { return zh }
        return Self.english[zh] ?? zh
    }
}

/// 全局翻译函数
public func L(_ zh: String) -> String {
    Localization.shared.t(zh)
}

/// 剩余时间格式化（跟随语言）
public func localizedTimeRemaining(_ minutes: Double?) -> String {
    guard let minutes, minutes > 0 else { return "—" }
    let m = Int(minutes.rounded())
    if Localization.shared.language == .en {
        return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) min"
    }
    return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟"
}

/// 图表时间窗口标签
public func localizedWindowLabel(_ seconds: Double) -> String {
    let zh: String
    switch seconds {
    case 60: zh = "最近 1 分钟"
    case 300: zh = "最近 5 分钟"
    case 900: zh = "最近 15 分钟"
    case 3600: zh = "最近 1 小时"
    default: zh = "最近 \(Int(seconds / 60)) 分钟"
    }
    return L(zh)
}

extension Localization {
    /// 中文原文 → 英文
    static let english: [String: String] = [
        // 面板
        "整机功耗": "System power",
        "整机功耗 · 每 1 秒读取": "System power · reads every 1 s",
        "等待数据": "Waiting for data",
        "等待数据 →": "Waiting →",
        "无内置电池": "No internal battery",
        "功率趋势": "Power trend",
        "功率来源": "Power source",
        "功率流向": "Power flow",
        "功率来源随时间变化": "Power source over time",
        "整机功耗 / 电池净功率": "System power / net battery",
        "适配器输入": "Adapter input",
        "墙插估算": "Wall estimate",
        "含适配器损耗": "incl. adapter loss",
        "电池净功率": "Net battery power",
        "风扇转速": "Fan speed",
        "无风扇或不可读": "No fan / unavailable",
        "已停转": "stopped",
        "已停转（空闲时正常）": "stopped (normal when idle)",
        "DC 输入 · SMC 实时": "DC input · SMC live",
        "DC 输入 · 系统遥测": "DC input · system telemetry",
        "完整窗口": "Full window",
        "开机启动": "Launch at login",
        "待批准": "Approval needed",
        "峰值": "Peak",
        "平均": "Average",
        "累计": "Session",
        "输入": "Input",
        "电源": "Adapter",
        "电池": "Battery",
        "电源 / 电池": "Adapter / battery",
        "来源占比": "Source share",
        "温度与散热": "Temperature & cooling",
        "正 = 充电，负 = 放电": "positive = charging, negative = discharging",
        "系统估计": "system estimate",
        "未报告": "not reported",
        "系统遥测估计": "system telemetry estimate",
        "DC 输入 + 损耗": "DC input + loss",
        "Tp* 集群传感器最高": "max of Tp* cluster sensors",
        "平台": "Platform",
        "风扇": "Fan",
        "状态": "State",
        "净功率": "Net power",
        "剩余时间": "Time remaining",
        "本次会话": "this session",
        "每 1 秒采样": "sampled every 1 s",
        "每 1 秒读取": "reads every 1 s",
        "macOS 功率监视器": "macOS power monitor",
        "适配器": "Adapter",
        "DC 输入": "DC input",
        "额定功率": "Rated power",
        "适配器损耗": "Adapter loss",
        "系统遥测": "System telemetry",
        "SMC 实时": "SMC live",
        "演示数据": "Demo data",
        // 流向图
        "电源输入 →": "Adapter →",
        "电池供电 →": "Battery →",
        "电池辅助 →": "Battery boost →",
        "电池充电 ←": "Charging ←",
        "整机 W": "System W",
        "系统": "System",
        "屏幕": "Display",
        "接口": "Ports",
        "电池充电 →": "Battery charging →",
        "电池待机": "Battery idle",
        "未接电源": "On battery",
        // 状态（来自 Core）
        "充电中": "Charging",
        "放电中": "Discharging",
        "已充满": "Fully charged",
        "外接电源": "On AC",
        "电池供电": "On battery",
        "外接电源 · 待机": "On AC · idle",
        "混合供电": "Hybrid power",
        "本机无内置电池": "No internal battery",
        "系统遥测（约 20 秒刷新）": "System telemetry (~20 s)",
        // 窗口
        "最近 1 分钟": "Last 1 min",
        "最近 5 分钟": "Last 5 min",
        "最近 15 分钟": "Last 15 min",
        "最近 1 小时": "Last 1 hour",
        "1 分钟": "1 min",
        "5 分钟": "5 min",
        "15 分钟": "15 min",
        "1 小时": "1 h",
        "1 分": "1 m",
        "5 分": "5 m",
        "15 分": "15 m",
        // 登录项
        "已启用": "Enabled",
        "等待系统批准": "Waiting for approval",
        "未启用": "Disabled",
        "系统未找到该应用": "Not found by system",
        "未知": "Unknown",
        "登录时自动启动 WattMeter · ": "Launch WattMeter at login · ",
        // 菜单与提示
        "打开主窗口": "Open main window",
        "开机自动启动": "Launch at login",
        "开机自动启动（等待系统批准…）": "Launch at login (waiting for approval…)",
        "退出 WattMeter": "Quit WattMeter",
        "退出": "Quit",
        "关于语言": "Language",
        "无法修改开机自动启动": "Could not change launch at login",
        "未知错误。可以把 WattMeter.app 放到「应用程序」文件夹后再试。": "Unknown error. Try moving WattMeter.app into /Applications and retry.",
        "好": "OK",
        "WattMeter — 实时功率": "WattMeter — real-time power",
        "整机": "system",
        "电源 ": "adapter ",
        "电池 ": "battery ",
        "输入 ": "input ",
        "风扇 ": "fan ",
        "CPU ": "CPU ",
        "左为供电源，中间为整机，右侧为系统 / 屏幕 / 接口的功率分配；流线圆点指示能量方向。":
            "Ports on the left (adapter and battery), the system in the middle, loads on the right (system / display / ports); moving dots show the power-flow direction.",
        "左为供电源，中间为整机，右侧为系统 / 屏幕 / 接口 / 电池的功率分配；流线圆点指示能量方向。":
            "Sources on the left, the system in the middle, branches on the right (system / display / ports / battery); moving dots show the direction of power flow.",
        "正在读取功率…": "Reading power…",
        "无法读取功率数据（可能被系统权限拦截）": "Unable to read power data (possibly blocked by system permissions)",
        "功率为系统内部测量值；墙插功率为估算值（DC 输入 + 适配器损耗），与插座功率计可能有 5–15% 差异。":
            "Power values are measured inside the system. The wall figure is an estimate (DC input + adapter loss) and may differ from a plug meter by 5–15%.",
    ]
}
