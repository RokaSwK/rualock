import CoreGraphics
import QuartzCore

/// Follows one face from frame to frame and tells whether it has proved it's live.
///
/// A face that stays in view the whole time can't be swapped for a photo: slipping a phone in means
/// the face disappears or jumps, which starts a new track. So a track proves itself once, by
/// blinking (a photo never blinks), or by being the face in front of the camera right after you
/// unlocked the Mac, and stays verified for as long as it's continuously in view.
struct FaceTrack {
    static let maxGap: CFTimeInterval = 1.0     // missing longer than this: a new track
    static let minOverlap: CGFloat = 0.3        // overlap with the last position needed to be the same face
    static let blinkMax: CFTimeInterval = 0.8   // closed longer than this isn't a blink (looking down)
    static let closed = 0.6                     // eyes below this fraction of their recent openness: closed
    static let reopened = 0.85                  // and back above this: open again

    private(set) var lastSeen: CFTimeInterval = 0
    /// Blinked, or trusted because you had just unlocked.
    private(set) var verified = false
    /// The latest recognition result for this face. See `setMatched`.
    private(set) var matched = false
    private var box: CGRect?
    private var history: [(t: CFTimeInterval, v: Double)] = []
    private var closedSince: CFTimeInterval?

    /// Picks which of this frame's faces continues the track (nil if none is visible) and
    /// starts a new track when the face is a different one or came back after a gap.
    /// `detected` is false for frames that only refit landmarks inside the last detection's boxes:
    /// those boxes come out slightly different, so they continue the track but don't move or break it.
    mutating func update(_ faces: [FaceEngine.Face], at t: CFTimeInterval, detected: Bool = true) -> FaceEngine.Face? {
        if !detected {
            guard let box, t - lastSeen <= Self.maxGap,
                  let best = faces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(best.box, box) > 0 else { return nil }
            follow(best, at: t, moveBox: false)
            return best
        }
        if let box, t - lastSeen <= Self.maxGap,
           let best = faces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(best.box, box) >= Self.minOverlap {
            follow(best, at: t)
            return best
        }
        guard let face = faces.first else {
            if t - lastSeen > Self.maxGap { self = FaceTrack(); why = "face out of view" }
            return nil
        }
        let reason = box == nil ? "new face" : t - lastSeen > Self.maxGap
            ? String(format: "back after %.1f s", t - lastSeen) : "face jumped"
        self = FaceTrack()
        why = reason
        if Prefs.debugLiveness { note("liveness: new track (\(reason))") }
        follow(face, at: t)
        return face
    }

    /// Mark this track as you without a blink (you've just unlocked with your password or Touch ID).
    mutating func trust() { verified = true; why = "just unlocked" }

    /// Record a recognition result. A change of identity clears verification: a blink from someone
    /// else's face must not carry over to your photo held up in the same place. One miss in a row is
    /// tolerated (a head turn can drop a single frame below the threshold); two make it someone else.
    mutating func setMatched(_ m: Bool) {
        if m {
            if !matched { verified = false; why = "now matches you" }
            matched = true
            misses = 0
        } else {
            misses += 1
            if misses >= 2 || !matched {
                if matched { why = "two recognition misses" }
                matched = false
                verified = false
            }
        }
    }

    private var misses = 0
    /// Why the track is in its current state, for `-debugLiveness`.
    private(set) var why = "new face"

    /// Start a new track on `face` (for example, you, when the tracked face turned out to be someone else).
    mutating func restart(with face: FaceEngine.Face, at t: CFTimeInterval) {
        self = FaceTrack()
        why = "switched to your face"
        follow(face, at: t)
    }

    private mutating func follow(_ face: FaceEngine.Face, at t: CFTimeInterval, moveBox: Bool = true) {
        if moveBox { box = face.box }
        lastSeen = t
        guard let v = face.openness else { return }
        history.append((t, v))
        history.removeAll { t - $0.t > 3 }
        guard history.count >= 6 else { return }
        let sorted = history.map(\.v).sorted()
        let normal = sorted[Int(Double(sorted.count - 1) * 0.8)]
        if v < Self.closed * normal {
            if closedSince == nil { closedSince = t }
        } else if v > Self.reopened * normal, let since = closedSince {
            if t - since <= Self.blinkMax && matched { verified = true; why = "blinked" }  // only your face's blinks count
            if Prefs.debugLiveness && !verified {
                note(String(format: "liveness: eyes closed %.2f s (%@)", t - since, matched ? "too slow" : "not matched"))
            }
            closedSince = nil
        }
    }
}

private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter + 1e-9)
}
