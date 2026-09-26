import AppKit
import SwiftUI
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var originalPanel: NSPanel?
    private var translationPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        DebugServer.shared.start()
        #endif

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "captions.bubble.fill",
                                   accessibilityDescription: "JaSub")
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Update icon when running state changes
        TranslationEngine.shared.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: running ? "captions.bubble.fill" : "captions.bubble",
                    accessibilityDescription: "JaSub"
                )
                self?.statusItem?.button?.appearsDisabled = false
                if running {
                    self?.statusItem?.button?.contentTintColor = .systemRed
                } else {
                    self?.statusItem?.button?.contentTintColor = nil
                }
            }
            .store(in: &cancellables)

        // Popover
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: MenuBarView())
        popover = p

        // Floating windows: translation first (to get its frame), then original above it
        translationPanel = makeTranslationPanel()
        if let tFrame = translationPanel?.frame {
            originalPanel = makeOriginalPanel(above: tFrame)
        }

        // Show/hide original panel when toggle changes
        TranslationEngine.shared.$showOriginal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                if show {
                    self?.originalPanel?.orderFront(nil)
                } else {
                    self?.originalPanel?.orderOut(nil)
                }
            }
            .store(in: &cancellables)

        // Show/hide translation panel when toggle changes
        TranslationEngine.shared.$showTranslation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                if show {
                    self?.translationPanel?.orderFront(nil)
                } else {
                    self?.translationPanel?.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }

    @objc private func handleClick(_ sender: Any) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu() {
        let engine = TranslationEngine.shared
        let menu = NSMenu()
        let runTitle = engine.isRunning
            ? NSLocalizedString("Stop", comment: "")
            : NSLocalizedString("Start", comment: "")
        menu.addItem(NSMenuItem(title: runTitle, action: #selector(toggleRunning), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit JaSub", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleRunning() {
        let engine = TranslationEngine.shared
        engine.isRunning ? engine.stop() : engine.start()
    }

    @objc private func togglePopover(_ sender: Any) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(sender)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }
}
