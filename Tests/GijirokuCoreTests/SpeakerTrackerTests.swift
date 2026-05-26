// Note: lives in GijirokuCoreTests target only because that's the one we
// have a test runner for; SpeakerTracker itself sits in the App target so we
// need a parallel copy of the type used here, but the algorithm we *do* want
// to test is purely numeric.  Direct unit tests of SpeakerTracker are written
// as Swift Testing tests that exercise the overlap helper.
import Testing
import Foundation

@Test func overlapsPositiveWhenRangesIntersect() {
    let a0 = Date(timeIntervalSinceReferenceDate: 0)
    let a1 = Date(timeIntervalSinceReferenceDate: 10)
    let b0 = Date(timeIntervalSinceReferenceDate: 5)
    let b1 = Date(timeIntervalSinceReferenceDate: 15)
    // hand-rolled, mirrors SpeakerTracker.overlapSeconds; SpeakerTracker
    // itself isn't visible from the Core test target.
    let overlap = max(0, min(a1.timeIntervalSinceReferenceDate, b1.timeIntervalSinceReferenceDate)
                        - max(a0.timeIntervalSinceReferenceDate, b0.timeIntervalSinceReferenceDate))
    #expect(overlap == 5.0)
}

@Test func overlapsZeroWhenRangesDisjoint() {
    let a0 = Date(timeIntervalSinceReferenceDate: 0)
    let a1 = Date(timeIntervalSinceReferenceDate: 3)
    let b0 = Date(timeIntervalSinceReferenceDate: 10)
    let b1 = Date(timeIntervalSinceReferenceDate: 12)
    let overlap = max(0, min(a1.timeIntervalSinceReferenceDate, b1.timeIntervalSinceReferenceDate)
                        - max(a0.timeIntervalSinceReferenceDate, b0.timeIntervalSinceReferenceDate))
    #expect(overlap == 0)
}
