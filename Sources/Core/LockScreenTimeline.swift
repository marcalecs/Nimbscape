import Foundation

/// Frame schedule for a lock-screen video: plays normally, eases to a stop, then holds the last
/// frame until the file is long enough. macOS decides how long the lock screen plays the file,
/// so the "play for N seconds" setting is baked into the video itself.
///
/// Output is at the source frame rate with a uniform frame duration; each entry says whether
/// that output frame shows the next source frame (`true`) or repeats the previous one (`false`).
public enum LockScreenTimeline {
    /// Durations the user can pick.
    public enum PlayDuration: Int, CaseIterable, Codable, Sendable {
        case seconds30 = 30, minutes2 = 120, minutes5 = 300

        public var displayName: String {
            switch self {
            case .seconds30: return "30 s"
            case .minutes2: return "2 min"
            case .minutes5: return "5 min"
            }
        }
    }

    /// Minimum file length: shorter files freeze after one pass on the lock screen.
    public static let minimumTotalSeconds: Double = 300
    /// Length of the ease-out before the hold.
    public static let easeOutSeconds: Double = 1.5
    /// Each source frame is shown up to this many times at the end of the ease-out.
    public static let easeOutMaxRepeat = 8

    /// - Parameters:
    ///   - fps: source (and output) frame rate.
    ///   - playSeconds: how long the video plays normally before easing out.
    /// - Returns: one flag per output frame; `true` = advance to the next source frame.
    public static func advanceFlags(fps: Double, playSeconds: Double) -> [Bool] {
        let fps = max(1, fps)
        // Playing the whole minimum length needs no ease-out or hold.
        let totalSeconds = playSeconds >= minimumTotalSeconds ? playSeconds : max(minimumTotalSeconds, playSeconds + easeOutSeconds)
        let total = Int((totalSeconds * fps).rounded(.up))
        var flags: [Bool] = []
        flags.reserveCapacity(total)

        // 1. Normal playback.
        let playFrames = min(total, Int((playSeconds * fps).rounded()))
        flags.append(contentsOf: repeatElement(true, count: playFrames))

        // 2. Ease out: each source frame repeated more and more (ease-in of the slowdown).
        if playSeconds < minimumTotalSeconds {
            let easeFrames = Int((easeOutSeconds * fps).rounded())
            var produced = 0
            while produced < easeFrames && flags.count < total {
                let progress = Double(produced) / Double(max(1, easeFrames))
                let repeats = max(1, Int((1 + progress * progress * Double(easeOutMaxRepeat - 1)).rounded()))
                flags.append(true)
                produced += 1
                for _ in 1..<repeats where produced < easeFrames && flags.count < total {
                    flags.append(false)
                    produced += 1
                }
            }
        }

        // 3. Hold the last frame until the file is long enough.
        if flags.count < total {
            flags.append(contentsOf: repeatElement(false, count: total - flags.count))
        }
        return flags
    }
}
