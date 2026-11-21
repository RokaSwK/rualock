import CoreGraphics
import QuartzCore

/// Follows one face from frame to frame and tells whether it has proved it's live.
///
/// A face that stays in view the whole time can't be swapped for a photo: slipping a phone in means
/// the face disappears or jumps, which starts a new track. So a track proves itself once and stays
/// verified for as long as it's continuously in view. It proves itself by:
/// - blinking (a photo never blinks),
/// - talking: the mouth opening well past its recent normal for a few frames in a row (a photo,
///   however it's tilted or how its landmarks jitter, doesn't), or
/// - being the face in front of the camera right after you unlocked the Mac, or
/// - coming back within 6 s, within two face widths of where it was, after a confirmed face
///   dropped out for a moment
///   (looking down makes detection flicker; a photo would have to be slid into your place, while
///   you're still right there, within those 6 s).
struct FaceTrack {
    static let maxGap: CFTimeInterval = 1.0     // missing longer than this: a new track
    static let minOverlap: CGFloat = 0.3        // overlap with the last position needed to be the same face
    static let blinkMax: CFTimeInterval = 0.8   // closed longer than this isn't a blink (looking down)
    static let closed = 0.6                     // eyes below this fraction of their recent openness: closed
    static let reopened = 0.85                  // and back above this: open again
    static let talkOpen = 0.3                   // mouth opening (height / width) this far above its normal...
    static let talkFrames = 3                   // ...for this many frames in a row: talking (jitter is ~0.03-0.1)
    static let missTolerance: CFTimeInterval = 1.5  // recognition misses ridden out on a face that stays put
    static let reacquireWindow: CFTimeInterval = 6  // a confirmed face that drops out and comes back this soon...
    static let reacquireDistance: CGFloat = 2.0     // ...this close (in face widths) keeps its confirmation
    static let stillOverlap: CGFloat = 0.6      // "stays put": overlap with where it last matched

    /// Receives each decision (new track, verified, ...), for diagnostics. Nil in tests.
    static var log: ((String, [String: Any]) -> Void)?

    private(set) var lastSeen: CFTimeInterval = 0
    /// Proved live, or trusted because you had just unlocked.
    private(set) var verified = false
    /// The latest recognition result for this face. See `setMatched`.
    private(set) var matched = false
    /// Why the track is in its current state.
    private(set) var why = "new face"

    private var box: CGRect?
    private var eyes: [(t: CFTimeInterval, v: Double)] = []
    private var mouth: [(t: CFTimeInterval, open: Double)] = []
    private var mouthOpenRun = 0
    private var closedSince: CFTimeInterval?
    private var misses = 0
    private var lastMatch: (t: CFTimeInterval, box: CGRect)?
    /// Where and when a confirmed face was last seen, carried over to the next track for `reacquireWindow`.
    private var lostConfirmed: (t: CFTimeInterval, box: CGRect)?

    /// A fresh track that remembers this one if it was confirmed.
    private func successor() -> FaceTrack {
        var next = FaceTrack()
        if verified, matched, let box { next.lostConfirmed = (lastSeen, box) } else { next.lostConfirmed = lostConfirmed }
        return next
    }

    /// Picks which of this frame's faces continues the track (nil if none is visible) and
    /// starts a new track when the face is a different one or came back after a gap.
    /// `detected` is false for frames that only refit landmarks inside the last detection's boxes:
    /// those boxes come out slightly different, so they continue the track but don't move or break it.
    mutating func update(_ faces: [FaceEngine.Face], at t: CFTimeInterval, detected: Bool = true) -> FaceEngine.Face? {
        if !detected {
            guard let box, t - lastSeen <= Self.maxGap,
                  let best = faces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(best.box, box) > 0 else {
                mouthOpenRun = 0
                return nil
            }
            follow(best, at: t, moveBox: false)
            return best
        }
        if let box, t - lastSeen <= Self.maxGap,
           let best = faces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(best.box, box) >= Self.minOverlap {
            follow(best, at: t)
            return best
        }
        guard let face = faces.first else {
            mouthOpenRun = 0
            if box != nil, t - lastSeen > Self.maxGap {
                Self.log?("track_lost", ["verified": verified, "matched": matched])
                self = successor()
                why = "face out of view"
            }
            return nil
        }
        let reason = box == nil ? "new face" : t - lastSeen > Self.maxGap ? "back after a gap" : "face jumped"
        var info: [String: Any] = ["reason": reason, "wasVerified": verified]
        if let box { info["gap"] = t - lastSeen; info["overlap"] = Double(iou(face.box, box)) }
        Self.log?("track_new", info)
        self = successor()
        why = reason
        follow(face, at: t)
        return face
    }

    /// Mark this track as you without a blink (you've just unlocked with your password or Touch ID).
    mutating func trust() {
        verified = true
        why = "just unlocked"
        Self.log?("verified", ["by": "unlock"])
    }

    /// Record a recognition result. A change of identity clears verification: a blink from someone
    /// else's face must not carry over to your photo held up in the same place. A verified face that
    /// stays put rides out up to 1.5 s of misses (looking down or turning drops the match score);
    /// otherwise two misses in a row make it someone else. `score` is only logged.
    mutating func setMatched(_ m: Bool, score: Float? = nil) {
        let t = lastSeen
        if m {
            if !matched {
                verified = false
                why = "now matches you"
                if let lost = lostConfirmed, let box, t - lost.t <= Self.reacquireWindow,
                   hypot(box.midX - lost.box.midX, box.midY - lost.box.midY) <= Self.reacquireDistance * max(box.width, lost.box.width) {
                    verified = true
                    why = "came back"
                    Self.log?("verified", ["by": "came back", "gap": t - lost.t])
                }
                lostConfirmed = nil
            }
            matched = true
            misses = 0
            if let box { lastMatch = (t, box) }
            return
        }
        misses += 1
        guard matched else { return }
        if verified, let last = lastMatch, let box, t - last.t <= Self.missTolerance, iou(box, last.box) >= Self.stillOverlap {
            Self.log?("miss_tolerated", ["misses": misses, "since": t - last.t, "score": Double(score ?? -1)])
            return
        }
        guard misses >= 2 else { return }
        Self.log?("unmatched", ["misses": misses, "wasVerified": verified])
        why = "stopped matching"
        matched = false
        verified = false
    }

    /// Start a new track on `face` (for example, you, when the tracked face turned out to be someone else).
    mutating func restart(with face: FaceEngine.Face, at t: CFTimeInterval) {
        Self.log?("track_new", ["reason": "switched to your face", "wasVerified": verified])
        self = FaceTrack()
        why = "switched to your face"
        follow(face, at: t)
    }

    private mutating func follow(_ face: FaceEngine.Face, at t: CFTimeInterval, moveBox: Bool = true) {
        if moveBox { box = face.box }
        lastSeen = t
        if let v = face.openness { watchEyes(v, at: t) }
        if let open = face.mouthOpen { watchMouth(open, at: t) } else { mouthOpenRun = 0 }
    }

    private mutating func watchEyes(_ v: Double, at t: CFTimeInterval) {
        eyes.append((t, v))
        eyes.removeAll { t - $0.t > 3 }
        guard eyes.count >= 6 else { return }
        let sorted = eyes.map(\.v).sorted()
        let normal = sorted[Int(Double(sorted.count - 1) * 0.8)]
        if v < Self.closed * normal {
            if closedSince == nil { closedSince = t }
        } else if v > Self.reopened * normal, let since = closedSince {
            closedSince = nil
            let duration = t - since
            let counts = duration <= Self.blinkMax && matched  // only your face's blinks count
            Self.log?("eyes_closed", ["seconds": duration, "normal": normal, "counted": counts, "matched": matched, "verified": verified])
            if counts && !verified { prove("blink") }
        }
    }

    private mutating func watchMouth(_ open: Double, at t: CFTimeInterval) {
        mouth.append((t, open))
        mouth.removeAll { t - $0.t > 3 }
        guard mouth.count >= 8 else { return }
        let sorted = mouth.map(\.open).sorted()
        let normal = sorted[sorted.count / 2]
        // Count only consecutive wide-open frames of a matching face that still has to prove itself.
        mouthOpenRun = matched && !verified && open >= normal + Self.talkOpen ? mouthOpenRun + 1 : 0
        if mouthOpenRun >= Self.talkFrames {
            prove("talking", ["open": open, "normal": normal])
        }
    }

    private mutating func prove(_ how: String, _ info: [String: Any] = [:]) {
        verified = true
        why = how
        var i = info
        i["by"] = how
        Self.log?("verified", i)
    }
}

func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter + 1e-9)
}

/// Keyboard and mouse input as presence: it keeps you "here" while the camera can't see your face
/// (looking down at the keyboard), but only as an unbroken continuation of your confirmed face.
/// Any pause in input longer than `gap` since your face was last confirmed ends it, so someone who
/// sits down after you leave can't pick it up; and it lasts at most `limit` without your face.
struct PresenceChain {
    static let gap: TimeInterval = 3
    /// How long input can carry on without your face (Settings › Typing keeps you here); 0 turns it off.
    var limit: TimeInterval = 90

    /// When you were last known to be here.
    private(set) var presence: Date
    private(set) var typing = false

    init(at date: Date, limit: TimeInterval = 90) {
        presence = date
        self.limit = limit
    }

    /// `faceAt` is when your confirmed face was last in view; `lastInput` the latest keyboard or mouse
    /// event. Returns "start" or why it ended, when that changes.
    mutating func update(now: Date, faceInView: Bool, faceAt: Date, lastInput: Date) -> String? {
        if faceInView {
            presence = max(presence, faceAt)
            defer { typing = false }
            return typing ? "face back" : nil
        }
        if lastInput > presence, lastInput.timeIntervalSince(presence) <= Self.gap, limit > 0, lastInput.timeIntervalSince(faceAt) <= limit {
            presence = lastInput
            defer { typing = true }
            return typing ? nil : "start"
        }
        if typing, now.timeIntervalSince(presence) > Self.gap {
            typing = false
            return lastInput.timeIntervalSince(faceAt) > limit ? "limit" : "input paused"
        }
        return nil
    }
}
