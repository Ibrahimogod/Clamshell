import ClamshellInput
import ClamshellWire
import GameController
import UIKit

/// A hardware keyboard and mouse on the phone (M4), forwarded to the Mac while streaming.
/// - Keyboard: `GCKeyboard` key codes are HID usages, so they go out unchanged, through
///   `HardwareKeyRemap` (⌥-Tab → ⌘-Tab, ⌃-Space → ⌘-Space; iOS keeps ⌘-Tab and ⌘-Space for itself).
/// - Mouse: `GCMouse` raw deltas (not the iOS pointer position), buttons and the scroll wheel.
@MainActor
final class HardwareInput {
    private weak var input: InputClient?
    private var remap = HardwareKeyRemap()
    private var observers: [NSObjectProtocol] = []
    private(set) var keyboardConnected = false
    private(set) var mouseConnected = false
    /// Mac points per mouse count. GCMouse deltas are device counts, close to points at default speed.
    var mouseScale = 1.0
    var remapEnabled = UserDefaults.standard.object(forKey: "remapCommandTab") as? Bool ?? true {
        didSet { remap.enabled = remapEnabled; UserDefaults.standard.set(remapEnabled, forKey: "remapCommandTab") }
    }

    init(input: InputClient) {
        self.input = input
        remap.enabled = remapEnabled
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach(keyboard: GCKeyboard.coalesced) }
        })
        observers.append(nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardConnected = false; self?.input?.releaseAllHeld() }
        })
        observers.append(nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { for m in GCMouse.mice() { self?.attach(mouse: m) } }
        })
        observers.append(nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseConnected = GCMouse.mice().isEmpty == false }
        })
        attach(keyboard: GCKeyboard.coalesced)
        for m in GCMouse.mice() { attach(mouse: m) }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        for m in GCMouse.mice() {
            m.mouseInput?.mouseMovedHandler = nil
            m.mouseInput?.leftButton.pressedChangedHandler = nil
            m.mouseInput?.rightButton?.pressedChangedHandler = nil
            m.mouseInput?.middleButton?.pressedChangedHandler = nil
            m.mouseInput?.scroll.valueChangedHandler = nil
        }
    }

    private func attach(keyboard: GCKeyboard?) {
        guard let kb = keyboard?.keyboardInput else { return }
        keyboardConnected = true
        kb.keyChangedHandler = { [weak self] _, _, code, pressed in
            let usage = UInt16(truncatingIfNeeded: code.rawValue)
            MainActor.assumeIsolated { self?.key(usage, down: pressed) }
        }
    }

    private func key(_ usage: UInt16, down: Bool) {
        guard let input, usage != 0 else { return }
        for e in remap.handle(usage, down: down) {
            if case .key(let u, let d) = e { input.key(u, down: d) }
        }
    }

    private func attach(mouse: GCMouse?) {
        guard let m = mouse?.mouseInput else { return }
        mouseConnected = true
        m.mouseMovedHandler = { [weak self] _, dx, dy in
            // GameController's y grows upwards; the Mac's grows downwards.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.input?.move(dx: Double(dx) * self.mouseScale, dy: -Double(dy) * self.mouseScale)
            }
        }
        m.leftButton.pressedChangedHandler = { [weak self] _, _, p in MainActor.assumeIsolated { self?.input?.button(.left, down: p) } }
        m.rightButton?.pressedChangedHandler = { [weak self] _, _, p in MainActor.assumeIsolated { self?.input?.button(.right, down: p) } }
        m.middleButton?.pressedChangedHandler = { [weak self] _, _, p in MainActor.assumeIsolated { self?.input?.button(.middle, down: p) } }
        m.scroll.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.input?.scroll(dx: Double(x) * 4, dy: -Double(y) * 4, phase: .none) }
        }
    }
}
