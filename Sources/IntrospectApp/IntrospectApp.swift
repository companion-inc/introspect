import AppKit
import UserNotifications
import SwiftUI

enum IntrospectTheme {
    static let accent = Color(red: 0.36, green: 0.53, blue: 0.96)
    static let selection = Color(red: 0.36, green: 0.53, blue: 0.96)
    static let cardCorner: CGFloat = 12
    static let pageMaxWidth: CGFloat = 820
}

/// A wrapping flow layout: lays children left-to-right, wrapping to the next
/// row when the current one is full. Each child keeps its natural width, so
/// trigger-word pills never stretch into fixed-width blocks or overlap.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

enum HealthState: Equatable {
    case ok
    case warning
    case off

    init(ok: Bool) {
        self = ok ? .ok : .warning
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .off: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Card<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

struct StatusDot: View {
    let state: HealthState

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
    }
}

struct CheckRow: View {
    let title: String
    let detail: String
    let state: HealthState

    init(_ title: String, detail: String, ok: Bool) {
        self.init(title, detail: detail, state: HealthState(ok: ok))
    }

    init(_ title: String, detail: String, state: HealthState) {
        self.title = title
        self.detail = detail
        self.state = state
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: state)
            Text(title)
                .frame(width: 110, alignment: .leading)
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

enum IntrospectNotificationPermission: Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            true
        case .unknown, .notDetermined, .denied:
            false
        }
    }

    var detail: String {
        switch self {
        case .authorized:
            "allowed by macOS"
        case .provisional:
            "delivered quietly by macOS"
        case .ephemeral:
            "temporarily allowed by macOS"
        case .notDetermined:
            "not requested yet"
        case .denied:
            "blocked in macOS System Settings"
        case .unknown:
            "unknown"
        }
    }
}

enum IntrospectNotifications {
    static let commandLineFlag = "--post-notification"
    static let requestFlag = "--request-notification"
    static let statusFlag = "--notification-status"
    static let statusFileFlag = "--notification-status-file"

    private final class ExitCodeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?

        func set(_ newValue: Int) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        var code: Int? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @MainActor
    static func runCommandLineIfNeeded() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.contains(commandLineFlag) || args.contains(requestFlag) || args.contains(statusFlag) else {
            return false
        }

        if args.contains(requestFlag) {
            return false
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        guard let index = args.firstIndex(of: commandLineFlag) else {
            if args.contains(statusFlag) {
                exit(Int32(statusSynchronously(outputPath: value(after: statusFileFlag, in: args))))
            }
            return true
        }

        let title = args.indices.contains(index + 1) ? args[index + 1] : "Introspect"
        let body = args.indices.contains(index + 2) ? args[index + 2] : ""
        exit(Int32(postSynchronously(title: title, body: body)))
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    static func post(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "introspect-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func postSynchronously(title: String, body: String) -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        let exitCode = ExitCodeBox()

        Task.detached {
            let status = await authorizationStatus()
            let permission = IntrospectNotificationPermission(status)
            let allowed: Bool
            if permission == .notDetermined {
                allowed = await requestAuthorization()
            } else {
                allowed = permission.allowsDelivery
            }

            guard allowed else {
                fputs("Introspect notifications are not authorized.\n", stderr)
                exitCode.set(2)
                semaphore.signal()
                return
            }

            do {
                try await post(title: title, body: body)
                exitCode.set(0)
            } catch {
                fputs("Failed to post Introspect notification: \(error)\n", stderr)
                exitCode.set(1)
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            fputs("Timed out posting Introspect notification.\n", stderr)
            return 124
        }
        return exitCode.code ?? 1
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag),
              args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    private static func statusSynchronously(outputPath: String? = nil) -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        let exitCode = ExitCodeBox()
        let bundleSummary = """
        bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")
        bundlePath=\(Bundle.main.bundlePath)
        executablePath=\(Bundle.main.executablePath ?? "nil")
        """

        Task.detached {
            let permission = IntrospectNotificationPermission(await authorizationStatus())
            let detail = "\(permission.detail)\n\(bundleSummary)"
            if let outputPath {
                try? (detail + "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
            } else {
                print(detail)
            }
            exitCode.set(permission.allowsDelivery ? 0 : 2)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            fputs("Timed out reading Introspect notification status.\n", stderr)
            return 124
        }
        return exitCode.code ?? 1
    }
}

@main
@MainActor
final class IntrospectApplication: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var retainedDelegate: IntrospectApplication?

    private let model = IntrospectModel()
    private var window: NSWindow?
    private var didStartInterface = false

    static func main() {
        if IntrospectNotifications.runCommandLineIfNeeded() {
            return
        }
        let app = NSApplication.shared
        let delegate = IntrospectApplication()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        delegate.startInterfaceIfNeeded()
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        startInterfaceIfNeeded()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let content = ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 660)
            let hostingView = NSHostingView(rootView: content)
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Introspect"
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.toolbarStyle = .unified
            newWindow.isOpaque = true
            newWindow.backgroundColor = NSColor.windowBackgroundColor
            newWindow.contentView = hostingView
            newWindow.isReleasedWhenClosed = false
            newWindow.setFrameAutosaveName("IntrospectMainWindow")
            newWindow.center()
            window = newWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startInterfaceIfNeeded() {
        guard !didStartInterface else { return }
        didStartInterface = true
        showWindow()
        Task { await model.start(requestNotificationOnLaunch: CommandLine.arguments.contains(IntrospectNotifications.requestFlag)) }
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
                Section("Monitor") {
                    Label("Overview", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .tag(IntrospectSection.status)
                    Label("Runs", systemImage: "clock.arrow.circlepath")
                        .tag(IntrospectSection.runs)
                    Label("Projects", systemImage: "folder")
                        .tag(IntrospectSection.projects)
                }
                Section("Configure") {
                    Label("Hooks", systemImage: "bolt")
                        .tag(IntrospectSection.hooks)
                    Label("Trigger Words", systemImage: "exclamationmark.bubble")
                        .tag(IntrospectSection.words)
                    Label("Notifications", systemImage: "bell")
                        .tag(IntrospectSection.notifications)
                }
                Section("Storage") {
                    Label("Local Profile", systemImage: "archivebox")
                        .tag(IntrospectSection.profile)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 240)
            .navigationTitle("Introspect")
            .safeAreaInset(edge: .bottom) {
                SidebarHealthFooter(model: model)
            }
        } detail: {
            Group {
                if [.projects, .runs].contains(model.selectedSection ?? .status) {
                    VStack(alignment: .leading, spacing: 16) {
                        switch model.selectedSection ?? .status {
                        case .runs:
                            RunsSection(model: model)
                        default:
                            ProjectsSection(model: model)
                        }
                        if !model.lastCommandOutput.isEmpty {
                            CommandOutputView(output: model.lastCommandOutput) {
                                model.lastCommandOutput = ""
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch model.selectedSection ?? .status {
                            case .status:
                                OverviewSection(model: model)
                            case .hooks:
                                HooksSection(model: model)
                            case .notifications:
                                NotificationsSection(model: model)
                            case .runs:
                                RunsSection(model: model)
                            case .projects:
                                ProjectsSection(model: model)
                            case .words:
                                WordsSection(model: model)
                            case .profile:
                                ProfileSection(model: model)
                            }
                            if !model.lastCommandOutput.isEmpty {
                                CommandOutputView(output: model.lastCommandOutput) {
                                    model.lastCommandOutput = ""
                                }
                            }
                        }
                        .frame(maxWidth: IntrospectTheme.pageMaxWidth, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(IntrospectTheme.accent)
    }
}

struct SidebarHealthFooter: View {
    @ObservedObject var model: IntrospectModel

    private var state: HealthState {
        model.hasWarning ? .warning : (model.mode == .off ? .off : .ok)
    }

    private var label: String {
        model.hasWarning ? "Needs attention" : model.mode.statusLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                model.selectedSection = .status
            } label: {
                HStack(spacing: 9) {
                    StatusDot(state: state)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(model.lastRunText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Overview")
        }
    }
}

struct OverviewSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        PageHeader(
            title: "Overview",
            subtitle: "Trigger signals from your Claude and Codex sessions feed a reflector that improves your agent instructions."
        )

        HealthBanner(model: model)

        Card("Prompt links") {
            HStack(spacing: 8) {
                CheckRow("Claude", detail: model.claudePromptStatus, ok: model.claudePromptOK)
                if model.claudePromptOK {
                    Button("Unlink") {
                        Task { await model.unlinkClaudePrompt() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove the ~/.claude/CLAUDE.md symlink. Apply Configuration in Hooks recreates it.")
                }
            }
            Divider()
            HStack(spacing: 8) {
                CheckRow("Codex", detail: model.codexPromptStatus, ok: model.codexPromptOK)
                if model.codexPromptOK {
                    Button("Unlink") {
                        Task { await model.unlinkCodexPrompt() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove the ~/.codex/AGENTS.md symlink. Apply Configuration in Hooks recreates it.")
                }
            }
        }

        Card("Detection") {
            CheckRow("Claude hook", detail: detectionDetail(model.claudeHookInstalled), state: detectionState(model.claudeHookInstalled))
            Divider()
            CheckRow("Codex hook", detail: detectionDetail(model.codexHookInstalled), state: detectionState(model.codexHookInstalled))
            Divider()
            CheckRow("Codex scanner", detail: detectionDetail(model.codexScannerInstalled), state: detectionState(model.codexScannerInstalled))
            Divider()
            CheckRow("Health monitor", detail: detectionDetail(model.healthMonitorInstalled), state: detectionState(model.healthMonitorInstalled))
            Divider()
            CheckRow("Notifications", detail: model.notificationStatusDetail, state: model.notificationHealthState)
        }

        Card("Activity") {
            InfoRow(label: "Queued events", value: "\(model.queuedEvents)")
            Divider()
            InfoRow(label: "Last reflector run", value: model.lastRunText)
        }

        Card("Locations") {
            LocationRow(label: "App repo", path: model.repoDisplayPath) {
                Task { await model.openRepoFolder() }
            }
            Divider()
            LocationRow(label: "Private profile", path: model.profileDisplayPath) {
                Task { await model.openProfileFolder() }
            }
        }
    }

    private func detectionDetail(_ installed: Bool) -> String {
        if model.mode == .off { return "off" }
        return installed ? "installed" : "missing"
    }

    private func detectionState(_ installed: Bool) -> HealthState {
        if model.mode == .off { return .off }
        return installed ? .ok : .warning
    }
}

struct HealthBanner: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(bannerColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: bannerSymbol)
                    .font(.title2)
                    .foregroundStyle(bannerColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.healthTitle)
                    .font(.headline)
                Text(model.healthDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                .stroke(bannerColor.opacity(0.35))
        )
    }

    private var bannerColor: Color {
        if model.hasWarning { return .orange }
        if model.mode == .off { return Color(nsColor: .tertiaryLabelColor) }
        return .green
    }

    private var bannerSymbol: String {
        if model.hasWarning { return "exclamationmark.triangle.fill" }
        if model.mode == .off { return "pause.circle.fill" }
        return "checkmark.circle.fill"
    }
}

struct LocationRow: View {
    let label: String
    let path: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Open", action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct HooksSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        PageHeader(
            title: "Hooks",
            subtitle: "Choose when reflection runs after a trigger word, and which agent runs it."
        )

        Card("When to reflect") {
            Picker("Reflection mode", selection: reflectionMode) {
                ForEach(ReflectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.mode.helpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.mode == .nightly {
                Divider()
                HStack(spacing: 10) {
                    Text("Run the nightly review at")
                        .foregroundStyle(.secondary)
                    DatePicker("Nightly time", selection: nightlyTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
            }
        }

        Card("Reflector agent") {
            Picker("Reflector agent", selection: reflectorRunner) {
                ForEach(ReflectorRunner.allCases) { runner in
                    Text(runner.title).tag(runner)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.reflectorRunner.helpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                Text("Model overrides")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ReflectorModelField(
                    title: "Claude",
                    placeholder: "CLI default",
                    text: $model.reflectorClaudeModel
                )
                ReflectorModelField(
                    title: "Claude fallback",
                    placeholder: "none",
                    text: $model.reflectorClaudeFallbackModel
                )
                ReflectorModelField(
                    title: "Codex",
                    placeholder: "CLI default",
                    text: $model.reflectorCodexModel
                )

                HStack(spacing: 8) {
                    Button("Apply Models", systemImage: "checkmark.circle") {
                        Task { await model.saveReflectorAgentSettings() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Use Defaults", systemImage: "arrow.counterclockwise") {
                        Task { await model.clearReflectorModels() }
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(model.isApplyingConfiguration)
            }
        }

        if model.isApplyingConfiguration {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Updating configuration")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reflectionMode: Binding<ReflectionMode> {
        Binding {
            model.mode
        } set: { mode in
            Task { await model.setReflectionMode(mode) }
        }
    }

    private var reflectorRunner: Binding<ReflectorRunner> {
        Binding {
            model.reflectorRunner
        } set: { runner in
            Task { await model.setReflectorRunner(runner) }
        }
    }

    private var nightlyTime: Binding<Date> {
        Binding {
            Calendar.current.date(
                bySettingHour: model.nightlyHour,
                minute: model.nightlyMinute,
                second: 0,
                of: Date()
            ) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let hour = components.hour ?? 3
            let minute = components.minute ?? 0
            Task { await model.setNightlyTime(hour: hour, minute: minute) }
        }
    }
}

struct ReflectorModelField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct NotificationsSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        PageHeader(
            title: "Notifications",
            subtitle: "Control the banner that appears when Introspect starts a reflector run."
        )

        Card("Delivery") {
            Toggle(isOn: notificationsEnabled) {
                Label("Notify when a reflector starts", systemImage: "bell")
            }
            .toggleStyle(.switch)

            Divider()

            CheckRow("Permission", detail: model.notificationPermission.detail, state: model.notificationPermissionHealthState)
        }

        HStack(spacing: 10) {
            Button {
                Task { await model.requestNotificationPermission() }
            } label: {
                Label("Enable", systemImage: "bell.badge")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.notificationsEnabled || model.notificationPermission.allowsDelivery)

            Button {
                Task { await model.sendTestNotification() }
            } label: {
                Label("Send Test", systemImage: "paperplane")
            }
            .buttonStyle(.bordered)
            .disabled(!model.notificationsEnabled)

            Button {
                model.openNotificationSettings()
            } label: {
                Label("System Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
        }
    }

    private var notificationsEnabled: Binding<Bool> {
        Binding {
            model.notificationsEnabled
        } set: { enabled in
            Task { await model.setNotificationsEnabled(enabled) }
        }
    }
}

struct WordsSection: View {
    @ObservedObject var model: IntrospectModel
    @State private var newWord = ""
    @State private var showBulkEditor = false

    var body: some View {
        PageHeader(
            title: "Trigger Words",
            subtitle: "Only these exact words wake the reflector. Everything else in a prompt is ignored."
        )

        Card {
            HStack(spacing: 8) {
                TextField("Add a word", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Text("\(model.activeTriggerWords.count) words")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.activeTriggerWords.isEmpty {
                Text("No trigger words — the hook will never fire.")
                    .foregroundStyle(.secondary)
            } else {
                WordChipList(words: model.activeTriggerWords) { word in
                    model.removeTriggerWord(word)
                }
            }

            Divider()

            DisclosureGroup("Edit as text", isExpanded: $showBulkEditor) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One exact word per line. Lowercase letters only — no prefixes, no phrases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.triggerWordsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }

        HStack(spacing: 10) {
            Button {
                Task { await model.saveWordProfile() }
            } label: {
                Label("Save Changes", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasUnsavedWordChanges)

            Button("Revert") {
                model.resetWordDraft()
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasUnsavedWordChanges)

            if model.hasUnsavedWordChanges {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
        }
    }

    private func addWord() {
        model.addTriggerWord(newWord)
        newWord = ""
    }
}

struct RunsSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runs")
                        .font(.title.weight(.semibold))
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .help("Reload trigger runs and transcripts")
            }

            HStack(spacing: 0) {
                RunsListPane(model: model)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 430)

                Divider()

                RunDetailPane(model: model)
                    .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6))
            )
        }
    }

    private var summary: String {
        let events = model.triggerRuns.reduce(0) { $0 + $1.eventCount }
        let changed = model.triggerRuns.filter { $0.reflectorSummary?.didChange == true }.count
        let runText = model.triggerRuns.count == 1 ? "1 run" : "\(model.triggerRuns.count) runs"
        let changeText = changed == 1 ? "1 prompt/skill change" : "\(changed) prompt/skill changes"
        let eventText = events == 1 ? "1 prompt event" : "\(events) prompt events"
        return "\(runText) · \(changeText) · \(eventText)"
    }
}

struct RunsListPane: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.triggerRuns.isEmpty {
                ContentUnavailableView(
                    "No Runs",
                    systemImage: "clock.badge.questionmark",
                    description: Text("No reflector run has been recorded yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.triggerRuns) { run in
                            RunRow(
                                run: run,
                                isSelected: run.id == model.selectedRunID
                            ) {
                                model.selectTriggerRun(run)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RunRow: View {
    let run: TriggerRunRecord
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(run.outcomeTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(run.outcomeBadge)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel(run.outcomeBadge)
                }

                Text(run.outcomeDetail)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !run.matched.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(run.matched, id: \.self) { word in
                                TriggerWordPill(word: word, isSelected: isSelected)
                            }
                        }
                    }
                    .accessibilityLabel("Trigger words: \(run.triggerWordsText)")
                }

                HStack(spacing: 6) {
                    if let runner = run.effectiveRunner {
                        Label(runner, systemImage: "terminal")
                    }
                    Label("\(run.surfaceDiffs.count)", systemImage: "rectangle.and.pencil.and.ellipsis")
                    Label(run.timestampText, systemImage: "clock")
                    Label("\(run.sessionIDs.count)", systemImage: "bubble.left.and.text.bubble.right")
                    Label("\(run.eventCount)", systemImage: "text.line.first.and.arrowtriangle.forward")
                    if run.dryRun {
                        Label("Dry run", systemImage: "flask")
                    }
                    if run.transcriptPaths.isEmpty {
                        Label("No transcript", systemImage: "doc.badge.ellipsis")
                    }
                }
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IntrospectTheme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct RunDetailPane: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let run = model.selectedRun {
                RunDetailHeader(model: model, run: run)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        RunTriggerCauseBlock(run: run)
                        ReflectorTraceBlock(model: model, run: run)
                        AgentSurfaceDiffBlock(run: run)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Select a Run",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Choose a reflector run to read what the AI changed and why.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ReflectorTraceBlock: View {
    @ObservedObject var model: IntrospectModel
    let run: TriggerRunRecord
    @State private var promptExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label("Reflector trace", systemImage: run.reflectorSummary?.systemImage ?? "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if let runner = run.effectiveRunner {
                    ScopePill(text: runner)
                }
                ScopePill(text: run.modelBadgeText)
                if let fallback = run.fallbackModelBadgeText {
                    ScopePill(text: fallback)
                }
                if let exit = run.reflectorSummary?.exitCode {
                    ScopePill(text: "exit \(exit)")
                }
            }

            if let summary = run.reflectorSummary {
                if !summary.outputText.isEmpty {
                    Text(summary.outputText)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The reflector command completed, but it did not write decision text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !model.reflectorPromptText.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $promptExpanded) {
                        Text(model.reflectorPromptText)
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    } label: {
                        Label("Prompt sent to reflector", systemImage: "text.page")
                            .font(.callout.weight(.semibold))
                    }
                }

                if !summary.commandText.isEmpty {
                    Divider()
                    Text(summary.commandText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                    Text("This batch has no matching reflector log entry yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                if !model.reflectorPromptText.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $promptExpanded) {
                        Text(model.reflectorPromptText)
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    } label: {
                        Label("Queued reflector prompt", systemImage: "text.page")
                            .font(.callout.weight(.semibold))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45))
        )
    }
}

struct AgentSurfaceDiffBlock: View {
    let run: TriggerRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label("Agent surface diff", systemImage: "rectangle.and.pencil.and.ellipsis")
                    .font(.headline)
                Spacer()
                ScopePill(text: "\(run.surfaceDiffs.count) changes")
            }

            if run.surfaceDiffs.isEmpty {
                Text("No AGENTS.md, CLAUDE.md, rule, or skill changes were recorded for this reflector run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(run.surfaceDiffs) { diff in
                        AgentSurfaceDiffRow(diff: diff)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45))
        )
    }
}

struct AgentSurfaceDiffRow: View {
    let diff: AgentSurfaceDiffRecord

    var body: some View {
        DisclosureGroup {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(diff.diffText.trimmedOr("No textual diff was captured."))
                    .font(.system(.caption, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.top, 6)
            }
            .frame(maxHeight: 320)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: diff.systemImage)
                    .foregroundStyle(IntrospectTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diff.displayPath)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(diff.kindLabel) · \(diff.beforeLineCount) -> \(diff.afterLineCount) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ScopePill(text: diff.changeType)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RunTriggerCauseBlock: View {
    let run: TriggerRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Trigger words", systemImage: "exclamationmark.bubble")
                .font(.headline)

            if run.matched.isEmpty {
                Text("No matched trigger words were recorded for this run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(run.matched, id: \.self) { word in
                            TriggerWordPill(word: word)
                        }
                    }
                    .padding(.bottom, 1)
                }
                .accessibilityLabel("Trigger words: \(run.triggerWordsText)")
            }

            if !run.events.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(run.events.prefix(5)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Label(event.sourceLabel, systemImage: event.sourceSystemImage)
                                Text(event.timestampText)
                                if !event.matched.isEmpty {
                                    Text(event.matched.joined(separator: ", "))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Text(event.snippet.isEmpty ? "No snippet recorded." : event.snippet)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45))
        )
    }
}

struct RunDetailHeader: View {
    @ObservedObject var model: IntrospectModel
    let run: TriggerRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: run.reflectorSummary?.systemImage ?? "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(IntrospectTheme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(run.outcomeTitle)
                        .font(.title3.bold())
                    Text(run.outcomeDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ScopePill(text: run.outcomeBadge)
                            if let target = run.reflectorSummary?.targetName {
                                ScopePill(text: target)
                            }
                            if let runner = run.effectiveRunner {
                                ScopePill(text: runner)
                            }
                            ScopePill(text: run.modelBadgeText)
                            if let exit = run.reflectorSummary?.exitCode {
                                ScopePill(text: "exit \(exit)")
                            }
                            ScopePill(text: "\(run.eventCount) prompt events")
                            ScopePill(text: "\(run.sessionIDs.count) sessions")
                            if run.dryRun {
                                ScopePill(text: "dry run")
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    model.openOriginalThread()
                } label: {
                    Label("Open Thread", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(run.sessionIDs.isEmpty && model.selectedTranscriptPath == nil)
                .help("Open the original Claude/Codex conversation that triggered this run")

                Menu {
                    if run.transcriptPaths.count > 1 {
                        Section("Original thread") {
                            ForEach(run.transcriptPaths, id: \.self) { path in
                                Button(model.displayPathForUser(path)) {
                                    model.selectTranscript(path: path)
                                }
                            }
                        }
                    }
                    Button("Copy Reflector Output", systemImage: "doc.on.clipboard") {
                        model.copySelectedReflectorOutput()
                    }
                    .disabled(run.reflectorSummary?.outputText.isEmpty ?? true)
                    Button("Reveal Transcript in Finder", systemImage: "folder") {
                        model.revealSelectedTranscript()
                    }
                    .disabled(model.selectedTranscriptPath == nil)
                    Button("Copy Transcript Path", systemImage: "doc.on.clipboard") {
                        model.copySelectedTranscriptPath()
                    }
                    .disabled(model.selectedTranscriptPath == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.large)
                .fixedSize()
                .help("More actions")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ProjectsSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Projects")
                        .font(.title.weight(.semibold))
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isScanningSurfaces {
                    ProgressView()
                        .controlSize(.small)
                        .help("Scanning agent files and skills")
                }

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .help("Rescan agent files and skills")

                Button("Open Repo", systemImage: "folder") {
                    Task { await model.openRepoFolder() }
                }
                .buttonStyle(.bordered)

            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search projects, files, scopes, and paths", text: $model.surfaceSearchText)
                    .textFieldStyle(.plain)
                if !model.surfaceSearchText.isEmpty {
                    Button {
                        model.surfaceSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6))
            )

            HStack(spacing: 0) {
                ProjectHierarchyPane(
                    model: model,
                    projects: model.filteredProjectTrees,
                    selectedID: model.selectedSurfaceID
                )
                .frame(minWidth: 330, idealWidth: 390, maxWidth: 460)

                Divider()

                ProjectSurfaceDetail(model: model)
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6))
            )
        }
        .confirmationDialog(
            trashDialogTitle,
            isPresented: Binding(
                get: { model.surfacePendingTrash != nil },
                set: { if !$0 { model.surfacePendingTrash = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.confirmTrash() }
            }
            Button("Cancel", role: .cancel) {
                model.surfacePendingTrash = nil
            }
        } message: {
            Text(trashDialogMessage)
        }
    }

    private var trashDialogTitle: String {
        guard let record = model.surfacePendingTrash else { return "" }
        return "Move \u{201C}\(record.name)\u{201D} to the Trash?"
    }

    private var trashDialogMessage: String {
        guard let record = model.surfacePendingTrash else { return "" }
        let target = model.trashTargetURL(for: record)
        if record.kind == .skill {
            return "The whole skill folder at \(target.path) moves to the Trash. You can restore it from there."
        }
        return "\(target.path) moves to the Trash. You can restore it from there."
    }

    private var summary: String {
        var parts = [
            "\(model.projectTrees.count) roots",
            "\(model.promptSurfaces.count) agent files",
            "\(model.skillSurfaces.count) skills"
        ]
        if model.duplicateSkillGroups > 0 {
            parts.append("\(model.duplicateSkillGroups) duplicate skill names")
        }
        return parts.joined(separator: " · ")
    }
}

struct ProjectHierarchyPane: View {
    let model: IntrospectModel
    let projects: [ProjectTreeRecord]
    let selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files")
                    .font(.caption.weight(.semibold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

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
                                model: model,
                                project: project,
                                selectedID: selectedID
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
    let model: IntrospectModel
    let project: ProjectTreeRecord
    let selectedID: String?

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
                model: model,
                title: "Agent Files",
                systemImage: "doc.text",
                items: project.prompts,
                selectedID: selectedID
            )

            SurfaceGroupNode(
                model: model,
                title: "Skills",
                systemImage: "hammer",
                items: project.skills,
                selectedID: selectedID
            )
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct SurfaceGroupNode: View {
    let model: IntrospectModel
    let title: String
    let systemImage: String
    let items: [ProjectSurfaceRecord]
    let selectedID: String?

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
                            model: model,
                            item: item,
                            isSelected: item.id == selectedID
                        )
                    }
                }
            }
        }
    }
}

struct SurfaceTreeRow: View {
    let model: IntrospectModel
    let item: ProjectSurfaceRecord
    let isSelected: Bool

    var body: some View {
        Button {
            model.selectSurface(item)
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
        .contextMenu {
            Button("Edit in Introspect") {
                model.selectSurface(item)
                model.beginEditingSurface()
            }
            Button("Open in Default Editor") {
                model.openSurfaceInEditor(item)
            }
            Button("Reveal in Finder") {
                model.revealSurface(item)
            }
            Button("Copy Path") {
                model.copySurfacePath(item)
            }
            Divider()
            Button(item.kind == .skill ? "Move Skill Folder to Trash" : "Move to Trash", role: .destructive) {
                model.requestTrash(item)
            }
        }
    }
}

struct ProjectSurfaceDetail: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let record = model.selectedSurface {
                SurfaceDetailHeader(model: model, record: record)
                Divider()
                if model.isEditingSurface {
                    SurfaceEditor(model: model)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            SurfaceMeaning(record: record)
                            if record.kind == .skill {
                                SkillFrontmatterSummary(content: model.selectedSurfaceContent)
                            }
                            SurfaceMetadata(record: record)
                            SurfaceContentBlock(content: model.selectedSurfaceContent)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
    @ObservedObject var model: IntrospectModel
    let record: ProjectSurfaceRecord

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

            if !model.isEditingSurface {
                Button("Edit", systemImage: "pencil") {
                    model.beginEditingSurface()
                }
                .buttonStyle(.bordered)
                .help("Edit this file in Introspect")

                Button("Reveal", systemImage: "arrow.up.forward.app") {
                    model.revealSurface(record)
                }
                .buttonStyle(.bordered)
                .help("Show in Finder")

                Menu {
                    Button("Open in Default Editor") {
                        model.openSurfaceInEditor(record)
                    }
                    Button("Copy Path") {
                        model.copySurfacePath(record)
                    }
                    Divider()
                    Button(record.kind == .skill ? "Move Skill Folder to Trash" : "Move to Trash", role: .destructive) {
                        model.requestTrash(record)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SurfaceEditor: View {
    @ObservedObject var model: IntrospectModel

    private var isDirty: Bool {
        model.surfaceDraftContent != model.selectedSurfaceContent
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.surfaceDraftContent)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack(spacing: 10) {
                if isDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                }
                Spacer()
                Button("Cancel") {
                    model.cancelEditingSurface()
                }
                .buttonStyle(.bordered)
                Button("Save", systemImage: "square.and.arrow.down") {
                    Task { await model.saveSurfaceEdits() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
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

struct TriggerWordPill: View {
    let word: String
    var isSelected = false

    var body: some View {
        Text(word)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7))
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
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 6) {
                    Text(word)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Button {
                        onRemove(word)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \u{201C}\(word)\u{201D}")
                }
                .padding(.leading, 10)
                .padding(.trailing, 7)
                .padding(.vertical, 5)
                .background(IntrospectTheme.accent.opacity(0.12))
                .overlay(
                    Capsule().stroke(IntrospectTheme.accent.opacity(0.25), lineWidth: 1)
                )
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProfileSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        PageHeader(
            title: "Local Profile",
            subtitle: "A private git repo for your prompt variants, personal skills, trigger words, and reflector logs. It stays on this machine and out of the open-source app repo."
        )

        Card("State") {
            CheckRow("Git repo", detail: model.profileGitStatus, ok: model.profileGitOK)
            Divider()
            CheckRow("Word profile", detail: model.wordProfileStatus, ok: model.wordProfileOK)
            Divider()
            InfoRow(label: "Last commit", value: model.profileLastCommit)
        }

        HStack(spacing: 10) {
            if model.profileGitOK {
                Button {
                    Task { await model.commitProfileChanges() }
                } label: {
                    Label("Commit Changes", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task { await model.openProfileFolder() }
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
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

struct CommandOutputView: View {
    let output: String
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last command")
                    .font(.caption.weight(.semibold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(IntrospectTheme.accent)
            }
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6))
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6))
        )
    }
}

enum IntrospectSection: Hashable {
    case status
    case hooks
    case notifications
    case runs
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
        case .immediate: "Right After Trigger"
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
            "Trigger prompts enqueue and kick one locked worker immediately. Debounce and cooldown still batch bursts."
        case .nightly:
            "Trigger prompts enqueue only; a LaunchAgent reviews the batch at the selected time."
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

    static func parse(_ value: String?) -> ReflectionMode {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "nightly":
            .nightly
        case "off":
            .off
        default:
            .immediate
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
            "Uses the installed agent with the most recent local usage profile. Model overrides apply after the runner is selected."
        case .claude:
            "Forces reflector runs through Claude. Leave the model fields empty to use Claude's CLI default."
        case .codex:
            "Forces reflector runs through Codex. Leave the model field empty to use Codex's CLI default."
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

struct TriggerEventRecord: Identifiable, Hashable {
    let id: String
    let timestampValue: String
    let timestampText: String
    let triggered: Bool
    let sessionID: String
    let cwd: String
    let transcriptPath: String
    let transcriptLine: Int?
    let matched: [String]
    let snippet: String
    let source: String

    var sourceLabel: String {
        switch source {
        case "codex_transcript_scan":
            return "Codex scanner"
        case "hook", "":
            return "Hook"
        default:
            return source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var sourceSystemImage: String {
        switch source {
        case "codex_transcript_scan":
            return "clock.arrow.circlepath"
        default:
            return "bolt"
        }
    }
}

struct ReflectorRunSummary: Hashable {
    let timestampValue: String
    let runner: String?
    let eventCount: Int?
    let exitCode: Int?
    let commandText: String
    let outputText: String
    let classification: String?
    let targetName: String?
    let outcomeTitle: String
    let outcomeDetail: String
    let systemImage: String

    var runnerText: String? {
        guard let runner, !runner.isEmpty else { return nil }
        return runner
    }

    var didChange: Bool {
        if let classification {
            return classification != "no_change"
        }
        let lower = outputText.lowercased()
        if lower.contains("no files changed") || lower.contains("nothing committed") {
            return false
        }
        return lower.contains("committed") || lower.contains("pushed") || lower.contains("files changed")
    }
}

struct TriggerRunRecord: Identifiable {
    let id: String
    let timestampValue: String
    let timestampText: String
    let eventCount: Int
    let dryRun: Bool
    let sessionIDs: [String]
    let matched: [String]
    let events: [TriggerEventRecord]
    let transcriptPaths: [String]
    let runner: String?
    let model: String?
    let fallbackModel: String?
    let promptPath: String?
    let surfaceDiffPath: String?
    let surfaceDiffs: [AgentSurfaceDiffRecord]
    let reflectorSummary: ReflectorRunSummary?

    var outcomeTitle: String {
        reflectorSummary?.outcomeTitle ?? "Reflector run"
    }

    var outcomeDetail: String {
        reflectorSummary?.outcomeDetail ?? "Waiting for reflector output"
    }

    var outcomeBadge: String {
        reflectorSummary?.classification ?? (reflectorSummary == nil ? "pending" : "complete")
    }

    var triggerWordsText: String {
        matched.joined(separator: ", ")
    }

    var effectiveRunner: String? {
        let value = runner?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty, value != "dry-run" {
            return value
        }
        return reflectorSummary?.runnerText
    }

    var modelBadgeText: String {
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "model: CLI default" : "model: \(value)"
    }

    var fallbackModelBadgeText: String? {
        let value = fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : "fallback: \(value)"
    }
}

struct AgentSurfaceDiffRecord: Identifiable, Hashable {
    let id: String
    let path: String
    let displayPath: String
    let kind: String
    let changeType: String
    let beforeLineCount: Int
    let afterLineCount: Int
    let diffText: String

    var kindLabel: String {
        switch kind {
        case "skill":
            return "Skill"
        case "agent_rule":
            return "Claude rule"
        default:
            return "Agent file"
        }
    }

    var systemImage: String {
        switch kind {
        case "skill":
            return "hammer"
        case "agent_rule":
            return "list.bullet.rectangle"
        default:
            return "doc.text"
        }
    }
}

private struct TriggerBatchRecord {
    let id: String
    let timestampValue: String
    let eventCount: Int
    let matched: [String]
    let dryRun: Bool
    let sessionIDs: [String]
    let runner: String?
    let model: String?
    let fallbackModel: String?
    let promptPath: String?
    let surfaceDiffPath: String?
}

private struct ReflectorInvocation {
    let timestampValue: String
    let runner: String
    let eventCount: Int?
}

private struct ReflectorRunBuilder {
    let timestampValue: String
    let runner: String?
    let eventCount: Int?
    var commandText: String
    var outputLines: [String]
}

@MainActor
final class IntrospectModel: ObservableObject {
    @Published var selectedSection: IntrospectSection? = .runs
    @Published var mode: ReflectionMode = .immediate
    @Published var reflectorRunner: ReflectorRunner = .defaultRunner
    @Published var reflectorClaudeModel = ""
    @Published var reflectorClaudeFallbackModel = ""
    @Published var reflectorCodexModel = ""
    @Published var nightlyHour = 3
    @Published var nightlyMinute = 0
    @Published var claudePromptOK = false
    @Published var codexPromptOK = false
    @Published var claudeHookInstalled = false
    @Published var codexHookInstalled = false
    @Published var codexScannerInstalled = false
    @Published var healthMonitorInstalled = false
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
    @Published var surfacePendingTrash: ProjectSurfaceRecord?
    @Published var triggerRuns: [TriggerRunRecord] = []
    @Published var selectedRunID: String?
    @Published var selectedTranscriptPath: String?
    @Published var reflectorPromptText = ""
    @Published var isEditingSurface = false
    @Published var surfaceDraftContent = ""
    @Published var isScanningSurfaces = false
    @Published var duplicateSkillGroups = 0
    @Published var notificationsEnabled = true
    @Published var notificationPermission: IntrospectNotificationPermission = .unknown
    @Published var notificationHelperInstalled = false
    @Published var isApplyingConfiguration = false

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
        let repoPath = env["INTROSPECT_REPO"] ?? "\(NSHomeDirectory())/Companion/Code/introspect"
        let profilePath = env["INTROSPECT_PROFILE_DIR"] ?? "\(NSHomeDirectory())/.introspect/profile"
        repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
        profileURL = URL(fileURLWithPath: profilePath).standardizedFileURL
    }

    var repoPath: String { repoURL.path }
    var profilePath: String { profileURL.path }
    var repoDisplayPath: String { displayPath(repoURL) }
    var profileDisplayPath: String { displayPath(profileURL) }

    var claudePromptStatus: String {
        claudePromptOK ? "~/.claude/CLAUDE.md -> \(displayPath(repoURL))/AGENTS.md" : "not linked to this repo"
    }

    var codexPromptStatus: String {
        codexPromptOK ? "~/.codex/AGENTS.md -> \(displayPath(repoURL))/AGENTS.md" : "not linked to this repo"
    }

    var hooksSummary: String {
        if mode == .off {
            return "disabled"
        }
        if allHooksInstalled && codexScannerInstalled {
            return healthMonitorInstalled
                ? "Claude/Codex hooks, scanner, and monitor installed"
                : "hooks and scanner installed, monitor missing"
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
        mode == .off || (allHooksInstalled && codexScannerInstalled && healthMonitorInstalled)
    }

    var hasWarning: Bool {
        !claudePromptOK ||
            !codexPromptOK ||
            !healthMonitorInstalled ||
            (mode != .off && (!allHooksInstalled || !codexScannerInstalled)) ||
            (mode != .off && notificationsEnabled && notificationHealthState == .warning)
    }

    var healthTitle: String {
        if hasWarning { return "Needs attention" }
        if mode == .off { return "Paused" }
        return "Everything is running"
    }

    var healthDetail: String {
        if hasWarning {
            var missing: [String] = []
            if !claudePromptOK || !codexPromptOK { missing.append("prompt links") }
            if mode != .off && !allHooksInstalled { missing.append("hooks") }
            if mode != .off && !codexScannerInstalled { missing.append("the Codex scanner") }
            if !healthMonitorInstalled { missing.append("the health monitor") }
            return isApplyingConfiguration
                ? "Updating configuration."
                : "Missing: \(missing.joined(separator: ", ")). Introspect will repair this automatically."
        }
        if mode == .off {
            return "Hooks are disabled. Prompts stay linked, but no trigger events are collected."
        }
        let events = queuedEvents == 1 ? "1 queued event" : "\(queuedEvents) queued events"
        return "\(mode.statusLabel) · \(events) · last run \(lastRunText)"
    }

    var activeTriggerWords: [String] {
        parseWords(triggerWordsText)
    }

    var hasUnsavedWordChanges: Bool {
        activeTriggerWords != savedTriggerWords
    }

    var selectedSurface: ProjectSurfaceRecord? {
        projectTrees
            .flatMap(\.allSurfaces)
            .first { $0.id == selectedSurfaceID }
    }

    var selectedRun: TriggerRunRecord? {
        triggerRuns.first { $0.id == selectedRunID }
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
        profileGitOK ? "\(displayPath(profileURL))/.git" : "not initialized"
    }

    var wordProfileStatus: String {
        wordProfileOK ? displayPath(wordProfileURL) : "missing"
    }

    private var wordProfileURL: URL {
        profileURL.appendingPathComponent("trigger-words.json")
    }

    private var profileSettingsURL: URL {
        profileURL.appendingPathComponent("settings.json")
    }

    private var builtNotificationHelperURL: URL {
        repoURL.appendingPathComponent(".build/Introspect.app/Contents/MacOS/Introspect")
    }

    private var installedNotificationHelperURL: URL {
        URL(fileURLWithPath: "/Applications/Introspect.app/Contents/MacOS/Introspect")
    }

    private var notificationHelperURL: URL {
        fileManager.isExecutableFile(atPath: installedNotificationHelperURL.path)
            ? installedNotificationHelperURL
            : builtNotificationHelperURL
    }

    var notificationStatusDetail: String {
        if !notificationsEnabled {
            return "disabled"
        }
        if !notificationHelperInstalled {
            return "app helper missing"
        }
        return notificationPermission.detail
    }

    var notificationHealthState: HealthState {
        if !notificationsEnabled || mode == .off {
            return .off
        }
        guard notificationHelperInstalled, notificationPermission.allowsDelivery else {
            return .warning
        }
        return .ok
    }

    var notificationPermissionHealthState: HealthState {
        if !notificationsEnabled {
            return .off
        }
        return notificationPermission.allowsDelivery ? .ok : .warning
    }

    func refreshNotificationState() async {
        loadProfileSettings()
        notificationHelperInstalled = fileManager.isExecutableFile(atPath: notificationHelperURL.path)
        notificationPermission = IntrospectNotificationPermission(await IntrospectNotifications.authorizationStatus())
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        do {
            try saveProfileSettings(["notifications_enabled": enabled])
            lastCommandOutput = enabled ? "Enabled reflector notifications." : "Disabled reflector notifications."
        } catch {
            lastCommandOutput = "Failed to save notification setting: \(error.localizedDescription)"
        }

        if enabled, !notificationPermission.allowsDelivery {
            await requestNotificationPermission()
        } else {
            await refreshNotificationState()
        }
    }

    func requestNotificationPermission() async {
        let granted = await IntrospectNotifications.requestAuthorization()
        notificationPermission = IntrospectNotificationPermission(await IntrospectNotifications.authorizationStatus())
        lastCommandOutput = granted
            ? "macOS notifications are allowed for Introspect."
            : "macOS notifications are blocked for Introspect. Open System Settings to allow them."
    }

    func sendTestNotification() async {
        guard notificationsEnabled else {
            lastCommandOutput = "Notifications are disabled in Introspect."
            return
        }

        if notificationPermission == .notDetermined {
            await requestNotificationPermission()
        }

        if notificationPermission.allowsDelivery {
            do {
                try await IntrospectNotifications.post(
                    title: "Introspect",
                    body: "Notifications are coming from Introspect.app."
                )
                lastCommandOutput = "Sent a test notification from Introspect.app."
            } catch {
                lastCommandOutput = "Failed to send test notification: \(error.localizedDescription)"
            }
            await refreshNotificationState()
            return
        }

        lastCommandOutput = "macOS is blocking Introspect.app notifications. Open System Settings to allow Introspect."
        await refreshNotificationState()
    }

    func openNotificationSettings() {
        let deepLinks = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        for raw in deepLinks {
            guard let url = URL(string: raw) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func start(requestNotificationOnLaunch: Bool = false) async {
        await refresh()
        await ensureAutomaticSetup()
        await refresh()
        await handleNotificationStartup(requestAuthorization: requestNotificationOnLaunch)
    }

    private func handleNotificationStartup(requestAuthorization: Bool) async {
        guard notificationsEnabled, !notificationPermission.allowsDelivery else { return }
        selectedSection = .notifications
        if requestAuthorization || notificationPermission == .notDetermined {
            await requestNotificationPermission()
        } else if notificationPermission == .denied {
            lastCommandOutput = "macOS is blocking Introspect.app notifications. The Notifications pane is open; allow Introspect in System Settings, then press Send Test."
        }
    }

    private func ensureAutomaticSetup() async {
        guard !isApplyingConfiguration else { return }
        isApplyingConfiguration = true
        defer { isApplyingConfiguration = false }

        var repaired = false
        if !profileGitOK || !wordProfileOK || !fileManager.fileExists(atPath: profileSettingsURL.path) {
            await initializeProfileRepo(report: false, refreshAfter: false)
            repaired = true
        }

        if !currentProjectAgentFilesReady {
            await initializeCurrentProjectAgentFiles(report: false, refreshAfter: false)
            repaired = true
        }

        if mode != .off && (!claudePromptOK || !codexPromptOK || !allHooksInstalled || !codexScannerInstalled) {
            await applySystemPromptAndHooks(report: false, refreshAfter: false)
            repaired = true
        }

        if repaired {
            lastCommandOutput = "Introspect repaired local setup automatically."
        }
    }

    private var currentProjectAgentFilesReady: Bool {
        fileManager.fileExists(atPath: repoURL.appendingPathComponent("AGENTS.md").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent("CLAUDE.md").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent(".agents/skills").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent(".claude/skills").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent(".claude/rules").path)
    }

    func refresh() async {
        await refreshNotificationState()
        claudePromptOK = symlink(homeURL.appendingPathComponent(".claude/CLAUDE.md"), pointsTo: repoURL.appendingPathComponent("AGENTS.md"))
        codexPromptOK = symlink(homeURL.appendingPathComponent(".codex/AGENTS.md"), pointsTo: repoURL.appendingPathComponent("AGENTS.md"))
        let claude = hookStatus(path: homeURL.appendingPathComponent(".claude/settings.json"))
        let codex = hookStatus(path: homeURL.appendingPathComponent(".codex/hooks.json"))
        claudeHookInstalled = claude.installed
        codexHookInstalled = codex.installed
        mode = claude.mode ?? codex.mode ?? mode
        launchAgentInstalled = fileManager.fileExists(atPath: homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.reflector.plist").path)
        codexScannerInstalled = fileManager.fileExists(atPath: homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist").path)
        healthMonitorInstalled = fileManager.fileExists(atPath: homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.health.plist").path)
        if let launchEnvironment = readReflectorLaunchEnvironment() {
            reflectorRunner = ReflectorRunner.parse(launchEnvironment["INTROSPECT_REFLECTOR_RUNNER"])
            reflectorClaudeModel = launchEnvironment["INTROSPECT_REFLECTOR_CLAUDE_MODEL"] ?? ""
            reflectorClaudeFallbackModel = launchEnvironment["INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL"] ?? ""
            reflectorCodexModel = launchEnvironment["INTROSPECT_REFLECTOR_CODEX_MODEL"] ?? ""
        }
        queuedEvents = lineCount(repoURL.appendingPathComponent("feedback/trigger-queue.jsonl"))
        lastRunText = readLastRun()
        loadTriggerHistory()
        loadWordProfile()
        profileGitOK = fileManager.fileExists(atPath: profileURL.appendingPathComponent(".git").path)
        wordProfileOK = fileManager.fileExists(atPath: wordProfileURL.path)
        profileLastCommit = profileGitOK
            ? await gitOutput(["-C", profileURL.path, "log", "-1", "--oneline"]).trimmedOr("none")
            : "none"

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

    func applySystemPromptAndHooks(report: Bool = true, refreshAfter: Bool = true) async {
        await initializeProfileRepo(report: false, refreshAfter: false)
        try? saveConfigurationSettings()
        var args = [
            repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
            "--reflect-mode", mode.rawValue,
            "--nightly-hour", "\(nightlyHour)",
            "--nightly-minute", "\(nightlyMinute)",
            "--runner", reflectorRunner.rawValue,
            "--claude-model", normalizedModelSetting(reflectorClaudeModel),
            "--claude-fallback-model", normalizedModelSetting(reflectorClaudeFallbackModel),
            "--codex-model", normalizedModelSetting(reflectorCodexModel)
        ]
        if mode == .off {
            args = [
                repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
                "--reflect-mode", "off"
            ]
        }
        let output = await shell("/bin/bash", args)
        if report {
            lastCommandOutput = output
        }
        if refreshAfter {
            await refresh()
        }
    }

    func disableHooks() async {
        await setReflectionMode(.off)
    }

    func setReflectionMode(_ newMode: ReflectionMode) async {
        guard mode != newMode else { return }
        mode = newMode
        await applyConfigurationChange()
    }

    func setReflectorRunner(_ newRunner: ReflectorRunner) async {
        guard reflectorRunner != newRunner else { return }
        reflectorRunner = newRunner
        await applyConfigurationChange()
    }

    func saveReflectorAgentSettings() async {
        await applyConfigurationChange()
    }

    func clearReflectorModels() async {
        reflectorClaudeModel = ""
        reflectorClaudeFallbackModel = ""
        reflectorCodexModel = ""
        await applyConfigurationChange()
    }

    func setNightlyTime(hour: Int, minute: Int) async {
        guard nightlyHour != hour || nightlyMinute != minute else { return }
        nightlyHour = hour
        nightlyMinute = minute
        guard mode == .nightly else {
            try? saveConfigurationSettings()
            return
        }
        await applyConfigurationChange()
    }

    private func applyConfigurationChange() async {
        guard !isApplyingConfiguration else { return }
        isApplyingConfiguration = true
        defer { isApplyingConfiguration = false }
        await applySystemPromptAndHooks(report: true, refreshAfter: true)
    }

    private func saveConfigurationSettings() throws {
        try saveProfileSettings([
            "notifications_enabled": notificationsEnabled,
            "reflect_mode": mode.rawValue,
            "reflector_runner": reflectorRunner.rawValue,
            "reflector_claude_model": normalizedModelSetting(reflectorClaudeModel),
            "reflector_claude_fallback_model": normalizedModelSetting(reflectorClaudeFallbackModel),
            "reflector_codex_model": normalizedModelSetting(reflectorCodexModel),
            "nightly_hour": nightlyHour,
            "nightly_minute": nightlyMinute
        ])
    }

    func initializeProfileRepo(report: Bool = true, refreshAfter: Bool = true) async {
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
            if !fileManager.fileExists(atPath: profileSettingsURL.path) {
                try writeJSON([
                    "notifications_enabled": notificationsEnabled,
                    "reflect_mode": mode.rawValue,
                    "reflector_runner": reflectorRunner.rawValue,
                    "reflector_claude_model": normalizedModelSetting(reflectorClaudeModel),
                    "reflector_claude_fallback_model": normalizedModelSetting(reflectorClaudeFallbackModel),
                    "reflector_codex_model": normalizedModelSetting(reflectorCodexModel),
                    "nightly_hour": nightlyHour,
                    "nightly_minute": nightlyMinute
                ], to: profileSettingsURL)
            }
            let readme = profileURL.appendingPathComponent("README.md")
            if !fileManager.fileExists(atPath: readme.path) {
                try """
                # Introspect Local Profile

                This repository is private local state for Introspect:

                - `trigger-words.json`: exact trigger words.
                - `settings.json`: local app preferences such as notification delivery.
                - `prompts/`: private prompt variants.
                - `skills/`: private user skills.

                Commit changes locally when you want a checkpoint.
                """.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            if report {
                lastCommandOutput = "Failed to initialize profile files: \(error)"
            }
            return
        }

        if !fileManager.fileExists(atPath: profileURL.appendingPathComponent(".git").path) {
            _ = await gitOutput(["init", profileURL.path])
        }
        await commitProfileChanges(message: "Initialize Introspect profile", report: report)
        if refreshAfter {
            await refresh()
        }
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
        await commitProfileChanges(message: "Update trigger word profile")
        await refresh()
    }

    func resetWordDraft() {
        triggerWordsText = savedTriggerWords.joined(separator: "\n")
    }

    func addTriggerWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard word.wholeMatch(of: /^[a-z]+$/) != nil else { return }
        var words = activeTriggerWords
        guard !words.contains(word) else { return }
        words.append(word)
        triggerWordsText = words.sorted().joined(separator: "\n")
    }

    func removeTriggerWord(_ word: String) {
        triggerWordsText = activeTriggerWords.filter { $0 != word }.joined(separator: "\n")
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

    func selectTriggerRun(_ run: TriggerRunRecord) {
        selectedRunID = run.id
        selectedTranscriptPath = run.transcriptPaths.first
        loadSelectedReflectorPrompt()
    }

    func selectTranscript(path: String) {
        selectedTranscriptPath = path
    }

    func revealSelectedTranscript() {
        guard let path = selectedTranscriptPath, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copySelectedTranscriptPath() {
        guard let path = selectedTranscriptPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        lastCommandOutput = "Copied \(path)"
    }

    func openOriginalThread() {
        guard let run = selectedRun else { return }
        let selectedPath = selectedTranscriptPath ?? run.transcriptPaths.first
        if let selectedPath, selectedPath.contains("/.codex/sessions/"),
           let sessionID = run.sessionIDs.first(where: { !$0.isEmpty && $0 != "unknown" }),
           let url = URL(string: "codex://threads/\(sessionID)"),
           NSWorkspace.shared.open(url) {
            lastCommandOutput = "Opened original Codex thread \(sessionID)."
            return
        }

        if let sessionID = run.sessionIDs.first(where: { !$0.isEmpty && $0 != "unknown" }) {
            let command = "claude --resume \(sessionID)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            if let selectedPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedPath)])
            }
            lastCommandOutput = "Copied \(command) and revealed the original JSONL. Claude app deep-link format is not verified here."
            return
        }

        if let selectedPath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedPath)])
            lastCommandOutput = "Revealed the original JSONL."
        }
    }

    func copySelectedReflectorOutput() {
        guard let output = selectedRun?.reflectorSummary?.outputText, !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        lastCommandOutput = "Copied reflector output"
    }

    func displayPathForUser(_ path: String) -> String {
        displayPath(URL(fileURLWithPath: path))
    }

    func selectSurface(_ record: ProjectSurfaceRecord) {
        isEditingSurface = false
        selectedSurfaceID = record.id
        loadSelectedSurfaceContent()
    }

    func revealSelectedSurface() {
        guard let selectedSurface else { return }
        revealSurface(selectedSurface)
    }

    func revealSurface(_ record: ProjectSurfaceRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.absolutePath)])
    }

    func openSurfaceInEditor(_ record: ProjectSurfaceRecord) {
        NSWorkspace.shared.open(URL(fileURLWithPath: record.absolutePath))
    }

    func copySurfacePath(_ record: ProjectSurfaceRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.absolutePath, forType: .string)
        lastCommandOutput = "Copied \(record.absolutePath)"
    }

    func requestTrash(_ record: ProjectSurfaceRecord) {
        surfacePendingTrash = record
    }

    func trashTargetURL(for record: ProjectSurfaceRecord) -> URL {
        let url = URL(fileURLWithPath: record.absolutePath)
        if record.kind == .skill && url.lastPathComponent == "SKILL.md" {
            return url.deletingLastPathComponent()
        }
        return url
    }

    func confirmTrash() async {
        guard let record = surfacePendingTrash else { return }
        surfacePendingTrash = nil
        let url = trashTargetURL(for: record)
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
            lastCommandOutput = "Moved \(displayPath(url)) to the Trash."
            if selectedSurfaceID == record.id {
                selectedSurfaceID = nil
            }
        } catch {
            lastCommandOutput = "Failed to move \(displayPath(url)) to the Trash: \(error.localizedDescription)"
        }
        await refresh()
    }

    func beginEditingSurface() {
        surfaceDraftContent = selectedSurfaceContent
        isEditingSurface = true
    }

    func cancelEditingSurface() {
        isEditingSurface = false
    }

    func saveSurfaceEdits() async {
        guard let selectedSurface else { return }
        // Resolve symlinks so an atomic write replaces the target file, not the link itself.
        let url = URL(fileURLWithPath: selectedSurface.absolutePath).resolvingSymlinksInPath()
        do {
            try surfaceDraftContent.write(to: url, atomically: true, encoding: .utf8)
            lastCommandOutput = "Saved \(displayPath(url))."
            isEditingSurface = false
        } catch {
            lastCommandOutput = "Failed to save \(displayPath(url)): \(error.localizedDescription)"
        }
        await refresh()
    }

    func unlinkClaudePrompt() async {
        await removePromptLink(homeURL.appendingPathComponent(".claude/CLAUDE.md"))
    }

    func unlinkCodexPrompt() async {
        await removePromptLink(homeURL.appendingPathComponent(".codex/AGENTS.md"))
    }

    private func removePromptLink(_ url: URL) async {
        do {
            try fileManager.removeItem(at: url)
            lastCommandOutput = "Removed \(displayPath(url)). Apply Configuration in Hooks recreates it."
        } catch {
            lastCommandOutput = "Failed to remove \(displayPath(url)): \(error.localizedDescription)"
        }
        await refresh()
    }

    func initializeCurrentProjectAgentFiles(report: Bool = true, refreshAfter: Bool = true) async {
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
            if report {
                lastCommandOutput = "Initialized project agent files in \(repoURL.path)."
            }
        } catch {
            if report {
                lastCommandOutput = "Failed to initialize project agent files: \(error)"
            }
        }
        if refreshAfter {
            await refresh()
        }
    }

    private func commitProfileChanges(message: String, report: Bool = true) async {
        _ = await gitOutput(["-C", profileURL.path, "add", "."])
        let status = await gitOutput(["-C", profileURL.path, "status", "--porcelain"])
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if report {
                lastCommandOutput = "Profile repo has no uncommitted changes."
            }
            return
        }
        let output = await gitOutput(["-C", profileURL.path, "commit", "-m", message])
        if report {
            lastCommandOutput = output
        }
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

    private func loadProfileSettings() {
        let settings = readProfileSettings()
        notificationsEnabled = settings["notifications_enabled"] as? Bool ?? true
        mode = ReflectionMode.parse(settings["reflect_mode"] as? String)
        reflectorRunner = ReflectorRunner.parse(settings["reflector_runner"] as? String)
        reflectorClaudeModel = settings["reflector_claude_model"] as? String ?? ""
        reflectorClaudeFallbackModel = settings["reflector_claude_fallback_model"] as? String ?? ""
        reflectorCodexModel = settings["reflector_codex_model"] as? String ?? ""
        if let hour = settings["nightly_hour"] as? Int, (0...23).contains(hour) {
            nightlyHour = hour
        }
        if let minute = settings["nightly_minute"] as? Int, (0...59).contains(minute) {
            nightlyMinute = minute
        }
    }

    private func saveProfileSettings(_ updates: [String: Any]) throws {
        try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)
        var settings = readProfileSettings()
        for (key, value) in updates {
            settings[key] = value
        }
        try writeJSON(settings, to: profileSettingsURL)
    }

    private func readProfileSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: profileSettingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
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
                      command.contains("trigger-reflect.sh") else { continue }
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

    private func readReflectorLaunchEnvironment() -> [String: String]? {
        let plists = [
            homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist"),
            homeURL.appendingPathComponent("Library/LaunchAgents/ai.companion.introspect.reflector.plist")
        ]
        for plist in plists {
            guard let data = try? Data(contentsOf: plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let root = object as? [String: Any],
                  let env = root["EnvironmentVariables"] as? [String: Any] else {
                continue
            }
            return env.reduce(into: [String: String]()) { result, pair in
                if let value = pair.value as? String {
                    result[pair.key] = value
                }
            }
        }
        return nil
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
            return "never"
        }
        return friendlyTimestamp(value)
    }

    private func loadTriggerHistory() {
        let events = readTriggerEvents()
            .sorted { compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending }
        let batches = readTriggerBatches()
            .sorted { compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending }
        let reflectorSummaries = readReflectorSummaries()
        var runs: [TriggerRunRecord] = []

        for batch in batches.prefix(100) {
            let reflectorSummary = matchingReflectorSummary(for: batch, in: reflectorSummaries)
            let sessionIDs = Set(batch.sessionIDs)
            let candidates = events.filter { event in
                event.triggered &&
                    sessionIDs.contains(event.sessionID) &&
                    compareTimestamps(event.timestampValue, batch.timestampValue) != .orderedDescending
            }
            let runEvents = Array(candidates.prefix(max(batch.eventCount, 1)))
            let matched = unique(batch.matched + runEvents.flatMap(\.matched))
            let fallbackPaths = events
                .filter { sessionIDs.contains($0.sessionID) }
                .compactMap { $0.transcriptPath.isEmpty ? nil : $0.transcriptPath }
            let transcriptPaths = unique(runEvents.compactMap { $0.transcriptPath.isEmpty ? nil : $0.transcriptPath } + fallbackPaths)
            runs.append(
                TriggerRunRecord(
                    id: batch.id,
                    timestampValue: batch.timestampValue,
                    timestampText: friendlyTimestamp(batch.timestampValue),
                    eventCount: batch.eventCount,
                    dryRun: batch.dryRun,
                    sessionIDs: batch.sessionIDs,
                    matched: matched,
                    events: runEvents,
                    transcriptPaths: transcriptPaths,
                    runner: batch.runner,
                    model: batch.model,
                    fallbackModel: batch.fallbackModel,
                    promptPath: batch.promptPath,
                    surfaceDiffPath: batch.surfaceDiffPath,
                    surfaceDiffs: readSurfaceDiffs(batch.surfaceDiffPath),
                    reflectorSummary: reflectorSummary
                )
            )
        }

        if runs.isEmpty {
            let grouped = Dictionary(grouping: events.filter(\.triggered), by: \.sessionID)
            runs = grouped.values.compactMap { sessionEvents in
                guard let first = sessionEvents.sorted(by: {
                    compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending
                }).first else {
                    return nil
                }
                let orderedEvents = sessionEvents.sorted {
                    compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending
                }
                return TriggerRunRecord(
                    id: "session-\(first.sessionID)-\(first.timestampValue)",
                    timestampValue: first.timestampValue,
                    timestampText: friendlyTimestamp(first.timestampValue),
                    eventCount: orderedEvents.count,
                    dryRun: false,
                    sessionIDs: [first.sessionID],
                    matched: unique(orderedEvents.flatMap(\.matched)),
                    events: orderedEvents,
                    transcriptPaths: unique(orderedEvents.compactMap { $0.transcriptPath.isEmpty ? nil : $0.transcriptPath }),
                    runner: nil,
                    model: nil,
                    fallbackModel: nil,
                    promptPath: nil,
                    surfaceDiffPath: nil,
                    surfaceDiffs: [],
                    reflectorSummary: nil
                )
            }
            .sorted { compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending }
        }

        triggerRuns = runs
        if selectedRunID == nil || selectedRun == nil {
            selectedRunID = triggerRuns.first?.id
        }
        if let selectedRun {
            if selectedTranscriptPath == nil || !selectedRun.transcriptPaths.contains(selectedTranscriptPath ?? "") {
                selectedTranscriptPath = selectedRun.transcriptPaths.first
            }
        } else {
            selectedTranscriptPath = nil
        }
        loadSelectedReflectorPrompt()
    }

    private func readTriggerEvents() -> [TriggerEventRecord] {
        let url = repoURL.appendingPathComponent("feedback/events.jsonl")
        return readJSONLines(url).enumerated().map { index, object in
            let timestamp = object["ts"] as? String ?? ""
            let sessionID = object["session_id"] as? String ?? "unknown"
            let transcriptLine = intValue(object["transcript_line"])
            let id = object["dedupe_key"] as? String
                ?? "\(timestamp)-\(sessionID)-\(transcriptLine ?? index)"
            return TriggerEventRecord(
                id: id,
                timestampValue: timestamp,
                timestampText: friendlyTimestamp(timestamp),
                triggered: object["triggered"] as? Bool ?? false,
                sessionID: sessionID,
                cwd: object["cwd"] as? String ?? "",
                transcriptPath: object["transcript_path"] as? String ?? "",
                transcriptLine: transcriptLine,
                matched: object["matched"] as? [String] ?? [],
                snippet: object["snippet"] as? String ?? "",
                source: object["source"] as? String ?? "hook"
            )
        }
    }

    private func readTriggerBatches() -> [TriggerBatchRecord] {
        let url = repoURL.appendingPathComponent("feedback/reflector-batches.jsonl")
        return readJSONLines(url).enumerated().map { index, object in
            let timestamp = object["ts"] as? String ?? ""
            let sessions = (object["sessions"] as? [String] ?? [])
                .filter { !$0.isEmpty }
                .sorted()
            return TriggerBatchRecord(
                id: "\(timestamp)-\(index)-\(sessions.joined(separator: ","))",
                timestampValue: timestamp,
                eventCount: max(intValue(object["event_count"]) ?? 0, 0),
                matched: object["matched"] as? [String] ?? [],
                dryRun: object["dry_run"] as? Bool ?? false,
                sessionIDs: sessions,
                runner: object["runner"] as? String,
                model: object["model"] as? String,
                fallbackModel: object["fallback_model"] as? String,
                promptPath: object["prompt_path"] as? String,
                surfaceDiffPath: object["surface_diff_path"] as? String
            )
        }
    }

    private func readSurfaceDiffs(_ path: String?) -> [AgentSurfaceDiffRecord] {
        guard let path, !path.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let changes = object["changes"] as? [[String: Any]] else {
            return []
        }
        return changes.enumerated().map { index, change in
            let path = change["path"] as? String ?? ""
            let displayPath = change["display_path"] as? String ?? path
            return AgentSurfaceDiffRecord(
                id: "\(path)-\(index)",
                path: path,
                displayPath: displayPath,
                kind: change["kind"] as? String ?? "agent_file",
                changeType: change["change_type"] as? String ?? "modified",
                beforeLineCount: intValue(change["before_line_count"]) ?? 0,
                afterLineCount: intValue(change["after_line_count"]) ?? 0,
                diffText: change["diff"] as? String ?? ""
            )
        }
    }

    private func readReflectorSummaries() -> [ReflectorRunSummary] {
        let url = repoURL.appendingPathComponent("feedback/reflector.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var summaries: [ReflectorRunSummary] = []
        var current: ReflectorRunBuilder?

        for linePart in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(linePart)

            if let invocation = parseReflectorInvocation(line) {
                if let builder = current {
                    summaries.append(makeReflectorSummary(from: builder, exitCode: nil))
                }
                current = ReflectorRunBuilder(
                    timestampValue: invocation.timestampValue,
                    runner: invocation.runner,
                    eventCount: invocation.eventCount,
                    commandText: "",
                    outputLines: []
                )
                continue
            }

            if let (timestamp, message) = reflectorLogParts(line),
               message.hasPrefix("command: ") {
                if current == nil {
                    current = ReflectorRunBuilder(
                        timestampValue: timestamp,
                        runner: nil,
                        eventCount: nil,
                        commandText: "",
                        outputLines: []
                    )
                }
                current?.commandText = String(message.dropFirst("command: ".count))
                continue
            }

            if let exit = parseReflectorExit(line), let builder = current {
                summaries.append(makeReflectorSummary(from: builder, exitCode: exit.code))
                current = nil
                continue
            }

            if current != nil, reflectorLogParts(line) == nil {
                current?.outputLines.append(line)
            }
        }

        if let builder = current {
            summaries.append(makeReflectorSummary(from: builder, exitCode: nil))
        }
        return summaries
    }

    private func matchingReflectorSummary(
        for batch: TriggerBatchRecord,
        in summaries: [ReflectorRunSummary]
    ) -> ReflectorRunSummary? {
        guard let batchDate = dateValue(batch.timestampValue) else {
            return summaries.first {
                compareTimestamps($0.timestampValue, batch.timestampValue) != .orderedAscending
            }
        }

        return summaries.compactMap { summary -> (summary: ReflectorRunSummary, score: TimeInterval)? in
            guard let summaryDate = dateValue(summary.timestampValue) else { return nil }
            let delta = summaryDate.timeIntervalSince(batchDate)
            guard delta >= -5, delta <= 900 else { return nil }
            let countPenalty: TimeInterval
            if let eventCount = summary.eventCount {
                countPenalty = eventCount == batch.eventCount ? 0 : 120
            } else {
                countPenalty = 30
            }
            return (summary, abs(delta) + countPenalty)
        }
        .min { $0.score < $1.score }?
        .summary
    }

    private func makeReflectorSummary(
        from builder: ReflectorRunBuilder,
        exitCode: Int?
    ) -> ReflectorRunSummary {
        let output = builder.outputLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = reflectorOutcome(for: output, exitCode: exitCode)
        return ReflectorRunSummary(
            timestampValue: builder.timestampValue,
            runner: builder.runner,
            eventCount: builder.eventCount,
            exitCode: exitCode,
            commandText: builder.commandText,
            outputText: output,
            classification: outcome.classification,
            targetName: outcome.targetName,
            outcomeTitle: outcome.title,
            outcomeDetail: outcome.detail,
            systemImage: outcome.systemImage
        )
    }

    private func reflectorOutcome(
        for output: String,
        exitCode: Int?
    ) -> (classification: String?, targetName: String?, title: String, detail: String, systemImage: String) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var classification: String?
        var targetName: String?

        if let line = lines.first(where: { $0.localizedCaseInsensitiveContains("Classification:") }) {
            let parsed = parseReflectorMarker("Classification:", in: line)
            classification = parsed.value?.lowercased()
            targetName = parsed.target
        }

        if classification == nil,
           let line = lines.first(where: { $0.localizedCaseInsensitiveContains("Decision:") }) {
            let parsed = parseReflectorMarker("Decision:", in: line)
            classification = parsed.value?.lowercased()
            targetName = parsed.target
        }

        if classification == nil {
            let lower = output.lowercased()
            if lower.contains("no_change") || lower.contains("no files changed") || lower.contains("nothing committed") {
                classification = "no_change"
            }
        }

        let commitHash = extractCommitHash(from: output)
        let title = reflectorTitle(for: classification, exitCode: exitCode)
        var detail = reflectorDetail(for: classification, targetName: targetName, exitCode: exitCode)
        if let commitHash {
            detail += " · commit \(commitHash)"
        }

        return (
            classification,
            targetName,
            title,
            detail,
            reflectorSystemImage(for: classification, exitCode: exitCode)
        )
    }

    private func parseReflectorMarker(
        _ marker: String,
        in line: String
    ) -> (value: String?, target: String?) {
        guard let markerRange = line.range(of: marker, options: .caseInsensitive) else {
            return (nil, nil)
        }

        var valueText = String(line[markerRange.upperBound...])
        var targetText: String?
        if let dashRange = valueText.range(of: "—") ?? valueText.range(of: " - ") {
            targetText = cleanReflectorToken(String(valueText[dashRange.upperBound...]))
            valueText = String(valueText[..<dashRange.lowerBound])
        }
        if let paren = valueText.firstIndex(of: "(") {
            valueText = String(valueText[..<paren])
        }

        let value = cleanReflectorToken(valueText)
        let target = targetText.flatMap { $0.isEmpty ? nil : $0 }
        return (value.isEmpty ? nil : value, target)
    }

    private func cleanReflectorToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#`*:;., ")))
    }

    private func reflectorTitle(for classification: String?, exitCode: Int?) -> String {
        if let exitCode, exitCode != 0 {
            return "Reflector failed"
        }
        switch classification {
        case "no_change":
            return "No change"
        case "core_prompt":
            return "Core prompt"
        case "project_prompt":
            return "Project prompt"
        case "profile_memory":
            return "Profile memory"
        case "skill_new":
            return "New skill"
        case "skill_update":
            return "Skill update"
        case "project_skill_new":
            return "New project skill"
        case "project_skill_update":
            return "Project skill update"
        case "skill_prune":
            return "Skill prune"
        case let value?:
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return "Reflector output"
        }
    }

    private func reflectorDetail(for classification: String?, targetName: String?, exitCode: Int?) -> String {
        if let exitCode, exitCode != 0 {
            return "Command exited with code \(exitCode)"
        }
        let suffix = targetName.map { ": \($0)" } ?? ""
        switch classification {
        case "no_change":
            return "No prompt or skill edit"
        case "core_prompt":
            return "Changed the core agent prompt"
        case "project_prompt":
            return "Changed a project prompt\(suffix)"
        case "profile_memory":
            return "Updated profile memory\(suffix)"
        case "skill_new":
            return "Created a skill\(suffix)"
        case "skill_update":
            return "Updated a skill\(suffix)"
        case "project_skill_new":
            return "Created a project skill\(suffix)"
        case "project_skill_update":
            return "Updated a project skill\(suffix)"
        case "skill_prune":
            return "Pruned a skill\(suffix)"
        case let value?:
            return "Reflector classified this as \(value)\(suffix)"
        default:
            return "Reflector completed"
        }
    }

    private func reflectorSystemImage(for classification: String?, exitCode: Int?) -> String {
        if let exitCode, exitCode != 0 {
            return "exclamationmark.triangle"
        }
        switch classification {
        case "no_change":
            return "checkmark.circle"
        case "core_prompt", "project_prompt":
            return "doc.text"
        case "profile_memory":
            return "person.crop.circle"
        case "skill_new", "skill_update", "project_skill_new", "project_skill_update", "skill_prune":
            return "hammer"
        default:
            return "doc.text.magnifyingglass"
        }
    }

    private func extractCommitHash(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.lowercased().contains("commit") else { continue }
            for token in line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let candidate = String(token)
                if candidate.range(of: #"^[0-9a-f]{6,40}$"#, options: .regularExpression) != nil {
                    return candidate
                }
            }
        }
        return nil
    }

    private func parseReflectorInvocation(_ line: String) -> ReflectorInvocation? {
        guard let (timestamp, message) = reflectorLogParts(line),
              message.hasPrefix("invoking "),
              let marker = message.range(of: " reflector for ") else {
            return nil
        }
        let runnerStart = message.index(message.startIndex, offsetBy: "invoking ".count)
        let runner = String(message[runnerStart..<marker.lowerBound])
        let afterMarker = message[marker.upperBound...]
        let eventCount = afterMarker
            .split(separator: " ")
            .first
            .flatMap { Int(String($0)) }
        return ReflectorInvocation(
            timestampValue: timestamp,
            runner: runner,
            eventCount: eventCount
        )
    }

    private func parseReflectorExit(_ line: String) -> (timestamp: String, code: Int?)? {
        guard let (timestamp, message) = reflectorLogParts(line),
              message.hasPrefix("reflector exited code=") else {
            return nil
        }
        let codeText = message
            .dropFirst("reflector exited code=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (timestamp, Int(codeText))
    }

    private func reflectorLogParts(_ line: String) -> (timestamp: String, message: String)? {
        guard let split = line.firstIndex(of: " ") else { return nil }
        let timestamp = String(line[..<split])
        guard dateValue(timestamp) != nil else { return nil }
        return (timestamp, String(line[line.index(after: split)...]))
    }

    private func loadSelectedReflectorPrompt() {
        guard let path = selectedRun?.promptPath, !path.isEmpty else {
            reflectorPromptText = ""
            return
        }
        reflectorPromptText = (try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)) ?? ""
    }

    private func readJSONLines(_ url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }
    }

    private func compareTimestamps(_ lhs: String, _ rhs: String) -> ComparisonResult {
        // Introspect writes uniform ISO-8601 UTC timestamps
        // ("2026-06-13T21:54:12+00:00"), which sort lexically in chronological
        // order. Comparing the strings directly avoids allocating a date
        // formatter per comparison — this runs hundreds of thousands of times
        // while building Runs, so parsing here froze the UI on launch.
        lhs.compare(rhs)
    }

    private func dateValue(_ value: String) -> Date? {
        Self.isoParser.date(from: value) ?? Self.isoParserFractional.date(from: value)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            guard !value.isEmpty, seen.insert(value).inserted else {
                return false
            }
            return true
        }
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let isoParserFractional: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()
    private static let friendlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func friendlyTimestamp(_ value: String) -> String {
        guard let date = Self.isoParser.date(from: value)
            ?? Self.isoParserFractional.date(from: value) else { return value }
        return Self.friendlyFormatter.string(from: date)
    }

    private func parseWords(_ text: String) -> [String] {
        let pattern = /^[a-z]+$/
        let words = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.wholeMatch(of: pattern) != nil }
        return Array(Set(words)).sorted()
    }

    private func normalizedModelSetting(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["", "default", "auto"].contains(trimmed.lowercased()) {
            return ""
        }
        return trimmed
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
