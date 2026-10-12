import AppKit
import SwiftUI

// SC-6 正式包装（冻结语义 §6，修订记录 R1 §6.4）：关于窗口五要素＋真实更新流程。
// 网络语义（R1）：仅当用户点按「检查更新…」时连接 blacstar7.github.io 获取本频道清单；
// 用户点按「下载并安装」并再次确认后才下载更新包；此外应用不产生任何网络活动。
// 全部失败如实报告并写入本地回滚日志；失败不触碰当前安装（冻结语义 §4／R1）。

/// 更新流程状态（AboutView 展示层）。
enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case found(version: String, build: Int, notes: String)
    case downloading(received: Int64, expected: Int64)
    case readyToInstall(version: String, build: Int)
    case installing
    case installed(version: String)
    case failed(stage: String, message: String)
    case residueNotice(count: Int, backupNames: [String])
}

@MainActor
final class UpdateFlowModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var isRelaunching = false
    @Published private(set) var relaunchFailed = false
    private let relauncher: any UpdateRelaunching
    private let logURL: URL
    private var installedBuild: Int?

    let info = ReleaseInfo.current()

    /// R1 附注三第 1 条：启动路径只读识别未完成更新的残留备份，仅记录并在本页提示人工恢复。
    init(relauncher: any UpdateRelaunching = UpdateRelaunchCoordinator(),
         logURL: URL = UpdateFlowModel.rollbackLogURL, inspectResidue: Bool = true) {
        self.relauncher = relauncher
        self.logURL = logURL
        guard inspectResidue else { return }
        let outcome = UpdateInstaller.handleResidueAtLaunch(rollbackLog: UpdateRollbackLog(fileURL: logURL), channel: info.updateChannel)
        if case .notice(let count, let names) = outcome {
            phase = .residueNotice(count: count, backupNames: names)
        }
    }

    private var manifestData: Data?
    private var verifiedManifest: UpdateManifest?
    private var stagingDirectory: URL?
    private var zipFileURL: URL?
    private var manifestRequestURL: URL?

    /// 本地回滚日志（冻结语义 §4.5／R1：纯本地追加，不联网、不上传）。
    nonisolated static let rollbackLogURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SinClean", directoryHint: .isDirectory)
        .appending(path: "update-rollback.log")

    private var rollbackLog: UpdateRollbackLog {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return UpdateRollbackLog(fileURL: logURL)
    }

    private var currentBuild: Int { info.buildNumberInt ?? 0 }
    private var currentChannel: UpdateChannel { info.updateChannel ?? .internal }

    private var systemVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    func resetToIdle() {
        guard !isRelaunching else { return }
        installedBuild = nil
        relaunchFailed = false
        phase = .idle
        manifestData = nil
        verifiedManifest = nil
        if let staging = stagingDirectory {
            UpdateInstaller.clearStaging(staging)
        }
        stagingDirectory = nil
        zipFileURL = nil
        manifestRequestURL = nil
    }

    /// 用户点按「检查更新…」：对本频道清单 URL 发起一次 GET（唯一触发点①）。
    func checkForUpdates() async {
        guard !isRelaunching else { return }
        phase = .checking
        let log = rollbackLog
        let manifestURL: URL
        switch UpdateDownloader.manifestURL() {
        case .failure(let error):
            recordFailure(stage: "检查", message: describe(error), log: log, category: "manifest-url-invalid")
            return
        case .success(let url): manifestURL = url
        }
        manifestRequestURL = manifestURL
        let result = await UpdateDownloader.fetchManifest(from: manifestURL)
        let data: Data
        switch result {
        case .failure(let error):
            recordFailure(stage: "检查", message: describe(error), log: log, category: "manifest-fetch-failed")
            return
        case .success(let fetched): data = fetched
        }
        manifestData = data
        switch UpdateVerifier.verifyManifest(
            manifestData: data,
            currentBuild: currentBuild,
            channel: currentChannel,
            signerPublicKeyRaw: UpdatePublicKey.rawData,
            systemVersion: systemVersionString
        ) {
        case .failure(.notNewer):
            phase = .upToDate
        case .failure(let error):
            recordFailure(stage: "检查", message: describe(error), log: log, category: "manifest-verify-failed")
        case .success(let manifest):
            phase = .found(version: manifest.version, build: manifest.build, notes: manifest.notes)
            verifiedManifest = manifest
        }
    }

    /// 用户点按「下载并安装」（唯一触发点②）：下载 → 全管线校验 → 等待安装确认。
    func downloadAndInstall() async {
        guard let manifest = verifiedManifest, let origin = manifestRequestURL else {
            phase = .failed(stage: "下载", message: String(localized: "更新信息缺失，请重新检查更新。"))
            return
        }
        let log = rollbackLog
        let staging: URL
        switch UpdateInstaller.makeStagingDirectory() {
        case .failure(let error):
            recordFailure(stage: "下载", message: describe(error), log: log, category: "staging-create-failed")
            return
        case .success(let url): staging = url
        }
        stagingDirectory = staging
        let zipURL = staging.appending(path: "update-package.zip")
        zipFileURL = zipURL
        phase = .downloading(received: 0, expected: Int64(manifest.packageBytes))
        let downloadResult = await UpdateDownloader.downloadPackage(
            from: URL(string: manifest.packageURL) ?? URL(fileURLWithPath: "/dev/null"),
            manifestOrigin: origin,
            expectedBytes: Int64(manifest.packageBytes),
            to: zipURL
        ) { [weak self] received in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(received: received, expected: Int64(manifest.packageBytes))
            }
        }
        switch downloadResult {
        case .failure(let error):
            UpdateInstaller.clearStaging(staging)
            stagingDirectory = nil
            zipFileURL = nil
            recordFailure(stage: "下载", message: describe(error), log: log, category: "package-download-failed")
            return
        case .success: break
        }
        // 下载完成后做全管线校验（字节数／SHA-256／磁盘余量；冻结语义 §2.5／§4）。
        switch UpdateVerifier.verify(
            manifestData: data(),
            packageAt: zipURL,
            currentBuild: currentBuild,
            channel: currentChannel,
            signerPublicKeyRaw: UpdatePublicKey.rawData,
            systemVersion: systemVersionString,
            stagingVolume: staging
        ) {
        case .failure(let error):
            UpdateInstaller.clearStaging(staging)
            stagingDirectory = nil
            zipFileURL = nil
            recordFailure(stage: "下载", message: describe(error), log: log, category: "package-verify-failed")
        case .success:
            phase = .readyToInstall(version: manifest.version, build: manifest.build)
        }
    }

    /// 安装确认框「安装」：同卷三步替换（备份→移入→删备份），失败自动恢复。
    func confirmInstall() async {
        guard let manifest = verifiedManifest,
              let staging = stagingDirectory,
              let zipURL = zipFileURL
        else {
            phase = .failed(stage: "安装", message: String(localized: "更新文件缺失，请重新检查更新。"))
            return
        }
        let log = rollbackLog
        phase = .installing
        let installLogURL = logURL
        let installResult: Result<URL, UpdateInstallError> = await Task.detached(priority: .userInitiated) {
            UpdateInstaller.install(
                zipFile: zipURL,
                staging: staging,
                rollbackLog: UpdateRollbackLog(fileURL: installLogURL),
                channel: manifest.channel,
                targetVersion: manifest.version,
                targetBuild: manifest.build
            )
        }.value
        UpdateInstaller.clearStaging(staging)
        stagingDirectory = nil
        zipFileURL = nil
        manifestData = nil
        switch installResult {
        case .success:
            installationDidSucceed(version: manifest.version, build: manifest.build)
        case .failure(let error):
            recordFailure(stage: "安装", message: describe(error), log: log, category: "install-failed")
        }
    }

    func installationDidSucceed(version: String, build: Int) {
        installedBuild = build
        relaunchFailed = false
        phase = .installed(version: version)
    }

    /// 「重新打开」：只在新实例准备完成且隔离等待后交接；失败保留安装结果和旧实例。
    func relaunch() {
        guard !isRelaunching, case .installed(let version) = phase,
              let build = installedBuild else { return }
        isRelaunching = true
        relaunchFailed = false
        Task { @MainActor in
            let failure = await relauncher.run(build: build)
            rollbackLog.record(channel: currentChannel, targetVersion: version, targetBuild: build,
                               category: "relaunch-failed", reason: failure.rawValue)
            isRelaunching = false
            relaunchFailed = true
        }
    }

    // MARK: - 失败落账

    private func recordFailure(stage: String, message: String, log: UpdateRollbackLog, category: String) {
        log.record(
            channel: currentChannel,
            targetVersion: verifiedManifest?.version ?? "-",
            targetBuild: verifiedManifest?.build ?? currentBuild,
            category: category,
            reason: message
        )
        phase = .failed(stage: stage, message: message)
    }

    private func data() -> Data { manifestData ?? Data() }

    // MARK: - 错误文案（如实、中性；界面不说假话）

    private func describe(_ error: UpdateNetworkError) -> String {
        switch error {
        case .manifestURLMissing:
            return String(localized: "本构建未配置更新清单地址，无法检查更新。")
        case .manifestTooLarge:
            return String(localized: "更新清单超出大小上限，已拒绝。")
        case .schemeNotHTTPS(let scheme):
            return String(localized: "更新地址不是 HTTPS（\(scheme)），已拒绝。")
        case .hostNotWhitelisted(let host):
            return String(localized: "更新地址的目标服务器（\(host)）不在允许列表内，已拒绝。")
        case .explicitPort(let port):
            return String(localized: "更新地址包含显式端口（\(port)），已拒绝。")
        case .userInfoPresent:
            return String(localized: "更新地址包含用户信息，已拒绝。")
        case .manifestOriginUnknown, .packageOriginMismatch:
            return String(localized: "更新包地址与更新清单不同源，已拒绝。")
        case .redirectRejected:
            return String(localized: "服务器要求重定向，已按规则拒绝。")
        case .serverStatus(let status):
            return String(localized: "服务器返回状态 \(status)，未获取到内容。")
        case .transport(let reason):
            return String(localized: "网络传输失败：\(reason)")
        case .emptyBody:
            return String(localized: "服务器返回了空内容。")
        case .writeFailed(let reason):
            return String(localized: "写入暂存文件失败：\(reason)")
        }
    }

    private func describe(_ error: UpdateRejection) -> String {
        switch error {
        case .malformedManifest:
            return String(localized: "更新清单格式不合法，已拒绝。")
        case .channelMismatch:
            return String(localized: "更新清单的发布频道与本构建不一致，已拒绝。")
        case .notNewer:
            return String(localized: "已是最新版本。")
        case .systemTooOld(let required, _):
            return String(localized: "此更新要求 macOS \(required) 或更高版本。")
        case .invalidSignerKey, .signatureMismatch:
            return String(localized: "更新清单签名校验未通过，已拒绝。")
        case .packageMissing:
            return String(localized: "更新包不存在。")
        case .packageUnreadable:
            return String(localized: "更新包无法读取。")
        case .packageSizeMismatch:
            return String(localized: "更新包字节数与清单不符，已拒绝。")
        case .packageHashMismatch:
            return String(localized: "更新包校验值与清单不符，已拒绝。")
        case .insufficientDiskSpace:
            return String(localized: "磁盘可用空间不足，已取消更新。")
        }
    }

    private func describe(_ error: UpdateInstallError) -> String {
        switch error {
        case .stagingRootUnavailable:
            return String(localized: "无法定位缓存目录，已取消。")
        case .stagingCreateFailed(let reason):
            return String(localized: "创建暂存目录失败：\(reason)")
        case .packageMissing:
            return String(localized: "更新包不存在。")
        case .guardFailed(let reason):
            return String(localized: "更新包安全校验未通过，已拒绝：\(String(describing: reason))")
        case .extractionFailed(let reason):
            return String(localized: "解包失败：\(reason)")
        case .currentBundleMissing:
            return String(localized: "无法定位当前安装位置，已取消。")
        case .boundaryViolation:
            return String(localized: "安装路径边界校验未通过，已取消。")
        case .journalWriteFailed(let reason):
            return String(localized: "记录更新事务信息失败，已取消（当前版本未受影响）：\(reason)")
        case .journalWriteFailedRestored(let reason):
            return String(localized: "记录更新事务信息失败，已自动恢复当前版本：\(reason)")
        case .volumeUnidentifiable:
            return String(localized: "无法确认更新暂存目录与安装位置是否同卷，已取消（当前版本未受影响）。")
        case .crossVolumeRefused:
            return String(localized: "更新暂存目录与安装位置不在同一磁盘卷，已取消（当前版本未受影响）。")
        case .peakSpaceInsufficient:
            return String(localized: "磁盘可用空间不足以完成替换，已取消。")
        case .backupFailed(let reason):
            return String(localized: "备份当前版本失败，当前版本未受影响：\(reason)")
        case .replaceFailed:
            return String(localized: "替换失败，已自动恢复当前版本。")
        case .restoreFailed(let reason):
            return String(localized: "替换且自动恢复失败，备份保留在原目录：\(reason)")
        }
    }
}

struct AboutView: View {
    @StateObject private var model = UpdateFlowModel()
    @State private var showsLicense = false
    @State private var showsChangelog = false
    @State private var showsInstallConfirm = false

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityLabel("Sin Clean 图标")
            Text("Sin Clean")
                .font(.title)
                .fontWeight(.semibold)
            Text(model.info.versionLine)
                .accessibilityIdentifier("about.version")
            if let channelLine = model.info.channelLine {
                Text(channelLine)
                    .accessibilityIdentifier("about.channel")
            }
            Text(model.info.copyright)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("about.copyright")
            HStack(spacing: 12) {
                Button("许可证") { showsLicense = true }
                    .accessibilityIdentifier("about.license")
                Button("更新日志") { showsChangelog = true }
                    .accessibilityIdentifier("about.changelog")
                Button("检查更新…") {
                    Task { await model.checkForUpdates() }
                }
                .disabled(!isCheckEnabled)
                .accessibilityIdentifier("about.checkUpdates")
            }
            .padding(.top, 4)
            updateStatusArea
        }
        .padding(28)
        .frame(minWidth: 440)
        .sheet(isPresented: $showsLicense) {
            BundledTextView(title: String(localized: "许可证"), resourceName: "LICENSE")
        }
        .sheet(isPresented: $showsChangelog) {
            BundledTextView(title: String(localized: "更新日志"), resourceName: "CHANGELOG")
        }
        .alert("安装更新", isPresented: $showsInstallConfirm) {
            Button("安装") {
                Task { await model.confirmInstall() }
            }
            Button("取消", role: .cancel) {
                model.resetToIdle()
            }
        } message: {
            if case .readyToInstall(let version, let build) = model.phase {
                Text("即将把当前 Sin Clean 替换为新版本 \(version)（构建 \(build)）。替换在本机完成；如失败会自动恢复当前版本。")
            }
        }
    }

    private var isCheckEnabled: Bool {
        switch model.phase {
        case .idle, .upToDate, .failed, .residueNotice: return true
        case .found: return false
        case .checking, .downloading, .readyToInstall, .installing, .installed: return false
        }
    }

    /// 更新状态区（冻结语义 R1 §6.4：检查中／已是最新／发现新版本／进度／安装／结果）。
    private var updateStatusArea: some View {
        VStack(spacing: 8) {
            switch model.phase {
            case .idle:
                EmptyView()
            case .residueNotice(let count, let names):
                VStack(spacing: 6) {
                    Text("检测到 \(count) 个未完成更新的备份，已保留未删除。")
                        .accessibilityIdentifier("about.updateStatus")
                    Text("如需恢复旧版本，请将备份目录改名为 SinClean.app（详见恢复说明）：\(names.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 380)
                }
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查更新…")
                }
                .accessibilityIdentifier("about.updateStatus")
            case .upToDate:
                Text("已是最新版本。")
                    .accessibilityIdentifier("about.updateStatus")
            case .found(let version, let build, let notes):
                VStack(spacing: 8) {
                    Text("发现新版本 \(version)（构建 \(build)）")
                        .fontWeight(.medium)
                        .accessibilityIdentifier("about.updateStatus")
                    if !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 360)
                    }
                    HStack(spacing: 12) {
                        Button("下载并安装") {
                            Task { await model.downloadAndInstall() }
                        }
                        .accessibilityIdentifier("about.updateInstall")
                        Button("暂不", role: .cancel) {
                            model.resetToIdle()
                        }
                        .accessibilityIdentifier("about.updateLater")
                    }
                }
            case .downloading(let received, let expected):
                VStack(spacing: 6) {
                    Text("正在下载更新…")
                        .accessibilityIdentifier("about.updateStatus")
                    ProgressView(value: Double(received), total: Double(max(expected, 1)))
                        .frame(width: 240)
                    Text("\(received) / \(expected) 字节")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            case .readyToInstall:
                Button("继续安装…") {
                    showsInstallConfirm = true
                }
                .accessibilityIdentifier("about.updateConfirmEntry")
            case .installing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装…")
                }
                .accessibilityIdentifier("about.updateStatus")
            case .installed(let version):
                VStack(spacing: 8) {
                    Text("更新已安装（\(version)）。")
                        .accessibilityIdentifier("about.updateStatus")
                    HStack(spacing: 12) {
                        Button("重新打开") { model.relaunch() }
                            .disabled(model.isRelaunching)
                            .accessibilityIdentifier("about.updateRelaunch")
                        Button("稍后") { model.resetToIdle() }
                            .disabled(model.isRelaunching)
                    }
                    if model.isRelaunching {
                        ProgressView("正在重新打开…")
                    }
                    if model.relaunchFailed {
                        Text("无法重新打开新版本，当前应用已保留。请稍后重试。")
                            .foregroundStyle(.red)
                            .frame(maxWidth: 380)
                            .accessibilityIdentifier("about.relaunchError")
                    }
                }
            case .failed(let stage, let message):
                VStack(spacing: 6) {
                    Text("\(stage)失败：\(message)")
                        .foregroundStyle(.red)
                        .frame(maxWidth: 380)
                        .accessibilityIdentifier("about.updateStatus")
                    Button("重试") {
                        Task { await model.checkForUpdates() }
                    }
                    .accessibilityIdentifier("about.updateRetry")
                }
            }
        }
        .animation(.default, value: model.phase)
    }
}

/// 只读展示随包文本（许可证／更新日志）；文件缺失时如实说明。
private struct BundledTextView: View {
    let title: String
    let resourceName: String
    @Environment(\.dismiss) private var dismiss

    private var bundledText: String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(bundledText ?? String(localized: "随包文件缺失：\(resourceName).txt"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}
