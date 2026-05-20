import AppKit
import Audio2TxtCore
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedAudioURLs: [URL] = []
    @Published var status: String = "请选择一个或多个 m4a/mp3 音频文件"
    @Published var isRunning: Bool = false
    @Published var logs: [String] = []
    @Published var overallProgress: Double = 0.0
    @Published var overallProgressText: String = "等待开始"
    @Published var isSettingsPresented: Bool = false
    @Published var settings: AppSettings = AppSettingsStore.load()

    private var fileProgress: [URL: Double] = [:]

    var logsText: String {
        logs.joined(separator: "\n")
    }

    func addAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .wav, .aiff]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "添加课程录音（可多选）"

        if panel.runModal() == .OK {
            var merged = Set(selectedAudioURLs)
            var newCount = 0
            for url in panel.urls {
                if merged.insert(url).inserted {
                    newCount += 1
                }
            }
            selectedAudioURLs = Array(merged).sorted { $0.path < $1.path }
            status = "已选择 \(selectedAudioURLs.count) 个文件"
            appendLog("新增 \(newCount) 个文件，当前总数: \(selectedAudioURLs.count)")
            for url in panel.urls.sorted(by: { $0.path < $1.path }) {
                appendLog("- \(url.path)")
            }
        }
    }

    func clearAndReselect() {
        selectedAudioURLs.removeAll()
        fileProgress.removeAll()
        overallProgress = 0
        overallProgressText = "等待开始"
        addAudio()
    }

    func removeAudio(_ url: URL) {
        selectedAudioURLs.removeAll { $0 == url }
        fileProgress.removeValue(forKey: url)
        recomputeOverallProgress()
        status = selectedAudioURLs.isEmpty ? "请选择一个或多个 m4a/mp3 音频文件" : "已选择 \(selectedAudioURLs.count) 个文件"
    }

    func startTranscription() {
        guard !isRunning else { return }
        guard !selectedAudioURLs.isEmpty else {
            status = "请先选择音频文件"
            return
        }

        isRunning = true
        logs.removeAll()
        fileProgress = Dictionary(uniqueKeysWithValues: selectedAudioURLs.map { ($0, 0.0) })
        overallProgress = 0.0
        overallProgressText = "准备中 0%"
        Task {
            do {
                let fileEnv = (try? EnvLoader.load()) ?? [:]
                let env = settings.mergedEnv(base: fileEnv)
                let config = try AppConfig(env: env)
                let files = selectedAudioURLs

                appendLog("开始执行上传 -> 提交 -> 轮询 -> 下载流程")
                appendLog("并发任务数: \(min(config.maxConcurrentJobs, files.count))")

                let results = try await transcribeBatch(files: files, config: config)
                playCompletionSoundIfNeeded()
                appendLog("转写已完成，开始选择保存位置")
                setProgress(1.0, text: "转写完成 100%")

                guard let outputTargets = resolveOutputTargetsAfterCompletion(for: files) else {
                    status = "转写完成：已取消保存"
                    appendLog("用户取消保存，结果仅保留在本次会话内")
                    isRunning = false
                    return
                }
                try saveBatch(files: files, results: results, outputTargets: outputTargets, config: config)

                status = "全部完成：\(files.count) 个文件"
                appendLog("全部任务完成")
            } catch {
                status = "失败：\(error.localizedDescription)"
                appendLog("错误: \(error.localizedDescription)")
            }
            isRunning = false
        }
    }

    func saveSettings(_ newSettings: AppSettings) {
        settings = newSettings
        AppSettingsStore.save(newSettings)
        appendLog("设置已保存到本地")
    }

    private func transcribeBatch(files: [URL], config: AppConfig) async throws -> [URL: TranscriptionCoordinator.Result] {
        let limit = max(1, min(config.maxConcurrentJobs, files.count))
        var nextIndex = 0
        var results: [URL: TranscriptionCoordinator.Result] = [:]

        try await withThrowingTaskGroup(of: (URL, TranscriptionCoordinator.Result).self) { group in
            for _ in 0..<limit {
                guard nextIndex < files.count else { break }
                let audioURL = files[nextIndex]
                nextIndex += 1
                group.addTask { @Sendable in
                    try await self.transcribeOne(audioURL: audioURL, config: config)
                }
            }

            while let completed = try await group.next() {
                results[completed.0] = completed.1
                if nextIndex < files.count {
                    let audioURL = files[nextIndex]
                    nextIndex += 1
                    group.addTask { @Sendable in
                        try await self.transcribeOne(audioURL: audioURL, config: config)
                    }
                }
            }
        }
        return results
    }

    private func transcribeOne(audioURL: URL, config: AppConfig) async throws -> (URL, TranscriptionCoordinator.Result) {
        let prefix = "[\(audioURL.lastPathComponent)] "
        await MainActor.run { self.appendLog(prefix + "开始任务") }

        let coordinator = TranscriptionCoordinator(config: config)
        let result = try await coordinator.transcribe(
            audioFileURL: audioURL,
            logger: { [weak self] message in
                Task { @MainActor in
                    self?.appendLog(prefix + message)
                }
            },
            progress: { [weak self] value in
                Task { @MainActor in
                    self?.updateProgress(for: audioURL, value: value)
                }
            }
        )
        await MainActor.run {
            self.updateProgress(for: audioURL, value: 1.0)
        }
        return (audioURL, result)
    }

    private func updateProgress(for file: URL, value: Double) {
        let clamped = max(0.0, min(1.0, value))
        let old = fileProgress[file] ?? 0.0
        fileProgress[file] = max(old, clamped)
        recomputeOverallProgress()
    }

    private func recomputeOverallProgress() {
        guard !selectedAudioURLs.isEmpty else {
            setProgress(0.0, text: "等待开始")
            return
        }
        let total = selectedAudioURLs.reduce(0.0) { partial, url in
            partial + (fileProgress[url] ?? 0.0)
        }
        let value = total / Double(selectedAudioURLs.count)
        let percent = Int((value * 100).rounded())
        setProgress(value, text: "转写进度 \(percent)%")
    }

    private func setProgress(_ value: Double, text: String) {
        overallProgress = max(0.0, min(1.0, value))
        overallProgressText = text
    }

    private func saveBatch(
        files: [URL],
        results: [URL: TranscriptionCoordinator.Result],
        outputTargets: [URL: URL],
        config: AppConfig
    ) throws {
        for file in files {
            guard let result = results[file], let outputURL = outputTargets[file] else { continue }
            let prefix = "[\(file.lastPathComponent)] "
            let content = buildOutputText(result: result)
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            appendLog(prefix + "保存成功: \(outputURL.path)")

            if config.saveRawJSON {
                let rawURL = outputURL.deletingPathExtension().appendingPathExtension("raw.json")
                do {
                    try result.rawJSONData.write(to: rawURL, options: .atomic)
                    appendLog(prefix + "调试JSON已保存: \(rawURL.path)")
                } catch {
                    appendLog(prefix + "调试JSON保存失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func resolveOutputTargetsAfterCompletion(for files: [URL]) -> [URL: URL]? {
        if files.count == 1 {
            let file = files[0]
            let suggestedName = file.deletingPathExtension().lastPathComponent + ".txt"
            guard let output = presentSavePanel(suggestedName: suggestedName) else { return nil }
            return [file: output]
        }

        guard let directory = presentDirectoryPanel() else { return nil }

        var mapping: [URL: URL] = [:]
        for file in files {
            let outputName = file.deletingPathExtension().lastPathComponent + ".txt"
            mapping[file] = directory.appendingPathComponent(outputName)
        }
        return mapping
    }

    private func buildOutputText(result: TranscriptionCoordinator.Result) -> String {
        let now = Date()
        let headerDate = formatHeaderDate(now)
        let durationText = formatDuration(result.audioDurationMs)
        let headerLine = "\(headerDate)|\(durationText)"
        var blocks: [String] = [headerLine]

        if let summary = result.summaryText, !summary.isEmpty {
            blocks.append("全文总结:\n\(summary)")
        }
        if !result.summaryKeywords.isEmpty {
            let keywordsLine = result.summaryKeywords.joined(separator: "、")
            blocks.append("关键词:\n\(keywordsLine)")
        }
        blocks.append("文字记录:\n\(result.text)")
        if let translation = result.translationText, !translation.isEmpty {
            blocks.append("翻译结果:\n\(translation)")
        }
        return blocks.joined(separator: "\n\n")
    }

    private func formatHeaderDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 a h:mm"
        return formatter.string(from: date)
    }

    private func formatDuration(_ durationMs: Int?) -> String {
        guard let durationMs, durationMs > 0 else { return "时长未知" }
        let totalSec = durationMs / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return "\(h)小时\(m)分钟\(s)秒"
        }
        return "\(m)分钟\(s)秒"
    }

    private func presentDirectoryPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择批量输出目录"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func presentSavePanel(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.title = "保存转写文本"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        logs.append(line)
    }

    private func playCompletionSoundIfNeeded() {
        guard settings.completionSoundEnabled else { return }
        if let sound = NSSound(named: NSSound.Name("Blow")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = AppViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("豆包语音妙记")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                Button("添加音频") { vm.addAudio() }
                    .disabled(vm.isRunning)
                Button("清空并重选") { vm.clearAndReselect() }
                    .disabled(vm.isRunning)
                Button(vm.isRunning ? "转写中..." : "开始转写") { vm.startTranscription() }
                    .disabled(vm.isRunning || vm.selectedAudioURLs.isEmpty)
                Spacer()
                Button {
                    vm.isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.bordered)
                .help("打开设置")
            }

            HStack(spacing: 10) {
                ProgressView(value: vm.overallProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: .infinity)
                Text(vm.overallProgressText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 130, alignment: .trailing)
            }

            Text("已选音频（支持多次添加，可跨文件夹）")
                .font(.headline)

            ScrollView {
                if vm.selectedAudioURLs.isEmpty {
                    Text("未选择文件")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.selectedAudioURLs, id: \.self) { url in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("删除") { vm.removeAudio(url) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(vm.isRunning)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(vm.status)
                .font(.system(size: 13))

            Text("运行日志")
                .font(.headline)

            ScrollView {
                Text(vm.logsText.isEmpty ? "暂无日志" : vm.logsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .padding(10)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .sheet(isPresented: $vm.isSettingsPresented) {
            SettingsView(
                initial: vm.settings,
                onSave: { vm.saveSettings($0) },
                onClose: { vm.isSettingsPresented = false }
            )
        }
    }
}

struct SettingsView: View {
    @State private var draft: AppSettings
    @State private var showAdvanced: Bool = false
    @State private var translateENToZH: Bool
    @State private var translateZHToEN: Bool
    let onSave: (AppSettings) -> Void
    let onClose: () -> Void

    init(initial: AppSettings, onSave: @escaping (AppSettings) -> Void, onClose: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        let isZhToEn = initial.translationSourceLang == "zh_cn" && initial.translationTargetLang == "en_us"
        _translateZHToEN = State(initialValue: isZhToEn)
        _translateENToZH = State(initialValue: !isZhToEn)
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.title3)
                .fontWeight(.semibold)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        Text("豆包语音妙记")
                            .font(.headline)
                        LabeledField("应用 Key (VOLC_APP_KEY)", text: $draft.volcAppKey)
                        LabeledSecureField("访问 Key (VOLC_ACCESS_KEY)", text: $draft.volcAccessKey)
                        LabeledField("资源 ID (VOLC_RESOURCE_ID)", text: $draft.volcResourceId)
                        HStack(spacing: 8) {
                            Text("配置指南：")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Link("创建应用", destination: URL(string: "https://console.volcengine.com/speech/app?opt=create")!)
                                .font(.system(size: 12))
                            Text("｜")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Link("模型信息", destination: URL(string: "https://console.volcengine.com/speech/service/10039")!)
                                .font(.system(size: 12))
                        }
                        .padding(.leading, 214)
                    }

                    Divider()

                    Group {
                        Text("TOS")
                            .font(.headline)
                        LabeledField("地域 (TOS_REGION)", text: $draft.tosRegion)
                        LabeledField("访问域名 (TOS_ENDPOINT)", text: $draft.tosEndpoint)
                        LabeledField("存储桶名称 (TOS_BUCKET)", text: $draft.tosBucket)
                        LabeledField("访问密钥 AK (TOS_AK)", text: $draft.tosAK)
                        LabeledSecureField("访问密钥 SK (TOS_SK)", text: $draft.tosSK)
                        LabeledField("STS 临时令牌（可选）", text: $draft.tosStsToken)
                        LabeledField("对象前缀（目录）", text: $draft.tosObjectPrefix)
                    }

                    Divider()

                    Toggle("完成时声音提示", isOn: $draft.completionSoundEnabled)

                    Divider()

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledIntField("签名 URL 有效期（秒）", value: $draft.tosSignExpiresSec)
                            HelpText("对应 TOS_SIGN_EXPIRES_SEC，决定上传后临时下载链接多久失效。")

                            LabeledIntField("轮询间隔（秒）", value: $draft.pollIntervalSec)
                            HelpText("对应 POLL_INTERVAL_SEC，每隔多少秒查询一次转写状态。")

                            LabeledIntField("最长等待（分钟）", value: $draft.maxWaitMin)
                            HelpText("对应 MAX_WAIT_MIN，超过该时间仍未完成则超时失败。")

                            LabeledIntField("最大并发任务数", value: $draft.maxConcurrentJobs)
                            HelpText("对应 MAX_CONCURRENT_JOBS，同时处理的音频文件上限。")

                            Toggle("完成后删除 TOS 临时音频", isOn: $draft.deleteTempObject)
                            HelpText("对应 DELETE_TEMP_OBJECT，建议开启，避免桶里堆积临时文件。")

                            Toggle("保存原始响应 JSON（调试用）", isOn: $draft.saveRawJSON)
                            HelpText("对应 SAVE_RAW_JSON，开启后会在 txt 同目录输出 .raw.json。")

                            Divider()

                            Toggle("启用翻译文本（可选）", isOn: $draft.translationEnabled)
                                .onChange(of: draft.translationEnabled) { enabled in
                                    if enabled {
                                        translateENToZH = true
                                        translateZHToEN = false
                                    }
                                }
                            HelpText("默认关闭；开启后默认方向为英语 -> 中文。")

                            Toggle("英语 -> 中文", isOn: $translateENToZH)
                                .disabled(!draft.translationEnabled)
                                .opacity(draft.translationEnabled ? 1.0 : 0.45)
                                .onChange(of: translateENToZH) { newValue in
                                    if newValue {
                                        translateZHToEN = false
                                    } else if !translateZHToEN {
                                        translateENToZH = true
                                    }
                                }

                            Toggle("中文 -> 英文", isOn: $translateZHToEN)
                                .disabled(!draft.translationEnabled)
                                .opacity(draft.translationEnabled ? 1.0 : 0.45)
                                .onChange(of: translateZHToEN) { newValue in
                                    if newValue {
                                        translateENToZH = false
                                    } else if !translateENToZH {
                                        translateZHToEN = true
                                    }
                                }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("高级选项（任务参数）")
                            .font(.headline)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { onClose() }
                Button("保存") {
                    if translateZHToEN {
                        draft.translationSourceLang = "zh_cn"
                        draft.translationTargetLang = "en_us"
                    } else {
                        draft.translationSourceLang = "en_us"
                        draft.translationTargetLang = "zh_cn"
                    }
                    onSave(draft)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
    }
}

private struct HelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 214)
            .padding(.top, -4)
    }
}

private struct LabeledField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 210, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct LabeledSecureField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 210, alignment: .leading)
            SecureField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct LabeledIntField: View {
    let title: String
    @Binding var value: Int

    init(_ title: String, value: Binding<Int>) {
        self.title = title
        _value = value
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 210, alignment: .leading)
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }
}
