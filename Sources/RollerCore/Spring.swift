import Foundation

/// A damped spring that moves progress from 0 to 1.
///
/// `duration` is the perceived duration: a critically damped spring is
/// within 1% of its target after that time. `damping` is the damping ratio:
/// 1.0 settles without overshoot, lower values bounce.
public struct Spring: Equatable {
    public var duration: Double
    public var damping: Double

    public init(duration: Double, damping: Double) {
        self.duration = max(duration, 0)
        self.damping = min(max(damping, 0.05), 1)
    }

    /// Natural angular frequency chosen so a critically damped spring
    /// reaches 99% at `duration` ((1 + wt) e^-wt = 0.01 at wt ~ 6.64).
    var omega: Double { 6.638 / max(duration, 0.001) }

    /// Progress at time `t` seconds.
    public func value(at t: Double) -> Double {
        guard duration > 0 else { return 1 }
        if t <= 0 { return 0 }
        let w = omega, z = damping
        if z >= 0.999 {
            return 1 - (1 + w * t) * exp(-w * t)
        }
        let wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
    }

    /// Whether the spring has come to rest at time `t`.
    public func isSettled(at t: Double) -> Bool {
        guard duration > 0 else { return true }
        if t >= duration * 4 { return true }
        guard t >= duration * 0.5 else { return false }
        // The envelope bounds every future deviation.
        let envelope = damping >= 0.999
            ? (1 + omega * t) * exp(-omega * t)
            : exp(-damping * omega * t) / (1 - damping * damping).squareRoot()
        return envelope < 0.002
    }
}

/// Linear interpolation helpers.
public enum Lerp {
    public static func value(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    public static func rect(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: value(Double(a.minX), Double(b.minX), t),
               y: value(Double(a.minY), Double(b.minY), t),
               width: value(Double(a.width), Double(b.width), t),
               height: value(Double(a.height), Double(b.height), t))
    }
}
