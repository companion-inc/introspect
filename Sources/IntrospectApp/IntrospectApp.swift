import AppKit
import SwiftUI

enum IntrospectTheme {
    static let accent = Color(red: 0.20, green: 0.52, blue: 0.63)
    static let selection = Color(red: 0.18, green: 0.42, blue: 0.52)
}

@main
@MainActor
final class IntrospectApplication: NSObject, NSApplicationDelegate {
    private let model = IntrospectModel()
    private var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = IntrospectApplication()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
        Task { await model.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let content = ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 700)
            let hostingView = NSHostingView(rootView: content)
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1220, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Introspect"
            newWindow.contentView = hostingView
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        Label(model.hooksSummary, systemImage: model.systemInstalled ? "checkmark.circle" : "exclamationmark.triangle")
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
                Label("Projects", systemImage: "folder")
                    .tag(IntrospectSection.projects)
                Label("Words", systemImage: "text.badge.checkmark")
                    .tag(IntrospectSection.words)
                Label("Local Profile", systemImage: "externaldrive.badge.timemachine")
                    .tag(IntrospectSection.profile)
            }
            .navigationTitle("Introspect")
        } detail: {
            Group {
                if (model.selectedSection ?? .status) == .projects {
                    VStack(alignment: .leading, spacing: 20) {
                        HeaderView(model: model)
                        ProjectsSection(model: model)
                        if !model.lastCommandOutput.isEmpty {
                            CommandOutputView(output: model.lastCommandOutput)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            HeaderView(model: model)
                            switch model.selectedSection ?? .status {
                            case .status:
                                StatusSection(model: model)
                            case .hooks:
                                HooksSection(model: model)
                            case .projects:
                                ProjectsSection(model: model)
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
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(IntrospectTheme.accent)
    }
}

struct HeaderView: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 30))
                    .foregroundStyle(IntrospectTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Introspect")
                        .font(.largeTitle.bold())
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
            StatusRow("Codex scanner", value: model.codexScannerInstalled ? "installed" : "missing", systemImage: model.codexScannerInstalled ? "checkmark.circle" : "exclamationmark.triangle")
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

            Picker("Reflector agent", selection: $model.reflectorRunner) {
                ForEach(ReflectorRunner.allCases) { runner in
                    Label(runner.title, systemImage: runner.symbolName)
                        .tag(runner)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            Text(model.reflectorRunner.helpText)
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
                Text("Links Claude and Codex to this prompt, installs or removes prompt-submit hooks, installs the Codex transcript scanner, and installs a nightly LaunchAgent only when Nightly is selected.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WordsSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Only these words trigger the hook. Everything else is ignored by default.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Trigger Words")
                        .font(.headline)
                    Text("\(model.activeTripwireWords.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.16))
                        .clipShape(Capsule())
                }
                WordChipList(words: model.activeTripwireWords)
            }

            WordEditor(
                title: "Edit Trigger Words",
                subtitle: "One exact word per line. No prefixes, no phrases.",
                text: $model.triggerWordsText
            )

            HStack(spacing: 12) {
                Button {
                    Task { await model.saveWordProfile() }
                } label: {
                    Label("Save Trigger Words", systemImage: "square.and.arrow.down")
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

struct ProjectsSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProjectBrowserToolbar(model: model)

            HStack(spacing: 0) {
                ProjectHierarchyPane(
                    projects: model.filteredProjectTrees,
                    selectedID: model.selectedSurfaceID,
                    onSelect: model.selectSurface
                )
                .frame(minWidth: 330, idealWidth: 390, maxWidth: 460)

                Divider()

                ProjectSurfaceDetail(
                    record: model.selectedSurface,
                    content: model.selectedSurfaceContent,
                    onReveal: model.revealSelectedSurface
                )
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 600)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
            )
        }
    }
}

struct ProjectBrowserToolbar: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Tree")
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        Text("\(model.projectTrees.count) roots")
                        Text("\(model.promptSurfaces.count) agent files")
                        Text("\(model.skillSurfaces.count) skills")
                        if model.duplicateSkillGroups > 0 {
                            Text("\(model.duplicateSkillGroups) duplicate names")
                                .foregroundStyle(.orange)
                        }
                        if model.isScanningSurfaces {
                            Label("Scanning", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(IntrospectTheme.accent)
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)

                Button("Initialize Current Project", systemImage: "plus.app") {
                    Task { await model.initializeCurrentProjectAgentFiles() }
                }
                .buttonStyle(.borderedProminent)

                Button("Open Repo", systemImage: "folder") {
                    Task { await model.openRepoFolder() }
                }
                .buttonStyle(.bordered)
            }

            TextField("Search roots, files, scopes, and paths", text: $model.surfaceSearchText)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ProjectHierarchyPane: View {
    let projects: [ProjectTreeRecord]
    let selectedID: String?
    let onSelect: (ProjectSurfaceRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Hierarchy", systemImage: "list.bullet.indent")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if projects.isEmpty {
                ContentUnavailableView(
                    "No Agent Files",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("No prompts or skills matched the current search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(projects) { project in
                            ProjectTreeNode(
                                project: project,
                                selectedID: selectedID,
                                onSelect: onSelect
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProjectTreeNode: View {
    let project: ProjectTreeRecord
    let selectedID: String?
    let onSelect: (ProjectSurfaceRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Label(project.name, systemImage: project.systemImage)
                    .font(.headline)
                    .lineLimit(1)
                Text(project.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            SurfaceGroupNode(
                title: "Agent Files",
                systemImage: "doc.text",
                items: project.prompts,
                selectedID: selectedID,
                onSelect: onSelect
            )

            SurfaceGroupNode(
                title: "Skills",
                systemImage: "hammer",
                items: project.skills,
                selectedID: selectedID,
                onSelect: onSelect
            )
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct SurfaceGroupNode: View {
    let title: String
    let systemImage: String
    let items: [ProjectSurfaceRecord]
    let selectedID: String?
    let onSelect: (ProjectSurfaceRecord) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Label("\(title) (\(items.count))", systemImage: systemImage)
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        SurfaceTreeRow(
                            item: item,
                            isSelected: item.id == selectedID,
                            onSelect: onSelect
                        )
                    }
                }
            }
        }
    }
}

struct SurfaceTreeRow: View {
    let item: ProjectSurfaceRecord
    let isSelected: Bool
    let onSelect: (ProjectSurfaceRecord) -> Void

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.systemImage)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                    Text(item.relativePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text("\(item.lineCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color(nsColor: .tertiaryLabelColor))
                    .accessibilityLabel("\(item.lineCount) lines")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IntrospectTheme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

struct ProjectSurfaceDetail: View {
    let record: ProjectSurfaceRecord?
    let content: String
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record {
                SurfaceDetailHeader(record: record, onReveal: onReveal)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SurfaceMeaning(record: record)
                        if record.kind == .skill {
                            SkillFrontmatterSummary(content: content)
                        }
                        SurfaceMetadata(record: record)
                        SurfaceContentBlock(content: content)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Select a File",
                    systemImage: "sidebar.left",
                    description: Text("Choose a prompt or skill from the tree to inspect its scope and contents.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct SurfaceDetailHeader: View {
    let record: ProjectSurfaceRecord
    let onReveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.systemImage)
                .font(.title2)
                .foregroundStyle(IntrospectTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(record.name)
                    .font(.title3.bold())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ScopePill(text: record.scope)
                    ScopePill(text: record.kind.rawValue)
                    ScopePill(text: "\(record.lineCount) lines")
                }
                Text(record.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Reveal", systemImage: "arrow.up.forward.app", action: onReveal)
                .buttonStyle(.bordered)
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ScopePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            .clipShape(Capsule())
    }
}

struct SurfaceMeaning: View {
    let record: ProjectSurfaceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scope")
                .font(.headline)
            Text(scopeExplanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopeExplanation: String {
        if record.scope.contains("global") || record.scope.contains("user") {
            return "Loaded outside a single repo. Changes here affect many future sessions, so this is for durable cross-project behavior or personal skills."
        }
        if record.scope.contains("override") {
            return "This replaces the normal AGENTS.md at its level instead of appending to it. Use it only for a subtree that must not inherit that layer's regular guidance."
        }
        if record.kind == .skill {
            return "Loaded on demand when the task matches this skill. This is the right place for repeatable workflows, tool procedures, references, scripts, and project-specific know-how."
        }
        if record.scope.contains("local") {
            return "Private local Claude guidance. It should stay out of git and hold notes that should not be shared with the project."
        }
        return "Project-level agent guidance. This is the right place for repo-specific architecture, build/test commands, and behavior that should load whenever an agent works in this project."
    }
}

struct SurfaceMetadata: View {
    let record: ProjectSurfaceRecord

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            StatusRow("Root", value: record.projectName, systemImage: "folder")
            StatusRow("Relative path", value: record.relativePath, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            StatusRow("Absolute path", value: record.absolutePath, systemImage: "doc")
            if let target = record.target {
                StatusRow("Symlink target", value: target, systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

struct SkillFrontmatterSummary: View {
    let content: String

    var body: some View {
        let metadata = parseFrontmatter(content)
        if !metadata.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Skill Metadata")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        StatusRow(key, value: value, systemImage: "tag")
                    }
                }
            }
        }
    }

    private func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let value = parts[1]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if ["name", "description"].contains(key) {
                values[key] = value
            }
        }
        return values
    }
}

struct SurfaceContentBlock: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contents")
                .font(.headline)
            ScrollView(.horizontal) {
                Text(content.isEmpty ? "No readable UTF-8 content." : content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor))
            )
        }
    }
}

struct WordChipList: View {
    let words: [String]

    private let columns = [
        GridItem(.adaptive(minimum: 88), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(words, id: \.self) { word in
                Text(word)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
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
    case projects
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

enum ReflectorRunner: String, CaseIterable, Identifiable {
    case defaultRunner = "default"
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultRunner: "Default"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var helpText: String {
        switch self {
        case .defaultRunner:
            "Uses the installed agent with the most recent local usage profile. No random selection."
        case .claude:
            "Forces reflector runs through Claude using Claude's configured default model."
        case .codex:
            "Forces reflector runs through Codex using Codex's configured default model."
        }
    }

    var symbolName: String {
        switch self {
        case .defaultRunner: "person.crop.circle.badge.checkmark"
        case .claude: "c.circle"
        case .codex: "terminal"
        }
    }

    static func parse(_ value: String?) -> ReflectorRunner {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude":
            .claude
        case "codex":
            .codex
        default:
            .defaultRunner
        }
    }
}

enum ProjectSurfaceKind: String {
    case agentFile = "Agent file"
    case skill = "Skill"
}

struct ProjectSurfaceRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let scope: String
    let path: String
    let absolutePath: String
    let projectName: String
    let projectPath: String
    let relativePath: String
    let target: String?
    let systemImage: String
    let kind: ProjectSurfaceKind
    let lineCount: Int
}

struct ProjectTreeRecord: Identifiable {
    let id: String
    let name: String
    let path: String
    let systemImage: String
    let prompts: [ProjectSurfaceRecord]
    let skills: [ProjectSurfaceRecord]

    var allSurfaces: [ProjectSurfaceRecord] {
        prompts + skills
    }
}

@MainActor
final class IntrospectModel: ObservableObject {
    @Published var selectedSection: IntrospectSection? = .projects
    @Published var mode: ReflectionMode = .immediate
    @Published var reflectorRunner: ReflectorRunner = .defaultRunner
    @Published var nightlyHour = 3
    @Published var nightlyMinute = 0
    @Published var claudePromptOK = false
    @Published var codexPromptOK = false
    @Published var claudeHookInstalled = false
    @Published var codexHookInstalled = false
    @Published var codexScannerInstalled = false
    @Published var launchAgentInstalled = false
    @Published var queuedEvents = 0
    @Published var lastRunText = "unknown"
    @Published var triggerWordsText = ""
    @Published var profileGitOK = false
    @Published var wordProfileOK = false
    @Published var profileLastCommit = "none"
    @Published var lastCommandOutput = ""
    @Published var promptSurfaces: [ProjectSurfaceRecord] = []
    @Published var skillSurfaces: [ProjectSurfaceRecord] = []
    @Published var projectTrees: [ProjectTreeRecord] = []
    @Published var selectedSurfaceID: String?
    @Published var selectedSurfaceContent = ""
    @Published var surfaceSearchText = ""
    @Published var isScanningSurfaces = false
    @Published var duplicateSkillGroups = 0

    private let fileManager = FileManager.default
    private let repoURL: URL
    private let profileURL: URL
    private let homeURL: URL
    private let defaultTriggerWords = [
        "arse", "ass", "asshole", "bastard", "bitch", "bullshit", "crap", "cunt",
        "damn", "dipshit", "dumb", "dumbass", "dumbfuck", "fag", "faggot", "ffs",
        "fuck", "fucked", "fucker", "fuckin", "fucking", "goddamn", "hell", "idiot",
        "mf", "moron", "motherfucker", "motherfucking", "nigga", "nigger", "retard",
        "retarded", "shitty", "stupid", "wtf"
    ]
    private var savedTriggerWords: [String] = []
    private let skippedScanDirectories = Set([
        ".build", ".cache", ".git", ".next", ".swiftpm", "DerivedData", "__pycache__",
        "build", "cache", "dist", "node_modules", "plugins"
    ])

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
        if allHooksInstalled && codexScannerInstalled {
            return "Claude/Codex hooks plus scanner installed"
        }
        if allHooksInstalled {
            return "hooks installed, scanner missing"
        }
        if claudeHookInstalled || codexHookInstalled {
            return "partially installed"
        }
        return "not installed"
    }

    var allHooksInstalled: Bool {
        claudeHookInstalled && codexHookInstalled
    }

    var systemInstalled: Bool {
        mode == .off || (allHooksInstalled && codexScannerInstalled)
    }

    var hasWarning: Bool {
        !claudePromptOK || !codexPromptOK || (mode != .off && (!allHooksInstalled || !codexScannerInstalled))
    }

    var statusLine: String {
        if hasWarning {
            return "Needs attention: apply the system prompt or fix missing hooks."
        }
        return "Live: \(mode.statusLabel), \(queuedEvents) queued event(s)."
    }

    var activeTripwireWords: [String] {
        parseWords(triggerWordsText)
    }

    var selectedSurface: ProjectSurfaceRecord? {
        projectTrees
            .flatMap(\.allSurfaces)
            .first { $0.id == selectedSurfaceID }
    }

    var filteredProjectTrees: [ProjectTreeRecord] {
        let query = surfaceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return projectTrees }
        return projectTrees.compactMap { project in
            let projectMatches = [project.name, project.path].contains { $0.lowercased().contains(query) }
            if projectMatches {
                return project
            }
            let prompts = project.prompts.filter { surfaceMatches($0, query: query) }
            let skills = project.skills.filter { surfaceMatches($0, query: query) }
            guard !prompts.isEmpty || !skills.isEmpty else { return nil }
            return ProjectTreeRecord(
                id: project.id,
                name: project.name,
                path: project.path,
                systemImage: project.systemImage,
                prompts: prompts,
                skills: skills
            )
        }
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
        codexScannerInstalled = fileManager.fileExists(atPath: homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist").path)
        reflectorRunner = readReflectorRunner()
        queuedEvents = lineCount(repoURL.appendingPathComponent("feedback/frustration-queue.jsonl"))
        lastRunText = readLastRun()
        loadWordProfile()
        profileGitOK = fileManager.fileExists(atPath: profileURL.appendingPathComponent(".git").path)
        wordProfileOK = fileManager.fileExists(atPath: wordProfileURL.path)
        profileLastCommit = await gitOutput(["-C", profileURL.path, "log", "-1", "--oneline"]).trimmedOr("none")

        isScanningSurfaces = true
        applySurfaceScan(scanProjectSurfaces(roots: priorityScanRoots()))
        try? await Task.sleep(nanoseconds: 1_000_000)
        let surfaces = scanProjectSurfaces()
        applySurfaceScan(surfaces)
        isScanningSurfaces = false
    }

    private func applySurfaceScan(_ surfaces: (prompts: [ProjectSurfaceRecord], skills: [ProjectSurfaceRecord])) {
        promptSurfaces = surfaces.prompts
        skillSurfaces = surfaces.skills
        duplicateSkillGroups = countDuplicateSkillGroups(skills: surfaces.skills)
        projectTrees = buildProjectTrees(prompts: surfaces.prompts, skills: surfaces.skills)
        if selectedSurfaceID == nil || selectedSurface == nil {
            selectedSurfaceID = defaultSelectedSurfaceID()
        }
        loadSelectedSurfaceContent()
    }

    func applySystemPromptAndHooks() async {
        await initializeProfileRepo()
        var args = [
            repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
            "--reflect-mode", mode.rawValue,
            "--nightly-hour", "\(nightlyHour)",
            "--nightly-minute", "\(nightlyMinute)",
            "--runner", reflectorRunner.rawValue
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
                    "words": defaultTriggerWords,
                    "learned_candidates": [],
                    "notes": "Local Introspect profile. Only these exact words trigger the hook."
                ]
                try writeJSON(data, to: wordProfileURL)
            }
            let readme = profileURL.appendingPathComponent("README.md")
            if !fileManager.fileExists(atPath: readme.path) {
                try """
                # Introspect Local Profile

                This repository is private local state for Introspect:

                - `frustration-words.json`: exact tripwire words.
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
        let words = parseWords(triggerWordsText)
        do {
            try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)
            try writeJSON(["words": words], to: wordProfileURL)
            savedTriggerWords = words
            lastCommandOutput = "Saved \(words.count) trigger word(s)."
        } catch {
            lastCommandOutput = "Failed to save word profile: \(error)"
        }
        await commitProfileChanges(message: "Update frustration word profile")
        await refresh()
    }

    func resetWordDraft() {
        triggerWordsText = savedTriggerWords.joined(separator: "\n")
    }

    func commitProfileChanges() async {
        await commitProfileChanges(message: "Update Introspect profile")
        await refresh()
    }

    func openProfileFolder() async {
        NSWorkspace.shared.open(profileURL)
    }

    func openRepoFolder() async {
        NSWorkspace.shared.open(repoURL)
    }

    func selectSurface(_ record: ProjectSurfaceRecord) {
        selectedSurfaceID = record.id
        loadSelectedSurfaceContent()
    }

    func revealSelectedSurface() {
        guard let selectedSurface else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedSurface.absolutePath)])
    }

    func initializeCurrentProjectAgentFiles() async {
        do {
            let agentsURL = repoURL.appendingPathComponent("AGENTS.md")
            if !fileManager.fileExists(atPath: agentsURL.path) {
                try """
                # AGENTS.md

                ## Project Notes

                - Add project-specific build, test, architecture, and agent behavior here.
                - Keep user-wide rules in the global prompt; keep private local notes in `CLAUDE.local.md`.
                """.write(to: agentsURL, atomically: true, encoding: .utf8)
            }

            let claudeURL = repoURL.appendingPathComponent("CLAUDE.md")
            if !fileManager.fileExists(atPath: claudeURL.path) {
                try """
                @AGENTS.md

                ## Claude Code

                - Shared project instructions live in `AGENTS.md`.
                - Add only Claude-specific project behavior below this line.
                """.write(to: claudeURL, atomically: true, encoding: .utf8)
            }

            try fileManager.createDirectory(at: repoURL.appendingPathComponent(".agents/skills"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: repoURL.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: repoURL.appendingPathComponent(".claude/rules"), withIntermediateDirectories: true)
            try ensureGitignoreEntry("CLAUDE.local.md")
            lastCommandOutput = "Initialized project agent files in \(repoURL.path)."
        } catch {
            lastCommandOutput = "Failed to initialize project agent files: \(error)"
        }
        await refresh()
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

    private func scanProjectSurfaces(roots: [URL]? = nil) -> (prompts: [ProjectSurfaceRecord], skills: [ProjectSurfaceRecord]) {
        var prompts: [ProjectSurfaceRecord] = []
        var skills: [ProjectSurfaceRecord] = []
        var visitedDirectories: Set<String> = []
        var seenFiles: Set<String> = []
        for root in (roots ?? scanRoots()) where fileManager.fileExists(atPath: root.path) {
            collectProjectSurfaces(
                at: root.standardizedFileURL,
                depth: 0,
                maxDepth: 6,
                prompts: &prompts,
                skills: &skills,
                visitedDirectories: &visitedDirectories,
                seenFiles: &seenFiles
            )
        }
        prompts.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        skills.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (prompts, skills)
    }

    private func buildProjectTrees(prompts: [ProjectSurfaceRecord], skills: [ProjectSurfaceRecord]) -> [ProjectTreeRecord] {
        let allProjectPaths = Set((prompts + skills).map(\.projectPath))
        return allProjectPaths.sorted(by: compareProjectPaths).map { projectPath in
            let projectPrompts = prompts.filter { $0.projectPath == projectPath }
            let projectSkills = skills.filter { $0.projectPath == projectPath }
            let sample = projectPrompts.first ?? projectSkills.first
            return ProjectTreeRecord(
                id: projectPath,
                name: sample?.projectName ?? URL(fileURLWithPath: projectPath).lastPathComponent,
                path: displayPath(URL(fileURLWithPath: projectPath)),
                systemImage: projectIcon(for: projectPath),
                prompts: projectPrompts.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
                skills: projectSkills.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            )
        }
    }

    private func countDuplicateSkillGroups(skills: [ProjectSurfaceRecord]) -> Int {
        let grouped = Dictionary(grouping: skills) { $0.name.lowercased() }
        return grouped.values.filter { group in
            Set(group.map(\.projectPath)).count > 1 || Set(group.map(\.absolutePath)).count > 1
        }.count
    }

    private func defaultSelectedSurfaceID() -> String? {
        let repoPath = repoURL.standardizedFileURL.path
        if let repoTree = projectTrees.first(where: { $0.id == repoPath }) {
            return repoTree.prompts.first?.id ?? repoTree.skills.first?.id
        }
        return projectTrees.first?.allSurfaces.first?.id
    }

    private func compareProjectPaths(_ lhs: String, _ rhs: String) -> Bool {
        let lhsRank = projectSortRank(lhs)
        let rhsRank = projectSortRank(rhs)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func projectSortRank(_ path: String) -> Int {
        let homePath = homeURL.standardizedFileURL.path
        if path == repoURL.standardizedFileURL.path { return 0 }
        if path == homePath + "/.codex" { return 1 }
        if path == homePath + "/.claude" { return 2 }
        if path == homePath + "/.agents" { return 3 }
        if path.hasPrefix(homePath + "/Projects/") { return 4 }
        if path.hasPrefix(homePath + "/Companion/Code/") { return 5 }
        if path.hasPrefix(homePath + "/Documents/Codex/") { return 6 }
        return 10
    }

    private func scanRoots() -> [URL] {
        [
            repoURL,
            homeURL.appendingPathComponent("Projects"),
            homeURL.appendingPathComponent("Companion/Code"),
            homeURL.appendingPathComponent("Documents/Codex"),
            homeURL.appendingPathComponent(".codex"),
            homeURL.appendingPathComponent(".claude"),
            homeURL.appendingPathComponent(".agents")
        ]
    }

    private func priorityScanRoots() -> [URL] {
        [
            repoURL,
            homeURL.appendingPathComponent(".codex"),
            homeURL.appendingPathComponent(".claude"),
            homeURL.appendingPathComponent(".agents")
        ]
    }

    private func collectProjectSurfaces(
        at directory: URL,
        depth: Int,
        maxDepth: Int,
        prompts: inout [ProjectSurfaceRecord],
        skills: inout [ProjectSurfaceRecord],
        visitedDirectories: inout Set<String>,
        seenFiles: inout Set<String>
    ) {
        guard depth <= maxDepth else { return }
        let directoryPath = directory.standardizedFileURL.path
        guard visitedDirectories.insert(directoryPath).inserted else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return
        }

        for entry in entries {
            let name = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isDirectory == true
            let path = entry.standardizedFileURL.path

            if isDirectory {
                if skippedScanDirectories.contains(name) { continue }
                collectProjectSurfaces(
                    at: entry,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    prompts: &prompts,
                    skills: &skills,
                    visitedDirectories: &visitedDirectories,
                    seenFiles: &seenFiles
                )
                continue
            }

            guard seenFiles.insert(path).inserted else { continue }
            if isAgentPromptFile(entry) {
                prompts.append(surfaceRecord(for: entry, isSkill: false))
            }
            if isSkillFile(entry) {
                skills.append(surfaceRecord(for: entry, isSkill: true))
            }
        }
    }

    private func isAgentPromptFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ["AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md"].contains(name) {
            return true
        }
        return url.path.contains("/.claude/rules/") && name.hasSuffix(".md")
    }

    private func isSkillFile(_ url: URL) -> Bool {
        url.lastPathComponent == "SKILL.md" && url.path.contains("/skills/")
    }

    private func surfaceRecord(for url: URL, isSkill: Bool) -> ProjectSurfaceRecord {
        let path = url.standardizedFileURL.path
        let projectRoot = projectRoot(for: url)
        let projectPath = projectRoot.standardizedFileURL.path
        let relativePath = relativePath(from: projectRoot, to: url)
        return ProjectSurfaceRecord(
            id: path,
            name: surfaceName(for: url, isSkill: isSkill),
            scope: surfaceScope(for: url, isSkill: isSkill),
            path: displayPath(url),
            absolutePath: path,
            projectName: projectName(for: projectRoot),
            projectPath: projectPath,
            relativePath: relativePath,
            target: symlinkTarget(for: url),
            systemImage: isSkill ? "hammer" : "doc.text",
            kind: isSkill ? .skill : .agentFile,
            lineCount: lineCount(url)
        )
    }

    private func surfaceMatches(_ surface: ProjectSurfaceRecord, query: String) -> Bool {
        [
            surface.name,
            surface.scope,
            surface.path,
            surface.absolutePath,
            surface.projectName,
            surface.relativePath,
            surface.kind.rawValue
        ].contains { $0.lowercased().contains(query) }
    }

    private func loadSelectedSurfaceContent() {
        guard let selectedSurface else {
            selectedSurfaceContent = ""
            return
        }
        let url = URL(fileURLWithPath: selectedSurface.absolutePath)
        selectedSurfaceContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func surfaceName(for url: URL, isSkill: Bool) -> String {
        if isSkill {
            return url.deletingLastPathComponent().lastPathComponent
        }
        if url.path.contains("/.claude/rules/") {
            return ".claude/rules/\(url.lastPathComponent)"
        }
        return url.lastPathComponent
    }

    private func surfaceScope(for url: URL, isSkill: Bool) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        if path.hasPrefix(homePath + "/.codex/skills/") {
            return "Codex user skill"
        }
        if path.hasPrefix(homePath + "/.codex/") {
            return url.lastPathComponent == "AGENTS.override.md" ? "Codex global override" : "Codex global"
        }
        if path.hasPrefix(homePath + "/.claude/skills/") {
            return "Claude personal skill"
        }
        if path.hasPrefix(homePath + "/.claude/rules/") {
            return "Claude user rule"
        }
        if path.hasPrefix(homePath + "/.claude/") {
            return "Claude user"
        }
        if isSkill {
            if path.contains("/.agents/skills/") { return "Codex project skill" }
            if path.contains("/.claude/skills/") { return "Claude project skill" }
            return "Repo skill"
        }
        if path.contains("/.claude/rules/") {
            return "Claude project rule"
        }
        switch url.lastPathComponent {
        case "AGENTS.override.md":
            return "Codex project override"
        case "AGENTS.md":
            return "Codex project append"
        case "CLAUDE.local.md":
            return "Claude local append"
        case "CLAUDE.md":
            return "Claude project append"
        default:
            return "Agent file"
        }
    }

    private func projectRoot(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        for globalDirectory in [".codex", ".claude", ".agents"] {
            let globalURL = homeURL.appendingPathComponent(globalDirectory).standardizedFileURL
            let globalPath = globalURL.path
            if path == globalPath || path.hasPrefix(globalPath + "/") {
                return globalURL
            }
        }

        let floorPaths = Set(scanRoots().map { $0.standardizedFileURL.path })
        var current = url.deletingLastPathComponent().standardizedFileURL
        while current.path != homePath && current.path != "/" {
            if isProjectRoot(current) || floorPaths.contains(current.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return url.deletingLastPathComponent().standardizedFileURL
    }

    private func isProjectRoot(_ url: URL) -> Bool {
        let markerFiles = [
            ".git",
            "Package.swift",
            "package.json",
            "pyproject.toml",
            "Cargo.toml",
            "AGENTS.md",
            "CLAUDE.md"
        ]
        if markerFiles.contains(where: { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return true
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    private func projectName(for root: URL) -> String {
        let path = root.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        switch path {
        case homePath + "/.codex":
            return "Codex Global"
        case homePath + "/.claude":
            return "Claude Global"
        case homePath + "/.agents":
            return "Agent Skills"
        default:
            if path == repoURL.standardizedFileURL.path {
                return "Introspect"
            }
            return root.lastPathComponent.isEmpty ? path : root.lastPathComponent
        }
    }

    private func projectIcon(for projectPath: String) -> String {
        let homePath = homeURL.standardizedFileURL.path
        if projectPath == homePath + "/.codex" {
            return "terminal"
        }
        if projectPath == homePath + "/.claude" {
            return "bubble.left.and.text.bubble.right"
        }
        if projectPath == homePath + "/.agents" {
            return "hammer"
        }
        if projectPath == repoURL.standardizedFileURL.path {
            return "app.connected.to.app.below.fill"
        }
        return "folder"
    }

    private func relativePath(from root: URL, to url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath {
            return url.lastPathComponent
        }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return displayPath(url)
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeURL.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }

    private func symlinkTarget(for url: URL) -> String? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }
        let targetURL: URL
        if destination.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: destination)
        } else {
            targetURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return displayPath(targetURL.standardizedFileURL)
    }

    private func ensureGitignoreEntry(_ entry: String) throws {
        let gitignoreURL = repoURL.appendingPathComponent(".gitignore")
        let current = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        let lines = current.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.contains(entry) else { return }
        let prefix = current.isEmpty || current.hasSuffix("\n") ? current : current + "\n"
        try (prefix + entry + "\n").write(to: gitignoreURL, atomically: true, encoding: .utf8)
    }

    private func loadWordProfile() {
        wordProfileOK = fileManager.fileExists(atPath: wordProfileURL.path)
        guard let data = try? Data(contentsOf: wordProfileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            savedTriggerWords = defaultTriggerWords
            resetWordDraft()
            return
        }
        savedTriggerWords = (object["words"] as? [String] ?? defaultTriggerWords).sorted()
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

    private func readReflectorRunner() -> ReflectorRunner {
        let plists = [
            homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist"),
            homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.reflector.plist")
        ]
        for plist in plists {
            guard let data = try? Data(contentsOf: plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let root = object as? [String: Any],
                  let env = root["EnvironmentVariables"] as? [String: Any],
                  let raw = env["INTROSPECT_REFLECTOR_RUNNER"] as? String else {
                continue
            }
            return ReflectorRunner.parse(raw)
        }
        return .defaultRunner
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
