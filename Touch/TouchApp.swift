import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Entry Point
@main
struct TouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate (Menu & Lifecycle)
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBarItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem.button {
            button.image = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: "Touch Haptics")
        }
        
        setupMenu()
        TouchLogic.shared.startListener()
        TouchLogic.shared.setupWorkspaceObserver()
    }
    
    func setupMenu() {
        let menu = NSMenu()
        
        let toggleItem = NSMenuItem(title: "Haptics Enabled", action: #selector(toggleHaptics(_:)), keyEquivalent: "e")
        toggleItem.state = TouchLogic.shared.isEnabled ? .on : .off
        toggleItem.target = self
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusBarItem.menu = menu
    }
    
    @objc func toggleHaptics(_ sender: NSMenuItem) {
        TouchLogic.shared.isEnabled.toggle()
        sender.state = TouchLogic.shared.isEnabled ? .on : .off
    }
    
    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { print(error) }
    }
}

// MARK: - Logic Core
class TouchLogic {
    static let shared = TouchLogic()
    
    var isEnabled = true
    var scrollAccumulator: Double = 0
    var lastHapticTime: TimeInterval = 0
    var lastGestureTime: TimeInterval = 0
    
    func setupWorkspaceObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            if self.isEnabled { HapticEngine.shared.play(.longShortShort) }
        }
    }
    
    func startListener() {
        // Mask includes Scroll, Right Click, and Gestures (30 = Pinch, 29 = Swipe)
        let mask = (1 << CGEventType.scrollWheel.rawValue) |
                   (1 << CGEventType.rightMouseDown.rawValue) |
                   (1 << 30) // Pinch
        
        let tapCallback: CGEventTapCallBack = { (proxy, type, event, refcon) in
            if !TouchLogic.shared.isEnabled { return Unmanaged.passRetained(event) }
            
            // 1. Right Click
            if type == .rightMouseDown {
                HapticEngine.shared.play(.shortShort)
            }
            
            // 2. Launchpad (Pinch Gesture)
            if Int(type.rawValue) == 30 {
                HapticEngine.shared.play(.launchpad)
            }
            
            // 3. Scroll & Mission Control
            if type == .scrollWheel {
                let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
                let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                
                // Mission Control detection (high velocity swipe up)
                if isContinuous && dy > 45 {
                    HapticEngine.shared.play(.missionControl)
                    TouchLogic.shared.scrollAccumulator = 0
                }
                // Regular Scrolling
                else {
                    TouchLogic.shared.scrollAccumulator += abs(dy)
                    if TouchLogic.shared.scrollAccumulator > 5.0 {
                        let now = Date().timeIntervalSince1970
                        if now - TouchLogic.shared.lastHapticTime > 0.03 {
                            HapticEngine.shared.tick(.generic)
                            TouchLogic.shared.lastHapticTime = now
                            TouchLogic.shared.scrollAccumulator = 0
                        }
                    }
                }
            }
            
            return Unmanaged.passRetained(event)
        }
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil
        ) else { return }
        
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - Haptic Engine
class HapticEngine {
    static let shared = HapticEngine()
    private let performer = NSHapticFeedbackManager.defaultPerformer
    private var lastPatternTrigger: TimeInterval = 0
    
    enum Pattern { case shortShort, longShortShort, missionControl, launchpad }
    
    func play(_ pattern: Pattern) {
        let now = Date().timeIntervalSince1970
        guard now - lastPatternTrigger > 0.5 else { return }
        lastPatternTrigger = now
        
        DispatchQueue.main.async {
            switch pattern {
            case .shortShort:
                self.tick(.alignment); self.delay(0.08) { self.tick(.alignment) }
            case .longShortShort:
                self.tick(.generic); self.delay(0.12) { self.tick(.alignment) }; self.delay(0.2) { self.tick(.alignment) }
            case .missionControl:
                // Fast rising double-tap
                self.tick(.alignment); self.delay(0.04) { self.tick(.generic) }
            case .launchpad:
                // Three quick light taps (mimicking a pinch)
                self.tick(.alignment); self.delay(0.06) { self.tick(.alignment) }; self.delay(0.12) { self.tick(.alignment) }
            }
        }
    }
    
    func tick(_ type: NSHapticFeedbackManager.FeedbackPattern) {
        performer.perform(type, performanceTime: .now)
    }
    
    private func delay(_ seconds: Double, _ closure: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: closure)
    }
}
