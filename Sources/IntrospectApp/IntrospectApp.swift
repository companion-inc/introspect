import AppKit
import SwiftUI

@main
struct IntrospectApplication: App {
    @StateObject private var model = IntrospectModel()

    var body: some Scene {
        MenuBarExtra("Introspect", systemImage: "brain.head.profile") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Introspect", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 840, minHeight: 640)
                .task { await model.refresh() }
        }
        .windowResizability(.contentMinSize)
    }
}

struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: IntrospectModel

    var body: some View {
        Button("Open Introspect") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Label(model.mode.statusLabel, systemImage: model.mode.symbolName)
        Label(model.hooksSummary, systemImage: model.allHooksInstalled ? "checkmark.circle" : "exclamationmark.triangle")
        Divider()
        Button("Refresh") {
            Task { await model.refresh() }
        }
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Label("Status", systemImage: "waveform.path.ecg")
                    .tag(IntrospectSection.status)
                Label("Hooks", systemImage: "switch.2")
                    .tag(IntrospectSection.hooks)
                Label("Words", systemImage: "text.badge.checkmark")
                    .tag(IntrospectSection.words)
                Label("Local Profile", systemImage: "externaldrive.badge.timemachine")
                    .tag(IntrospectSection.profile)
            }
            .navigationTitle("Introspect")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HeaderView(model: model)
                    switch model.selectedSection ?? .status {
                    case .status:
                        StatusSection(model: model)
                    case .hooks:
                        HooksSection(model: model)
                    case .words:
                        WordsSection(model: model)
                    case .profile:
                        ProfileSection(model: model)
                    }
                    if !model.lastCommandOutput.isEmpty {
                        CommandOutputView(output: model.lastCommandOutput)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct HeaderView: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Introspect")
                        .font(.largeTitle.weight(.semibold))
                    Text("Open-source app. Private local prompt, skills, word profile, and feedback repo.")
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.statusLine)
                .font(.callout)
                .foregroundStyle(model.hasWarning ? .orange : .secondary)
        }
    }
}

struct StatusSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
            StatusRow("Bundle ID", value: "ai.companion.introspect", systemImage: "app.badge")
            StatusRow("Repo", value: model.repoPath, systemImage: "folder")
            StatusRow("Private profile", value: model.profilePath, systemImage: "lock.doc")
            StatusRow("Claude prompt", value: model.claudePromptStatus, systemImage: model.claudePromptOK ? "checkmark.circle" : "xmark.circle")
            StatusRow("Codex prompt", value: model.codexPromptStatus, systemImage: model.codexPromptOK ? "checkmark.circle" : "xmark.circle")
            StatusRow("Hooks", value: model.hooksSummary, systemImage: model.allHooksInstalled ? "checkmark.circle" : "exclamationmark.triangle")
            StatusRow("Queued events", value: "\(model.queuedEvents)", systemImage: "tray.full")
            StatusRow("Last reflector run", value: model.lastRunText, systemImage: "clock.arrow.circlepath")
        }

        HStack(spacing: 12) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await model.openProfileFolder() }
            } label: {
                Label("Open Profile", systemImage: "folder")
            }
        }
        .buttonStyle(.bordered)
    }
}

struct HooksSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Reflection mode", selection: $model.mode) {
                ForEach(ReflectionMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            Text(model.mode.helpText)
                .foregroundStyle(.secondary)

            if model.mode == .nightly {
                HStack {
                    Stepper(value: $model.nightlyHour, in: 0...23) {
                        Text("Hour \(String(format: "%02d", model.nightlyHour))")
                    }
                    Stepper(value: $model.nightlyMinute, in: 0...59) {
                        Text("Minute \(String(format: "%02d", model.nightlyMinute))")
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await model.applySystemPromptAndHooks() }
                } label: {
                    Label("Apply System Prompt", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    Task { await model.disableHooks() }
                } label: {
                    Label("Disable Hooks", systemImage: "power")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What apply does")
                    .font(.headline)
                Text("Links Claude and Codex to this prompt, installs or removes prompt-submit hooks, and installs a nightly LaunchAgent only when Nightly is selected.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WordsSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The hook starts with the built-in hardcoded list, then applies your local include/exclude profile from Git. Excluded words win.")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 18) {
                WordEditor(
                    title: "Include",
                    subtitle: "Extra words you personally use when frustrated.",
                    text: $model.includeWordsText
                )
                WordEditor(
                    title: "Exclude",
                    subtitle: "Words that should never trigger for you.",
                    text: $model.excludeWordsText
                )
            }

            HStack(spacing: 12) {
                Button {
                    Task { await model.saveWordProfile() }
                } label: {
                    Label("Save Word Profile", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.resetWordDraft()
                } label: {
                    Label("Reset Draft", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct ProfileSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                StatusRow("Git repo", value: model.profileGitStatus, systemImage: model.profileGitOK ? "checkmark.circle" : "xmark.circle")
                StatusRow("Word profile", value: model.wordProfileStatus, systemImage: model.wordProfileOK ? "checkmark.circle" : "xmark.circle")
                StatusRow("Last local commit", value: model.profileLastCommit, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            }

            HStack(spacing: 12) {
                Button {
                    Task { await model.initializeProfileRepo() }
                } label: {
                    Label("Initialize Local Profile Repo", systemImage: "plus.app")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.commitProfileChanges() }
                } label: {
                    Label("Commit Profile Changes", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.bordered)
            }

            Text("This folder is intentionally local. It can track your private prompt, skills, approved/rejected tripwire words, and reflector logs without putting them in the open-source app repo.")
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    let systemImage: String

    init(_ label: String, value: String, systemImage: String) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
    }

    var body: some View {
        GridRow {
            Label(label, systemImage: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}

struct WordEditor: View {
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
                )
        }
    }
}

struct CommandOutputView: View {
    let output: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Command")
                .font(.headline)
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

enum IntrospectSection: Hashable {
    case status
    case hooks
    case words
    case profile
}

enum ReflectionMode: String, CaseIterable, Identifiable {
    case immediate
    case nightly
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediate: "Right After Frustration"
        case .nightly: "Nightly"
        case .off: "Disabled"
        }
    }

    var statusLabel: String {
        switch self {
        case .immediate: "Immediate reflection"
        case .nightly: "Nightly reflection"
        case .off: "Hooks disabled"
        }
    }

    var helpText: String {
        switch self {
        case .immediate:
            "Frustration prompts enqueue and kick one locked worker immediately. Debounce and cooldown still batch bursts."
        case .nightly:
            "Frustration prompts enqueue only; a LaunchAgent reviews the batch at the selected time."
        case .off:
            "Prompt links stay available, but Claude and Codex hooks are removed."
        }
    }

    var symbolName: String {
        switch self {
        case .immediate: "bolt.circle"
        case .nightly: "moon.stars"
        case .off: "pause.circle"
        }
    }
}

@MainActor
final class IntrospectModel: ObservableObject {
    @Published var selectedSection: IntrospectSection? = .status
    @Published var mode: ReflectionMode = .immediate
    @Published var nightlyHour = 3
    @Published var nightlyMinute = 0
    @Published var claudePromptOK = false
    @Published var codexPromptOK = false
    @Published var claudeHookInstalled = false
    @Published var codexHookInstalled = false
    @Published var launchAgentInstalled = false
    @Published var queuedEvents = 0
    @Published var lastRunText = "unknown"
    @Published var includeWordsText = ""
    @Published var excludeWordsText = ""
    @Published var profileGitOK = false
    @Published var wordProfileOK = false
    @Published var profileLastCommit = "none"
    @Published var lastCommandOutput = ""

    private let fileManager = FileManager.default
    private let repoURL: URL
    private let profileURL: URL
    private let homeURL: URL
    private var savedIncludeWords: [String] = []
    private var savedExcludeWords: [String] = []

    init() {
        homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let env = ProcessInfo.processInfo.environment
        let repoPath = env["INTROSPECT_REPO"] ?? "\(NSHomeDirectory())/Projects/introspect"
        let profilePath = env["INTROSPECT_PROFILE_DIR"] ?? "\(NSHomeDirectory())/.introspect/profile"
        repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
        profileURL = URL(fileURLWithPath: profilePath).standardizedFileURL
    }

    var repoPath: String { repoURL.path }
    var profilePath: String { profileURL.path }

    var claudePromptStatus: String {
        claudePromptOK ? "~/.claude/CLAUDE.md -> \(repoURL.path)/AGENTS.md" : "not linked to this repo"
    }

    var codexPromptStatus: String {
        codexPromptOK ? "~/.codex/AGENTS.md -> \(repoURL.path)/AGENTS.md" : "not linked to this repo"
    }

    var hooksSummary: String {
        if mode == .off {
            return "disabled"
        }
        if allHooksInstalled {
            return "Claude and Codex hooks installed"
        }
        if claudeHookInstalled || codexHookInstalled {
            return "partially installed"
        }
        return "not installed"
    }

    var allHooksInstalled: Bool {
        claudeHookInstalled && codexHookInstalled
    }

    var hasWarning: Bool {
        !claudePromptOK || !codexPromptOK || (mode != .off && !allHooksInstalled)
    }

    var statusLine: String {
        if hasWarning {
            return "Needs attention: apply the system prompt or fix missing hooks."
        }
        return "Live: \(mode.statusLabel), \(queuedEvents) queued event(s)."
    }

    var profileGitStatus: String {
        profileGitOK ? "\(profileURL.path)/.git" : "not initialized"
    }

    var wordProfileStatus: String {
        wordProfileOK ? "\(wordProfileURL.path)" : "missing"
    }

    private var wordProfileURL: URL {
        profileURL.appendingPathComponent("frustration-words.json")
    }

    func refresh() async {
        claudePromptOK = symlink(homeURL.appendingPathComponent(".claude/CLAUDE.md"), pointsTo: repoURL.appendingPathComponent("AGENTS.md"))
        codexPromptOK = symlink(homeURL.appendingPathComponent(".codex/AGENTS.md"), pointsTo: repoURL.appendingPathComponent("AGENTS.md"))
        let claude = hookStatus(path: homeURL.appendingPathComponent(".claude/settings.json"))
        let codex = hookStatus(path: homeURL.appendingPathComponent(".codex/hooks.json"))
        claudeHookInstalled = claude.installed
        codexHookInstalled = codex.installed
        mode = claude.mode ?? codex.mode ?? .off
        launchAgentInstalled = fileManager.fileExists(atPath: homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.reflector.plist").path)
        queuedEvents = lineCount(repoURL.appendingPathComponent("feedback/frustration-queue.jsonl"))
        lastRunText = readLastRun()
        loadWordProfile()
        profileGitOK = fileManager.fileExists(atPath: profileURL.appendingPathComponent(".git").path)
        wordProfileOK = fileManager.fileExists(atPath: wordProfileURL.path)
        profileLastCommit = await gitOutput(["-C", profileURL.path, "log", "-1", "--oneline"]).trimmedOr("none")
    }

    func applySystemPromptAndHooks() async {
        await initializeProfileRepo()
        var args = [
            repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
            "--reflect-mode", mode.rawValue,
            "--nightly-hour", "\(nightlyHour)",
            "--nightly-minute", "\(nightlyMinute)"
        ]
        if mode == .off {
            args = [
                repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
                "--reflect-mode", "off"
            ]
        }
        lastCommandOutput = await shell("/bin/bash", args)
        await refresh()
    }

    func disableHooks() async {
        mode = .off
        lastCommandOutput = await shell(
            "/bin/bash",
            [repoURL.appendingPathComponent("scripts/install-hooks.sh").path, "--reflect-mode", "off"]
        )
        await refresh()
    }

    func initializeProfileRepo() async {
        do {
            try fileManager.createDirectory(at: profileURL.appendingPathComponent("skills"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: profileURL.appendingPathComponent("prompts"), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: wordProfileURL.path) {
                let data: [String: Any] = [
                    "include": [],
                    "exclude": ["shit"],
                    "learned_candidates": [],
                    "notes": "Local Introspect profile. Excluded words win over defaults."
                ]
                try writeJSON(data, to: wordProfileURL)
            }
            let readme = profileURL.appendingPathComponent("README.md")
            if !fileManager.fileExists(atPath: readme.path) {
                try """
                # Introspect Local Profile

                This repository is private local state for Introspect:

                - `frustration-words.json`: approved and rejected tripwire words.
                - `prompts/`: private prompt variants.
                - `skills/`: private user skills.

                Commit changes locally when you want a checkpoint.
                """.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            lastCommandOutput = "Failed to initialize profile files: \(error)"
            return
        }

        if !fileManager.fileExists(atPath: profileURL.appendingPathComponent(".git").path) {
            _ = await gitOutput(["init", profileURL.path])
        }
        await commitProfileChanges(message: "Initialize Introspect profile")
        await refresh()
    }

    func saveWordProfile() async {
        let include = parseWords(includeWordsText)
        let exclude = parseWords(excludeWordsText)
        do {
            try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)
            try writeJSON(["include": include, "exclude": exclude], to: wordProfileURL)
            savedIncludeWords = include
            savedExcludeWords = exclude
            lastCommandOutput = "Saved \(include.count) included and \(exclude.count) excluded word(s)."
        } catch {
            lastCommandOutput = "Failed to save word profile: \(error)"
        }
        await commitProfileChanges(message: "Update frustration word profile")
        await refresh()
    }

    func resetWordDraft() {
        includeWordsText = savedIncludeWords.joined(separator: "\n")
        excludeWordsText = savedExcludeWords.joined(separator: "\n")
    }

    func commitProfileChanges() async {
        await commitProfileChanges(message: "Update Introspect profile")
        await refresh()
    }

    func openProfileFolder() async {
        NSWorkspace.shared.open(profileURL)
    }

    private func commitProfileChanges(message: String) async {
        _ = await gitOutput(["-C", profileURL.path, "add", "."])
        let status = await gitOutput(["-C", profileURL.path, "status", "--porcelain"])
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastCommandOutput = "Profile repo has no uncommitted changes."
            return
        }
        lastCommandOutput = await gitOutput(["-C", profileURL.path, "commit", "-m", message])
    }

    private func loadWordProfile() {
        wordProfileOK = fileManager.fileExists(atPath: wordProfileURL.path)
        guard let data = try? Data(contentsOf: wordProfileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            savedIncludeWords = []
            savedExcludeWords = ["shit"]
            resetWordDraft()
            return
        }
        savedIncludeWords = (object["include"] as? [String] ?? []).sorted()
        savedExcludeWords = (object["exclude"] as? [String] ?? []).sorted()
        resetWordDraft()
    }

    private func symlink(_ link: URL, pointsTo expected: URL) -> Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        return URL(fileURLWithPath: destination).standardizedFileURL.path == expected.standardizedFileURL.path
    }

    private func hookStatus(path: URL) -> (installed: Bool, mode: ReflectionMode?) {
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let groups = hooks["UserPromptSubmit"] as? [[String: Any]] else {
            return (false, nil)
        }
        for group in groups {
            guard let entries = group["hooks"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let command = entry["command"] as? String,
                      command.contains("frustration-reflect.sh") else { continue }
                if command.contains("INTROSPECT_REFLECT_MODE=nightly") {
                    return (true, .nightly)
                }
                if command.contains("INTROSPECT_REFLECT_MODE=off") {
                    return (false, .off)
                }
                return (true, .immediate)
            }
        }
        return (false, nil)
    }

    private func lineCount(_ path: URL) -> Int {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return 0
        }
        return text.split(separator: "\n").count
    }

    private func readLastRun() -> String {
        let stateURL = repoURL.appendingPathComponent("feedback/reflector-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["last_run_at"] as? String else {
            return "unknown"
        }
        return value
    }

    private func parseWords(_ text: String) -> [String] {
        let pattern = /^[a-z]+$/
        let words = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.wholeMatch(of: pattern) != nil }
        return Array(Set(words)).sorted()
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func gitOutput(_ args: [String]) async -> String {
        await shell("/usr/bin/git", args)
    }

    private func shell(_ executable: String, _ args: [String]) async -> String {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    return output
                }
                return output.isEmpty ? "Command failed with exit \(process.terminationStatus)" : output
            } catch {
                return "Command failed: \(error)"
            }
        }.value
    }
}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
