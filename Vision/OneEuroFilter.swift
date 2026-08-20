//
//  OneEuroFilter.swift
//  Swingline
//
//  The One Euro Filter (Casiez, Roussel, Vogel, 2012), a speed adaptive low pass
//  filter. It smooths slow movement hard, to kill jitter, and lets fast movement
//  through, to keep latency low. That trade is exactly what a live pose preview
//  wants: still hands stop shaking, a fast downswing stays responsive.
//
//  Used on the live capture path only. The analysis path keeps its non causal
//  Savitzky Golay smoothing, which can look ahead because playback is not live.
//
//  House rule: no em dashes anywhere.
//

import Foundation

/// A single scalar One Euro Filter. One instance per coordinate channel.
final class OneEuroScalar {
    private var minCutoff: Double
    private var beta: Double
    private var dCutoff: Double

    private var lastValue: Double = 0
    private var lastDeriv: Double = 0
    private var lastTime: Double?
    private var started = false

    init(minCutoff: Double = 1.0, beta: Double = 0.0, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    func reset() {
        started = false
        lastTime = nil
    }

    /// Filter one sample. `timestamp` is in seconds.
    func filter(_ value: Double, timestamp: Double) -> Double {
        guard started, let previousTime = lastTime, timestamp > previousTime else {
            started = true
            lastValue = value
            lastDeriv = 0
            lastTime = timestamp
            return value
        }

        let dt = timestamp - previousTime
        lastTime = timestamp

        // Derivative of the signal, itself low pass filtered at dCutoff.
        let rawDeriv = (value - lastValue) / dt
        let deriv = Self.lowPass(rawDeriv, previous: lastDeriv, alpha: Self.alpha(cutoff: dCutoff, dt: dt))
        lastDeriv = deriv

        // The cutoff rises with speed, so quick motion is filtered less.
        let cutoff = minCutoff + beta * abs(deriv)
        let filtered = Self.lowPass(value, previous: lastValue, alpha: Self.alpha(cutoff: cutoff, dt: dt))
        lastValue = filtered
        return filtered
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * max(cutoff, 1e-6))
        return 1.0 / (1.0 + tau / max(dt, 1e-6))
    }

    private static func lowPass(_ value: Double, previous: Double, alpha: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}

/// A bank of One Euro Filters, one per array position, so a whole landmark array
/// can be smoothed channel by channel across frames.
final class OneEuroVectorFilter {
    private var channels: [OneEuroScalar] = []
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double

    init(minCutoff: Double = 1.0, beta: Double = 0.0, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    func reset() { channels.forEach { $0.reset() } }

    /// Filter an array of values against the same timestamp. The bank grows to fit
    /// the array on first use and stays fixed after, so index i is always the same
    /// channel.
    func filter(_ values: [Double], timestamp: Double) -> [Double] {
        if channels.count != values.count {
            channels = (0..<values.count).map { _ in
                OneEuroScalar(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
            }
        }
        return zip(channels, values).map { $0.filter($1, timestamp: timestamp) }
    }
}
