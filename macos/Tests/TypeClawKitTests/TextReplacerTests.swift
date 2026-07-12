import XCTest
@testable import TypeClawKit

final class TextReplacerTests: XCTestCase {
    func testSuccessfulReplacementValidatesBeforeAndAfterSelection() {
        let poster = EventPoster()
        var validationCount = 0
        var didPost = false
        var didAbandon = false
        let replacer = immediateReplacer(poster: poster)

        replacer.replaceLastToken(
            reason: "test",
            deleteCount: 4,
            with: "тест",
            isStillValid: {
                validationCount += 1
                return true
            },
            didAbandon: { didAbandon = true },
            didPost: { didPost = true }
        )

        XCTAssertEqual(validationCount, 2)
        XCTAssertEqual(poster.selectedCounts, [4])
        XCTAssertEqual(poster.postedText, ["тест"])
        XCTAssertTrue(didPost)
        XCTAssertFalse(didAbandon)
    }

    func testFocusInvalidationAfterSelectionAbandonsBeforeInsertion() {
        let poster = EventPoster()
        var validationCount = 0
        var didPost = false
        var didAbandon = false
        let replacer = immediateReplacer(poster: poster)

        replacer.replaceLastToken(
            reason: "test",
            deleteCount: 4,
            with: "тест",
            isStillValid: {
                validationCount += 1
                return validationCount == 1
            },
            didAbandon: { didAbandon = true },
            didPost: { didPost = true }
        )

        XCTAssertEqual(poster.selectedCounts, [4])
        XCTAssertTrue(poster.postedText.isEmpty)
        XCTAssertFalse(didPost)
        XCTAssertTrue(didAbandon)
    }

    func testEventCreationFailureAbandonsTransaction() {
        let poster = EventPoster()
        poster.unicodeResult = false
        var didPost = false
        var didAbandon = false
        let replacer = immediateReplacer(poster: poster)

        replacer.replaceLastToken(
            reason: "test",
            deleteCount: 4,
            with: "тест",
            isStillValid: { true },
            didAbandon: { didAbandon = true },
            didPost: { didPost = true }
        )

        XCTAssertFalse(didPost)
        XCTAssertTrue(didAbandon)
    }

    func testSelectionFailurePreventsUnicodeInsertion() {
        let poster = EventPoster()
        poster.selectionResult = false
        var didAbandon = false
        let replacer = immediateReplacer(poster: poster)

        replacer.replaceLastToken(
            reason: "test",
            deleteCount: 4,
            with: "тест",
            isStillValid: { true },
            didAbandon: { didAbandon = true }
        )

        XCTAssertTrue(poster.postedText.isEmpty)
        XCTAssertTrue(didAbandon)
    }

    func testCancellationInvalidatesScheduledTransaction() {
        let poster = EventPoster()
        var scheduled: DispatchWorkItem?
        let replacer = TypeClawTextReplacer(
            poster: poster,
            scheduler: { scheduled = $0 }
        )

        replacer.replaceLastToken(
            reason: "test",
            deleteCount: 4,
            with: "тест",
            isStillValid: { true }
        )
        replacer.cancelPending(reason: "newInput")
        scheduled?.perform()

        XCTAssertTrue(poster.selectedCounts.isEmpty)
        XCTAssertTrue(poster.postedText.isEmpty)
    }

    private func immediateReplacer(poster: EventPoster) -> TypeClawTextReplacer {
        TypeClawTextReplacer(poster: poster, scheduler: { $0.perform() })
    }
}

private final class EventPoster: TypeClawTextEventPosting {
    var selectionResult = true
    var unicodeResult = true
    var selectedCounts: [Int] = []
    var postedText: [String] = []

    func selectPreviousCharacters(_ count: Int) -> Bool {
        selectedCounts.append(count)
        return selectionResult
    }

    func postUnicode(_ text: String) -> Bool {
        postedText.append(text)
        return unicodeResult
    }
}
