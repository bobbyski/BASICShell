import BASICCore
import AppKit
import CoreText
import GameController
import MarkdownUI
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import VectorTerminalSDK
import WebKit

final class StudioInputCoordinator: @unchecked Sendable {
    private let condition = NSCondition()
    private var isAwaitingLine = false
    private var isAwaitingRawKey = false
    private var isProgramRunning = false
    private var submittedLine: String?
    private var submittedExitKey: String?
    private var exitLineInputOnSpecialKey = false
    private var lineInputOptions = BASICLineInputOptions()
    private var keyBuffer: [String] = []

    func beginLineInput(exitOnSpecialKey: Bool = false) {
        beginLineInput(exitOnSpecialKey: exitOnSpecialKey, options: BASICLineInputOptions())
    }

    func beginLineInput(exitOnSpecialKey: Bool = false, options: BASICLineInputOptions) {
        condition.lock()
        isAwaitingLine = true
        submittedLine = nil
        submittedExitKey = nil
        exitLineInputOnSpecialKey = exitOnSpecialKey
        lineInputOptions = options
        condition.unlock()
    }

    func waitForLine() -> String? {
        waitForLineInput()?.text
    }

    func waitForLineInput() -> BASICLineInputResult? {
        condition.lock()
        while isAwaitingLine {
            condition.wait()
        }
        let line = submittedLine
        let exitKey = submittedExitKey
        submittedLine = nil
        submittedExitKey = nil
        condition.unlock()
        return line.map { BASICLineInputResult(text: $0, exitKey: exitKey) }
    }

    func submitLine(_ line: String) {
        condition.lock()
        guard isAwaitingLine else {
            condition.unlock()
            return
        }
        submittedLine = line
        submittedExitKey = nil
        exitLineInputOnSpecialKey = false
        lineInputOptions = BASICLineInputOptions()
        isAwaitingLine = false
        condition.signal()
        condition.unlock()
    }

    func submitLineInputExit(line: String, key: String) {
        condition.lock()
        guard isAwaitingLine, exitLineInputOnSpecialKey else {
            condition.unlock()
            return
        }
        submittedLine = line
        submittedExitKey = key
        exitLineInputOnSpecialKey = false
        lineInputOptions = BASICLineInputOptions()
        isAwaitingLine = false
        condition.signal()
        condition.unlock()
    }

    func cancelLineInput() {
        condition.lock()
        guard isAwaitingLine else {
            condition.unlock()
            return
        }
        submittedLine = nil
        submittedExitKey = nil
        exitLineInputOnSpecialKey = false
        lineInputOptions = BASICLineInputOptions()
        isAwaitingLine = false
        condition.signal()
        condition.unlock()
    }

    func awaitingLineInput() -> Bool {
        condition.lock()
        let value = isAwaitingLine
        condition.unlock()
        return value
    }

    func shouldExitLineInputOnSpecialKey() -> Bool {
        condition.lock()
        let value = isAwaitingLine && exitLineInputOnSpecialKey
        condition.unlock()
        return value
    }

    func activeLineInputOptions() -> BASICLineInputOptions {
        condition.lock()
        let value = isAwaitingLine ? lineInputOptions : BASICLineInputOptions()
        condition.unlock()
        return value
    }

    func setProgramRunning(_ running: Bool) {
        condition.lock()
        isProgramRunning = running
        if !running {
            isAwaitingRawKey = false
            condition.signal()
        }
        condition.unlock()
    }

    func shouldCaptureKeyOnly() -> Bool {
        condition.lock()
        let value = (isProgramRunning || isAwaitingRawKey) && !isAwaitingLine
        condition.unlock()
        return value
    }

    func pushKey(_ key: String) {
        condition.lock()
        keyBuffer.append(key)
        condition.signal()
        condition.unlock()
    }

    func clearKeys() {
        condition.lock()
        keyBuffer.removeAll()
        condition.unlock()
    }

    func readKey() -> String? {
        condition.lock()
        let key = keyBuffer.isEmpty ? nil : keyBuffer.removeFirst()
        condition.unlock()
        return key
    }

    func beginRawKeyInput() {
        condition.lock()
        isAwaitingRawKey = true
        condition.unlock()
    }

    func endRawKeyInput() {
        condition.lock()
        isAwaitingRawKey = false
        condition.signal()
        condition.unlock()
    }

    func rawKeyInputActive() -> Bool {
        condition.lock()
        let value = isAwaitingRawKey
        condition.unlock()
        return value
    }

    func waitForRawKey() -> String? {
        condition.lock()
        while keyBuffer.isEmpty && isAwaitingRawKey {
            condition.wait()
        }
        let key = keyBuffer.isEmpty ? nil : keyBuffer.removeFirst()
        condition.unlock()
        return key
    }
}

final class StudioConsoleInputState: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOverwriteMode = false

    func setOverwriteMode(_ value: Bool) {
        condition.lock()
        isOverwriteMode = value
        condition.unlock()
    }

    func toggleOverwriteMode() -> Bool {
        condition.lock()
        isOverwriteMode.toggle()
        let value = isOverwriteMode
        condition.unlock()
        return value
    }

    func overwriteMode() -> Bool {
        condition.lock()
        let value = isOverwriteMode
        condition.unlock()
        return value
    }
}

final class StudioGamepadInputCoordinator: NSObject, @unchecked Sendable {
    private let condition = NSCondition()
    private var keyBuffer: [String] = []
    private var configuredControllerIDs: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )
        GCController.controllers().forEach(configure)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        GCController.stopWirelessControllerDiscovery()
    }

    func readKey() -> String? {
        GCController.controllers().forEach(configure)
        condition.lock()
        let key = keyBuffer.isEmpty ? nil : keyBuffer.removeFirst()
        condition.unlock()
        return key
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configure(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        condition.lock()
        configuredControllerIDs.remove(ObjectIdentifier(controller))
        condition.unlock()
    }

    private func configure(_ controller: GCController) {
        let identifier = ObjectIdentifier(controller)
        condition.lock()
        let inserted = configuredControllerIDs.insert(identifier).inserted
        condition.unlock()
        guard inserted else { return }

        push("[GP:CONNECTED")

        if let gamepad = controller.extendedGamepad {
            bind(gamepad.buttonA, "A")
            bind(gamepad.buttonB, "B")
            bind(gamepad.buttonX, "X")
            bind(gamepad.buttonY, "Y")
            bind(gamepad.leftShoulder, "LEFT_SHOULDER")
            bind(gamepad.rightShoulder, "RIGHT_SHOULDER")
            bind(gamepad.leftTrigger, "LEFT_TRIGGER")
            bind(gamepad.rightTrigger, "RIGHT_TRIGGER")
            bind(gamepad.dpad.up, "DPAD_UP")
            bind(gamepad.dpad.down, "DPAD_DOWN")
            bind(gamepad.dpad.left, "DPAD_LEFT")
            bind(gamepad.dpad.right, "DPAD_RIGHT")
            bind(gamepad.leftThumbstick.up, "LEFT_STICK_UP")
            bind(gamepad.leftThumbstick.down, "LEFT_STICK_DOWN")
            bind(gamepad.leftThumbstick.left, "LEFT_STICK_LEFT")
            bind(gamepad.leftThumbstick.right, "LEFT_STICK_RIGHT")
            bind(gamepad.rightThumbstick.up, "RIGHT_STICK_UP")
            bind(gamepad.rightThumbstick.down, "RIGHT_STICK_DOWN")
            bind(gamepad.rightThumbstick.left, "RIGHT_STICK_LEFT")
            bind(gamepad.rightThumbstick.right, "RIGHT_STICK_RIGHT")
        } else if let gamepad = controller.microGamepad {
            bind(gamepad.buttonA, "A")
            bind(gamepad.buttonX, "X")
            bind(gamepad.dpad.up, "DPAD_UP")
            bind(gamepad.dpad.down, "DPAD_DOWN")
            bind(gamepad.dpad.left, "DPAD_LEFT")
            bind(gamepad.dpad.right, "DPAD_RIGHT")
        }
    }

    private func bind(_ button: GCControllerButtonInput, _ descriptor: String) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.push("[GP:\(descriptor)")
        }
    }

    private func push(_ key: String) {
        condition.lock()
        keyBuffer.append(key)
        condition.unlock()
    }
}

