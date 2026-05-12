import CoreGraphics
import Foundation

@MainActor
final class MumbleGlobalInputMonitor {
    enum StartError: Error, Equatable {
        case permissionDenied
        case eventTapUnavailable
    }

    private let handler: (MumbleInputEvent) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping (MumbleInputEvent) -> Void) {
        self.handler = handler
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    static func hasListenEventAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestListenEventAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    func start() throws {
        guard Self.hasListenEventAccess() else {
            throw StartError.permissionDenied
        }

        stop()

        let eventMask = [
            CGEventType.keyDown,
            .keyUp,
            .flagsChanged,
            .otherMouseDown,
            .otherMouseUp,
        ].reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (1 << CGEventMask(eventType.rawValue))
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw StartError.eventTapUnavailable
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            throw StartError.eventTapUnavailable
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            enableTap()
            return
        }

        guard let inputEvent = MumbleInputEvent(cgEvent: event, type: type) else {
            return
        }

        handler(inputEvent)
    }

    private func enableTap() {
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private nonisolated static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<MumbleGlobalInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        Task { @MainActor in
            monitor.handleTapEvent(type: type, event: event)
        }

        return Unmanaged.passUnretained(event)
    }
}
