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

    func testTwoMissesMakeAnUnconfirmedFaceSomeoneElse() {
        var track = FaceTrack()
        for _ in 0 ..< 5 { step(&track, 0.30, matched: true) }
        step(&track, 0.30, matched: false)
        XCTAssertTrue(track.matched, "a head turn can drop one frame below the threshold")
        step(&track, 0.30, matched: false)
        XCTAssertFalse(track.matched)
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

/// Talking and smiling as signs of life, and riding out misses on a face that stays put.
final class LifeSignTests: XCTestCase {
    private let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3)
    private var t = 0.0

    private func step(_ track: inout FaceTrack, mouthOpen: Double = 0.05, mouthWidth: Double = 1.0,
                      box: CGRect? = nil, matched: Bool? = true) {
        let f = FaceEngine.Face(box: box ?? self.box, openness: 0.3, embedding: nil, mouthOpen: mouthOpen, mouthWidth: mouthWidth)
        _ = track.update([f], at: t)
        if let matched { track.setMatched(matched) }
        t += 0.1
    }

    func testTalkingVerifies() {
        var track = FaceTrack()
        for _ in 0 ..< 10 { step(&track, mouthOpen: 0.15) }
        for _ in 0 ..< 4 { step(&track, mouthOpen: 0.7) }  // a word: the mouth opens wide for 0.4 s
        XCTAssertTrue(track.verified)
        XCTAssertEqual(track.why, "talking")
    }

    func testLandmarkJitterIsNotTalking() {
        // Your mouth at rest measured 0.11-0.26 with frame-to-frame jumps up to ~0.1, sometimes one
        // frame far off. A photo's landmarks jitter like that too.
        var track = FaceTrack()
        let jitter = [0.16, 0.14, 0.09, 0.17, 0.21, 0.21, 0.20, 0.10, 0.55, 0.12, 0.05, 0.18, 0.14, 0.26, 0.05, 0.20]
        for i in 0 ..< 160 { step(&track, mouthOpen: jitter[i % jitter.count]) }
        XCTAssertFalse(track.verified)
    }

    func testTiltedPhotoDoesNotVerify() {
        // Tilting a photo squashes the mouth's height a little (cos 40° = 0.77) but keeps it closed.
        var track = FaceTrack()
        for i in 0 ..< 40 { step(&track, mouthOpen: 0.06 * (1 - 0.23 * Double(i % 10) / 10)) }
        XCTAssertFalse(track.verified)
    }

    func testMissesRiddenOutWhileStill() {
        var track = FaceTrack()
        step(&track)
        track.trust()
        for _ in 0 ..< 4 { step(&track, matched: false) }  // 0.4 s of misses, not moving
        XCTAssertTrue(track.verified)
        for _ in 0 ..< 12 { step(&track, matched: false) }  // past 1.5 s
        XCTAssertFalse(track.verified)
    }

    func testMissesNotRiddenOutWhenTheFaceMoves() {
        var track = FaceTrack()
        step(&track)
        track.trust()
        let moved = CGRect(x: 0.45, y: 0.45, width: 0.2, height: 0.3)  // still the same track, but shifted
        step(&track, box: moved, matched: false)
        step(&track, box: moved, matched: false)
        XCTAssertFalse(track.verified)
    }
}

/// Typing as presence, only as an unbroken continuation of your confirmed face.
final class PresenceChainTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testTypingCarriesOnFromYourFace() {
        var chain = PresenceChain(at: t0)
        // Face seen at 0; you keep typing every second, looking down, for 30 s.
        for s in stride(from: 1.0, through: 30, by: 1) {
            _ = chain.update(now: at(s), faceInView: false, faceAt: t0, lastInput: at(s))
        }
        XCTAssertTrue(chain.typing)
        XCTAssertEqual(chain.presence, at(30))
    }

    func testAPauseInInputEndsIt() {
        var chain = PresenceChain(at: t0)
        _ = chain.update(now: at(1), faceInView: false, faceAt: t0, lastInput: at(1))
        // You stand up: no input for 5 s, then someone else starts typing.
        XCTAssertEqual(chain.update(now: at(5), faceInView: false, faceAt: t0, lastInput: at(1)), "input paused")
        _ = chain.update(now: at(6), faceInView: false, faceAt: t0, lastInput: at(6))
        XCTAssertFalse(chain.typing)
        XCTAssertEqual(chain.presence, at(1))
    }

    func testInputStartingLongAfterYourFaceDoesNothing() {
        var chain = PresenceChain(at: t0)
        _ = chain.update(now: at(5), faceInView: false, faceAt: t0, lastInput: at(5))
        XCTAssertFalse(chain.typing)
        XCTAssertEqual(chain.presence, t0)
    }

    func testCappedWithoutYourFace() {
        var chain = PresenceChain(at: t0)
        for s in stride(from: 1.0, through: 120, by: 1) {
            _ = chain.update(now: at(s), faceInView: false, faceAt: t0, lastInput: at(s))
        }
        XCTAssertEqual(chain.presence, at(90))
        XCTAssertFalse(chain.typing)
    }
}
