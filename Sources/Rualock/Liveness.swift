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
    static let blinkMax: CFTimeInterval = 0.6   // closed longer than this isn't a blink (looking down)
    static let closed = 0.6                     // eyes below this fraction of their recent openness: closed
    static let reopened = 0.85                  // and back above this: open again

    private(set) var lastSeen: CFTimeInterval = 0
    /// Blinked, or trusted because you had just unlocked.
    private(set) var verified = false
    /// The latest recognition result for this face.
    var matched = false
    private var box: CGRect?
    private var history: [(t: CFTimeInterval, v: Double)] = []
    private var closedSince: CFTimeInterval?

    /// Picks which of this frame's faces continues the track (nil if none is visible) and
    /// starts a new track when the face is a different one or came back after a gap.
    mutating func update(_ faces: [FaceEngine.Face], at t: CFTimeInterval) -> FaceEngine.Face? {
        if let box, t - lastSeen <= Self.maxGap,
           let best = faces.max(by: { iou($0.box, box) < iou($1.box, box) }), iou(best.box, box) >= Self.minOverlap {
            follow(best, at: t)
            return best
        }
        guard let face = faces.first else {
            if t - lastSeen > Self.maxGap { self = FaceTrack() }
            return nil
        }
        self = FaceTrack()
        follow(face, at: t)
        return face
    }

    /// Mark this track as you without a blink (you've just unlocked with your password or Touch ID).
    mutating func trust() { verified = true }

    private mutating func follow(_ face: FaceEngine.Face, at t: CFTimeInterval) {
        box = face.box
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
            if t - since <= Self.blinkMax { verified = true }
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
