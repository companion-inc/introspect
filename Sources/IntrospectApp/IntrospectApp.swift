import AppKit
import Charts
import Darwin
import NaturalLanguage
import UserNotifications
import SwiftUI

/// Builds a Color that resolves differently in light vs dark appearance, so the
/// whole app adapts without threading `colorScheme` through every view.
private func introspectDynamic(light: Int, dark: Int, alpha: Double = 1) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(introspectHex: isDark ? dark : light, alpha: CGFloat(alpha))
    })
}

extension NSColor {
    convenience init(introspectHex hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(introspectHex hex: Int, alpha: Double = 1) {
        self.init(nsColor: NSColor(introspectHex: hex, alpha: CGFloat(alpha)))
    }
}

/// Introspect design language — synthesized from the best-built desktop apps:
/// Superhuman's semantic token ramp + tight radii, Linear's cool-neutral
/// restraint and indigo accent, Granola's airy whitespace. Cool refined
/// neutral, hairline borders, a single indigo accent used sparingly.
enum IntrospectTheme {
    static let canvas = introspectDynamic(light: 0xF5F6F8, dark: 0x16171D)
    static let surface = introspectDynamic(light: 0xFFFFFF, dark: 0x1E1F27)
    static let surfaceAlt = introspectDynamic(light: 0xEDEFF3, dark: 0x131319)
    static let surfaceSunken = introspectDynamic(light: 0xEFF1F4, dark: 0x202129)

    static let ink = introspectDynamic(light: 0x171922, dark: 0xECEEF4)
    static let inkSecondary = introspectDynamic(light: 0x595D6B, dark: 0x9FA3B2)
    static let inkTertiary = introspectDynamic(light: 0x8A8E9C, dark: 0x6B6F7E)

    static let border = introspectDynamic(light: 0x2B2F3A, dark: 0xFFFFFF, alpha: 0.10)
    static let borderStrong = introspectDynamic(light: 0x2B2F3A, dark: 0xFFFFFF, alpha: 0.18)

    static let accent = introspectDynamic(light: 0x5E6AD2, dark: 0x8A93F0)
    static let accentSoft = introspectDynamic(light: 0x5E6AD2, dark: 0x8A93F0, alpha: 0.13)
    static let selection = introspectDynamic(light: 0x5E6AD2, dark: 0x8A93F0, alpha: 0.14)

    static let success = introspectDynamic(light: 0x2F9E5E, dark: 0x5FD08A)
    static let danger = introspectDynamic(light: 0xD64B4B, dark: 0xF0817F)
    static let warning = introspectDynamic(light: 0xC2841F, dark: 0xE3B25A)

    static let diffAddBg = introspectDynamic(light: 0xE4F2E8, dark: 0x18301F)
    static let diffDelBg = introspectDynamic(light: 0xFBE6E6, dark: 0x36201F)
    static let diffAddFg = introspectDynamic(light: 0x2C7A47, dark: 0x6FCB8C)
    static let diffDelFg = introspectDynamic(light: 0xC23B3B, dark: 0xEC8581)
    static let diffMeta = introspectDynamic(light: 0x6E6AD2, dark: 0x9B97E8)

    static let cardCorner: CGFloat = 9
    static let controlCorner: CGFloat = 6
    static let pageMaxWidth: CGFloat = 880

    /// New York serif for display titles — editorial weight without aping one brand.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
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
        case .ok: IntrospectTheme.success
        case .warning: IntrospectTheme.warning
        case .off: IntrospectTheme.inkTertiary
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(IntrospectTheme.display(27))
                .foregroundStyle(IntrospectTheme.ink)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(IntrospectTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
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
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(IntrospectTheme.inkTertiary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IntrospectTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                .stroke(IntrospectTheme.border)
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
    static let installFlag = "--install"
    static let uninstallFlag = "--uninstall"
    static let appStatusFlag = "--status"
    static let helpFlag = "--help"

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
        guard args.contains(commandLineFlag) ||
            args.contains(requestFlag) ||
            args.contains(statusFlag) ||
            args.contains(installFlag) ||
            args.contains(uninstallFlag) ||
            args.contains(appStatusFlag) ||
            args.contains(helpFlag) else {
            return false
        }

        if args.contains(requestFlag) {
            return false
        }

        if args.contains(helpFlag) {
            printCLIUsage()
            exit(0)
        }

        if args.contains(installFlag) {
            exit(Int32(runInstallCLI(uninstall: false)))
        }

        if args.contains(uninstallFlag) {
            exit(Int32(runInstallCLI(uninstall: true)))
        }

        if args.contains(appStatusFlag) {
            exit(Int32(runStatusCLI()))
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

    private static func printCLIUsage() {
        print("""
        Usage:
          Introspect --install      Set up ~/.introspect, prompt links, hooks, scanner, and health monitor
          Introspect --status       Print current Introspect setup status
          Introspect --uninstall    Remove Introspect hooks, scanner, monitor, and prompt links

        Notification helper:
          Introspect --request-notification
          Introspect --post-notification TITLE BODY
          Introspect --notification-status
        """)
    }

    private static func runInstallCLI(uninstall: Bool) -> Int {
        let root = runtimeRoot()
        let script = root.appendingPathComponent("scripts/install-hooks.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            fputs("Missing Introspect installer at \(script.path)\n", stderr)
            return 1
        }
        var args = [
            script.path,
            "--home", introspectHomeRoot().path,
            "--agents-home", agentsHomeRoot().path
        ]
        if uninstall {
            args.append("--uninstall")
        } else {
            args.append(contentsOf: ["--reflect-mode", "immediate"])
        }
        return runProcess("/bin/bash", args)
    }

    private static func runStatusCLI() -> Int {
        let root = runtimeRoot()
        let script = root.appendingPathComponent("scripts/introspect-status.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            fputs("Missing Introspect status script at \(script.path)\n", stderr)
            return 1
        }
        return runProcess("/bin/bash", [script.path])
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONDONTWRITEBYTECODE": "1",
            "INTROSPECT_REPO": runtimeRoot().path,
            "INTROSPECT_HOME": introspectHomeRoot().path,
            "AGENTS_HOME": agentsHomeRoot().path
        ]) { current, _ in current }
        do {
            try process.run()
            process.waitUntilExit()
            return Int(process.terminationStatus)
        } catch {
            fputs("Failed to run \(executable): \(error)\n", stderr)
            return 1
        }
    }

    private static func runtimeRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["INTROSPECT_REPO"], !configured.isEmpty {
            return URL(fileURLWithPath: configured).standardizedFileURL
        }
        if let bundled = bundledRuntimeRoot() {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    }

    private static func introspectHomeRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let configured = env["INTROSPECT_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured).standardizedFileURL
        }
        return URL(fileURLWithPath: "\(NSHomeDirectory())/.introspect").standardizedFileURL
    }

    private static func agentsHomeRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        return URL(fileURLWithPath: env["AGENTS_HOME"] ?? "\(NSHomeDirectory())/.agents").standardizedFileURL
    }

    private static func bundledRuntimeRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL?.standardizedFileURL else {
            return nil
        }
        let required = [
            "scripts/install-hooks.sh",
            "scripts/introspect-status.sh",
            "hooks/trigger-reflect.sh",
            "hooks/trigger-worker.py",
            "skills/index.json"
        ]
        let hasRuntime = required.allSatisfy {
            FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path)
        }
        return hasRuntime ? resources : nil
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
        let runUISmoke = CommandLine.arguments.contains("--ui-smoke")
        let app = NSApplication.shared
        let delegate = IntrospectApplication()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        delegate.startInterfaceIfNeeded()
        if runUISmoke {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let hasWindow = delegate.window != nil
                let isVisible = delegate.window?.isVisible == true
                let hasContent = delegate.window?.contentView != nil
                print("ui-smoke window=\(hasWindow) visible=\(isVisible) content=\(hasContent)")
                Darwin.exit(hasWindow && isVisible && hasContent ? 0 : 1)
            }
        }
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
            newWindow.backgroundColor = NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(introspectHex: isDark ? 0x262624 : 0xFAF9F5)
            }
            newWindow.contentView = hostingView
            newWindow.isReleasedWhenClosed = false
            newWindow.setFrameAutosaveName("IntrospectMainWindow")
            newWindow.center()
            window = newWindow
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
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
                Section {
                    Label("Overview", systemImage: "house")
                        .tag(IntrospectSection.status)
                }
                Section("Activity") {
                    Label("Signals", systemImage: "chart.bar")
                        .tag(IntrospectSection.signals)
                    Label("Runs", systemImage: "clock.arrow.circlepath")
                        .tag(IntrospectSection.runs)
                }
                Section("Sources") {
                    Label("Projects", systemImage: "folder")
                        .tag(IntrospectSection.projects)
                    Label("Introspect Home", systemImage: "shippingbox")
                        .tag(IntrospectSection.home)
                }
                Section("Setup") {
                    Label("Hooks", systemImage: "bolt")
                        .tag(IntrospectSection.hooks)
                    Label("Review Terms", systemImage: "text.badge.checkmark")
                        .tag(IntrospectSection.words)
                    Label("Notifications", systemImage: "bell")
                        .tag(IntrospectSection.notifications)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(IntrospectTheme.surfaceAlt)
            .navigationSplitViewColumnWidth(min: 204, ideal: 224, max: 248)
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
                            case .signals:
                                SignalsSection(model: model)
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
                            case .home:
                                IntrospectHomeSection(model: model)
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
            .background(IntrospectTheme.canvas)
            .foregroundStyle(IntrospectTheme.ink, IntrospectTheme.inkSecondary, IntrospectTheme.inkTertiary)
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

    private var previewEvents: [TriggerEventRecord] {
        Array(model.recentClassifierEvents.prefix(6))
    }

    private var trendYMax: Double {
        let maxScore = model.classifierScoreTrend.map(\.averageScore).max() ?? 0.3
        return max(0.2, (maxScore * 1.3 * 10).rounded(.up) / 10)
    }

    private var trendDayStride: Int {
        max(1, Int((Double(model.classifierScoreTrend.count) / 8).rounded(.up)))
    }

    var body: some View {
        PageHeader(
            title: "Overview",
            subtitle: "Wake signals from your Claude and Codex sessions feed a reflector that improves your agent instructions."
        )

        HealthBanner(model: model)

        Card("Configuration") {
            InfoRow(label: "Private home", value: model.introspectHomeDisplayPath)
            Divider()
            InfoRow(label: "Source prompt", value: model.sourcePromptDisplayPath)
            Divider()
            InfoRow(label: "Agents read", value: "~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, ~/.config/opencode/AGENTS.md")
        }

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            SignalMetricCard(title: "Prompt events", value: "\(model.signalPromptCount)", detail: "\(model.signalClassifierScoredCount) scored")
            SignalMetricCard(title: "Wake rate", value: model.signalTriggerRateText, detail: "\(model.signalTriggeredCount) woke")
            SignalMetricCard(title: "Review-only", value: model.signalReviewOnlyRateText, detail: "\(model.signalReviewOnlyCount) held for audit")
            SignalMetricCard(title: "Reflector runs", value: "\(model.triggerRuns.count)", detail: "\(model.signalChangedRunCount) changed")
            SignalMetricCard(title: "Avg score", value: model.signalAverageClassifierScoreText, detail: "classifier mean")
        }

        Card("Average wake score per day") {
            if model.classifierScoreTrend.count < 2 {
                Text("Not enough history yet — a daily trend appears after two days of scored prompts.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ScoreTrendBadge(delta: model.classifierScoreTrendDelta, days: model.classifierScoreTrend.count)

                    Chart(model.classifierScoreTrend) { point in
                        AreaMark(
                            x: .value("Day", point.day),
                            y: .value("Avg score", point.averageScore)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            .linearGradient(
                                colors: [IntrospectTheme.accent.opacity(0.22), IntrospectTheme.accent.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Avg score", point.averageScore)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(IntrospectTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))

                        PointMark(
                            x: .value("Day", point.day),
                            y: .value("Avg score", point.averageScore)
                        )
                        .foregroundStyle(IntrospectTheme.accent)
                        .symbolSize(34)
                    }
                    .chartYScale(domain: 0...trendYMax)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: trendDayStride)) { _ in
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel(format: FloatingPointFormatStyle<Double>().precision(.fractionLength(2)))
                                .font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .frame(height: 220)
                }
            }
        }

        Card("Recent activity") {
            if previewEvents.isEmpty {
                Text("No scored messages to show yet.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SignalEventHeader()
                    Divider().overlay(IntrospectTheme.border)
                    ForEach(previewEvents) { event in
                        SignalEventRow(event: event)
                        Divider().overlay(IntrospectTheme.border)
                    }
                    Button {
                        model.selectedSection = .signals
                    } label: {
                        HStack(spacing: 5) {
                            Text("See all decisions in Signals")
                            Image(systemName: "arrow.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(IntrospectTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)
                }
            }
        }

        Card("Agent prompt links") {
            HStack(spacing: 8) {
                CheckRow("Source prompt", detail: model.agentPromptStatus, ok: model.agentPromptOK)
            }
            Divider()
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
            Divider()
            HStack(spacing: 8) {
                CheckRow("OpenCode", detail: model.opencodePromptStatus, ok: model.opencodePromptOK)
                if model.opencodePromptOK {
                    Button("Unlink") {
                        Task { await model.unlinkOpenCodePrompt() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove the ~/.config/opencode/AGENTS.md symlink. Apply Configuration in Hooks recreates it.")
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
            LocationRow(label: "Introspect home", path: model.introspectHomeDisplayPath) {
                Task { await model.openIntrospectHomeFolder() }
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

struct ScoreTrendBadge: View {
    let delta: Double?
    let days: Int

    private var improving: Bool { (delta ?? 0) < -0.003 }
    private var worsening: Bool { (delta ?? 0) > 0.003 }

    private var color: Color {
        improving ? IntrospectTheme.success : (worsening ? IntrospectTheme.warning : IntrospectTheme.inkSecondary)
    }
    private var symbol: String {
        improving ? "arrow.down.right" : (worsening ? "arrow.up.right" : "arrow.right")
    }
    private var headline: String {
        improving ? "Trending down" : (worsening ? "Trending up" : "Holding steady")
    }
    private var detail: String {
        if improving { return "agent needs fewer corrections — instructions improving" }
        if worsening { return "more corrections lately — worth a look" }
        return "no clear change yet"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(headline)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if let delta {
                Text(String(format: "%+.3f over %d days", delta, days))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
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
        .background(IntrospectTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                .stroke(bannerColor.opacity(0.35))
        )
    }

    private var bannerColor: Color {
        if model.hasWarning { return IntrospectTheme.warning }
        if model.mode == .off { return IntrospectTheme.inkTertiary }
        return IntrospectTheme.success
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
            subtitle: "Choose when reflection runs after the classifier wakes Introspect, and which agent runs it."
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

        Card("Wake sensitivity") {
            Picker("Wake sensitivity", selection: wakeSensitivity) {
                ForEach(WakeSensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.wakeSensitivityDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.wakeSensitivity == .custom {
                Divider()
                HStack(spacing: 12) {
                    Stepper(value: $model.wakeCustomThreshold, in: 0.05...0.95, step: 0.01) {
                        Text("Threshold \(model.wakeCustomThresholdText)")
                            .font(.system(.body, design: .monospaced))
                    }

                    Button("Apply", systemImage: "checkmark.circle") {
                        Task { await model.saveWakeSensitivitySettings() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isApplyingConfiguration)
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
                Text("CLI model pins")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ReflectorModelField(
                    title: "Claude",
                    placeholder: "CLI default",
                    text: $model.reflectorClaudeModel
                )
                ReflectorModelField(
                    title: "Codex",
                    placeholder: "CLI default",
                    text: $model.reflectorCodexModel
                )

                HStack(spacing: 8) {
                    Button("Apply Pins", systemImage: "checkmark.circle") {
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

    private var wakeSensitivity: Binding<WakeSensitivity> {
        Binding {
            model.wakeSensitivity
        } set: { sensitivity in
            Task { await model.setWakeSensitivity(sensitivity) }
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
            title: "Review Terms",
            subtitle: "Optional exact terms for review metadata. Wake decisions come from the local intent classifier."
        )

        Card {
            HStack(spacing: 8) {
                TextField("Add a review term", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(addWord)
                Button("Add", action: addWord)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Text("\(model.activeTriggerWords.count) terms")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.activeTriggerWords.isEmpty {
                Text("No review terms. The classifier still controls wake decisions.")
                    .foregroundStyle(.secondary)
            } else {
                WordChipList(words: model.activeTriggerWords) { word in
                    model.removeTriggerWord(word)
                }
            }

            Divider()

            DisclosureGroup("Edit as text", isExpanded: $showBulkEditor) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One optional review term per line. Lowercase letters only; empty is the default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.triggerWordsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(IntrospectTheme.border)
                        )
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }

        HStack(spacing: 10) {
            Button {
                Task { await model.saveTriggerWords() }
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
                    .foregroundStyle(IntrospectTheme.accent)
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

struct SignalsSection: View {
    @ObservedObject var model: IntrospectModel

    private var recentVersions: [TriggerVersionAnalyticsRecord] {
        Array(model.versionStats.suffix(18))
    }

    private var topWords: [TriggerWordAnalyticsRecord] {
        Array(model.wordStats.prefix(12))
    }

    private var topReasons: [TriggerReasonAnalyticsRecord] {
        Array(model.reasonStats.prefix(10))
    }

    private var topClassifierEvidence: [ClassifierEvidenceAnalyticsRecord] {
        let words = model.classifierEvidenceStats.filter { $0.kind == "word" }
        return Array((words.isEmpty ? model.classifierEvidenceStats : words).prefix(12))
    }

    private var metricModelChecks: [ClassifierModelCheckRecord] {
        model.classifierModelChecks.filter { $0.precision != nil && $0.recall != nil }
    }

    private var shadowStats: [ClassifierShadowStatRecord] {
        Array(model.classifierShadowStats.prefix(8))
    }

    var body: some View {
        PageHeader(
            title: "Signals",
            subtitle: "Classifier wake scores, evidence tokens, message-level decisions, run outcomes, version rates, and optional review-term metadata."
        )

        Card("Classifier score distribution") {
            if model.classifierScoreBands.allSatisfy({ $0.promptCount == 0 }) {
                Text("No classifier-scored events have been recorded.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(model.classifierScoreBands) { band in
                    BarMark(
                        x: .value("Score band", band.label),
                        y: .value("Events", band.loggedOnlyCount)
                    )
                    .foregroundStyle(by: .value("Decision", "Logged"))

                    BarMark(
                        x: .value("Score band", band.label),
                        y: .value("Events", band.reviewOnlyCount)
                    )
                    .foregroundStyle(by: .value("Decision", "Review-only"))

                    BarMark(
                        x: .value("Score band", band.label),
                        y: .value("Events", band.wakeCount)
                    )
                    .foregroundStyle(by: .value("Decision", "Woke"))
                }
                .chartForegroundStyleScale([
                    "Logged": IntrospectTheme.inkTertiary,
                    "Review-only": IntrospectTheme.warning,
                    "Woke": IntrospectTheme.danger
                ])
                .chartXAxis {
                    AxisMarks(position: .bottom) {
                        AxisGridLine().foregroundStyle(IntrospectTheme.border)
                        AxisValueLabel()
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(IntrospectTheme.inkTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(IntrospectTheme.border)
                        AxisValueLabel().font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                    }
                }
                .frame(height: 220)
            }
        }

        Card("Candidate impact") {
            if shadowStats.isEmpty {
                Text("No shadow-scored candidate models have been recorded.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Chart(shadowStats) { stat in
                        BarMark(
                            x: .value("Model", stat.name),
                            y: .value("Messages", stat.addedWakeCount)
                        )
                        .foregroundStyle(by: .value("Impact", "Added wakes"))

                        BarMark(
                            x: .value("Model", stat.name),
                            y: .value("Messages", stat.removedWakeCount)
                        )
                        .foregroundStyle(by: .value("Impact", "Removed wakes"))
                    }
                    .chartForegroundStyleScale([
                        "Added wakes": IntrospectTheme.warning,
                        "Removed wakes": IntrospectTheme.accent
                    ])
                    .chartXAxis {
                        AxisMarks(position: .bottom) {
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel().font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .frame(height: 180)

                    Divider().overlay(IntrospectTheme.border)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        CandidateImpactHeader()
                        Divider().overlay(IntrospectTheme.border)
                        ForEach(shadowStats) { stat in
                            CandidateImpactRow(stat: stat)
                            Divider().overlay(IntrospectTheme.border)
                        }
                    }
                }
            }
        }

        Card("Classifier causes") {
            if topReasons.isEmpty {
                Text("No classifier reasons have been recorded.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Chart(topReasons) { stat in
                        BarMark(
                            x: .value("Events", stat.loggedOnlyCount),
                            y: .value("Cause", stat.reason),
                            height: .fixed(16)
                        )
                        .foregroundStyle(by: .value("Decision", "Logged"))

                        BarMark(
                            x: .value("Events", stat.reviewOnlyCount),
                            y: .value("Cause", stat.reason),
                            height: .fixed(16)
                        )
                        .foregroundStyle(by: .value("Decision", "Review-only"))

                        BarMark(
                            x: .value("Events", stat.wakeCount),
                            y: .value("Cause", stat.reason),
                            height: .fixed(16)
                        )
                        .foregroundStyle(by: .value("Decision", "Woke"))
                    }
                    .chartForegroundStyleScale([
                        "Logged": IntrospectTheme.inkTertiary,
                        "Review-only": IntrospectTheme.warning,
                        "Woke": IntrospectTheme.danger
                    ])
                    .chartXAxis {
                        AxisMarks(position: .bottom) {
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel().font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisValueLabel()
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(IntrospectTheme.inkSecondary)
                        }
                    }
                    .frame(height: CGFloat(topReasons.count * 32 + 28))

                    Divider().overlay(IntrospectTheme.border)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        SignalReasonHeader()
                        Divider().overlay(IntrospectTheme.border)
                        ForEach(topReasons) { stat in
                            SignalReasonRow(stat: stat)
                            Divider().overlay(IntrospectTheme.border)
                        }
                    }
                }
            }
        }

        Card("Classifier evidence frequency") {
            if topClassifierEvidence.isEmpty {
                Text("No classifier feature evidence has been recorded.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Chart(topClassifierEvidence) { stat in
                        BarMark(
                            x: .value("Events", stat.loggedOnlyCount),
                            y: .value("Evidence", stat.feature),
                            height: .fixed(16)
                        )
                        .foregroundStyle(by: .value("Decision", "Logged"))

                        BarMark(
                            x: .value("Events", stat.reviewOnlyCount),
                            y: .value("Evidence", stat.feature),
                            height: .fixed(16)
                        )
                        .foregroundStyle(by: .value("Decision", "Review-only"))

                        BarMark(
                            x: .value("Events", stat.wakeCount),
                            y: .value("Evidence", stat.feature),
                            height: .fixed(16)
                        )
                        .foregroundStyle(by: .value("Decision", "Woke"))
                    }
                    .chartForegroundStyleScale([
                        "Logged": IntrospectTheme.inkTertiary,
                        "Review-only": IntrospectTheme.warning,
                        "Woke": IntrospectTheme.danger
                    ])
                    .chartXAxis {
                        AxisMarks(position: .bottom) {
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel().font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisValueLabel()
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(IntrospectTheme.inkSecondary)
                        }
                    }
                    .frame(height: CGFloat(topClassifierEvidence.count * 32 + 28))

                    Divider().overlay(IntrospectTheme.border)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ClassifierEvidenceAnalyticsHeader()
                        Divider().overlay(IntrospectTheme.border)
                        ForEach(topClassifierEvidence) { stat in
                            ClassifierEvidenceAnalyticsRow(stat: stat)
                            Divider().overlay(IntrospectTheme.border)
                        }
                    }
                }
            }
        }

        Card("Recent classifier decisions") {
            if model.recentClassifierEvents.isEmpty {
                Text("No scored messages to show yet.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SignalEventHeader()
                    Divider().overlay(IntrospectTheme.border)
                    ForEach(model.recentClassifierEvents) { event in
                        SignalEventRow(event: event)
                        Divider().overlay(IntrospectTheme.border)
                    }
                }
            }
        }

        Card("Model quality checks") {
            if model.classifierModelChecks.isEmpty {
                Text("No model quality checks have been generated.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if !metricModelChecks.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Chart(metricModelChecks) { check in
                                BarMark(
                                    x: .value("Check", check.shortName),
                                    y: .value("Score", check.precision ?? 0)
                                )
                                .foregroundStyle(by: .value("Metric", "Precision"))

                                BarMark(
                                    x: .value("Check", check.shortName),
                                    y: .value("Score", check.recall ?? 0)
                                )
                                .foregroundStyle(by: .value("Metric", "Recall"))
                            }
                            .chartForegroundStyleScale([
                                "Precision": IntrospectTheme.success,
                                "Recall": IntrospectTheme.accent
                            ])
                            .chartYScale(domain: 0...1)
                            .chartXAxis {
                                AxisMarks(position: .bottom) {
                                    AxisValueLabel()
                                        .font(.caption2)
                                        .foregroundStyle(IntrospectTheme.inkTertiary)
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) {
                                    AxisGridLine().foregroundStyle(IntrospectTheme.border)
                                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0)))
                                        .font(.caption2)
                                        .foregroundStyle(IntrospectTheme.inkTertiary)
                                }
                            }
                            .frame(width: max(CGFloat(metricModelChecks.count) * 82, 680), height: 220)
                        }
                    }

                    Divider().overlay(IntrospectTheme.border)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.classifierModelChecks) { check in
                            ClassifierModelCheckRow(check: check)
                            Divider().overlay(IntrospectTheme.border)
                        }
                    }
                }
            }
        }

        Card("Optional review-term frequency") {
            if topWords.isEmpty {
                Text("No optional review terms have matched recorded events.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(topWords) { stat in
                    BarMark(
                        x: .value("Events", stat.eventCount),
                        y: .value("Word", stat.word),
                        height: .fixed(16)
                    )
                    .foregroundStyle(IntrospectTheme.accent.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("\(stat.eventCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(IntrospectTheme.inkTertiary)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) {
                        AxisGridLine().foregroundStyle(IntrospectTheme.border)
                        AxisValueLabel().font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisValueLabel()
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(IntrospectTheme.inkSecondary)
                    }
                }
                .chartPlotStyle { plot in
                    plot.padding(.trailing, 26)
                }
                .frame(height: CGFloat(topWords.count * 30 + 28))
            }
        }

        Card("Version trigger rate") {
            if recentVersions.isEmpty {
                Text("No prompt versions have been recorded.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Chart(recentVersions) { version in
                        AreaMark(
                            x: .value("Version", version.shortVersion),
                            y: .value("Wake rate", version.triggerRate)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            .linearGradient(
                                colors: [IntrospectTheme.accent.opacity(0.22), IntrospectTheme.accent.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Version", version.shortVersion),
                            y: .value("Wake rate", version.triggerRate)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(IntrospectTheme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))

                        PointMark(
                            x: .value("Version", version.shortVersion),
                            y: .value("Wake rate", version.triggerRate)
                        )
                        .foregroundStyle(IntrospectTheme.accent)
                        .symbolSize(26)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0)))
                                .font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .frame(height: 180)

                    Chart(recentVersions) { version in
                        BarMark(
                            x: .value("Version", version.shortVersion),
                            y: .value("Runs", version.runCount)
                        )
                        .foregroundStyle(by: .value("Run outcome", "All runs"))

                        BarMark(
                            x: .value("Version", version.shortVersion),
                            y: .value("Runs", version.changedRunCount)
                        )
                        .foregroundStyle(by: .value("Run outcome", "Changed"))
                    }
                    .chartForegroundStyleScale([
                        "All runs": IntrospectTheme.inkTertiary.opacity(0.55),
                        "Changed": IntrospectTheme.warning
                    ])
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(IntrospectTheme.border)
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(IntrospectTheme.inkTertiary)
                        }
                    }
                    .frame(height: 150)

                    Divider().overlay(IntrospectTheme.border)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        VersionSignalHeader()
                        Divider().overlay(IntrospectTheme.border)
                        ForEach(recentVersions.reversed()) { version in
                            VersionSignalRow(version: version)
                            Divider().overlay(IntrospectTheme.border)
                        }
                    }
                }
            }
        }

        Card("Intent classifier audit") {
            if model.classifierThresholdStats.isEmpty && model.classifierPromptVariantStats.isEmpty {
                Text("No classifier audit report has been generated.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if let threshold = model.classifierThresholdStats.first(where: { abs($0.threshold - 0.675) < 0.001 })
                        ?? model.classifierThresholdStats.last {
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            ClassifierAuditMetric(title: "Status", value: "High precision", detail: "foreground wake path")
                            ClassifierAuditMetric(title: "Precision", value: threshold.precisionText, detail: "audit at \(threshold.thresholdText)")
                            ClassifierAuditMetric(title: "Recall", value: threshold.recallText, detail: "audit at \(threshold.thresholdText)")
                            ClassifierAuditMetric(title: "Wake rate", value: threshold.wakeRateText, detail: "audit at \(threshold.thresholdText)")
                        }
                    }

                    if !model.classifierThresholdStats.isEmpty {
                        Chart {
                            ForEach(model.classifierThresholdStats) { stat in
                                LineMark(
                                    x: .value("Threshold", stat.threshold),
                                    y: .value("Score", stat.precision)
                                )
                                .foregroundStyle(by: .value("Metric", "Precision"))
                                .symbol(by: .value("Metric", "Precision"))

                                LineMark(
                                    x: .value("Threshold", stat.threshold),
                                    y: .value("Score", stat.recall)
                                )
                                .foregroundStyle(by: .value("Metric", "Recall"))
                                .symbol(by: .value("Metric", "Recall"))
                            }
                        }
                        .chartYScale(domain: 0...1)
                        .chartXAxis {
                            AxisMarks(position: .bottom) {
                                AxisGridLine().foregroundStyle(IntrospectTheme.border)
                                AxisValueLabel().font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) {
                                AxisGridLine().foregroundStyle(IntrospectTheme.border)
                                AxisValueLabel(format: FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0)))
                                    .font(.caption2).foregroundStyle(IntrospectTheme.inkTertiary)
                            }
                        }
                        .frame(height: 220)
                    }

                    if !model.classifierPromptVariantStats.isEmpty {
                        Divider().overlay(IntrospectTheme.border)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ClassifierVariantHeader()
                            Divider().overlay(IntrospectTheme.border)
                            ForEach(model.classifierPromptVariantStats) { variant in
                                ClassifierVariantRow(variant: variant)
                                Divider().overlay(IntrospectTheme.border)
                            }
                        }
                    }
                }
            }
        }

        Card("Optional review terms and outcomes") {
            if model.wordStats.isEmpty {
                Text("No review terms to show yet. Classifier score still controls wake decisions.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SignalWordHeader()
                    Divider()
                    ForEach(model.wordStats) { stat in
                        SignalWordRow(stat: stat)
                        Divider()
                    }
                }
            }
        }
    }
}

struct ClassifierAuditMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IntrospectTheme.inkTertiary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption)
                .foregroundStyle(IntrospectTheme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClassifierVariantHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Variant")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Precision")
                .frame(width: 72, alignment: .trailing)
            Text("Recall")
                .frame(width: 60, alignment: .trailing)
            Text("Wake")
                .frame(width: 58, alignment: .trailing)
            Text("FP/FN")
                .frame(width: 76, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(IntrospectTheme.inkTertiary)
        .padding(.vertical, 6)
    }
}

struct ClassifierVariantRow: View {
    let variant: ClassifierPromptVariantRecord

    var body: some View {
        HStack(spacing: 12) {
            Text(variant.displayName)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(variant.precisionText)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
            Text(variant.recallText)
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Text(variant.wakeRateText)
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
            Text("\(variant.falsePositiveCount)/\(variant.falseNegativeCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(IntrospectTheme.inkSecondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

struct ClassifierModelCheckRow: View {
    let check: ClassifierModelCheckRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(state: check.state)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(check.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(check.status)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(check.state.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(check.state.color.opacity(0.10))
                        .clipShape(Capsule())
                }
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(IntrospectTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text(check.outcomeText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(check.thresholdSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(IntrospectTheme.inkTertiary)
            }
            .frame(width: 126, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 4) {
                Text(check.countSummary)
                    .font(.caption.monospacedDigit())
                Text(check.sampleSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(IntrospectTheme.inkTertiary)
            }
            .frame(width: 116, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

struct CandidateImpactHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Candidate")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Would wake")
                .frame(width: 82, alignment: .trailing)
            Text("Added")
                .frame(width: 56, alignment: .trailing)
            Text("Removed")
                .frame(width: 66, alignment: .trailing)
            Text("Avg score")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(IntrospectTheme.inkTertiary)
        .padding(.vertical, 6)
    }
}

struct CandidateImpactRow: View {
    let stat: ClassifierShadowStatRecord

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(stat.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stat.sampleSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(IntrospectTheme.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(stat.candidateWakeText)
                .font(.caption.monospacedDigit())
                .frame(width: 82, alignment: .trailing)
            Text("\(stat.addedWakeCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(stat.addedWakeCount > 0 ? IntrospectTheme.warning : IntrospectTheme.inkSecondary)
                .frame(width: 56, alignment: .trailing)
            Text("\(stat.removedWakeCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(stat.removedWakeCount > 0 ? IntrospectTheme.accent : IntrospectTheme.inkSecondary)
                .frame(width: 66, alignment: .trailing)
            Text(stat.averageScoreText)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

struct SignalEventHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Decision")
                .frame(width: 94, alignment: .leading)
            Text("Score")
                .frame(width: 54, alignment: .trailing)
            Text("Gate")
                .frame(width: 76, alignment: .leading)
            Text("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(IntrospectTheme.inkTertiary)
        .padding(.vertical, 6)
    }
}

struct SignalEventRow: View {
    let event: TriggerEventRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.decisionLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(event.decisionColor)
                .frame(width: 94, alignment: .leading)
            Text(event.classifierScoreText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 54, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.classifierThresholdText)
                Text(event.classifierReviewThresholdText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 76, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(event.sourceLabel, systemImage: event.sourceSystemImage)
                    Text(event.timestampText)
                    Text(event.wakeReasonLabel)
                    if !event.matched.isEmpty {
                        Text(event.matched.joined(separator: ", "))
                            .foregroundStyle(IntrospectTheme.ink)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text(event.snippet.isEmpty ? "No snippet recorded." : event.snippet)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ClassifierEvidenceRow(explanations: event.classifierExplanations)
                ClassifierShadowPills(alternates: event.classifierAlternates)

                if !event.messageLocator.isEmpty || !event.eventID.isEmpty {
                    Text(event.messageLocator.isEmpty ? event.eventID : event.messageLocator)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

struct ClassifierEvidenceRow: View {
    let explanations: [ClassifierExplanationRecord]

    var body: some View {
        if !explanations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(explanations.prefix(6)) { explanation in
                        ClassifierEvidencePill(explanation: explanation)
                    }
                }
                .padding(.bottom, 1)
            }
            .accessibilityLabel("Classifier evidence: \(explanations.prefix(6).map(\.feature).joined(separator: ", "))")
        }
    }
}

struct ClassifierShadowPills: View {
    let alternates: [ClassifierAlternateRecord]

    var body: some View {
        if !alternates.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(alternates.prefix(6)) { alternate in
                        HStack(spacing: 5) {
                            Text(alternate.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(alternate.scoreText)
                            Text(alternate.decisionText)
                                .foregroundStyle(alternate.decisionColor)
                        }
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(IntrospectTheme.inkTertiary.opacity(0.10))
                        .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 1)
            }
            .accessibilityLabel("Shadow model scores: \(alternates.prefix(6).map { "\($0.name) \($0.scoreText)" }.joined(separator: ", "))")
        }
    }
}

struct ClassifierEvidencePill: View {
    let explanation: ClassifierExplanationRecord

    var body: some View {
        HStack(spacing: 4) {
            Text(explanation.feature)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(explanation.kindLabel)
                .foregroundStyle(IntrospectTheme.inkTertiary)
            Text(explanation.contributionText)
                .foregroundStyle(IntrospectTheme.inkTertiary)
        }
        .font(.caption2.monospaced())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(IntrospectTheme.accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(IntrospectTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ClassifierEvidenceSummaryPill: View {
    let stat: ClassifierEvidenceAnalyticsRecord

    var body: some View {
        HStack(spacing: 5) {
            Text(stat.feature)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(stat.kindLabel)
                .foregroundStyle(IntrospectTheme.inkTertiary)
            Text("\(stat.eventCount)x")
                .foregroundStyle(IntrospectTheme.inkTertiary)
            if stat.wakeCount > 0 {
                Text("\(stat.wakeCount) woke")
                    .foregroundStyle(IntrospectTheme.danger)
            }
            Text(stat.averageContributionText)
                .foregroundStyle(IntrospectTheme.inkTertiary)
        }
        .font(.caption2.monospaced())
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(IntrospectTheme.accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(IntrospectTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SignalReasonHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Cause")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Events")
                .frame(width: 58, alignment: .trailing)
            Text("Woke")
                .frame(width: 54, alignment: .trailing)
            Text("Review")
                .frame(width: 58, alignment: .trailing)
            Text("Changed")
                .frame(width: 70, alignment: .trailing)
            Text("Last seen")
                .frame(width: 100, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(IntrospectTheme.inkTertiary)
        .padding(.vertical, 6)
    }
}

struct SignalReasonRow: View {
    let stat: TriggerReasonAnalyticsRecord

    var body: some View {
        HStack(spacing: 12) {
            Text(stat.reason)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(stat.eventCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
            Text("\(stat.wakeCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(stat.wakeCount > 0 ? IntrospectTheme.danger : IntrospectTheme.inkSecondary)
                .frame(width: 54, alignment: .trailing)
            Text("\(stat.reviewOnlyCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(stat.reviewOnlyCount > 0 ? IntrospectTheme.warning : IntrospectTheme.inkSecondary)
                .frame(width: 58, alignment: .trailing)
            Text("\(stat.changedRunCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Text(stat.lastSeenText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

struct ClassifierEvidenceAnalyticsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Evidence")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Type")
                .frame(width: 46, alignment: .leading)
            Text("Events")
                .frame(width: 58, alignment: .trailing)
            Text("Woke")
                .frame(width: 54, alignment: .trailing)
            Text("Review")
                .frame(width: 58, alignment: .trailing)
            Text("Changed")
                .frame(width: 70, alignment: .trailing)
            Text("Avg")
                .frame(width: 58, alignment: .trailing)
            Text("Last seen")
                .frame(width: 100, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(IntrospectTheme.inkTertiary)
        .padding(.vertical, 6)
    }
}

struct ClassifierEvidenceAnalyticsRow: View {
    let stat: ClassifierEvidenceAnalyticsRecord

    var body: some View {
        HStack(spacing: 12) {
            Text(stat.feature)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(stat.kindLabel)
                .font(.caption)
                .foregroundStyle(IntrospectTheme.inkTertiary)
                .frame(width: 46, alignment: .leading)
            Text("\(stat.eventCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
            Text("\(stat.wakeCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(stat.wakeCount > 0 ? IntrospectTheme.danger : IntrospectTheme.inkSecondary)
                .frame(width: 54, alignment: .trailing)
            Text("\(stat.reviewOnlyCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(stat.reviewOnlyCount > 0 ? IntrospectTheme.warning : IntrospectTheme.inkSecondary)
                .frame(width: 58, alignment: .trailing)
            Text("\(stat.changedRunCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Text(stat.averageContributionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(IntrospectTheme.inkSecondary)
                .frame(width: 58, alignment: .trailing)
            Text(stat.lastSeenText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

struct SignalMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IntrospectTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(IntrospectTheme.border)
        )
    }
}

struct SignalWordHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Review term")
                .frame(minWidth: 120, alignment: .leading)
            Text("Events")
                .frame(width: 58, alignment: .trailing)
            Text("Runs")
                .frame(width: 50, alignment: .trailing)
            Text("Changed")
                .frame(width: 70, alignment: .trailing)
            Text("Tone")
                .frame(width: 86, alignment: .leading)
            Text("Last seen")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }
}

struct SignalWordRow: View {
    let stat: TriggerWordAnalyticsRecord

    var body: some View {
        HStack(spacing: 12) {
            TriggerWordPill(word: stat.word)
                .frame(minWidth: 120, alignment: .leading)
            Text("\(stat.eventCount)")
                .font(.callout.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
            Text("\(stat.runCount)")
                .font(.callout.monospacedDigit())
                .frame(width: 50, alignment: .trailing)
            Text("\(stat.changedRunCount)")
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            SentimentBadge(score: stat.averageSentiment)
                .frame(width: 86, alignment: .leading)
            Text(stat.lastSeenText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

struct VersionSignalHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Version")
                .frame(width: 64, alignment: .leading)
            Text("Prompts")
                .frame(width: 64, alignment: .trailing)
            Text("Woke")
                .frame(width: 58, alignment: .trailing)
            Text("Review")
                .frame(width: 58, alignment: .trailing)
            Text("Runs")
                .frame(width: 54, alignment: .trailing)
            Text("Changed")
                .frame(width: 70, alignment: .trailing)
            Text("Rate")
                .frame(width: 58, alignment: .trailing)
            Text("Delta")
                .frame(width: 64, alignment: .trailing)
            Text("Commit subject")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(IntrospectTheme.inkTertiary)
        .padding(.vertical, 6)
    }
}

struct VersionSignalRow: View {
    let version: TriggerVersionAnalyticsRecord

    var body: some View {
        HStack(spacing: 10) {
            Text(version.shortVersion)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .frame(width: 64, alignment: .leading)
            Text("\(version.promptCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Text("\(version.triggerCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(version.triggerCount > 0 ? IntrospectTheme.danger : IntrospectTheme.inkSecondary)
                .frame(width: 58, alignment: .trailing)
            Text("\(version.reviewOnlyCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(version.reviewOnlyCount > 0 ? IntrospectTheme.warning : IntrospectTheme.inkSecondary)
                .frame(width: 58, alignment: .trailing)
            Text("\(version.runCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 54, alignment: .trailing)
            Text("\(version.changedRunCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(version.changedRunCount > 0 ? IntrospectTheme.warning : IntrospectTheme.inkSecondary)
                .frame(width: 70, alignment: .trailing)
            Text(version.triggerRateText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 58, alignment: .trailing)
            Text(version.deltaText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(version.deltaColor)
                .frame(width: 64, alignment: .trailing)
            Text(version.subject.trimmedOr(version.lastSeenText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 7)
    }
}

struct SentimentBadge: View {
    let score: Double?

    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var label: String {
        guard let score else { return "none" }
        return String(format: "%+.2f", score)
    }

    private var color: Color {
        guard let score else { return IntrospectTheme.inkTertiary }
        if score < -0.25 { return IntrospectTheme.warning }
        if score > 0.25 { return IntrospectTheme.success }
        return IntrospectTheme.inkSecondary
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
            .background(IntrospectTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                    .stroke(IntrospectTheme.border)
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
        .background(IntrospectTheme.canvas)
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
                    .accessibilityLabel("Review terms: \(run.triggerWordsText)")
                }

                HStack(spacing: 6) {
                    if let runner = run.effectiveRunner {
                        Label(runner, systemImage: "terminal")
                    }
                    if run.highestClassifierScore != nil {
                        Label(run.highestClassifierScoreText, systemImage: "gauge")
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
                        RunCountDeltaBlock(run: run)
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
        .background(IntrospectTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(IntrospectTheme.border)
        )
    }
}

struct RunCountDeltaBlock: View {
    let run: TriggerRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Counts moved", systemImage: "chart.bar.xaxis")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                RunCountMetric(title: "Messages", value: "\(run.eventCount)", detail: "\(run.wakeEventCount) woke")
                RunCountMetric(title: "Review", value: "\(run.reviewOnlyEventCount)", detail: "held below wake")
                RunCountMetric(title: "Files", value: "\(run.surfaceDiffs.count)", detail: "agent surfaces")
                RunCountMetric(title: "Line delta", value: run.lineDeltaText, detail: "captured diff")
                RunCountMetric(title: "Sessions", value: "\(run.sessionIDs.count)", detail: "source threads")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IntrospectTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(IntrospectTheme.border)
        )
    }
}

struct RunCountMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IntrospectTheme.inkTertiary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 7))
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
        .background(IntrospectTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(IntrospectTheme.border)
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

    private var topClassifierEvidence: [ClassifierEvidenceAnalyticsRecord] {
        struct Counts {
            let feature: String
            let kind: String
            var eventCount = 0
            var wakeCount = 0
            var reviewOnlyCount = 0
            var contributionSum = 0.0
            var lastSeenValue = ""
            var lastSeenText = ""
        }

        var countsByKey: [String: Counts] = [:]
        for event in run.events {
            var eventEvidence: [String: ClassifierExplanationRecord] = [:]
            for explanation in event.classifierExplanations {
                let key = "\(explanation.kind)\u{1f}\(explanation.feature)"
                if let current = eventEvidence[key], current.contribution >= explanation.contribution {
                    continue
                }
                eventEvidence[key] = explanation
            }

            for (key, explanation) in eventEvidence {
                var counts = countsByKey[key] ?? Counts(feature: explanation.feature, kind: explanation.kind)
                counts.eventCount += 1
                counts.contributionSum += explanation.contribution
                if event.triggered {
                    counts.wakeCount += 1
                } else if event.reviewTriggered {
                    counts.reviewOnlyCount += 1
                }
                if counts.lastSeenValue.isEmpty || event.timestampValue > counts.lastSeenValue {
                    counts.lastSeenValue = event.timestampValue
                    counts.lastSeenText = event.timestampText
                }
                countsByKey[key] = counts
            }
        }

        let records = countsByKey.map { _, counts in
            ClassifierEvidenceAnalyticsRecord(
                feature: counts.feature,
                kind: counts.kind,
                eventCount: counts.eventCount,
                wakeCount: counts.wakeCount,
                reviewOnlyCount: counts.reviewOnlyCount,
                loggedOnlyCount: max(counts.eventCount - counts.wakeCount - counts.reviewOnlyCount, 0),
                changedRunCount: 0,
                averageContribution: counts.eventCount > 0 ? counts.contributionSum / Double(counts.eventCount) : 0,
                lastSeenValue: counts.lastSeenValue,
                lastSeenText: counts.lastSeenText
            )
        }
        .sorted {
            if $0.wakeCount != $1.wakeCount {
                return $0.wakeCount > $1.wakeCount
            }
            if $0.eventCount != $1.eventCount {
                return $0.eventCount > $1.eventCount
            }
            return $0.averageContribution > $1.averageContribution
        }

        let words = records.filter { $0.kind == "word" }
        return Array((words.isEmpty ? records : words).prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label("Classifier decision", systemImage: "gauge")
                    .font(.headline)
                Spacer()
                if run.highestClassifierScore != nil {
                    ScopePill(text: run.highestClassifierScoreText)
                }
                if run.wakeEventCount > 0 {
                    ScopePill(text: "\(run.wakeEventCount) woke")
                }
                if run.reviewOnlyEventCount > 0 {
                    ScopePill(text: "\(run.reviewOnlyEventCount) review-only")
                }
            }

            if run.matched.isEmpty {
                Text("No optional review terms matched. The run was decided by classifier score.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Optional review terms")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IntrospectTheme.inkTertiary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(run.matched, id: \.self) { word in
                                TriggerWordPill(word: word)
                            }
                        }
                        .padding(.bottom, 1)
                    }
                    .accessibilityLabel("Review terms: \(run.triggerWordsText)")
                }
            }

            if !topClassifierEvidence.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Classifier evidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IntrospectTheme.inkTertiary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(topClassifierEvidence) { stat in
                                ClassifierEvidenceSummaryPill(stat: stat)
                            }
                        }
                        .padding(.bottom, 1)
                    }
                    .accessibilityLabel("Classifier evidence: \(topClassifierEvidence.map(\.feature).joined(separator: ", "))")
                }
            }

            if !run.events.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(run.events.prefix(5)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(event.decisionLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(event.decisionColor)
                                Label(event.sourceLabel, systemImage: event.sourceSystemImage)
                                Text(event.timestampText)
                                Text(event.version)
                                    .font(.system(.caption, design: .monospaced))
                                Text(event.classifierScoreText)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(IntrospectTheme.ink)
                                Text(event.classifierThresholdText)
                                    .font(.caption.monospacedDigit())
                                Text(event.classifierReviewThresholdText)
                                    .font(.caption.monospacedDigit())
                                Text(event.wakeReasonLabel)
                                    .font(.caption)
                                if !event.matched.isEmpty {
                                    Text(event.matched.joined(separator: ", "))
                                        .foregroundStyle(.primary)
                                }
                                SentimentBadge(score: event.sentimentScore)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                            Text(event.snippet.isEmpty ? "No snippet recorded." : event.snippet)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            ClassifierEvidenceRow(explanations: event.classifierExplanations)
                            if !event.messageLocator.isEmpty || !event.eventID.isEmpty {
                                Text(event.messageLocator.isEmpty ? event.eventID : event.messageLocator)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IntrospectTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(IntrospectTheme.border)
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
                            if run.highestClassifierScore != nil {
                                ScopePill(text: run.highestClassifierScoreText)
                            }
                            if run.reviewOnlyEventCount > 0 {
                                ScopePill(text: "\(run.reviewOnlyEventCount) review-only")
                            }
                            ScopePill(text: "\(run.surfaceDiffs.count) files")
                            ScopePill(text: run.lineDeltaText)
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
        .background(IntrospectTheme.canvas)
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
            .background(IntrospectTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(IntrospectTheme.border)
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
            .background(IntrospectTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                    .stroke(IntrospectTheme.border)
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
        .background(IntrospectTheme.canvas)
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
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : IntrospectTheme.inkTertiary)
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
        .background(IntrospectTheme.canvas)
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
                .background(IntrospectTheme.surface)

            Divider()

            HStack(spacing: 10) {
                if isDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(IntrospectTheme.accent)
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
            .background(IntrospectTheme.canvas)
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
            .background(IntrospectTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(IntrospectTheme.border)
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

struct IntrospectHomeSection: View {
    @ObservedObject var model: IntrospectModel

    var body: some View {
        PageHeader(
            title: "Introspect Home",
            subtitle: "A private git repo for your prompt variants, personal skills, review terms, and reflector logs. It stays on this machine and out of the open-source app repo."
        )

        Card("State") {
            CheckRow("Git repo", detail: model.homeGitStatus, ok: model.homeGitOK)
            Divider()
            CheckRow(
                "Review terms",
                detail: model.triggerWordsStatus,
                state: model.triggerWordsOK ? .ok : .off
            )
            Divider()
            InfoRow(label: "Last commit", value: model.homeLastCommit)
            Divider()
            InfoRow(label: "Working tree", value: model.homeWorkingTreeStatus)
        }

        HStack(spacing: 10) {
            if model.homeGitOK {
                Button {
                    Task { await model.commitHomeChanges() }
                } label: {
                    Label("Commit Changes", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                Task { await model.openIntrospectHomeFolder() }
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
        }

        Card("Version history") {
            if model.homeCommits.isEmpty {
                Text("No Introspect Home commits yet.")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.homeCommits) { commit in
                                HomeCommitRow(
                                    commit: commit,
                                    isSelected: commit.id == model.selectedHomeCommitID
                                ) {
                                    Task { await model.selectHomeCommit(commit) }
                                }
                            }
                        }
                        .padding(.trailing, 12)
                    }
                    .frame(width: 260)
                    .frame(minHeight: 360, maxHeight: 520)

                    Divider()

                    ScrollView([.vertical, .horizontal]) {
                        Text(model.selectedHomeCommitDiff.trimmedOr("No diff loaded."))
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(.leading, 14)
                    }
                    .frame(minHeight: 360, maxHeight: 520)
                }
            }
        }
    }
}

struct HomeCommitRow: View {
    let commit: HomeCommitRecord
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(commit.shortHash)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    Spacer(minLength: 8)
                    Text(commit.timestampText)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
                Text(commit.subject)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? IntrospectTheme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
            .background(IntrospectTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(IntrospectTheme.border)
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IntrospectTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: IntrospectTheme.cardCorner)
                .stroke(IntrospectTheme.border)
        )
    }
}

enum IntrospectSection: Hashable {
    case status
    case signals
    case hooks
    case notifications
    case runs
    case projects
    case words
    case home
}

enum ReflectionMode: String, CaseIterable, Identifiable {
    case immediate
    case nightly
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediate: "Right After Wake"
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
            "Wake prompts enqueue and kick one locked worker immediately. Debounce and cooldown still batch bursts."
        case .nightly:
            "Wake prompts enqueue only; a LaunchAgent reviews the batch at the selected time."
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
            "Runs through the installed agent with the most recent local activity. Blank model fields keep each CLI default."
        case .claude:
            "Runs every reflector through Claude. Leave the model field empty to use Claude's CLI default."
        case .codex:
            "Runs every reflector through Codex. Leave the model field empty to use Codex's CLI default."
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

enum WakeSensitivity: String, CaseIterable, Identifiable {
    case quiet
    case balanced
    case sensitive
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .sensitive: "Sensitive"
        case .custom: "Custom"
        }
    }

    var helpText: String {
        switch self {
        case .quiet:
            "Only high-confidence negative feedback wakes Introspect."
        case .balanced:
            "Uses the classifier's production threshold."
        case .sensitive:
            "Wakes on earlier frustration signals and accepts more false positives."
        case .custom:
            "Uses the exact threshold below."
        }
    }

    var fixedThreshold: Double? {
        switch self {
        case .quiet:
            0.80
        case .sensitive:
            0.50
        case .balanced, .custom:
            nil
        }
    }

    func thresholdSummary(customThreshold: Double) -> String {
        switch self {
        case .balanced:
            "threshold: model default"
        case .custom:
            String(format: "threshold: %.2f", customThreshold)
        case .quiet, .sensitive:
            String(format: "threshold: %.2f", fixedThreshold ?? customThreshold)
        }
    }

    static func parse(_ value: String?) -> WakeSensitivity {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "quiet":
            .quiet
        case "sensitive":
            .sensitive
        case "custom":
            .custom
        default:
            .balanced
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
    let eventID: String
    let messageLocator: String
    let dedupeKey: String
    let timestampValue: String
    let timestampText: String
    let version: String
    let triggered: Bool
    let reviewTriggered: Bool
    let wakeReason: String
    let sessionID: String
    let cwd: String
    let transcriptPath: String
    let transcriptLine: Int?
    let matched: [String]
    let snippet: String
    let source: String
    let sentimentScore: Double?
    let classifierScore: Double?
    let classifierThreshold: Double?
    let classifierReviewThreshold: Double?
    let classifierModelType: String?
    let classifierExplanations: [ClassifierExplanationRecord]
    let classifierAlternates: [ClassifierAlternateRecord]

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

    var sentimentText: String {
        guard let sentimentScore else { return "tone none" }
        return "tone \(String(format: "%+.2f", sentimentScore))"
    }

    var classifierScoreText: String {
        guard let classifierScore else { return "no score" }
        return String(format: "%.3f", classifierScore)
    }

    var classifierThresholdText: String {
        guard let classifierThreshold else { return "threshold unknown" }
        return String(format: "wake %.2f", classifierThreshold)
    }

    var classifierReviewThresholdText: String {
        guard let classifierReviewThreshold else { return "review unknown" }
        return String(format: "review %.2f", classifierReviewThreshold)
    }

    var decisionLabel: String {
        if triggered { return "Woke reflector" }
        if reviewTriggered { return "Review only" }
        return "Logged"
    }

    var decisionColor: Color {
        if triggered { return IntrospectTheme.danger }
        if reviewTriggered { return IntrospectTheme.warning }
        return IntrospectTheme.inkSecondary
    }

    var wakeReasonLabel: String {
        let value = wakeReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "reason unknown" }
        return value.replacingOccurrences(of: "_", with: " ")
    }
}

struct ClassifierExplanationRecord: Identifiable, Hashable {
    let id: String
    let kind: String
    let feature: String
    let contribution: Double

    var kindLabel: String {
        switch kind {
        case "char":
            return "char"
        case "word":
            return "word"
        default:
            return kind.isEmpty ? "feature" : kind
        }
    }

    var contributionText: String {
        String(format: "%+.2f", contribution)
    }
}

struct ClassifierAlternateRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let score: Double?
    let threshold: Double?
    let reviewThreshold: Double?
    let triggered: Bool
    let review: Bool
    let modelType: String?
    let error: String?

    var scoreText: String {
        guard let score else { return "error" }
        return String(format: "%.3f", score)
    }

    var decisionText: String {
        if error != nil { return "error" }
        if triggered { return "wake" }
        if review { return "review" }
        return "log"
    }

    var decisionColor: Color {
        if error != nil { return IntrospectTheme.danger }
        if triggered { return IntrospectTheme.warning }
        if review { return IntrospectTheme.accent }
        return IntrospectTheme.inkTertiary
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
        return value.isEmpty ? nil : "Claude CLI fallback model: \(value)"
    }

    var lineDelta: Int {
        surfaceDiffs.reduce(0) { $0 + ($1.afterLineCount - $1.beforeLineCount) }
    }

    var lineDeltaText: String {
        if lineDelta > 0 { return "+\(lineDelta) lines" }
        if lineDelta < 0 { return "\(lineDelta) lines" }
        return "0 line delta"
    }

    var highestClassifierScore: Double? {
        events.compactMap(\.classifierScore).max()
    }

    var highestClassifierScoreText: String {
        guard let highestClassifierScore else { return "score none" }
        return String(format: "score %.3f", highestClassifierScore)
    }

    var reviewOnlyEventCount: Int {
        events.filter { $0.reviewTriggered && !$0.triggered }.count
    }

    var wakeEventCount: Int {
        events.filter(\.triggered).count
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

struct TriggerWordAnalyticsRecord: Identifiable {
    let word: String
    let eventCount: Int
    let runCount: Int
    let changedRunCount: Int
    let lastSeenValue: String
    let lastSeenText: String
    let averageSentiment: Double?

    var id: String { word }
}

struct TriggerReasonAnalyticsRecord: Identifiable {
    let reason: String
    let eventCount: Int
    let wakeCount: Int
    let reviewOnlyCount: Int
    let loggedOnlyCount: Int
    let changedRunCount: Int
    let lastSeenValue: String
    let lastSeenText: String

    var id: String { reason }
}

struct ClassifierEvidenceAnalyticsRecord: Identifiable {
    let feature: String
    let kind: String
    let eventCount: Int
    let wakeCount: Int
    let reviewOnlyCount: Int
    let loggedOnlyCount: Int
    let changedRunCount: Int
    let averageContribution: Double
    let lastSeenValue: String
    let lastSeenText: String

    var id: String { "\(kind):\(feature)" }

    var kindLabel: String {
        switch kind {
        case "char":
            return "char"
        case "word":
            return "word"
        default:
            return kind.isEmpty ? "feature" : kind
        }
    }

    var averageContributionText: String {
        String(format: "%+.2f", averageContribution)
    }
}

struct ClassifierScoreBandRecord: Identifiable {
    let lowerBound: Double
    let upperBound: Double
    let promptCount: Int
    let wakeCount: Int
    let reviewOnlyCount: Int

    var id: String { label }
    var loggedOnlyCount: Int { max(promptCount - wakeCount - reviewOnlyCount, 0) }
    var label: String { String(format: "%.1f-%.1f", lowerBound, upperBound) }
}

struct ClassifierScoreDayRecord: Identifiable {
    let day: Date
    let label: String
    let averageScore: Double
    let promptCount: Int
    let wakeCount: Int

    var id: Date { day }
    var averageScoreText: String { String(format: "%.3f", averageScore) }
}

struct ClassifierShadowStatRecord: Identifiable {
    let name: String
    let promptCount: Int
    let candidateWakeCount: Int
    let candidateReviewOnlyCount: Int
    let productionWakeCount: Int
    let addedWakeCount: Int
    let removedWakeCount: Int
    let errorCount: Int
    let averageScore: Double?

    var id: String { name }

    var candidateWakeText: String {
        guard promptCount > 0 else { return "0%" }
        return Self.percentText(Double(candidateWakeCount) / Double(promptCount))
    }

    var averageScoreText: String {
        guard let averageScore else { return "--" }
        return String(format: "%.3f", averageScore)
    }

    var sampleSummary: String {
        var parts = ["\(promptCount) scored"]
        if candidateReviewOnlyCount > 0 {
            parts.append("\(candidateReviewOnlyCount) review")
        }
        if productionWakeCount > 0 {
            parts.append("\(productionWakeCount) prod wake")
        }
        if errorCount > 0 {
            parts.append("\(errorCount) errors")
        }
        return parts.joined(separator: " · ")
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

struct TriggerVersionAnalyticsRecord: Identifiable {
    let version: String
    let promptCount: Int
    let triggerCount: Int
    let reviewOnlyCount: Int
    let runCount: Int
    let changedRunCount: Int
    let firstSeenValue: String
    let lastSeenValue: String
    let lastSeenText: String
    let subject: String
    let previousTriggerRateDelta: Double?

    var id: String { version }

    var shortVersion: String {
        String(version.prefix(7))
    }

    var triggerRate: Double {
        guard promptCount > 0 else { return 0 }
        return Double(triggerCount) / Double(promptCount)
    }

    var triggerRateText: String {
        Self.percentFormatter.string(from: NSNumber(value: triggerRate)) ?? "0%"
    }

    var deltaText: String {
        guard let previousTriggerRateDelta else { return "first" }
        let value = Self.percentFormatter.string(from: NSNumber(value: abs(previousTriggerRateDelta))) ?? "0%"
        if previousTriggerRateDelta > 0 {
            return "+\(value)"
        }
        if previousTriggerRateDelta < 0 {
            return "-\(value)"
        }
        return "0%"
    }

    var deltaColor: Color {
        guard let previousTriggerRateDelta else { return IntrospectTheme.inkTertiary }
        if previousTriggerRateDelta > 0 { return IntrospectTheme.warning }
        if previousTriggerRateDelta < 0 { return IntrospectTheme.success }
        return IntrospectTheme.inkSecondary
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

struct ClassifierThresholdRecord: Identifiable {
    let threshold: Double
    let precision: Double
    let recall: Double
    let wakeRate: Double
    let truePositiveCount: Int
    let falsePositiveCount: Int
    let falseNegativeCount: Int
    let trueNegativeCount: Int

    var id: String { thresholdText }
    var thresholdText: String { String(format: "%.2f", threshold) }
    var precisionText: String { Self.percentText(precision) }
    var recallText: String { Self.percentText(recall) }
    var wakeRateText: String { Self.percentText(wakeRate) }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

struct ClassifierPromptVariantRecord: Identifiable {
    let variant: String
    let precision: Double
    let recall: Double
    let accuracy: Double
    let wakeRate: Double
    let truePositiveCount: Int
    let falsePositiveCount: Int
    let falseNegativeCount: Int
    let trueNegativeCount: Int

    var id: String { variant }
    var displayName: String { variant.replacingOccurrences(of: "_", with: " ") }
    var precisionText: String { Self.percentText(precision) }
    var recallText: String { Self.percentText(recall) }
    var wakeRateText: String { Self.percentText(wakeRate) }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

struct ClassifierModelCheckRecord: Identifiable {
    let name: String
    let shortName: String
    let status: String
    let detail: String
    let threshold: Double?
    let precision: Double?
    let recall: Double?
    let wakeRate: Double?
    let truePositiveCount: Int?
    let falsePositiveCount: Int?
    let falseNegativeCount: Int?
    let trueNegativeCount: Int?
    let wakeCount: Int?
    let rowCount: Int?
    let maxScore: Double?
    let state: HealthState

    var id: String { name }

    var outcomeText: String {
        if let precision, let recall {
            return "\(Self.percentText(precision)) / \(Self.percentText(recall))"
        }
        if let wakeCount, let rowCount {
            return "\(wakeCount)/\(rowCount) wakes"
        }
        return "--"
    }

    var thresholdSummary: String {
        guard let threshold else { return "threshold --" }
        return String(format: "threshold %.3f", threshold)
    }

    var countSummary: String {
        if let truePositiveCount, let falsePositiveCount, let falseNegativeCount, let trueNegativeCount {
            return "\(truePositiveCount)/\(falsePositiveCount)/\(falseNegativeCount)/\(trueNegativeCount)"
        }
        if let maxScore {
            return String(format: "max %.3f", maxScore)
        }
        return "--"
    }

    var sampleSummary: String {
        if let rowCount {
            return "\(rowCount) rows"
        }
        return "rows --"
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

private struct ParsedClassifierMetric {
    let threshold: Double
    let precision: Double
    let recall: Double
    let wakeRate: Double
    let truePositiveCount: Int
    let falsePositiveCount: Int
    let falseNegativeCount: Int
    let trueNegativeCount: Int
    let rowCount: Int?
}

struct HomeCommitRecord: Identifiable, Hashable {
    let hash: String
    let shortHash: String
    let timestampValue: String
    let timestampText: String
    let subject: String

    var id: String { hash }
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
    @Published var selectedSection: IntrospectSection? = .status
    @Published var mode: ReflectionMode = .immediate
    @Published var reflectorRunner: ReflectorRunner = .defaultRunner
    @Published var reflectorClaudeModel = ""
    @Published var reflectorClaudeFallbackModel = ""
    @Published var reflectorCodexModel = ""
    @Published var wakeSensitivity: WakeSensitivity = .balanced
    @Published var wakeCustomThreshold = 0.64
    @Published var nightlyHour = 3
    @Published var nightlyMinute = 0
    @Published var claudePromptOK = false
    @Published var codexPromptOK = false
    @Published var opencodePromptOK = false
    @Published var agentPromptOK = false
    @Published var claudeHookInstalled = false
    @Published var codexHookInstalled = false
    @Published var codexScannerInstalled = false
    @Published var healthMonitorInstalled = false
    @Published var launchAgentInstalled = false
    @Published var queuedEvents = 0
    @Published var lastRunText = "unknown"
    @Published var triggerWordsText = ""
    @Published var homeGitOK = false
    @Published var triggerWordsOK = false
    @Published var homeLastCommit = "none"
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
    @Published var signalPromptCount = 0
    @Published var signalTriggeredCount = 0
    @Published var signalReviewOnlyCount = 0
    @Published var signalChangedRunCount = 0
    @Published var signalVersionCount = 0
    @Published var signalAverageSentiment: Double?
    @Published var signalAverageClassifierScore: Double?
    @Published var signalClassifierScoredCount = 0
    @Published var wordStats: [TriggerWordAnalyticsRecord] = []
    @Published var reasonStats: [TriggerReasonAnalyticsRecord] = []
    @Published var classifierEvidenceStats: [ClassifierEvidenceAnalyticsRecord] = []
    @Published var classifierScoreBands: [ClassifierScoreBandRecord] = []
    @Published var classifierScoreTrend: [ClassifierScoreDayRecord] = []
    @Published var classifierShadowStats: [ClassifierShadowStatRecord] = []
    @Published var recentClassifierEvents: [TriggerEventRecord] = []
    @Published var versionStats: [TriggerVersionAnalyticsRecord] = []
    @Published var classifierThresholdStats: [ClassifierThresholdRecord] = []
    @Published var classifierPromptVariantStats: [ClassifierPromptVariantRecord] = []
    @Published var classifierModelChecks: [ClassifierModelCheckRecord] = []
    @Published var homeCommits: [HomeCommitRecord] = []
    @Published var selectedHomeCommitID: String?
    @Published var selectedHomeCommitDiff = ""
    @Published var homeWorkingTreeStatus = ""
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
    private let runtimeIsBundled: Bool
    private let agentsHomeURL: URL
    private let introspectHomeURL: URL
    private let feedbackURL: URL
    private let homeURL: URL
    private var savedTriggerWords: [String] = []
    private var appCommitSubjects: [String: String] = [:]
    private let skippedScanDirectories = Set([
        ".build", ".cache", ".git", ".next", ".swiftpm", "DerivedData", "__pycache__",
        "build", "cache", "dist", "node_modules", "plugins"
    ])

    init() {
        homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let env = ProcessInfo.processInfo.environment
        if let repoPath = env["INTROSPECT_REPO"], !repoPath.isEmpty {
            repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
            runtimeIsBundled = Self.isPackagedRuntime(repoURL)
        } else if let bundledRoot = Self.bundledRuntimeRoot() {
            repoURL = bundledRoot
            runtimeIsBundled = true
        } else {
            repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
            runtimeIsBundled = false
        }
        let agentsHomePath = env["AGENTS_HOME"] ?? "\(NSHomeDirectory())/.agents"
        agentsHomeURL = URL(fileURLWithPath: agentsHomePath).standardizedFileURL
        let introspectHomePath = env["INTROSPECT_HOME"] ?? "\(NSHomeDirectory())/.introspect"
        introspectHomeURL = URL(fileURLWithPath: introspectHomePath).standardizedFileURL
        if let feedbackPath = env["INTROSPECT_FEEDBACK_DIR"], !feedbackPath.isEmpty {
            feedbackURL = URL(fileURLWithPath: feedbackPath).standardizedFileURL
        } else if runtimeIsBundled {
            feedbackURL = introspectHomeURL.appendingPathComponent("feedback").standardizedFileURL
        } else {
            feedbackURL = repoURL.appendingPathComponent("feedback").standardizedFileURL
        }
    }

    private static func isPackagedRuntime(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasSuffix(".app/Contents/Resources")
    }

    private static func bundledRuntimeRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL?.standardizedFileURL else {
            return nil
        }
        let required = [
            "scripts/install-hooks.sh",
            "scripts/introspect-status.sh",
            "hooks/trigger-reflect.sh",
            "hooks/trigger-worker.py",
            "skills/index.json"
        ]
        let hasRuntime = required.allSatisfy {
            FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path)
        }
        return hasRuntime ? resources : nil
    }

    var repoPath: String { repoURL.path }
    var introspectHomePath: String { introspectHomeURL.path }
    var repoDisplayPath: String { displayPath(repoURL) }
    var introspectHomeDisplayPath: String { displayPath(introspectHomeURL) }
    var sourcePromptURL: URL { introspectHomeURL.appendingPathComponent("AGENTS.md").standardizedFileURL }
    var sourcePromptDisplayPath: String { displayPath(sourcePromptURL) }

    var agentPromptStatus: String {
        agentPromptOK ? sourcePromptDisplayPath : "missing source prompt"
    }

    var claudePromptStatus: String {
        claudePromptOK ? "~/.claude/CLAUDE.md -> \(sourcePromptDisplayPath)" : "not linked to ~/.introspect/AGENTS.md"
    }

    var codexPromptStatus: String {
        codexPromptOK ? "~/.codex/AGENTS.md -> \(sourcePromptDisplayPath)" : "not linked to ~/.introspect/AGENTS.md"
    }

    var opencodePromptStatus: String {
        opencodePromptOK ? "~/.config/opencode/AGENTS.md -> \(sourcePromptDisplayPath)" : "not linked to ~/.introspect/AGENTS.md"
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
            !opencodePromptOK ||
            !agentPromptOK ||
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
            if !agentPromptOK || !claudePromptOK || !codexPromptOK || !opencodePromptOK { missing.append("prompt links") }
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

    var signalTriggerRateText: String {
        guard signalPromptCount > 0 else { return "0%" }
        return Self.percentFormatter.string(
            from: NSNumber(value: Double(signalTriggeredCount) / Double(signalPromptCount))
        ) ?? "0%"
    }

    var signalReviewOnlyRateText: String {
        guard signalPromptCount > 0 else { return "0%" }
        return Self.percentFormatter.string(
            from: NSNumber(value: Double(signalReviewOnlyCount) / Double(signalPromptCount))
        ) ?? "0%"
    }

    var signalAverageClassifierScoreText: String {
        guard let signalAverageClassifierScore else { return "none" }
        return String(format: "%.3f", signalAverageClassifierScore)
    }

    /// Change in daily average wake score from the first half of the charted
    /// window to the second half. Negative = scores trending down, i.e. the
    /// agent needs fewer corrections over time (instructions improving).
    var classifierScoreTrendDelta: Double? {
        let points = classifierScoreTrend
        guard points.count >= 2 else { return nil }
        let mid = points.count / 2
        let early = points.prefix(mid)
        let late = points.suffix(points.count - mid)
        guard !early.isEmpty, !late.isEmpty else { return nil }
        let earlyMean = early.map(\.averageScore).reduce(0, +) / Double(early.count)
        let lateMean = late.map(\.averageScore).reduce(0, +) / Double(late.count)
        return lateMean - earlyMean
    }

    var signalAverageSentimentText: String {
        guard let signalAverageSentiment else { return "none" }
        return String(format: "%+.2f", signalAverageSentiment)
    }

    var signalAverageSentimentLabel: String {
        guard let score = signalAverageSentiment else { return "no scored snippets" }
        if score < -0.25 { return "negative average" }
        if score > 0.25 { return "positive average" }
        return "neutral average"
    }

    var clampedWakeCustomThreshold: Double {
        min(max(wakeCustomThreshold, 0.05), 0.95)
    }

    var wakeCustomThresholdText: String {
        String(format: "%.2f", clampedWakeCustomThreshold)
    }

    var wakeSensitivityDetail: String {
        "\(wakeSensitivity.helpText) \(wakeSensitivity.thresholdSummary(customThreshold: clampedWakeCustomThreshold))"
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

    var homeGitStatus: String {
        homeGitOK ? "\(displayPath(introspectHomeURL))/.git" : "not initialized"
    }

    var triggerWordsStatus: String {
        triggerWordsOK ? displayPath(triggerWordsURL) : "optional file not created"
    }

    private var triggerWordsURL: URL {
        introspectHomeURL.appendingPathComponent("trigger-words.txt")
    }

    private var homeSettingsURL: URL {
        introspectHomeURL.appendingPathComponent("settings.json")
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
        loadHomeSettings()
        notificationHelperInstalled = fileManager.isExecutableFile(atPath: notificationHelperURL.path)
        notificationPermission = IntrospectNotificationPermission(await IntrospectNotifications.authorizationStatus())
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        notificationsEnabled = enabled
        do {
            try saveHomeSettings(["notifications_enabled": enabled])
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
        if !homeGitOK || !fileManager.fileExists(atPath: homeSettingsURL.path) {
            await initializeIntrospectHome(report: false, refreshAfter: false)
            repaired = true
        }

        if !currentProjectAgentFilesReady {
            await initializeCurrentProjectAgentFiles(report: false, refreshAfter: false)
            repaired = true
        }

        if mode != .off && (!agentPromptOK || !claudePromptOK || !codexPromptOK || !opencodePromptOK || !allHooksInstalled || !codexScannerInstalled) {
            await applySystemPromptAndHooks(report: false, refreshAfter: false)
            repaired = true
        }

        if repaired {
            lastCommandOutput = "Introspect repaired local setup automatically."
        }
    }

    private var currentProjectAgentFilesReady: Bool {
        if runtimeIsBundled {
            return true
        }
        return fileManager.fileExists(atPath: repoURL.appendingPathComponent("AGENTS.md").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent("CLAUDE.md").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent(".agents/skills").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent(".claude/skills").path) &&
            fileManager.fileExists(atPath: repoURL.appendingPathComponent(".claude/rules").path)
    }

    func refresh() async {
        await refreshNotificationState()
        agentPromptOK = fileManager.fileExists(atPath: sourcePromptURL.path)
        claudePromptOK = symlink(homeURL.appendingPathComponent(".claude/CLAUDE.md"), pointsTo: sourcePromptURL)
        codexPromptOK = symlink(homeURL.appendingPathComponent(".codex/AGENTS.md"), pointsTo: sourcePromptURL)
        opencodePromptOK = symlink(homeURL.appendingPathComponent(".config/opencode/AGENTS.md"), pointsTo: sourcePromptURL)
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
            wakeSensitivity = WakeSensitivity.parse(launchEnvironment["INTROSPECT_WAKE_SENSITIVITY"])
            if let threshold = doubleSetting(launchEnvironment["INTROSPECT_WAKE_THRESHOLD"]) {
                wakeCustomThreshold = threshold
            }
        }
        queuedEvents = lineCount(feedbackURL.appendingPathComponent("trigger-queue.jsonl"))
        lastRunText = readLastRun()
        appCommitSubjects = await gitSubjectMap(in: repoURL)
        loadTriggerHistory()
        loadClassifierReports()
        loadTriggerWords()
        homeGitOK = fileManager.fileExists(atPath: introspectHomeURL.appendingPathComponent(".git").path)
        triggerWordsOK = fileManager.fileExists(atPath: triggerWordsURL.path)
        homeLastCommit = homeGitOK
            ? await gitOutput(["-C", introspectHomeURL.path, "log", "-1", "--oneline"]).trimmedOr("none")
            : "none"
        await loadHomeHistory()

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
        await initializeIntrospectHome(report: false, refreshAfter: false)
        try? saveConfigurationSettings()
        var args = [
            repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
            "--home", introspectHomeURL.path,
            "--agents-home", agentsHomeURL.path,
            "--prompt", sourcePromptURL.path,
            "--user-skills", introspectHomeURL.appendingPathComponent("skills").path,
            "--reflect-mode", mode.rawValue,
            "--nightly-hour", "\(nightlyHour)",
            "--nightly-minute", "\(nightlyMinute)",
            "--runner", reflectorRunner.rawValue,
            "--claude-model", normalizedModelSetting(reflectorClaudeModel),
            "--claude-fallback-model", normalizedModelSetting(reflectorClaudeFallbackModel),
            "--codex-model", normalizedModelSetting(reflectorCodexModel),
            "--wake-sensitivity", wakeSensitivity.rawValue,
            "--wake-threshold", wakeThresholdSetting
        ]
        if mode == .off {
            args = [
                repoURL.appendingPathComponent("scripts/install-hooks.sh").path,
                "--home", introspectHomeURL.path,
                "--agents-home", agentsHomeURL.path,
                "--prompt", sourcePromptURL.path,
                "--user-skills", introspectHomeURL.appendingPathComponent("skills").path,
                "--reflect-mode", "off",
                "--wake-sensitivity", wakeSensitivity.rawValue,
                "--wake-threshold", wakeThresholdSetting
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

    func setWakeSensitivity(_ newSensitivity: WakeSensitivity) async {
        guard wakeSensitivity != newSensitivity else { return }
        wakeSensitivity = newSensitivity
        wakeCustomThreshold = clampedWakeCustomThreshold
        await applyConfigurationChange()
    }

    func saveReflectorAgentSettings() async {
        await applyConfigurationChange()
    }

    func saveWakeSensitivitySettings() async {
        wakeCustomThreshold = clampedWakeCustomThreshold
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
        try saveHomeSettings([
            "notifications_enabled": notificationsEnabled,
            "reflect_mode": mode.rawValue,
            "reflector_runner": reflectorRunner.rawValue,
            "reflector_claude_model": normalizedModelSetting(reflectorClaudeModel),
            "reflector_claude_fallback_model": normalizedModelSetting(reflectorClaudeFallbackModel),
            "reflector_codex_model": normalizedModelSetting(reflectorCodexModel),
            "wake_sensitivity": wakeSensitivity.rawValue,
            "wake_custom_threshold": clampedWakeCustomThreshold,
            "nightly_hour": nightlyHour,
            "nightly_minute": nightlyMinute
        ])
    }

    func initializeIntrospectHome(report: Bool = true, refreshAfter: Bool = true) async {
        do {
            try fileManager.createDirectory(at: introspectHomeURL.appendingPathComponent("skills"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: introspectHomeURL.appendingPathComponent("memory"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: introspectHomeURL.appendingPathComponent("models"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: feedbackURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: introspectHomeURL.appendingPathComponent("runs"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: introspectHomeURL.appendingPathComponent("proposals"), withIntermediateDirectories: true)
            try ensureIntrospectHomeGitignore()
            let sourcePromptURL = introspectHomeURL.appendingPathComponent("AGENTS.md")
            if !fileManager.fileExists(atPath: sourcePromptURL.path) {
                let defaultPromptURL = repoURL.appendingPathComponent("templates/default-AGENTS.md")
                if fileManager.fileExists(atPath: defaultPromptURL.path) {
                    try fileManager.copyItem(at: defaultPromptURL, to: sourcePromptURL)
                } else {
                    try """
                    # AGENTS.md

                    ## Mission

                    - Add global user-wide agent guidance here.
                    """.write(to: sourcePromptURL, atomically: true, encoding: .utf8)
                }
            }
            let homeWakeModelURL = introspectHomeURL.appendingPathComponent("models/wake-logreg-v2-round4.json")
            let bundledWakeModelURL = repoURL.appendingPathComponent("models/wake-logreg-v2-round4.json")
            if !fileManager.fileExists(atPath: homeWakeModelURL.path),
               fileManager.fileExists(atPath: bundledWakeModelURL.path) {
                try fileManager.copyItem(at: bundledWakeModelURL, to: homeWakeModelURL)
            }
            let skillsIndexURL = introspectHomeURL.appendingPathComponent("skills/index.json")
            if !fileManager.fileExists(atPath: skillsIndexURL.path) {
                try writeJSON([
                    "version": 1,
                    "skills": []
                ], to: skillsIndexURL)
            }
            if !fileManager.fileExists(atPath: homeSettingsURL.path) {
                try writeJSON([
                    "notifications_enabled": notificationsEnabled,
                    "reflect_mode": mode.rawValue,
                    "reflector_runner": reflectorRunner.rawValue,
                    "reflector_claude_model": normalizedModelSetting(reflectorClaudeModel),
                    "reflector_claude_fallback_model": normalizedModelSetting(reflectorClaudeFallbackModel),
                    "reflector_codex_model": normalizedModelSetting(reflectorCodexModel),
                    "wake_sensitivity": wakeSensitivity.rawValue,
                    "wake_custom_threshold": clampedWakeCustomThreshold,
                    "nightly_hour": nightlyHour,
                    "nightly_minute": nightlyMinute
                ], to: homeSettingsURL)
            }
            let readme = introspectHomeURL.appendingPathComponent("README.md")
            if !fileManager.fileExists(atPath: readme.path) {
                try """
                # Introspect Home

                This repository is private local state for Introspect:

                - `AGENTS.md`: the Git-tracked source for the user-wide prompt linked into each agent's native prompt file.
                - `trigger-words.txt`: optional review terms, one lowercase word per line. Introspect does not install defaults.
                - `settings.json`: local app preferences such as notification delivery.
                - `skills/`: private user skills.
                - `memory/`: durable user and machine facts.
                - `feedback/`: ignored local trigger queues, logs, and run artifacts.
                - `runs/`: ignored local run artifacts.
                - `proposals/`: reflector proposals before they are accepted.
                - `models/`: ignored local model artifacts seeded or produced by Introspect.

                Durable prompt, settings, skill, and memory changes are Git-tracked. Runtime artifacts stay local and ignored.
                """.write(to: readme, atomically: true, encoding: .utf8)
            }
        } catch {
            if report {
                lastCommandOutput = "Failed to initialize home files: \(error)"
            }
            return
        }

        if !fileManager.fileExists(atPath: introspectHomeURL.appendingPathComponent(".git").path) {
            _ = await gitOutput(["init", introspectHomeURL.path])
        }
        await commitHomeChanges(message: "Initialize Introspect home", report: report)
        if refreshAfter {
            await refresh()
        }
    }

    func saveTriggerWords() async {
        let words = parseWords(triggerWordsText)
        do {
            try fileManager.createDirectory(at: introspectHomeURL, withIntermediateDirectories: true)
            try (words.joined(separator: "\n") + "\n").write(to: triggerWordsURL, atomically: true, encoding: .utf8)
            savedTriggerWords = words
            lastCommandOutput = "Saved \(words.count) review term(s)."
        } catch {
            lastCommandOutput = "Failed to save review terms: \(error)"
        }
        await commitHomeChanges(message: "Update review terms")
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

    func commitHomeChanges() async {
        await commitHomeChanges(message: "Update Introspect home")
        await refresh()
    }

    func openIntrospectHomeFolder() async {
        NSWorkspace.shared.open(introspectHomeURL)
    }

    func selectHomeCommit(_ commit: HomeCommitRecord) async {
        selectedHomeCommitID = commit.id
        selectedHomeCommitDiff = await homeCommitDiff(commit.hash)
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

    func unlinkOpenCodePrompt() async {
        await removePromptLink(homeURL.appendingPathComponent(".config/opencode/AGENTS.md"))
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
        if runtimeIsBundled {
            if report {
                lastCommandOutput = "The packaged Introspect runtime is not a project folder. Project agent files are discovered from existing project folders."
            }
            if refreshAfter {
                await refresh()
            }
            return
        }
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
                try fileManager.createSymbolicLink(atPath: claudeURL.path, withDestinationPath: "AGENTS.md")
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

    private func commitHomeChanges(message: String, report: Bool = true) async {
        _ = await gitOutput(["-C", introspectHomeURL.path, "add", "."])
        let status = await gitOutput(["-C", introspectHomeURL.path, "status", "--porcelain"])
        if status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if report {
                lastCommandOutput = "Introspect home has no uncommitted changes."
            }
            return
        }
        let output = await gitOutput(["-C", introspectHomeURL.path, "commit", "-m", message])
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
        if !runtimeIsBundled {
            let repoPath = repoURL.standardizedFileURL.path
            if let repoTree = projectTrees.first(where: { $0.id == repoPath }) {
                return repoTree.prompts.first?.id ?? repoTree.skills.first?.id
            }
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
        if !runtimeIsBundled && path == repoURL.standardizedFileURL.path { return 0 }
        if path == introspectHomeURL.standardizedFileURL.path { return 1 }
        if path == homePath + "/.codex" { return 2 }
        if path == homePath + "/.claude" { return 3 }
        if path == homePath + "/.agents" { return 4 }
        if path == homePath + "/.config/opencode" { return 5 }
        if path.hasPrefix(homePath + "/Projects/") { return 6 }
        if path.hasPrefix(homePath + "/Developer/") { return 7 }
        if path.hasPrefix(homePath + "/Code/") { return 8 }
        if path.hasPrefix(homePath + "/Documents/") { return 9 }
        return 10
    }

    private func scanRoots() -> [URL] {
        let runtimeRoots = runtimeIsBundled ? [] : [repoURL]
        return runtimeRoots + [
            introspectHomeURL,
            homeURL.appendingPathComponent("Projects"),
            homeURL.appendingPathComponent("Developer"),
            homeURL.appendingPathComponent("Code"),
            homeURL.appendingPathComponent("Documents"),
            homeURL.appendingPathComponent(".codex"),
            homeURL.appendingPathComponent(".claude"),
            homeURL.appendingPathComponent(".agents"),
            homeURL.appendingPathComponent(".config/opencode")
        ]
    }

    private func priorityScanRoots() -> [URL] {
        let runtimeRoots = runtimeIsBundled ? [] : [repoURL]
        return runtimeRoots + [
            introspectHomeURL,
            homeURL.appendingPathComponent(".codex"),
            homeURL.appendingPathComponent(".claude"),
            homeURL.appendingPathComponent(".agents"),
            homeURL.appendingPathComponent(".config/opencode")
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
                if skippedScanDirectories.contains(name) || shouldSkipSurfaceDirectory(entry) { continue }
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

    private func shouldSkipSurfaceDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.path == homeURL.appendingPathComponent(".codex/skills").standardizedFileURL.path
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
        let introspectHomePath = introspectHomeURL.standardizedFileURL.path
        if path.hasPrefix(introspectHomePath + "/skills/") {
            return "Introspect user skill"
        }
        if path == introspectHomePath || path.hasPrefix(introspectHomePath + "/") {
            return url.lastPathComponent == "AGENTS.md" ? "Introspect home prompt" : "Introspect home"
        }
        if path.hasPrefix(homePath + "/.codex/") {
            return url.lastPathComponent == "AGENTS.override.md" ? "Codex global override" : "Codex global"
        }
        if path.hasPrefix(homePath + "/.agents/skills/") {
            return "Codex/OpenCode user skill"
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
        if path.hasPrefix(homePath + "/.config/opencode/skills/") {
            return "OpenCode user skill"
        }
        if path.hasPrefix(homePath + "/.config/opencode/") {
            return "OpenCode global"
        }
        if isSkill {
            if path.contains("/.agents/skills/") { return "Codex/OpenCode project skill" }
            if path.contains("/.claude/skills/") { return "Claude project skill" }
            if path.contains("/.opencode/skills/") { return "OpenCode project skill" }
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
        let introspectHomePath = introspectHomeURL.standardizedFileURL.path
        if path == introspectHomePath || path.hasPrefix(introspectHomePath + "/") {
            return introspectHomeURL.standardizedFileURL
        }
        let opencodeGlobalURL = homeURL.appendingPathComponent(".config/opencode").standardizedFileURL
        let opencodeGlobalPath = opencodeGlobalURL.path
        if path == opencodeGlobalPath || path.hasPrefix(opencodeGlobalPath + "/") {
            return opencodeGlobalURL
        }
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
        case introspectHomeURL.standardizedFileURL.path:
            return "Introspect Home"
        case homePath + "/.codex":
            return "Codex Global"
        case homePath + "/.claude":
            return "Claude Global"
        case homePath + "/.agents":
            return "Agent Skills"
        case homePath + "/.config/opencode":
            return "OpenCode Global"
        default:
            if !runtimeIsBundled && path == repoURL.standardizedFileURL.path {
                return "Introspect"
            }
            return root.lastPathComponent.isEmpty ? path : root.lastPathComponent
        }
    }

    private func projectIcon(for projectPath: String) -> String {
        let homePath = homeURL.standardizedFileURL.path
        if projectPath == introspectHomeURL.standardizedFileURL.path {
            return "archivebox"
        }
        if projectPath == homePath + "/.codex" {
            return "terminal"
        }
        if projectPath == homePath + "/.claude" {
            return "bubble.left.and.text.bubble.right"
        }
        if projectPath == homePath + "/.agents" {
            return "hammer"
        }
        if projectPath == homePath + "/.config/opencode" {
            return "terminal"
        }
        if !runtimeIsBundled && projectPath == repoURL.standardizedFileURL.path {
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
        try ensureGitignoreEntry(entry, in: gitignoreURL)
    }

    private func ensureIntrospectHomeGitignore() throws {
        let gitignoreURL = introspectHomeURL.appendingPathComponent(".gitignore")
        for entry in ["feedback/", "runs/", "proposals/", "models/*.json", "models/*.json.*"] {
            try ensureGitignoreEntry(entry, in: gitignoreURL)
        }
    }

    private func ensureGitignoreEntry(_ entry: String, in gitignoreURL: URL) throws {
        let current = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
        let lines = current.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.contains(entry) else { return }
        let prefix = current.isEmpty || current.hasSuffix("\n") ? current : current + "\n"
        try (prefix + entry + "\n").write(to: gitignoreURL, atomically: true, encoding: .utf8)
    }

    private func loadTriggerWords() {
        triggerWordsOK = fileManager.fileExists(atPath: triggerWordsURL.path)
        guard let text = try? String(contentsOf: triggerWordsURL, encoding: .utf8) else {
            savedTriggerWords = []
            resetWordDraft()
            return
        }
        let words = parseWords(text)
        savedTriggerWords = words
        resetWordDraft()
    }

    private func loadHomeSettings() {
        let settings = readHomeSettings()
        notificationsEnabled = settings["notifications_enabled"] as? Bool ?? true
        mode = ReflectionMode.parse(settings["reflect_mode"] as? String)
        reflectorRunner = ReflectorRunner.parse(settings["reflector_runner"] as? String)
        reflectorClaudeModel = settings["reflector_claude_model"] as? String ?? ""
        reflectorClaudeFallbackModel = settings["reflector_claude_fallback_model"] as? String ?? ""
        reflectorCodexModel = settings["reflector_codex_model"] as? String ?? ""
        wakeSensitivity = WakeSensitivity.parse(settings["wake_sensitivity"] as? String)
        if let threshold = doubleSetting(settings["wake_custom_threshold"]) {
            wakeCustomThreshold = threshold
        }
        if let hour = settings["nightly_hour"] as? Int, (0...23).contains(hour) {
            nightlyHour = hour
        }
        if let minute = settings["nightly_minute"] as? Int, (0...59).contains(minute) {
            nightlyMinute = minute
        }
    }

    private func saveHomeSettings(_ updates: [String: Any]) throws {
        try fileManager.createDirectory(at: introspectHomeURL, withIntermediateDirectories: true)
        var settings = readHomeSettings()
        for (key, value) in updates {
            settings[key] = value
        }
        try writeJSON(settings, to: homeSettingsURL)
    }

    private func readHomeSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: homeSettingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func doubleSetting(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
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
        let stateURL = feedbackURL.appendingPathComponent("reflector-state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["last_run_at"] as? String else {
            return "never"
        }
        return friendlyTimestamp(value)
    }

    private func loadHomeHistory() async {
        guard homeGitOK else {
            homeCommits = []
            selectedHomeCommitID = nil
            selectedHomeCommitDiff = ""
            homeWorkingTreeStatus = "not initialized"
            return
        }

        homeWorkingTreeStatus = await gitOutput([
            "-C", introspectHomeURL.path,
            "status", "--short"
        ]).trimmedOr("clean")

        let output = await gitOutput([
            "-C", introspectHomeURL.path,
            "log", "-30",
            "--date=iso-strict",
            "--pretty=format:%H\u{1f}%h\u{1f}%ad\u{1f}%s"
        ])

        let commits = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> HomeCommitRecord? in
                let parts = String(line).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { return nil }
                return HomeCommitRecord(
                    hash: parts[0],
                    shortHash: parts[1],
                    timestampValue: parts[2],
                    timestampText: friendlyTimestamp(parts[2]),
                    subject: parts[3]
                )
            }

        homeCommits = commits
        if selectedHomeCommitID == nil || !commits.contains(where: { $0.id == selectedHomeCommitID }) {
            selectedHomeCommitID = commits.first?.id
        }
        if let selected = commits.first(where: { $0.id == selectedHomeCommitID }) {
            selectedHomeCommitDiff = await homeCommitDiff(selected.hash)
        } else {
            selectedHomeCommitDiff = ""
        }
    }

    private func homeCommitDiff(_ hash: String) async -> String {
        guard !hash.isEmpty else { return "" }
        return await gitOutput([
            "-C", introspectHomeURL.path,
            "show",
            "--format=medium",
            "--stat",
            "--patch",
            "--find-renames",
            hash
        ]).trimmedOr("No diff for \(hash).")
    }

    private func gitSubjectMap(in repo: URL) async -> [String: String] {
        let output = await gitOutput([
            "-C", repo.path,
            "log", "--all", "-300",
            "--pretty=format:%H\u{1f}%h\u{1f}%s"
        ])
        var subjects: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = String(line).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            subjects[parts[0]] = parts[2]
            subjects[parts[1]] = parts[2]
        }
        return subjects
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
        applySignalAnalytics(events: events, runs: runs)
        loadSelectedReflectorPrompt()
    }

    private func applySignalAnalytics(events: [TriggerEventRecord], runs: [TriggerRunRecord]) {
        signalPromptCount = events.count
        signalTriggeredCount = events.filter(\.triggered).count
        signalReviewOnlyCount = events.filter { $0.reviewTriggered && !$0.triggered }.count
        signalChangedRunCount = runs.filter(runDidChange).count
        let scoredSentiments = events.compactMap(\.sentimentScore)
        signalAverageSentiment = scoredSentiments.isEmpty
            ? nil
            : scoredSentiments.reduce(0, +) / Double(scoredSentiments.count)
        let classifierScores = events.compactMap(\.classifierScore)
        signalClassifierScoredCount = classifierScores.count
        signalAverageClassifierScore = classifierScores.isEmpty
            ? nil
            : classifierScores.reduce(0, +) / Double(classifierScores.count)
        classifierScoreBands = buildClassifierScoreBands(events: events)
        classifierScoreTrend = buildClassifierScoreTrend(events: events)
        classifierShadowStats = buildClassifierShadowStats(events: events)
        classifierEvidenceStats = buildClassifierEvidenceStats(events: events, runs: runs)
        recentClassifierEvents = Array(events.filter { $0.classifierScore != nil }.prefix(30))

        var wordEvents: [String: [TriggerEventRecord]] = [:]
        for event in events where !event.matched.isEmpty {
            for word in unique(event.matched) {
                wordEvents[word, default: []].append(event)
            }
        }

        var runCounts: [String: Int] = [:]
        var changedRunCounts: [String: Int] = [:]
        for run in runs {
            for word in unique(run.matched) {
                runCounts[word, default: 0] += 1
                if runDidChange(run) {
                    changedRunCounts[word, default: 0] += 1
                }
            }
        }

        wordStats = wordEvents.map { word, wordEvents in
            let ordered = wordEvents.sorted {
                compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending
            }
            let sentiments = ordered.compactMap(\.sentimentScore)
            let averageSentiment = sentiments.isEmpty ? nil : sentiments.reduce(0, +) / Double(sentiments.count)
            return TriggerWordAnalyticsRecord(
                word: word,
                eventCount: wordEvents.count,
                runCount: runCounts[word] ?? 0,
                changedRunCount: changedRunCounts[word] ?? 0,
                lastSeenValue: ordered.first?.timestampValue ?? "",
                lastSeenText: ordered.first?.timestampText ?? "unknown",
                averageSentiment: averageSentiment
            )
        }
        .sorted {
            if $0.eventCount != $1.eventCount {
                return $0.eventCount > $1.eventCount
            }
            return $0.word.localizedStandardCompare($1.word) == .orderedAscending
        }

        var changedRunCountsByReason: [String: Int] = [:]
        for run in runs where runDidChange(run) {
            for reason in unique(run.events.map(\.wakeReasonLabel)) {
                changedRunCountsByReason[reason, default: 0] += 1
            }
        }

        let reasonEvents = Dictionary(grouping: events) { event in
            event.wakeReasonLabel
        }
        reasonStats = reasonEvents.map { reason, reasonEvents in
            let ordered = reasonEvents.sorted {
                compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedDescending
            }
            let wakeCount = reasonEvents.filter(\.triggered).count
            let reviewOnlyCount = reasonEvents.filter { $0.reviewTriggered && !$0.triggered }.count
            let loggedOnlyCount = max(reasonEvents.count - wakeCount - reviewOnlyCount, 0)
            return TriggerReasonAnalyticsRecord(
                reason: reason,
                eventCount: reasonEvents.count,
                wakeCount: wakeCount,
                reviewOnlyCount: reviewOnlyCount,
                loggedOnlyCount: loggedOnlyCount,
                changedRunCount: changedRunCountsByReason[reason] ?? 0,
                lastSeenValue: ordered.first?.timestampValue ?? "",
                lastSeenText: ordered.first?.timestampText ?? "unknown"
            )
        }
        .sorted {
            if $0.wakeCount != $1.wakeCount {
                return $0.wakeCount > $1.wakeCount
            }
            if $0.reviewOnlyCount != $1.reviewOnlyCount {
                return $0.reviewOnlyCount > $1.reviewOnlyCount
            }
            if $0.eventCount != $1.eventCount {
                return $0.eventCount > $1.eventCount
            }
            return $0.reason.localizedStandardCompare($1.reason) == .orderedAscending
        }

        buildVersionStats(events: events, runs: runs)
    }

    private func buildVersionStats(events: [TriggerEventRecord], runs: [TriggerRunRecord]) {
        let chronological = events.sorted {
            compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedAscending
        }
        var versionOrder: [String] = []
        var seenVersions: Set<String> = []
        var eventsByVersion: [String: [TriggerEventRecord]] = [:]
        for event in chronological {
            let version = event.version.isEmpty ? "unknown" : event.version
            if seenVersions.insert(version).inserted {
                versionOrder.append(version)
            }
            eventsByVersion[version, default: []].append(event)
        }
        signalVersionCount = versionOrder.count

        let runsByVersion = runs.reduce(into: [String: [TriggerRunRecord]]()) { result, run in
            let versions = Set(run.events.map { $0.version.isEmpty ? "unknown" : $0.version })
            for version in versions {
                result[version, default: []].append(run)
            }
        }

        var previousRate: Double?
        var records: [TriggerVersionAnalyticsRecord] = []
        for version in versionOrder {
            let versionEvents = eventsByVersion[version] ?? []
            let triggerCount = versionEvents.filter(\.triggered).count
            let reviewOnlyCount = versionEvents.filter { $0.reviewTriggered && !$0.triggered }.count
            let promptCount = versionEvents.count
            let rate = promptCount > 0 ? Double(triggerCount) / Double(promptCount) : 0
            let versionRuns = runsByVersion[version] ?? []
            let ordered = versionEvents.sorted {
                compareTimestamps($0.timestampValue, $1.timestampValue) == .orderedAscending
            }
            records.append(
                TriggerVersionAnalyticsRecord(
                    version: version,
                    promptCount: promptCount,
                    triggerCount: triggerCount,
                    reviewOnlyCount: reviewOnlyCount,
                    runCount: versionRuns.count,
                    changedRunCount: versionRuns.filter(runDidChange).count,
                    firstSeenValue: ordered.first?.timestampValue ?? "",
                    lastSeenValue: ordered.last?.timestampValue ?? "",
                    lastSeenText: ordered.last?.timestampText ?? "unknown",
                    subject: appCommitSubjects[version] ?? appCommitSubjects[String(version.prefix(7))] ?? "",
                    previousTriggerRateDelta: previousRate.map { rate - $0 }
                )
            )
            previousRate = rate
        }
        versionStats = records
    }

    private func buildClassifierScoreBands(events: [TriggerEventRecord]) -> [ClassifierScoreBandRecord] {
        struct Counts {
            var prompt = 0
            var wake = 0
            var reviewOnly = 0
        }

        var bands = Array(repeating: Counts(), count: 10)
        for event in events {
            guard let score = event.classifierScore else { continue }
            let clamped = min(max(score, 0), 0.999_999)
            let index = min(Int(clamped * 10), 9)
            bands[index].prompt += 1
            if event.triggered {
                bands[index].wake += 1
            } else if event.reviewTriggered {
                bands[index].reviewOnly += 1
            }
        }

        return bands.enumerated().map { index, counts in
            let lower = Double(index) / 10
            return ClassifierScoreBandRecord(
                lowerBound: lower,
                upperBound: lower + 0.1,
                promptCount: counts.prompt,
                wakeCount: counts.wake,
                reviewOnlyCount: counts.reviewOnly
            )
        }
    }

    private func buildClassifierScoreTrend(events: [TriggerEventRecord]) -> [ClassifierScoreDayRecord] {
        struct Bucket { var total = 0.0; var count = 0; var wake = 0 }
        var byDay: [Date: Bucket] = [:]
        let calendar = Calendar.current
        for event in events {
            guard let score = event.classifierScore,
                  let date = dateValue(event.timestampValue) else { continue }
            let day = calendar.startOfDay(for: date)
            var bucket = byDay[day] ?? Bucket()
            bucket.total += score
            bucket.count += 1
            if event.triggered { bucket.wake += 1 }
            byDay[day] = bucket
        }
        return byDay.keys.sorted().suffix(30).map { day in
            let bucket = byDay[day]!
            return ClassifierScoreDayRecord(
                day: day,
                label: Self.dayLabelFormatter.string(from: day),
                averageScore: bucket.count > 0 ? bucket.total / Double(bucket.count) : 0,
                promptCount: bucket.count,
                wakeCount: bucket.wake
            )
        }
    }

    private func buildClassifierShadowStats(events: [TriggerEventRecord]) -> [ClassifierShadowStatRecord] {
        struct Counts {
            var prompt = 0
            var candidateWake = 0
            var candidateReviewOnly = 0
            var productionWake = 0
            var addedWake = 0
            var removedWake = 0
            var error = 0
            var scoreSum = 0.0
            var scoreCount = 0
        }

        var countsByName: [String: Counts] = [:]
        for event in events {
            for alternate in event.classifierAlternates {
                var counts = countsByName[alternate.name, default: Counts()]
                if alternate.error != nil {
                    counts.error += 1
                    countsByName[alternate.name] = counts
                    continue
                }
                guard let score = alternate.score else {
                    counts.error += 1
                    countsByName[alternate.name] = counts
                    continue
                }

                counts.prompt += 1
                counts.scoreSum += score
                counts.scoreCount += 1
                if alternate.triggered {
                    counts.candidateWake += 1
                } else if alternate.review {
                    counts.candidateReviewOnly += 1
                }
                if event.triggered {
                    counts.productionWake += 1
                }
                if alternate.triggered && !event.triggered {
                    counts.addedWake += 1
                }
                if !alternate.triggered && event.triggered {
                    counts.removedWake += 1
                }
                countsByName[alternate.name] = counts
            }
        }

        return countsByName.map { name, counts in
            ClassifierShadowStatRecord(
                name: name,
                promptCount: counts.prompt,
                candidateWakeCount: counts.candidateWake,
                candidateReviewOnlyCount: counts.candidateReviewOnly,
                productionWakeCount: counts.productionWake,
                addedWakeCount: counts.addedWake,
                removedWakeCount: counts.removedWake,
                errorCount: counts.error,
                averageScore: counts.scoreCount > 0 ? counts.scoreSum / Double(counts.scoreCount) : nil
            )
        }
        .sorted {
            if $0.promptCount != $1.promptCount {
                return $0.promptCount > $1.promptCount
            }
            if $0.addedWakeCount != $1.addedWakeCount {
                return $0.addedWakeCount > $1.addedWakeCount
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func classifierEvidenceKey(_ explanation: ClassifierExplanationRecord) -> String {
        "\(explanation.kind)\u{1f}\(explanation.feature)"
    }

    private func buildClassifierEvidenceStats(events: [TriggerEventRecord], runs: [TriggerRunRecord]) -> [ClassifierEvidenceAnalyticsRecord] {
        struct Counts {
            let feature: String
            let kind: String
            var eventCount = 0
            var wakeCount = 0
            var reviewOnlyCount = 0
            var contributionSum = 0.0
            var lastSeenValue = ""
            var lastSeenText = ""
        }

        var changedRunCounts: [String: Int] = [:]
        for run in runs where runDidChange(run) {
            var runKeys: Set<String> = []
            for event in run.events {
                for explanation in event.classifierExplanations {
                    runKeys.insert(classifierEvidenceKey(explanation))
                }
            }
            for key in runKeys {
                changedRunCounts[key, default: 0] += 1
            }
        }

        var countsByKey: [String: Counts] = [:]
        for event in events {
            var eventEvidence: [String: ClassifierExplanationRecord] = [:]
            for explanation in event.classifierExplanations {
                let key = classifierEvidenceKey(explanation)
                if let current = eventEvidence[key], current.contribution >= explanation.contribution {
                    continue
                }
                eventEvidence[key] = explanation
            }

            for (key, explanation) in eventEvidence {
                var counts = countsByKey[key] ?? Counts(feature: explanation.feature, kind: explanation.kind)
                counts.eventCount += 1
                counts.contributionSum += explanation.contribution
                if event.triggered {
                    counts.wakeCount += 1
                } else if event.reviewTriggered {
                    counts.reviewOnlyCount += 1
                }
                if counts.lastSeenValue.isEmpty ||
                    compareTimestamps(event.timestampValue, counts.lastSeenValue) == .orderedDescending {
                    counts.lastSeenValue = event.timestampValue
                    counts.lastSeenText = event.timestampText
                }
                countsByKey[key] = counts
            }
        }

        return countsByKey.map { key, counts in
            ClassifierEvidenceAnalyticsRecord(
                feature: counts.feature,
                kind: counts.kind,
                eventCount: counts.eventCount,
                wakeCount: counts.wakeCount,
                reviewOnlyCount: counts.reviewOnlyCount,
                loggedOnlyCount: max(counts.eventCount - counts.wakeCount - counts.reviewOnlyCount, 0),
                changedRunCount: changedRunCounts[key] ?? 0,
                averageContribution: counts.eventCount > 0 ? counts.contributionSum / Double(counts.eventCount) : 0,
                lastSeenValue: counts.lastSeenValue,
                lastSeenText: counts.lastSeenText
            )
        }
        .sorted {
            if $0.wakeCount != $1.wakeCount {
                return $0.wakeCount > $1.wakeCount
            }
            if $0.reviewOnlyCount != $1.reviewOnlyCount {
                return $0.reviewOnlyCount > $1.reviewOnlyCount
            }
            if $0.eventCount != $1.eventCount {
                return $0.eventCount > $1.eventCount
            }
            return $0.averageContribution > $1.averageContribution
        }
    }

    private func loadClassifierReports() {
        let reportDir = feedbackURL.appendingPathComponent("intent-classifier")
        let selectedStats = readClassifierThresholds(
            reportDir.appendingPathComponent("intent-v2-round4-split-grid-report.md")
        )
        let curveStats = readClassifierThresholds(
            reportDir.appendingPathComponent("group-holdout-logreg-round4-split-fixed-report.md")
        )
        let fallbackReports = [
            reportDir.appendingPathComponent("group-holdout-logreg-round4-split-fixed-report.md"),
            reportDir.appendingPathComponent("wake-logreg-exportable-report.md"),
            reportDir.appendingPathComponent("tfidf-audit-overrides-report.md")
        ]
        if selectedStats.isEmpty && curveStats.isEmpty {
            classifierThresholdStats = fallbackReports
                .map(readClassifierThresholds)
                .first { !$0.isEmpty } ?? []
        } else {
            classifierThresholdStats = (selectedStats + curveStats).sorted { lhs, rhs in
                lhs.threshold < rhs.threshold
            }
        }
        classifierPromptVariantStats = readClassifierPromptVariants(
            reportDir.appendingPathComponent("prompt-variant-audit-report.md")
        )
        classifierModelChecks = readClassifierModelChecks(reportDir: reportDir)
    }

    private func readClassifierThresholds(_ url: URL) -> [ClassifierThresholdRecord] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var tableKind: String?
        var selectedThreshold: Double?
        var records: [ClassifierThresholdRecord] = []
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("Selected threshold:") {
                selectedThreshold = Double(rawLine.replacingOccurrences(of: "Selected threshold:", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }
            if rawLine.hasPrefix("## ") {
                if rawLine.contains("Selected Group-Holdout Metrics") {
                    tableKind = "selected"
                } else if rawLine.contains("Thresholds On Subagent Audit Labels") ||
                    rawLine.contains("5-Fold CV Thresholds") ||
                    rawLine.contains("Overall Thresholds") {
                    tableKind = "thresholds"
                } else {
                    tableKind = nil
                }
                continue
            }
            guard let tableKind else { continue }
            let cells = markdownTableCells(rawLine)
            if tableKind == "selected" {
                guard cells.count >= 7, let threshold = selectedThreshold, let precision = Double(cells[0]) else { continue }
                records.append(
                    ClassifierThresholdRecord(
                        threshold: threshold,
                        precision: precision,
                        recall: Double(cells[1]) ?? 0,
                        wakeRate: Double(cells[2]) ?? 0,
                        truePositiveCount: Int(cells[3]) ?? 0,
                        falsePositiveCount: Int(cells[4]) ?? 0,
                        falseNegativeCount: Int(cells[5]) ?? 0,
                        trueNegativeCount: Int(cells[6]) ?? 0
                    )
                )
            } else {
                guard cells.count >= 8, let threshold = Double(cells[0]) else { continue }
                records.append(
                    ClassifierThresholdRecord(
                        threshold: threshold,
                        precision: Double(cells[1]) ?? 0,
                        recall: Double(cells[2]) ?? 0,
                        wakeRate: Double(cells[3]) ?? 0,
                        truePositiveCount: Int(cells[4]) ?? 0,
                        falsePositiveCount: Int(cells[5]) ?? 0,
                        falseNegativeCount: Int(cells[6]) ?? 0,
                        trueNegativeCount: Int(cells[7]) ?? 0
                    )
                )
            }
        }
        return records
    }

    private func readClassifierPromptVariants(_ url: URL) -> [ClassifierPromptVariantRecord] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.components(separatedBy: .newlines).compactMap { rawLine in
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 9, cells[0] != "variant" else { return nil }
            return ClassifierPromptVariantRecord(
                variant: cells[0],
                precision: Double(cells[1]) ?? 0,
                recall: Double(cells[2]) ?? 0,
                accuracy: Double(cells[3]) ?? 0,
                wakeRate: Double(cells[4]) ?? 0,
                truePositiveCount: Int(cells[5]) ?? 0,
                falsePositiveCount: Int(cells[6]) ?? 0,
                falseNegativeCount: Int(cells[7]) ?? 0,
                trueNegativeCount: Int(cells[8]) ?? 0
            )
        }
    }

    private func readClassifierModelChecks(reportDir: URL) -> [ClassifierModelCheckRecord] {
        var checks: [ClassifierModelCheckRecord] = []

        if let production = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round4-split-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Production v2",
                    shortName: "Production",
                    status: "Installed",
                    detail: "Private round-4 JSON kept as the foreground wake model.",
                    metric: production,
                    state: .ok
                )
            )
        }

        if let hardRound6 = readThresholdClassifierMetric(
            reportDir.appendingPathComponent("round6-wxyz-installed-holdout-report.md"),
            targetThreshold: 0.675
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-6 hard labels",
                    shortName: "Round 6",
                    status: "Gap found",
                    detail: "Installed model misses process-failure prompts near the gate.",
                    metric: hardRound6,
                    state: .warning
                )
            )
        }

        if let round6Candidate = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round6-holdout-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-6 retrain",
                    shortName: "R6 retrain",
                    status: "Rejected",
                    detail: "Higher recall, but below the 95% precision promotion floor.",
                    metric: round6Candidate,
                    state: .warning
                )
            )
        }

        if let round7Candidate = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round7-holdout-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-7 retrain",
                    shortName: "R7 retrain",
                    status: "Rejected",
                    detail: "TF-IDF hit the task-instruction versus process-failure boundary.",
                    metric: round7Candidate,
                    state: .warning
                )
            )
        }

        if let qwenAux = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round7-qwen-aux-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Qwen weak labels",
                    shortName: "Qwen weak",
                    status: "Rejected",
                    detail: "Weak labels made TF-IDF precise by waking on almost nothing.",
                    metric: qwenAux,
                    state: .warning
                )
            )
        }

        if let qwenPositiveAux = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round7-qwen-positive-aux-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Qwen positives",
                    shortName: "Qwen pos",
                    status: "Rejected",
                    detail: "Weak positives alone still missed nearly every held-out wake.",
                    metric: qwenPositiveAux,
                    state: .warning
                )
            )
        }

        if let hardRound8 = readThresholdClassifierMetric(
            reportDir.appendingPathComponent("round8-installed-eval-report.md"),
            targetThreshold: 0.675
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-8 hard labels",
                    shortName: "Round 8",
                    status: "Gap found",
                    detail: "Feature-boundary labels expose normal-instruction false wakes.",
                    metric: hardRound8,
                    state: .warning
                )
            )
        }

        if let round8Candidate = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round8-holdout-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-8 retrain",
                    shortName: "R8 retrain",
                    status: "Rejected",
                    detail: "TF-IDF still cannot separate task instructions from process failure.",
                    metric: round8Candidate,
                    state: .warning
                )
            )
        }

        if let twoStageGate = readTwoStageGateMetric(
            reportDir.appendingPathComponent("two-stage-gate-round8-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Two-stage gate",
                    shortName: "2-stage",
                    status: "Rejected",
                    detail: "A learned veto matched the TF-IDF ceiling instead of beating it.",
                    metric: twoStageGate,
                    state: .warning
                )
            )
        }

        if let round8ScoreEnsemble = readNamedHoldoutMetric(
            reportDir.appendingPathComponent("score-ensemble-round8-report.md"),
            metricName: "holdout best"
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-8 score ensemble",
                    shortName: "R8 ensemble",
                    status: "Rejected",
                    detail: "Stacking compact TF-IDF scorers stayed at the same hard-boundary ceiling.",
                    metric: round8ScoreEnsemble,
                    state: .warning
                )
            )
        }

        if let qwenRound8Aux = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round8-qwen-all-aux-w005-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-8 Qwen labels",
                    shortName: "R8 Qwen",
                    status: "Rejected",
                    detail: "More weak labels made the compact TF-IDF student too timid.",
                    metric: qwenRound8Aux,
                    state: .warning
                )
            )
        }

        if let distilledStudent = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("distilled-tfidf-student-round8-qwen-labels-w005-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Distilled TF-IDF student",
                    shortName: "Distill",
                    status: "Rejected",
                    detail: "Soft Qwen labels improved infrastructure, not the hard intent boundary.",
                    metric: distilledStudent,
                    state: .warning
                )
            )
        }

        if let hardRound9 = readThresholdClassifierMetric(
            reportDir.appendingPathComponent("round9-installed-eval-report.md"),
            targetThreshold: 0.675
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-9 hard labels",
                    shortName: "Round 9",
                    status: "Gap found",
                    detail: "Quoted context, revision, and agent-control labels expose the remaining intent boundary.",
                    metric: hardRound9,
                    state: .warning
                )
            )
        }

        if let round9Candidate = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round9-holdout-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-9 retrain",
                    shortName: "R9 retrain",
                    status: "Rejected",
                    detail: "Smaller TF-IDF cleared precision only by waking on almost nothing.",
                    metric: round9Candidate,
                    state: .warning
                )
            )
        }

        if let round9DistilledStudent = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("distilled-tfidf-student-round9-qwen-labels-w005-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-9 weak-teacher distill",
                    shortName: "R9 distill",
                    status: "Rejected",
                    detail: "Existing Qwen weak labels produced a small student with too little recall.",
                    metric: round9DistilledStudent,
                    state: .warning
                )
            )
        }

        if let qwen35BDistilledStudent = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("distilled-tfidf-student-qwen36-35b-nvfp4-round10-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Qwen 35B private distill",
                    shortName: "35B distill",
                    status: "Rejected",
                    detail: "Private DGX teacher labels improved coverage, but the tiny TF-IDF student still woke on too little.",
                    metric: qwen35BDistilledStudent,
                    state: .warning
                )
            )
        }

        if let qwen80BDistilledStudent = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("distilled-tfidf-student-qwen3-next-80b-fp8-round10-w002-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Qwen 80B private distill",
                    shortName: "80B distill",
                    status: "Rejected",
                    detail: "A larger private teacher improved precision cleanliness, but TF-IDF still missed most held-out wakes.",
                    metric: qwen80BDistilledStudent,
                    state: .warning
                )
            )
        }

        if let embeddingTeacherStudent = readEmbeddingTeacherStudentMetric(
            reportDir.appendingPathComponent("embedding-teacher-student-nomic-nosource-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Nomic embedding teacher-student",
                    shortName: "Nomic teach",
                    status: "Rejected",
                    detail: "Semantic embeddings plus 35B teacher labels stayed clean but missed almost every wake.",
                    metric: embeddingTeacherStudent,
                    state: .warning
                )
            )
        }

        for transformer in [
            (
                "4.39M BERT intent",
                "BERT 4M",
                "transformer-student-google-bert-l2-h128-round10-report.md",
                "Smallest transformer candidate was too blind at the deployment threshold."
            ),
            (
                "9.59M BERT intent",
                "BERT 10M",
                "transformer-student-google-bert-l2-h256-round10-report.md",
                "A wider two-layer BERT stayed precise by waking on almost nothing."
            ),
            (
                "DeBERTa xsmall intent",
                "DeBERTa",
                "transformer-student-deberta-v3-xsmall-round10-fp32-report.md",
                "DGX semantic ceiling test for the small-transformer path."
            ),
            (
                "DeBERTa hard-only intent",
                "DeBERTa hard",
                "transformer-student-deberta-v3-xsmall-hard-only-round9-fp32-report.md",
                "Hard-label-only ablation tested whether 80B pseudo-labels hurt the student."
            )
        ] {
            if let transformerMetric = readTransformerHoldoutMetric(
                reportDir.appendingPathComponent(transformer.2),
                metricName: "holdout at dev threshold"
            ) {
                let clearsGate = transformerMetric.precision >= 0.95 && transformerMetric.recall > 0.30
                checks.append(
                    classifierModelCheck(
                        name: transformer.0,
                        shortName: transformer.1,
                        status: clearsGate ? "Candidate" : "Rejected",
                        detail: transformer.3,
                        metric: transformerMetric,
                        state: clearsGate ? .ok : .warning
                    )
                )
            }
        }

        if let round8AfterRound9 = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("intent-v2-round8-after-round9-grid-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Round-8 after Round-9 train",
                    shortName: "R8+R9",
                    status: "Rejected",
                    detail: "Training on round-9 labels still failed to generalize to the round-8 boundary.",
                    metric: round8AfterRound9,
                    state: .warning
                )
            )
        }

        if let foldTrainedEnsemble = readNamedHoldoutMetric(
            reportDir.appendingPathComponent("fold-trained-and-ensemble-report.md"),
            metricName: "loro selected"
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Fold-trained ensemble",
                    shortName: "Fold AND",
                    status: "Rejected",
                    detail: "A fair fold-trained veto recovered recall but failed the precision floor.",
                    metric: foldTrainedEnsemble,
                    state: .warning
                )
            )
        }

        if let fastText = readSelectedClassifierMetric(
            reportDir.appendingPathComponent("fasttext-supervised-round8-ova-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "fastText supervised",
                    shortName: "fastText",
                    status: "Rejected",
                    detail: "Compact subword embeddings were tiny, but missed nearly every wake.",
                    metric: fastText,
                    state: .warning
                )
            )
        }

        if let createMLStatic = readSelectedThresholdMetric(
            reportDir.appendingPathComponent("createml-static-round7-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Create ML static",
                    shortName: "CML static",
                    status: "Rejected",
                    detail: "Mac-native static embedding model is small, but below precision floor.",
                    metric: createMLStatic,
                    state: .warning
                )
            )
        }

        if let createMLBERT = readSelectedThresholdMetric(
            reportDir.appendingPathComponent("createml-bert-round7-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Create ML BERT",
                    shortName: "CML BERT",
                    status: "Rejected",
                    detail: "Mac-native BERT embedding model did not beat the TF-IDF ceiling.",
                    metric: createMLBERT,
                    state: .warning
                )
            )
        }

        if let createMLMaxEnt = readSelectedThresholdMetric(
            reportDir.appendingPathComponent("createml-maxent-round7-report.md")
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Create ML maxEnt",
                    shortName: "CML maxEnt",
                    status: "Rejected",
                    detail: "Smallest Mac-native model has useful recall but too many false wakes.",
                    metric: createMLMaxEnt,
                    state: .warning
                )
            )
        }

        if let scoreEnsemble = readNamedHoldoutMetric(
            reportDir.appendingPathComponent("score-ensemble-round7-report.md"),
            metricName: "holdout at OOF threshold"
        ) {
            checks.append(
                classifierModelCheck(
                    name: "Score ensemble",
                    shortName: "Ensemble",
                    status: "Rejected",
                    detail: "Stacked TF-IDF scores did not generalize to the round-7 boundary.",
                    metric: scoreEnsemble,
                    state: .warning
                )
            )
        }

        if let nlEmbedding = readNamedHoldoutMetric(
            reportDir.appendingPathComponent("nlembedding-round7-report.md"),
            metricName: "holdout at OOF threshold"
        ) {
            checks.append(
                classifierModelCheck(
                    name: "NaturalLanguage embedding",
                    shortName: "NL embed",
                    status: "Rejected",
                    detail: "Apple sentence embeddings stayed below the precision floor.",
                    metric: nlEmbedding,
                    state: .warning
                )
            )
        }

        for baseline in [
            ("Current-label NB", "NB current", "group-holdout-nb-current-report.md"),
            ("Current-label logreg", "LR current", "group-holdout-logreg-current-report.md"),
            ("Current-label SVC", "SVC current", "group-holdout-svc-current-report.md")
        ] {
            if let currentBaseline = readGroupHoldoutBestMetric(
                reportDir.appendingPathComponent(baseline.2)
            ) {
                checks.append(
                    classifierModelCheck(
                        name: baseline.0,
                        shortName: baseline.1,
                        status: "Rejected",
                        detail: "Fresh all-label-file holdout rerun still misses the precision floor.",
                        metric: currentBaseline,
                        state: .warning
                    )
                )
            }
        }

        if let ollamaCheck = readOllamaIntentCheck(
            reportDir.appendingPathComponent("ollama-gemma3-270m-round8-smoke-report.md")
        ) {
            checks.append(ollamaCheck)
        }

        if let publicTraceCheck = readPublicTraceModelCheck(
            reportDir.appendingPathComponent("public-trace-installed-false-wake-report.md")
        ) {
            checks.append(publicTraceCheck)
        }

        return checks
    }

    private func classifierModelCheck(
        name: String,
        shortName: String,
        status: String,
        detail: String,
        metric: ParsedClassifierMetric,
        state: HealthState
    ) -> ClassifierModelCheckRecord {
        ClassifierModelCheckRecord(
            name: name,
            shortName: shortName,
            status: status,
            detail: detail,
            threshold: metric.threshold,
            precision: metric.precision,
            recall: metric.recall,
            wakeRate: metric.wakeRate,
            truePositiveCount: metric.truePositiveCount,
            falsePositiveCount: metric.falsePositiveCount,
            falseNegativeCount: metric.falseNegativeCount,
            trueNegativeCount: metric.trueNegativeCount,
            wakeCount: nil,
            rowCount: metric.rowCount,
            maxScore: nil,
            state: state
        )
    }

    private func readSelectedClassifierMetric(_ url: URL) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var selectedThreshold: Double?
        var inSelectedMetrics = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("Selected threshold:") {
                selectedThreshold = Double(rawLine.replacingOccurrences(of: "Selected threshold:", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }
            if rawLine.hasPrefix("## ") {
                inSelectedMetrics = rawLine.contains("Selected Group-Holdout Metrics")
                    || rawLine.contains("Selected Holdout Metrics")
                continue
            }
            guard inSelectedMetrics, let selectedThreshold else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 7,
                  let precision = Double(cells[0]),
                  let recall = Double(cells[1]),
                  let wakeRate = Double(cells[2]),
                  let truePositiveCount = Int(cells[3]),
                  let falsePositiveCount = Int(cells[4]),
                  let falseNegativeCount = Int(cells[5]),
                  let trueNegativeCount = Int(cells[6])
            else { continue }
            return ParsedClassifierMetric(
                threshold: selectedThreshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readSelectedThresholdMetric(_ url: URL) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inSelectedMetrics = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inSelectedMetrics = rawLine.contains("Selected Holdout Metric")
                continue
            }
            guard inSelectedMetrics else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 8,
                  let threshold = Double(cells[0]),
                  let precision = Double(cells[1]),
                  let recall = Double(cells[2]),
                  let wakeRate = Double(cells[3]),
                  let truePositiveCount = Int(cells[4]),
                  let falsePositiveCount = Int(cells[5]),
                  let falseNegativeCount = Int(cells[6]),
                  let trueNegativeCount = Int(cells[7])
            else { continue }
            return ParsedClassifierMetric(
                threshold: threshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readNamedHoldoutMetric(_ url: URL, metricName: String) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inHoldout = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inHoldout = rawLine.contains("Round-7 Holdout") || rawLine == "## Holdout"
                continue
            }
            guard inHoldout else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 9,
                  cells[0] == metricName,
                  let threshold = Double(cells[1]),
                  let precision = Double(cells[2]),
                  let recall = Double(cells[3]),
                  let wakeRate = Double(cells[4]),
                  let truePositiveCount = Int(cells[5]),
                  let falsePositiveCount = Int(cells[6]),
                  let falseNegativeCount = Int(cells[7]),
                  let trueNegativeCount = Int(cells[8])
            else { continue }
            return ParsedClassifierMetric(
                threshold: threshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readEmbeddingTeacherStudentMetric(_ url: URL) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inBest = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inBest = rawLine == "## Best"
                continue
            }
            guard inBest else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 10,
                  let threshold = Double(cells[2]),
                  let precision = Double(cells[3]),
                  let recall = Double(cells[4]),
                  let wakeRate = Double(cells[5]),
                  let truePositiveCount = Int(cells[6]),
                  let falsePositiveCount = Int(cells[7]),
                  let falseNegativeCount = Int(cells[8]),
                  let trueNegativeCount = Int(cells[9])
            else { continue }
            return ParsedClassifierMetric(
                threshold: threshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readGroupHoldoutBestMetric(_ url: URL) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inThresholds = false
        var best: ParsedClassifierMetric?
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inThresholds = rawLine.trimmingCharacters(in: .whitespacesAndNewlines) == "## Overall Thresholds"
                continue
            }
            guard inThresholds else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 8,
                  let threshold = Double(cells[0]),
                  let precision = Double(cells[1]),
                  let recall = Double(cells[2]),
                  let wakeRate = Double(cells[3]),
                  let truePositiveCount = Int(cells[4]),
                  let falsePositiveCount = Int(cells[5]),
                  let falseNegativeCount = Int(cells[6]),
                  let trueNegativeCount = Int(cells[7])
            else { continue }
            let metric = ParsedClassifierMetric(
                threshold: threshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
            if best == nil
                || metric.precision > best!.precision
                || (metric.precision == best!.precision && metric.recall > best!.recall) {
                best = metric
            }
        }
        return best
    }

    private func readTransformerHoldoutMetric(_ url: URL, metricName: String) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inMetrics = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inMetrics = rawLine.trimmingCharacters(in: .whitespacesAndNewlines) == "## Metrics"
                continue
            }
            guard inMetrics else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 9,
                  cells[0] == metricName,
                  let threshold = Double(cells[1]),
                  let precision = Double(cells[2]),
                  let recall = Double(cells[3]),
                  let wakeRate = Double(cells[4]),
                  let truePositiveCount = Int(cells[5]),
                  let falsePositiveCount = Int(cells[6]),
                  let falseNegativeCount = Int(cells[7]),
                  let trueNegativeCount = Int(cells[8])
            else { continue }
            return ParsedClassifierMetric(
                threshold: threshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readTwoStageGateMetric(_ url: URL) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inSelected = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inSelected = rawLine.contains("Selected Holdout Metric")
                continue
            }
            guard inSelected else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 9,
                  let gateThreshold = Double(cells[1]),
                  let precision = Double(cells[2]),
                  let recall = Double(cells[3]),
                  let wakeRate = Double(cells[4]),
                  let truePositiveCount = Int(cells[5]),
                  let falsePositiveCount = Int(cells[6]),
                  let falseNegativeCount = Int(cells[7]),
                  let trueNegativeCount = Int(cells[8])
            else { continue }
            return ParsedClassifierMetric(
                threshold: gateThreshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readOllamaIntentCheck(_ url: URL) -> ClassifierModelCheckRecord? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var rowCount: Int?
        var inMetrics = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("Rows:") {
                rowCount = Int(rawLine.replacingOccurrences(of: "Rows:", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }
            if rawLine.hasPrefix("## ") {
                inMetrics = rawLine.trimmingCharacters(in: .whitespacesAndNewlines) == "## Metrics"
                continue
            }
            guard inMetrics else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 8,
                  let precision = Double(cells[0]),
                  let recall = Double(cells[1]),
                  let wakeRate = Double(cells[2]),
                  let truePositiveCount = Int(cells[3]),
                  let falsePositiveCount = Int(cells[4]),
                  let falseNegativeCount = Int(cells[5]),
                  let trueNegativeCount = Int(cells[6])
            else { continue }
            return ClassifierModelCheckRecord(
                name: "Ollama Gemma 270M",
                shortName: "Gemma 270M",
                status: "Rejected",
                detail: "Tiny local LLM over-triggered and returned invalid JSON in smoke testing.",
                threshold: nil,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                wakeCount: nil,
                rowCount: rowCount ?? truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount,
                maxScore: nil,
                state: .warning
            )
        }
        return nil
    }

    private func readThresholdClassifierMetric(_ url: URL, targetThreshold: Double) -> ParsedClassifierMetric? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var inMetrics = false
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("## ") {
                inMetrics = rawLine.trimmingCharacters(in: .whitespacesAndNewlines) == "## Metrics"
                continue
            }
            guard inMetrics else { continue }
            let cells = markdownTableCells(rawLine)
            guard cells.count >= 8,
                  let threshold = Double(cells[0]),
                  abs(threshold - targetThreshold) < 0.0005,
                  let precision = Double(cells[1]),
                  let recall = Double(cells[2]),
                  let wakeRate = Double(cells[3]),
                  let truePositiveCount = Int(cells[4]),
                  let falsePositiveCount = Int(cells[5]),
                  let falseNegativeCount = Int(cells[6]),
                  let trueNegativeCount = Int(cells[7])
            else { continue }
            return ParsedClassifierMetric(
                threshold: threshold,
                precision: precision,
                recall: recall,
                wakeRate: wakeRate,
                truePositiveCount: truePositiveCount,
                falsePositiveCount: falsePositiveCount,
                falseNegativeCount: falseNegativeCount,
                trueNegativeCount: trueNegativeCount,
                rowCount: truePositiveCount + falsePositiveCount + falseNegativeCount + trueNegativeCount
            )
        }
        return nil
    }

    private func readPublicTraceModelCheck(_ url: URL) -> ClassifierModelCheckRecord? {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var rows: Int?
        var modelThreshold: Double?
        var wakeCount: Int?
        var maxScore: Double?
        var tableKind: String?

        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("Rows:") {
                rows = Int(rawLine.replacingOccurrences(of: "Rows:", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }
            if rawLine.hasPrefix("Model threshold:") {
                modelThreshold = Double(rawLine.replacingOccurrences(of: "Model threshold:", with: "").trimmingCharacters(in: .whitespaces))
                continue
            }
            if rawLine.hasPrefix("## ") {
                if rawLine.contains("Wake Counts") {
                    tableKind = "wake-counts"
                } else if rawLine.contains("Score Quantiles") {
                    tableKind = "quantiles"
                } else {
                    tableKind = nil
                }
                continue
            }

            let cells = markdownTableCells(rawLine)
            if tableKind == "wake-counts", cells.count >= 3,
               let threshold = Double(cells[0]),
               abs(threshold - (modelThreshold ?? 0.675)) < 0.0005 {
                wakeCount = Int(cells[1])
            } else if tableKind == "quantiles", cells.count >= 2, cells[0] == "1.00" {
                maxScore = Double(cells[1])
            }
        }

        guard let rows, let wakeCount else { return nil }
        return ClassifierModelCheckRecord(
            name: "Public trace control",
            shortName: "Public traces",
            status: wakeCount == 0 ? "Passed" : "Review",
            detail: "External coding-agent prompts used as false-wake controls.",
            threshold: modelThreshold,
            precision: nil,
            recall: nil,
            wakeRate: rows > 0 ? Double(wakeCount) / Double(rows) : nil,
            truePositiveCount: nil,
            falsePositiveCount: nil,
            falseNegativeCount: nil,
            trueNegativeCount: nil,
            wakeCount: wakeCount,
            rowCount: rows,
            maxScore: maxScore,
            state: wakeCount == 0 ? .ok : .warning
        )
    }

    private func markdownTableCells(_ rawLine: String) -> [String] {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return [] }
        let cells = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if cells.contains(where: { $0.contains("---") }) { return [] }
        return cells
    }

    private func runDidChange(_ run: TriggerRunRecord) -> Bool {
        !run.surfaceDiffs.isEmpty || run.reflectorSummary?.didChange == true
    }

    private func readTriggerEvents() -> [TriggerEventRecord] {
        let url = feedbackURL.appendingPathComponent("events.jsonl")
        return readJSONLines(url).enumerated().map { index, object in
            let timestamp = object["ts"] as? String ?? ""
            let sessionID = object["session_id"] as? String ?? "unknown"
            let transcriptLine = intValue(object["transcript_line"])
            let classifier = object["classifier"] as? [String: Any] ?? [:]
            let id = object["dedupe_key"] as? String
                ?? "\(timestamp)-\(sessionID)-\(transcriptLine ?? index)"
            return TriggerEventRecord(
                id: id,
                eventID: object["event_id"] as? String ?? id,
                messageLocator: object["message_locator"] as? String ?? "",
                dedupeKey: object["dedupe_key"] as? String ?? "",
                timestampValue: timestamp,
                timestampText: friendlyTimestamp(timestamp),
                version: object["version"] as? String ?? "unknown",
                triggered: object["triggered"] as? Bool ?? false,
                reviewTriggered: object["review_triggered"] as? Bool ?? false,
                wakeReason: object["wake_reason"] as? String ?? "",
                sessionID: sessionID,
                cwd: object["cwd"] as? String ?? "",
                transcriptPath: object["transcript_path"] as? String ?? "",
                transcriptLine: transcriptLine,
                matched: object["matched"] as? [String] ?? [],
                snippet: object["snippet"] as? String ?? "",
                source: object["source"] as? String ?? "hook",
                sentimentScore: sentimentScore(for: object["snippet"] as? String ?? ""),
                classifierScore: doubleValue(classifier["score"]),
                classifierThreshold: doubleValue(classifier["threshold"]),
                classifierReviewThreshold: doubleValue(classifier["review_threshold"]),
                classifierModelType: classifier["model_type"] as? String,
                classifierExplanations: readClassifierExplanations(classifier["explanations"]),
                classifierAlternates: readClassifierAlternates(classifier["alternates"])
            )
        }
    }

    private func readClassifierExplanations(_ value: Any?) -> [ClassifierExplanationRecord] {
        let rows = value as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { index, row in
            guard let contribution = doubleValue(row["contribution"]) else { return nil }
            let feature = (row["feature"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { return nil }
            let kind = row["kind"] as? String ?? "feature"
            return ClassifierExplanationRecord(
                id: "\(index)-\(kind)-\(feature)",
                kind: kind,
                feature: feature,
                contribution: contribution
            )
        }
    }

    private func readClassifierAlternates(_ value: Any?) -> [ClassifierAlternateRecord] {
        let rows = value as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { index, row in
            let rawName = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.isEmpty ? "candidate \(index + 1)" : rawName
            return ClassifierAlternateRecord(
                id: "\(index)-\(name)",
                name: name,
                score: doubleValue(row["score"]),
                threshold: doubleValue(row["threshold"]),
                reviewThreshold: doubleValue(row["review_threshold"]),
                triggered: row["triggered"] as? Bool ?? false,
                review: row["review"] as? Bool ?? false,
                modelType: row["model_type"] as? String,
                error: row["error"] as? String
            )
        }
    }

    private func readTriggerBatches() -> [TriggerBatchRecord] {
        let url = feedbackURL.appendingPathComponent("reflector-batches.jsonl")
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
        let url = feedbackURL.appendingPathComponent("reflector.log")
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
        case "home_memory":
            return "Home memory"
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
        case "home_memory":
            return "Updated home memory\(suffix)"
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
        case "home_memory":
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

    private static let sentimentTagger = NLTagger(tagSchemes: [.sentimentScore])
    private var sentimentCache: [String: Double?] = [:]

    private func sentimentScore(for text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = sentimentCache[trimmed] { return cached }
        let tagger = Self.sentimentTagger
        tagger.string = trimmed
        let (tag, _) = tagger.tag(at: trimmed.startIndex, unit: .paragraph, scheme: .sentimentScore)
        let score = tag.flatMap { Double($0.rawValue) }
        sentimentCache[trimmed] = score
        return score
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

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
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
    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
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

    private var wakeThresholdSetting: String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clampedWakeCustomThreshold)
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
            process.environment = ProcessInfo.processInfo.environment.merging([
                "PYTHONDONTWRITEBYTECODE": "1"
            ]) { current, _ in current }
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
