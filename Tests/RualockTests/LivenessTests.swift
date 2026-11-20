import CoreGraphics
import XCTest
@testable import Rualock

/// The blink check: what counts as a live face, and what must not.
final class LivenessTests: XCTestCase {
    private let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3)
    private var t = 0.0

    private func face(_ openness: Double) -> FaceEngine.Face {
        FaceEngine.Face(box: box, openness: openness, embedding: nil)
    }

    /// One frame at 10 fps; `matched` is the recognition result, when there is one.
    private func step(_ track: inout FaceTrack, _ openness: Double?, matched: Bool? = nil) {
        _ = track.update(openness.map { [face($0)] } ?? [], at: t)
        if let matched { track.setMatched(matched) }
        t += 0.1
    }

    private func blink(_ track: inout FaceTrack, matched: Bool) {
        for _ in 0 ..< 10 { step(&track, 0.30, matched: matched) }  // eyes open: builds their normal openness
        step(&track, 0.08, matched: matched)                       // closed
        step(&track, 0.30, matched: matched)                       // open again
    }

    func testYourBlinkVerifiesAndHoldsWhileInView() {
        var track = FaceTrack()
        blink(&track, matched: true)
        for _ in 0 ..< 50 { step(&track, 0.30, matched: true) }
        XCTAssertTrue(track.verified)
    }

    func testPhotoNeverVerifies() {
        var track = FaceTrack()
        for _ in 0 ..< 100 { step(&track, 0.30, matched: true) }
        XCTAssertFalse(track.verified)
    }

    func testStrangersBlinkDoesNotCarryOverToYourPhoto() {
        var track = FaceTrack()
        blink(&track, matched: false)                               // someone else sits down and blinks
        for _ in 0 ..< 20 { step(&track, 0.30, matched: true) }   // then holds up your photo in the same place
        XCTAssertFalse(track.verified)
    }

    func testOneMissIsToleratedTwoClear() {
        var track = FaceTrack()
        blink(&track, matched: true)
        step(&track, 0.30, matched: false)
        XCTAssertTrue(track.verified, "a head turn can drop one frame below the threshold")
        step(&track, 0.30, matched: false)
        XCTAssertFalse(track.verified)
    }

    func testGapOfMoreThanASecondStartsAnUnverifiedTrack() {
        var track = FaceTrack()
        blink(&track, matched: true)
        t += 1.2
        step(&track, 0.30, matched: true)
        XCTAssertFalse(track.verified)
    }

    func testLookingDownIsNotABlink() {
        var track = FaceTrack()
        for _ in 0 ..< 10 { step(&track, 0.30, matched: true) }
        for _ in 0 ..< 10 { step(&track, 0.12, matched: true) }   // narrowed for a second
        step(&track, 0.30, matched: true)
        XCTAssertFalse(track.verified)
    }

    func testTrustAfterUnlockSkipsTheBlink() {
        var track = FaceTrack()
        step(&track, 0.30, matched: true)
        track.trust()
        for _ in 0 ..< 20 { step(&track, 0.30, matched: true) }
        XCTAssertTrue(track.verified)
    }
}
