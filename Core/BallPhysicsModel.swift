//
//  BallPhysicsModel.swift
//  Swingline
//
//  Fits a ballistic trajectory to tracked ball positions and derives a flight
//  efficiency figure. Pure maths, no capture and no Vision, so it can be
//  reasoned about and tested on its own.
//
//  Honesty note that decides how this is used. This model is only as good as the
//  points fed to it, and reliably detecting a small fast ball in a captured
//  frame is the part that has never worked, in the web build or here, and cannot
//  be verified without a real strike clip. So this file provides the fit and
//  nothing pretends to have detected a ball. It stays dormant until real tracked
//  points arrive, exactly like the web ball flight, and the overlay draws it
//  only when a trajectory exists.
//
//  Coordinates are normalised image space, x and y in 0...1, y increasing
//  downward. The parabola is fitted directly and then evaluated, rather than
//  re-synthesised from an estimated gravity, so sign conventions cannot flip the
//  rendered path. g_px is still reported for reference.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import CoreGraphics

struct BallPhysicsModel {

    struct Trajectory {
        var positions: [CGPoint]
        var flightEfficiency: Double?
        var peakHeight: Double
        var horizontalDisplacement: Double
        var gravityPx: Double?
    }

    /*
      Fit x linearly and y quadratically against time, then evaluate the fitted
      model forward at 60 points a second until the ball leaves the bottom of the
      frame or six seconds pass. With fewer than five points there is not enough
      to fit a parabola, so it falls back to a straight constant velocity line
      from the last two points.
    */
    static func fitTrajectory(
        trackedPoints: [Point2D],
        times: [TimeInterval],
        gravityPx: Double? = nil
    ) -> Trajectory? {
        guard trackedPoints.count == times.count, trackedPoints.count >= 2 else { return nil }

        // Time from the first tracked point, in seconds. times are milliseconds
        // everywhere in this codebase, so convert.
        let t0 = times[0]
        let ts = times.map { ($0 - t0) / 1000.0 }

        if trackedPoints.count < 5 {
            return constantVelocityFallback(trackedPoints: trackedPoints, ts: ts)
        }

        let xs = trackedPoints.map { $0.x }
        let ys = trackedPoints.map { $0.y }

        // x(t) = vx t + x0
        guard let (vx, x0) = linearFit(ts, xs) else {
            return constantVelocityFallback(trackedPoints: trackedPoints, ts: ts)
        }
        // y(t) = c2 t^2 + c1 t + c0
        guard let (c2, c1, c0) = quadraticFit(ts, ys) else {
            return constantVelocityFallback(trackedPoints: trackedPoints, ts: ts)
        }

        // Gravity in px per second squared, from the curvature. In image space y
        // grows downward so a real shot curves with positive c2. Reported only.
        let gEstimate = abs(2.0 * c2)
        let gPx = gravityPx ?? (gEstimate > 1e-6 ? gEstimate : nil)

        // Evaluate forward.
        var positions: [CGPoint] = []
        let step = 1.0 / 60.0
        var t = 0.0
        while t <= 6.0 {
            let x = vx * t + x0
            let y = c2 * t * t + c1 * t + c0
            positions.append(CGPoint(x: x, y: y))
            if y > 0.95 { break }
            t += step
        }
        guard positions.count >= 2 else {
            return constantVelocityFallback(trackedPoints: trackedPoints, ts: ts)
        }

        return summarise(positions: positions, gravityPx: gPx)
    }

    // MARK: Fallback

    private static func constantVelocityFallback(trackedPoints: [Point2D], ts: [TimeInterval]) -> Trajectory? {
        guard trackedPoints.count >= 2 else { return nil }
        let a = trackedPoints[trackedPoints.count - 2]
        let b = trackedPoints[trackedPoints.count - 1]
        let dt = ts[ts.count - 1] - ts[ts.count - 2]
        guard dt > 1e-6 else { return nil }
        let vx = (b.x - a.x) / dt
        let vy = (b.y - a.y) / dt

        var positions: [CGPoint] = []
        let step = 1.0 / 60.0
        var t = 0.0
        while t <= 6.0 {
            let x = b.x + vx * t
            let y = b.y + vy * t
            positions.append(CGPoint(x: x, y: y))
            if y > 0.95 { break }
            t += step
        }
        guard positions.count >= 2 else { return nil }
        return summarise(positions: positions, gravityPx: nil)
    }

    // MARK: Summary

    private static func summarise(positions: [CGPoint], gravityPx: Double?) -> Trajectory {
        let xsEval = positions.map { $0.x }
        let ysEval = positions.map { $0.y }
        let horizontalDisplacement = abs((xsEval.last ?? 0) - (xsEval.first ?? 0))
        // Height above the launch point, y is down so the apex is the smallest y.
        let launchY = ysEval.first ?? 0
        let peakHeight = max(0, launchY - (ysEval.min() ?? launchY))
        let flightEfficiency: Double? = peakHeight > 1e-4 ? horizontalDisplacement / peakHeight : nil
        return Trajectory(
            positions: positions,
            flightEfficiency: flightEfficiency,
            peakHeight: peakHeight,
            horizontalDisplacement: horizontalDisplacement,
            gravityPx: gravityPx
        )
    }

    // MARK: Least squares

    // Returns (slope, intercept) for y = slope x + intercept.
    private static func linearFit(_ xs: [Double], _ ys: [Double]) -> (Double, Double)? {
        let n = Double(xs.count)
        guard n >= 2 else { return nil }
        let sx = xs.reduce(0, +)
        let sy = ys.reduce(0, +)
        let sxx = zip(xs, xs).reduce(0) { $0 + $1.0 * $1.1 }
        let sxy = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-12 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let intercept = (sy - slope * sx) / n
        return (slope, intercept)
    }

    // Returns (c2, c1, c0) for y = c2 x^2 + c1 x + c0 via the normal equations.
    private static func quadraticFit(_ xs: [Double], _ ys: [Double]) -> (Double, Double, Double)? {
        let n = Double(xs.count)
        guard n >= 3 else { return nil }
        var s0 = n, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var t0 = 0.0, t1 = 0.0, t2 = 0.0
        for i in 0..<xs.count {
            let x = xs[i], y = ys[i]
            let x2 = x * x
            s1 += x; s2 += x2; s3 += x2 * x; s4 += x2 * x2
            t0 += y; t1 += x * y; t2 += x2 * y
        }
        // Solve the 3x3 system A c = b for c = (c0, c1, c2).
        let A = [[s0, s1, s2], [s1, s2, s3], [s2, s3, s4]]
        let b = [t0, t1, t2]
        guard let c = solve3x3(A, b) else { return nil }
        return (c[2], c[1], c[0])
    }

    private static func solve3x3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        func det3(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det3(A)
        guard abs(d) > 1e-12 else { return nil }
        var result = [Double](repeating: 0, count: 3)
        for col in 0..<3 {
            var m = A
            for row in 0..<3 { m[row][col] = b[row] }
            result[col] = det3(m) / d
        }
        return result
    }
}
