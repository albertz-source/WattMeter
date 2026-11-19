import SwiftUI
import AppKit
import WattMeterCore

/// 关于窗口：版本、链接、致谢与诊断复制。
public struct AboutView: View {
    @ObservedObject private var l10n = Localization.shared
    @ObservedObject private var model = AboutModel()

    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    public var body: some View {
        VStack(spacing: 14) {
            header
            infoCard
            linksCard
            creditsCard
            footer
        }
        .padding(20)
        .frame(width: 420)
        .background(PanelBackground())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .foregroundStyle(.white.opacity(0.9))
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 8) {
            icon
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("WattMeter")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text(L("实时功率监视器"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NSImage(named: "WattMeter") {
            Image(nsImage: image)
                .resizable()
                .frame(width: 84, height: 84)
        } else {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(Palette.mint)
                .frame(width: 84, height: 84)
        }
    }

    // MARK: - 信息

    private var infoCard: some View {
        Card {
            VStack(spacing: 6) {
                infoRow(L("版本"), "v\(version) (\(L("构建")) \(build))")
                infoRow(L("系统要求"), L("macOS 13 及以上，Apple Silicon 与 Intel"))
                infoRow(L("隐私"), L("数据仅在本机读取，不联网、不需要 root"))
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 0)
        }
    }

    // MARK: - 链接

    private var linksCard: some View {
        Card(title: L("链接")) {
            VStack(spacing: 8) {
                linkRow(icon: "chevron.left.forwardslash.chevron.right",
                        title: L("GitHub 项目主页"),
                        subtitle: "github.com/albertz-source/WattMeter",
                        url: "https://github.com/albertz-source/WattMeter")
                linkRow(icon: "doc.text.magnifyingglass",
                        title: L("问题反馈"),
                        subtitle: "github.com/albertz-source/WattMeter/issues",
                        url: "https://github.com/albertz-source/WattMeter/issues")
            }
        }
    }

    private func linkRow(icon: String, title: String, subtitle: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.mint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 致谢

    private var creditsCard: some View {
        Card(title: L("致谢")) {
            VStack(alignment: .leading, spacing: 6) {
                creditRow(L("界面设计参考"), "PowerLens")
                creditRow(L("IOReport 读取方案参考"), "mactop")
                Text(L("数据来自 AppleSMC 与 IOReport，读写均在本地完成。"))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func creditRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                let text = "WattMeter v\(version) (\(build))\n" + Diagnostics.battery() + "\n\n" + Diagnostics.fans()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                model.copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.copied = false }
            } label: {
                Label(model.copied ? L("已复制") : L("复制诊断信息"),
                      systemImage: model.copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.mint)

            Spacer()

            Button(L("关闭")) {
                onClose()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}


/// About 窗口的轻量状态（避免依赖 @State，Command Line Tools 环境没有 SwiftUI 宏插件）
final class AboutModel: ObservableObject {
    @Published var copied = false
}
