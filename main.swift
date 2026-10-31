// 梦游 Sleepwalk：让 MacBook 合上盖子也继续运行（pmset disablesleep）。
// 菜单栏：左键弹出面板，再点一下收起；右键菜单。面板是液态玻璃：一台玻璃笔记本，醒时盖子张开、背后亮起暖光。
// Copyright (c) 2026 Haoli. MIT License.
import AppKit
import SwiftUI
import Combine
import IOKit

// 系统首选语言是中文就用中文，其余一律英文
let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
let appName = L("梦游", "Sleepwalk")

// MARK: - 状态

final class LidModel: ObservableObject {
    @Published var isOn = false
    @Published var onBattery = false
    @Published var battery: Int?
    @Published var remaining: String?
    @Published var passwordless = false
    // 正在等管理员密码或执行命令：这期间开关不可点，面板也不因失焦收起
    @Published var busy = false
    // 面板收起后暖光不再呼吸，省电
    @Published var panelVisible = false

    // 每个用户一份规则，互不覆盖
    static let ruleFile = "/etc/sudoers.d/sleepwalk-\(getuid())"

    // 记住“合上继续跑”是本 app 打开的。正常退出会恢复并清掉；强制退出、崩溃、
    // 无免密规则时注销关机会留下它，下次启动据此提醒（见 AppDelegate.checkLeftOn）。
    // 标记按用户存，只提醒打开它的那个用户；app 不是登录项，要再打开一次才会提醒
    static let leftOnKey = "SleepwalkTurnedOn"
    static var leftOn: Bool {
        get { UserDefaults.standard.bool(forKey: leftOnKey) }
        set { UserDefaults.standard.set(newValue, forKey: leftOnKey) }
    }

    // 本 app 打开成功就记下（清除在 refresh 里）
    private func noteResult(_ on: Bool) {
        if on && isOn { Self.leftOn = true }
    }

    func refresh() {
        let general = Self.output("/usr/bin/pmset", ["-g"])
        update(\.isOn, general.split(separator: "\n").contains {
            $0.contains("SleepDisabled") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        })
        let batt = Self.output("/usr/bin/pmset", ["-g", "batt"])
        update(\.onBattery, batt.contains("'Battery Power'"))
        if let r = batt.range(of: #"\d+%"#, options: .regularExpression) {
            update(\.battery, Int(batt[r].dropLast()))
        }
        // pmset 给的是剩余时长 "17:09"（17 小时 9 分），不是时刻；换成不会看错的写法
        let hm = batt.range(of: #"\d+:\d+(?= remaining)"#, options: .regularExpression)
            .map { batt[$0].split(separator: ":").compactMap { Int($0) } } ?? []
        var text: String?
        if hm.count == 2, hm[0] + hm[1] > 0 {
            let hours = hm[0] + (hm[1] >= 30 ? 1 : 0)
            text = hm[0] == 0 ? L("剩余 \(hm[1]) 分钟", "\(hm[1])m left") : L("剩余约 \(hours) 小时", "~\(hours)h left")
        }
        update(\.remaining, text)
        update(\.passwordless, FileManager.default.fileExists(atPath: Self.ruleFile))
        // 只要看到已恢复正常睡眠（不论谁恢复的）就清掉标记
        if !isOn && Self.leftOn { Self.leftOn = false }
    }

    // 只在值变了时才写，免得每 5 秒无故重绘
    private func update<T: Equatable>(_ key: ReferenceWritableKeyPath<LidModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    func toggle() {
        refresh()
        set(!isOn)
    }

    // 有免密规则就直接切换；没有就弹系统密码框。密码框在后台进程里，不卡界面
    func set(_ on: Bool, done: (() -> Void)? = nil) {
        guard !busy else { return }
        // 先读真实状态：已经是目标值就不弹密码框，免得取消密码框时把别人开的误记成本 app 开的
        refresh()
        if isOn == on {
            done?()
            return
        }
        if setWithoutPrompt(on) {
            done?()
            return
        }
        runPrivileged("/usr/bin/pmset -a disablesleep \(on ? 1 : 0)") { [weak self] in
            self?.noteResult(on)
            done?()
        }
    }

    // 只走免密规则，不弹任何框（注销、关机途中用）；返回是否成功
    @discardableResult
    func setWithoutPrompt(_ on: Bool) -> Bool {
        let ok = Self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]) == 0
        refresh()
        if ok { noteResult(on) }
        return ok
    }

    // 只有带盖子的 Mac（MacBook）才有 AppleClamshellState
    static var hasLid: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }

    // 只允许免密执行 pmset -a disablesleep 0/1。
    // 临时文件写在只有 root 能写的 sudoers.d 里（文件名带点，sudo 会跳过它），visudo 校验通过后原子改名，
    // 不经过 /tmp，别的程序没有机会抢先占位或中途改内容
    func installPasswordless() {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil else {
            Self.showError(L("用户名里有特殊字符，没法安全地写进规则。", "Your user name has characters that can't be written into the rule safely."))
            return
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let tmp = Self.ruleFile + ".tmp"
        runPrivileged("umask 077; printf '%s\\n' '\(rule)' > \(tmp) && /usr/sbin/visudo -cf \(tmp) && /usr/sbin/chown root:wheel \(tmp) && /bin/chmod 440 \(tmp) && /bin/mv -f \(tmp) \(Self.ruleFile); rc=$?; /bin/rm -f \(tmp); exit $rc")
    }

    func removePasswordless() {
        runPrivileged("/bin/rm -f \(Self.ruleFile)")
    }

    private func runPrivileged(_ command: String, done: (() -> Void)? = nil) {
        busy = true
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = Self.runAsAdmin(command)
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if let failure { Self.showError(failure) }
                done?()
            }
        }
    }

    // 用 osascript 弹系统的管理员密码框。成功或用户取消返回 nil，其余返回错误信息
    static func runAsAdmin(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "osascript" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 || message.contains("(-128)") ? nil : message
    }

    static func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("没有完成", "That didn't work")
        alert.informativeText = message
        alert.runModal()
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func output(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - 面板：液态玻璃

let amber = Color(red: 1, green: 0.624, blue: 0.18)

// 一条玻璃：白色渐变加亮边，像一根有厚度的玻璃棒
struct GlassBar: View {
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        shape
            .fill(LinearGradient(stops: [.init(color: .white.opacity(0.62), location: 0),
                                         .init(color: .white.opacity(0.18), location: 0.55),
                                         .init(color: .white.opacity(0.30), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(.white.opacity(0.7), lineWidth: 0.5))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.18), radius: 7, y: 6)
    }
}

// 玻璃笔记本：眠时合着，醒时盖子张开、背后亮起一团会呼吸的暖光。
// 只有一个数 open（0 合上，1 张开）在做动画，盖子角度、暖光、倒影都从它算出来，所以永远同步
struct LaptopTile: View, Animatable {
    var open: Double
    var breathing = true

    var animatableData: Double {
        get { open }
        set { open = newValue }
    }

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 18, style: .continuous)
        // 盖子先抬起一点，光才从缝里透出来
        let light = min(max((open - 0.2) / 0.8, 0), 1)
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: light < 0.01 || !breathing)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let breath = (1 - cos(t / 4.8 * 2 * .pi)) / 2
                Ellipse()
                    .fill(RadialGradient(stops: [.init(color: Color(red: 1, green: 0.69, blue: 0.31).opacity(0.85), location: 0),
                                                 .init(color: Color(red: 1, green: 0.55, blue: 0.2).opacity(0.25), location: 0.55),
                                                 .init(color: .clear, location: 1)],
                                         center: .center, startRadius: 0, endRadius: 60))
                    .frame(width: 190, height: 120)
                    .scaleEffect((0.85 + 0.15 * light) * (1 + 0.06 * breath))
                    .blur(radius: 10 + 2 * breath)
                    .brightness(0.15 * breath)
            }
            .offset(x: 150, y: 30)
            .opacity(light)

            // 桌面上的倒影：眠时是一点白，醒时渐渐换成偏右的暖色
            reflection(.white.opacity(0.12), center: 0.5).opacity(1 - light)
            reflection(Color(red: 1, green: 0.67, blue: 0.31).opacity(0.45), center: 0.8).opacity(light)

            GlassBar(width: 208, height: 13).offset(x: 34, y: 104)
            GlassBar(width: 204, height: 10)
                .rotationEffect(.degrees(-13 * open), anchor: UnitPoint(x: 4 / 204, y: 0.5))
                .offset(x: 36, y: 92)
        }
        .frame(width: 276, height: 156, alignment: .topLeading)
        .background(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
        .overlay(tile.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        .clipShape(tile)
        .contentShape(tile)
    }

    private func reflection(_ color: Color, center: Double) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [color, .clear], center: UnitPoint(x: center, y: 0.5), startRadius: 0, endRadius: 108))
            .frame(width: 216, height: 18)
            .offset(x: 30, y: 124)
    }
}

// 这套工具链没有 SwiftUI 宏插件，用不了 @State，指针位置放在一个小对象里
final class Hover: ObservableObject {
    @Published var point: CGPoint?
}

struct PanelView: View {
    @ObservedObject var model: LidModel
    static let width: CGFloat = 300
    @StateObject private var hover = Hover()

    var body: some View {
        let on = model.isOn
        VStack(spacing: 0) {
            LaptopTile(open: on ? 1 : 0, breathing: model.panelVisible)
                // 张开时慢慢抬起、轻轻落定；合上时干脆地落下
                .animation(on ? .spring(response: 0.85, dampingFraction: 0.86)
                              : .timingCurve(0.45, 0, 0.6, 1, duration: 0.55), value: on)
                .onTapGesture { if !model.busy { model.toggle() } }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // 标题就是状态，随开关切换
                    Text(on ? L("合上继续跑", "Awake when closed") : L("合上即睡", "Sleeps when closed"))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(on ? L("合盖后程序、下载、agent 都不停", "Agents keep running")
                            : L("打开开关，合盖后也继续运行", "Turn on to keep it running"))
                        .lineLimit(1)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                    // 只让 Mac 醒着，不管联网：断了网，调用云端模型的 agent 照样会停
                    if on {
                        Text(L("前提是 Wi-Fi 没断", "As long as Wi-Fi stays on"))
                            .lineLimit(1)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isOn }, set: { model.set($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(amber)
                    .disabled(model.busy)
            }
            .padding(EdgeInsets(top: 14, leading: 6, bottom: 12, trailing: 6))

            VStack(spacing: 0) {
                row(L("免密码切换", "Switch Without Password")) {
                    // 可选：打开要输一次密码装规则，关掉也要输一次密码删规则
                    Toggle("", isOn: Binding(get: { model.passwordless },
                                             set: { $0 ? model.installPasswordless() : model.removePasswordless() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .tint(amber)
                        .disabled(model.busy)
                }
            }
            .background(.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 2)

            HStack(spacing: 6) {
                Image(systemName: batterySymbol)
                Text(powerText).lineLimit(1)
                if on && model.onBattery {
                    Text(L("· 仍在耗电", "· Drains battery")).foregroundStyle(Color(red: 1, green: 0.7, blue: 0.36))
                }
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
            .padding(EdgeInsets(top: 12, leading: 8, bottom: 2, trailing: 8))
        }
        .padding(12)
        .frame(width: Self.width)
        .foregroundStyle(.white)
        .background(Color(red: 0.11, green: 0.118, blue: 0.18).opacity(0.26))
        // 一块跟着指针走的柔光，像玻璃表面的反光
        .background(alignment: .topLeading) {
            if let g = hover.point {
                Ellipse()
                    .fill(RadialGradient(colors: [.white.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 140))
                    .frame(width: 360, height: 240)
                    .position(g)
            }
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover.point = p } else { hover.point = nil }
        }
        .animation(.easeInOut(duration: 0.4), value: on)
    }

    private func row<V: View>(_ title: String, @ViewBuilder trailing: () -> V) -> some View {
        HStack {
            Text(title)
            Spacer()
            trailing()
        }
        .font(.system(size: 13))
        .frame(height: 38)
        .padding(.horizontal, 12)
    }

    private var batterySymbol: String {
        guard let b = model.battery else { return "powerplug" }
        let level = b > 87 ? 100 : b > 62 ? 75 : b > 37 ? 50 : b > 12 ? 25 : 0
        return "battery.\(level)percent"
    }

    private var powerText: String {
        let level = model.battery.map { "\($0)%" } ?? ""
        guard model.onBattery else { return "\(level) · " + L("接着电源", "On power") }
        return model.remaining.map { "\(level) · \($0)" } ?? level
    }
}

// 无边框的小窗：点别处或按 Esc 就收起，像菜单栏弹出的面板
final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { (delegate as? AppDelegate)?.hidePanel() }
}

// MARK: - 菜单栏与窗口

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = LidModel()
    private var item: NSStatusItem!
    private let glow = CALayer()
    private var window: NSWindow?
    private var panelHost: NSView?
    private var hiddenAt = Date.distantPast
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var keepAwakeOnQuit = false

    // 图标画布尺寸，以及光点在画布里的位置（左下角为原点）
    private static let iconSize = NSSize(width: 22, height: 18)
    private static let dotInIcon = CGPoint(x: 16.6, y: 7.9)
    private static let amberNS = NSColor(calibratedRed: 1.0, green: 0.71, blue: 0.32, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 已经有一个在跑（比如从别处又打开了一份）：这一份直接退出，不碰睡眠设置
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            keepAwakeOnQuit = true
            NSApp.terminate(nil)
            return
        }
        guard LidModel.hasLid else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("梦游只适用于 MacBook", "Sleepwalk is for MacBooks only")
            alert.informativeText = L("这台 Mac 没有可以合上的盖子。", "This Mac has no lid to close.")
            alert.runModal()
            keepAwakeOnQuit = true
            NSApp.terminate(nil)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = item.button else { return }
        button.image = Self.lidImage()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.wantsLayer = true

        glow.bounds = CGRect(x: 0, y: 0, width: 3.4, height: 3.4)
        glow.cornerRadius = 1.7
        glow.backgroundColor = Self.amberNS.cgColor
        glow.shadowColor = Self.amberNS.cgColor
        glow.shadowRadius = 3.5
        glow.shadowOpacity = 1
        glow.shadowOffset = .zero
        glow.isHidden = true
        button.layer?.addSublayer(glow)

        model.$isOn.sink { [weak self] on in self?.applyIcon(on) }.store(in: &cancellables)
        // 打开时多一行 Wi-Fi 提示：面板跟着改高度，顶边不动
        model.$isOn.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanel() }
        }.store(in: &cancellables)
        // 密码框关掉后把面板重新设为焦点，之后点别处它才会照常收起
        model.$busy.dropFirst().filter { !$0 }.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let w = self?.window, w.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                w.makeKey()
            }
        }.store(in: &cancellables)
        // 切到别的 app 时也收起（有时面板没拿到焦点，收不到失焦通知）
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.model.busy else { return }
            self.hidePanel()
        }
        model.refresh()
        checkLeftOn()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.model.refresh()
        }
        showPanel()
    }

    // 退出默认恢复正常睡眠，免得忘了它还开着。正常退出（菜单、⌘Q、活动监视器的“退出”、注销关机）经过这里；
    // 强制退出和崩溃不经过这里，由下次启动时的 checkLeftOn 兜底。
    // 有免密规则就直接恢复；没有就弹密码框。注销、关机途中不能弹框，只能试免密，失败也由 checkLeftOn 兜底。
    // 恢复失败（比如取消了密码框）就说明后果，让用户决定还退不退
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if keepAwakeOnQuit { return .terminateNow }
        model.refresh()
        guard model.isOn else { return .terminateNow }
        if model.setWithoutPrompt(false) || isSessionEnding { return .terminateNow }
        guard !model.busy else {
            NSSound.beep()
            return .terminateCancel
        }
        model.set(false) { [weak self] in
            guard let self else { return }
            let quit = !self.model.isOn || self.confirmQuitWhileOn()
            // 看过提示仍然退出，算有意保留，下次启动不再提醒
            if quit && self.model.isOn { LidModel.leftOn = false }
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    // 这次退出是不是注销、重启或关机
    private var isSessionEnding: Bool {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }

    private func confirmQuitWhileOn() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("正常睡眠没有恢复", "Normal sleep was not restored")
        alert.informativeText = L("合上继续跑还开着。现在退出，它会一直生效，重启后也是。",
                                  "Awake when closed is still on. If you quit now, it stays on, even after a restart.")
        alert.addButton(withTitle: L("不退出", "Don't Quit"))
        alert.addButton(withTitle: L("仍然退出", "Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func quitRestoringSleep() {
        NSApp.terminate(nil)
    }

    @objc private func quitKeepingAwake() {
        keepAwakeOnQuit = true
        LidModel.leftOn = false
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: L("Haoli 设计与制作\nMIT 许可证", "Designed and made by Haoli\nMIT License"),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: appName, .credits: credits])
    }

    // 上次是本 app 打开的“合上继续跑”，却没正常恢复就退出了（强制退出、崩溃、注销关机）：问用户怎么办。
    // 这里不弹密码框，只有用户选“恢复睡眠”才走 set(false)（有免密规则就不用输密码）
    private func checkLeftOn() {
        guard model.isOn else { LidModel.leftOn = false; return }
        guard LidModel.leftOn else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("上次没有正常退出", "Sleepwalk didn't quit normally last time")
        alert.informativeText = L("合上继续跑还开着，合盖后 Mac 不会睡眠。要恢复正常睡眠吗？",
                                  "Awake when closed is still on, so your Mac won't sleep when closed. Restore normal sleep?")
        alert.addButton(withTitle: L("恢复睡眠", "Restore Sleep"))
        alert.addButton(withTitle: L("保持开启", "Keep It On"))
        if alert.runModal() == .alertFirstButtonReturn {
            model.set(false)
        } else {
            LidModel.leftOn = false
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // 像托盘应用那样：点图标弹出，再点一下收起
    private func togglePanel() {
        if window?.isVisible == true {
            hidePanel()
        } else if Date().timeIntervalSince(hiddenAt) > 0.3 {
            // 刚因为这次点击失焦收起的，不要马上又弹出来
            showPanel()
        }
    }

    @objc private func showPanel() {
        if window == nil {
            let hosting = NSHostingView(rootView: PanelView(model: model))
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: size)
            let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .popUpMenu
            w.isReleasedWhenClosed = false
            w.delegate = self
            // 在当前桌面（包括全屏 app 的桌面）弹出
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.contentView = Self.glass(around: hosting) ?? Self.frosted(around: hosting)
            window = w
            panelHost = hosting
        }
        guard let w = window else { return }
        model.refresh()
        let target = panelOrigin(for: w.frame.size)
        // 从图标下方轻轻落下并淡入
        w.alphaValue = 0
        w.setFrameOrigin(NSPoint(x: target.x, y: target.y + 6))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.panelVisible = true
        item.button?.highlight(true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
            w.animator().setFrameOrigin(target)
        }
    }

    // macOS 26 起的液态玻璃。按类名在运行时查找，用旧 SDK 也能编译；
    // style 1 是 .clear
    private static func glass(around content: NSView) -> NSView? {
        guard let type = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let glass = type.init(frame: content.frame)
        glass.setValue(1, forKey: "style")
        glass.setValue(26, forKey: "cornerRadius")
        glass.setValue(content, forKey: "contentView")
        return glass
    }

    // 更早的系统用磨砂
    private static func frosted(around content: NSView) -> NSView {
        let blur = NSVisualEffectView(frame: content.frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 26
        blur.layer?.masksToBounds = true
        blur.addSubview(content)
        return blur
    }

    func hidePanel() {
        guard let w = window, w.isVisible else { return }
        hiddenAt = Date()
        item.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 0
        }, completionHandler: {
            if w.alphaValue < 0.01 {
                w.orderOut(nil)
                self.model.panelVisible = false
            }
        })
    }

    // 挂在菜单栏图标正下方，靠右不出屏
    private func fitPanel() {
        guard let w = window, let host = panelHost else { return }
        let size = host.fittingSize
        guard abs(size.height - w.frame.height) > 0.5 else { return }
        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        host.frame = NSRect(origin: .zero, size: size)
    }

    private func panelOrigin(for size: NSSize) -> NSPoint {
        // 刚启动时图标窗口可能还没摆好（frame 在原点附近），这时退回到屏幕右上角
        guard let screen = item.button?.window?.screen ?? NSScreen.main else { return .zero }
        let area = screen.visibleFrame
        var x = area.maxX - size.width - 10
        if let icon = item.button?.window?.frame, screen.frame.contains(icon.origin), icon.minX > screen.frame.minX + 1 {
            x = min(icon.midX - size.width / 2, x)
        }
        return NSPoint(x: max(area.minX + 10, x), y: area.maxY - size.height - 6)
    }

    func windowDidResignKey(_ notification: Notification) {
        // 弹出密码框时面板会失焦，这时不收起
        guard !model.busy else { return }
        hidePanel()
    }

    // 半合的笔记本侧影：底座 + 微微张开的盖子，铰链在左
    private static func lidImage() -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 4, width: 18, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()

            let lid = NSBezierPath(roundedRect: NSRect(x: 0, y: -0.8, width: 16.6, height: 1.6), xRadius: 0.8, yRadius: 0.8)
            var t = AffineTransform(translationByX: 3, byY: 7)
            t.rotate(byDegrees: 13)
            lid.transform(using: t)
            lid.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func clicked() {
        // 右键或 Control-点按弹出菜单
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func applyIcon(_ on: Bool) {
        guard let button = item.button else { return }
        button.toolTip = on ? L("合上继续跑", "Awake when closed") : L("合上即睡", "Sleeps when closed")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = button.bounds
        let x = (b.width - Self.iconSize.width) / 2 + Self.dotInIcon.x
        let yFromBottom = (b.height - Self.iconSize.height) / 2 + Self.dotInIcon.y
        glow.position = CGPoint(x: x, y: button.isFlipped ? b.height - yFromBottom : yFromBottom)
        glow.isHidden = !on
        CATransaction.commit()

        if on, glow.animation(forKey: "breathe") == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.25
            breathe.toValue = 1.0
            breathe.duration = 1.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(breathe, forKey: "breathe")
        } else if !on {
            glow.removeAnimation(forKey: "breathe")
        }
    }

    @objc private func togglePasswordless() {
        model.passwordless ? model.removePasswordless() : model.installPasswordless()
    }

    private func showMenu() {
        model.refresh()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: model.isOn ? L("现在：合上继续跑", "Now: awake when closed")
                                                  : L("现在：合上即睡", "Now: sleeps when closed"),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let panel = NSMenuItem(title: L("打开面板…", "Open Panel…"), action: #selector(showPanel), keyEquivalent: "")
        panel.target = self
        menu.addItem(panel)
        menu.addItem(.separator())

        let rule = NSMenuItem(title: L("免密码切换", "Switch Without Password"),
                              action: #selector(togglePasswordless), keyEquivalent: "")
        rule.target = self
        rule.state = model.passwordless ? .on : .off
        rule.isEnabled = !model.busy
        menu.addItem(rule)
        menu.addItem(.separator())

        let about = NSMenuItem(title: L("关于梦游", "About Sleepwalk"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        // 默认退出会恢复睡眠；按住 Option 换成“退出并保持醒着”
        let quit = NSMenuItem(title: L("退出（恢复正常睡眠）", "Quit (Restore Normal Sleep)"), action: #selector(quitRestoringSleep), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        let keep = NSMenuItem(title: L("退出并保持醒着", "Quit and Stay Awake"), action: #selector(quitKeepingAwake), keyEquivalent: "q")
        keep.target = self
        keep.keyEquivalentModifierMask = [.command, .option]
        keep.isAlternate = true
        menu.addItem(keep)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
