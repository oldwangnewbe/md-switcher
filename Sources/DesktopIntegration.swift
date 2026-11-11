import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class SwitcherAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<SwitcherAppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in delegate.showMainWindow() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard installed == noErr else { return }
        let id = EventHotKeyID(signature: 0x4D445357, id: 1) // MDSW
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                                            GetApplicationEventTarget(), 0, &hotKey)
        if registered != noErr { NSLog("MD Switcher hotkey unavailable (%d)", registered) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
    }
}

@MainActor
private final class LoginItemSettings: ObservableObject {
    private let service = SMAppService.mainApp
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    func refresh() { status = service.status }

    func toggle() {
        do {
            if status == .enabled || status == .requiresApproval { try service.unregister() }
            else { try service.register() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

struct LoginItemView: View {
    @StateObject private var settings = LoginItemSettings()

    var body: some View {
        GroupBox("登录与快捷键") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("登录 Mac 时打开换号器")
                    Spacer()
                    if settings.status == .requiresApproval {
                        Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Button(settings.status == .enabled || settings.status == .requiresApproval ? "关闭自启动" : "开启自启动") {
                        settings.toggle()
                    }
                }
                Text("⌃⌥M 显示主界面。关闭窗口后，换号器继续在后台运行。")
                    .foregroundStyle(.secondary)
                if let error = settings.error { Text(error).foregroundStyle(.orange) }
            }
            .padding(8)
        }
        .onAppear { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
