import ApplicationServices
import Carbon
import Foundation
import os

private let typeClawSyntheticEventMarker: Int64 = 0x5459464c4f57

protocol TypeClawTextEventPosting: AnyObject {
    func selectPreviousCharacters(_ count: Int) -> Bool
    func postUnicode(_ text: String) -> Bool
}

public final class TypeClawTextReplacer {
    typealias Scheduler = (DispatchWorkItem) -> Void

    private let logger = Logger(
        subsystem: "io.github.nnnickg.typeclaw.agent",
        category: "Replacement"
    )
    private let performanceLogger = Logger(
        subsystem: "io.github.nnnickg.typeclaw.agent",
        category: "Performance"
    )
    private let poster: TypeClawTextEventPosting
    private let scheduler: Scheduler
    private var pendingWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0

    public convenience init() {
        self.init(
            poster: TypeClawCGTextEventPoster(),
            scheduler: { DispatchQueue.main.async(execute: $0) }
        )
    }

    init(poster: TypeClawTextEventPosting, scheduler: @escaping Scheduler) {
        self.poster = poster
        self.scheduler = scheduler
    }

    public func cancelPending(reason: String) {
        guard pendingWorkItem != nil else {
            return
        }
        generation &+= 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        logger.debug("cancelled pending replacement reason=\(reason, privacy: .public)")
    }

    public func replaceLastToken(
        reason: String,
        deleteCount: Int,
        with text: String,
        isStillValid: @escaping () -> Bool,
        didAbandon: @escaping () -> Void = {},
        didPost: @escaping () -> Void = {}
    ) {
        guard deleteCount > 0, !text.isEmpty else {
            return
        }

        cancelPending(reason: "superseded")
        generation &+= 1
        let scheduledGeneration = generation
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == scheduledGeneration
            else {
                return
            }
            guard isStillValid() else {
                self.abandon(reason: "validationFailed", didAbandon: didAbandon)
                return
            }
            let workStarted = ProcessInfo.processInfo.systemUptime
            guard self.measured("replacement.selectPrevious.\(reason)", {
                self.poster.selectPreviousCharacters(deleteCount)
            }) else {
                self.abandon(reason: "selectionPostFailed", didAbandon: didAbandon)
                return
            }
            guard isStillValid() else {
                self.abandon(reason: "postValidationFailed", didAbandon: didAbandon)
                return
            }
            guard self.measured("replacement.postUnicode.\(reason)", {
                self.poster.postUnicode(text)
            }) else {
                self.abandon(reason: "unicodePostFailed", didAbandon: didAbandon)
                return
            }

            self.logger.notice(
                "replaced token reason=\(reason, privacy: .public) deleteCount=\(deleteCount, privacy: .public) insertedUtf16=\(text.utf16.count, privacy: .public)"
            )
            self.logPerformance(name: "replacement.work.\(reason)", started: workStarted)
            self.logPerformance(name: "replacement.decisionToPost.\(reason)", started: requestedAt)
            didPost()
            if self.generation == scheduledGeneration {
                self.pendingWorkItem = nil
            }
        }
        pendingWorkItem = workItem
        scheduler(workItem)
    }

    private func abandon(reason: String, didAbandon: () -> Void) {
        cancelPending(reason: reason)
        didAbandon()
    }

    private func measured<T>(_ name: String, _ body: () -> T) -> T {
        let started = ProcessInfo.processInfo.systemUptime
        defer { logPerformance(name: name, started: started) }
        return body()
    }

    private func logPerformance(name: String, started: TimeInterval) {
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000.0
        guard elapsedMs >= 0.25 else {
            return
        }
        performanceLogger.notice(
            "perf name=\(name, privacy: .public) durationMs=\(elapsedMs, privacy: .public) thresholdMs=0.25"
        )
    }
}

final class TypeClawCGTextEventPoster: TypeClawTextEventPosting {
    private let source = CGEventSource(stateID: .hidSystemState)

    init() {}

    func selectPreviousCharacters(_ count: Int) -> Bool {
        for _ in 0..<count {
            guard postKey(
                virtualKey: CGKeyCode(kVK_LeftArrow),
                keyDown: true,
                flags: .maskShift
            ),
            postKey(
                virtualKey: CGKeyCode(kVK_LeftArrow),
                keyDown: false,
                flags: .maskShift
            ) else {
                return false
            }
        }
        return true
    }

    func postUnicode(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return false
        }

        keyDown.setIntegerValueField(.eventSourceUserData, value: typeClawSyntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: typeClawSyntheticEventMarker)
        units.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            keyDown.keyboardSetUnicodeString(
                stringLength: units.count,
                unicodeString: baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: units.count,
                unicodeString: baseAddress
            )
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func postKey(
        virtualKey: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags = []
    ) -> Bool {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: virtualKey,
            keyDown: keyDown
        ) else {
            return false
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: typeClawSyntheticEventMarker)
        event.post(tap: .cghidEventTap)
        return true
    }
}
