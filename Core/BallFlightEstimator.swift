//
//  BallFlightEstimator.swift
//  Swingline
//
//  Estimates ball flight from body pose. Read this before trusting a number.
//
//  These are model estimates, not measurements. One quantity is measured, the
//  lead hand speed at impact. Everything after it is a club average lookup:
//  smash factor, carry efficiency and spin are fixed per club, and launch angle
//  is a fitted line off the forearm angle then clamped into a club range. Two
//  golfers with the same hand speed and the same selected club get identical
//  ball speed, carry and spin from this, however differently they actually
//  struck it. The carry formula is the vacuum projectile result times an
//  efficiency constant, so it ignores aerodynamics entirely and is a stock
//  ballpark, not a real carry.
//
//  So every figure this produces is shown labelled Est., its card's confidence
//  dot reflects how well the body was tracked rather than how good the guess is,
//  and the trajectory is a schematic indicator, not a path registered to the
//  scene. The club is a user setting, never detected from pose, which is not
//  possible.
//
//  House rule: no em dashes anywhere.
//

import Foundation
import CoreGraphics

public enum ClubType: String, CaseIterable, Codable {
    case driver, iron3, iron5, iron7, iron9, pw, wedge

    var label: String {
        switch self {
        case .driver: return "Driver"
        case .iron3: return "3 Iron"
        case .iron5: return "5 Iron"
        case .iron7: return "7 Iron"
        case .iron9: return "9 Iron"
        case .pw: return "Pitching Wedge"
        case .wedge: return "Sand Wedge"
        }
    }

    var clubLength: Double {
        switch self {
        case .driver: return 1.15
        case .iron3: return 0.99
        case .iron5: return 0.97
        case .iron7: return 0.95
        case .iron9: return 0.93
        case .pw: return 0.91
        case .wedge: return 0.89
        }
    }

    var speedMultiplier: Double {
        switch self {
        case .driver: return 3.0
        case .iron3: return 2.7
        case .iron5: return 2.5
        case .iron7: return 2.3
        case .iron9: return 2.1
        case .pw: return 2.0
        case .wedge: return 1.8
        }
    }

    var smashFactor: Double {
        switch self {
        case .driver: return 1.47
        case .iron3: return 1.40
        case .iron5: return 1.38
        case .iron7: return 1.36
        case .iron9: return 1.34
        case .pw: return 1.32
        case .wedge: return 1.28
        }
    }

    var carryEfficiency: Double {
        switch self {
        case .driver: return 0.95
        case .iron3, .iron5, .iron7, .iron9: return 0.88
        case .pw, .wedge: return 0.82
        }
    }

    var defaultSpin: Int {
        switch self {
        case .driver: return 2600
        case .iron3: return 3500
        case .iron5: return 4500
        case .iron7: return 5600
        case .iron9: return 7500
        case .pw: return 8500
        case .wedge: return 9500
        }
    }

    var launchAngleRange: ClosedRange<Double> {
        switch self {
        case .driver: return 8.0...16.0
        case .iron3: return 7.0...14.0
        case .iron5: return 9.0...16.0
        case .iron7: return 12.0...20.0
        case .iron9: return 15.0...24.0
        case .pw: return 18.0...28.0
        case .wedge: return 20.0...30.0
        }
    }
}

struct BallFlightEstimator {
    static let gravity: Double = 9.81

    // v_clubhead = k_club x v_wrist. armLength is accepted for a future physical
    // model but the shipped estimate uses the per club multiplier.
    static func estimateClubheadSpeed(wristSpeed: Double, club: ClubType, armLength: Double) -> Double {
        wristSpeed * club.speedMultiplier
    }

    static func estimateBallSpeed(clubheadSpeed: Double, club: ClubType) -> Double {
        clubheadSpeed * club.smashFactor
    }

    static func estimateLaunchAngle(forearmAngleFromVertical: Double, spineTilt: Double, club: ClubType) -> Double {
        let launch = 0.8 * forearmAngleFromVertical - 4.0 - 0.2 * spineTilt
        let range = club.launchAngleRange
        return min(max(launch, range.lowerBound), range.upperBound)
    }

    // Vacuum projectile carry times a per club efficiency. Ignores aerodynamics,
    // so it is a stock ballpark rather than a real carry.
    static func estimateCarryDistance(ballSpeed: Double, launchAngleDeg: Double, club: ClubType) -> Double {
        let theta = launchAngleDeg * .pi / 180.0
        let vacuum = (ballSpeed * ballSpeed * sin(2.0 * theta)) / gravity
        return vacuum * club.carryEfficiency
    }

    static func estimateSpinRate(club: ClubType) -> Int { club.defaultSpin }

    /*
      A schematic flight, not a scene registered path.

      The projection constants are arbitrary (150m of carry drawn as 0.8 of the
      image width), because there is no real camera geometry to register against.
      It gives the eye a plausible arc off the impact point and nothing more.
    */
    static func generateTrajectory(
        ballSpeed: Double,
        launchAngleDeg: Double,
        startPoint: CGPoint,
        duration: Double = 6.0,
        steps: Int = 60
    ) -> [CGPoint] {
        let theta = launchAngleDeg * .pi / 180.0
        let vx = ballSpeed * cos(theta)
        let vy = ballSpeed * sin(theta)
        let scaleX = 0.8 / 150.0
        let scaleY = 0.5 / 30.0

        var points: [CGPoint] = []
        let dt = duration / Double(steps)
        for i in 0...steps {
            let t = Double(i) * dt
            let xWorld = vx * t
            let yWorld = vy * t - 0.5 * gravity * t * t
            let x = startPoint.x + xWorld * scaleX
            let y = startPoint.y - yWorld * scaleY
            if y > 1.0 || y < 0.0 { break }
            points.append(CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)))
        }
        return points
    }
}

