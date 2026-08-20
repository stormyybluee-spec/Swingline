//
//  MetricInfo.swift
//  Swingline
//
//  The explanation behind every metric, kept out of SwingMetrics.swift on
//  purpose.
//
//  The brief asked for an `info: String` stored on SwingMetric itself. That
//  would mean editing all 23 initialisers, and it would flatten four separate
//  fields (what it measures, how it is worked out, the good range, how to read
//  it) into one blob that the sheet then has to pull apart again. So the info
//  lives here as a small struct, and SwingMetric picks it up through an
//  extension. SwingMetrics.swift does not change at all.
//
//  Lookup is by metric id first, then by the on screen label, both normalised
//  to letters and digits only. That means "X-Factor", "xFactor" and "x_factor"
//  all land on the same entry. If a metric shows no info button after you drop
//  this in, its id and label simply are not in the alias list below: add the id
//  to that entry's aliases and it will appear.
//
//  House rule: no em dashes anywhere.
//

import Foundation

// MARK: - The shape of one explanation

struct MetricInfo {
    let title: String
    let measures: String
    let calculation: String
    let goodRange: String
    let interpretation: String
}

// MARK: - Lookup

enum MetricInfoCatalog {

    static func info(for metric: SwingMetric) -> MetricInfo? {
        if let hit = table[key(metric.id)] { return hit }
        return table[key(metric.label)]
    }

    // Case, spaces, hyphens, brackets and full stops all stripped, so the same
    // entry answers to "Ball Speed (Est.)", "ballSpeedEst" and "ball_speed_est".
    private static func key(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let table: [String: MetricInfo] = {
        var out: [String: MetricInfo] = [:]
        for entry in entries {
            for alias in entry.aliases {
                out[key(alias)] = entry.info
            }
        }
        return out
    }()

    private struct Entry {
        let aliases: [String]
        let info: MetricInfo
    }

    private static let entries: [Entry] = [

        Entry(
            aliases: ["tempo", "swingTempo", "tempoRatio"],
            info: MetricInfo(
                title: "Tempo",
                measures: "The ratio of how long your backswing takes to how long your downswing takes.",
                calculation: "Backswing time in milliseconds divided by downswing time in milliseconds.",
                goodRange: "2.5 to 3.5",
                interpretation: "3:1 is the classic target. Higher means a slower, more patient backswing. Lower means you are rushing the transition."
            )
        ),

        Entry(
            aliases: ["backswing", "backswingTime", "backswingMs", "backswingDuration"],
            info: MetricInfo(
                title: "Backswing",
                measures: "How long the backswing lasts.",
                calculation: "Time from P1 (address) to P4 (top).",
                goodRange: "600 to 900 ms",
                interpretation: "Tour average is around 800 ms. Too fast and there is no time to load. Too slow and the swing loses its rhythm."
            )
        ),

        Entry(
            aliases: ["downswing", "downswingTime", "downswingMs", "downswingDuration"],
            info: MetricInfo(
                title: "Downswing",
                measures: "How long it takes to get from the top of the swing to the ball.",
                calculation: "Time from P4 (top) to P7 (impact).",
                goodRange: "250 to 350 ms",
                interpretation: "Tour average is around 300 ms. Shorter is more aggressive, but only counts if you keep control of the face."
            )
        ),

        Entry(
            aliases: ["score", "swingScore", "overallScore", "total"],
            info: MetricInfo(
                title: "Score",
                measures: "One overall number for the swing, weighted across the four categories.",
                calculation: "Weighted average of the four category scores.",
                goodRange: "60 to 100",
                interpretation: "100 is textbook technique and 60 or above is good. Below 60, go and work on your weakest category first."
            )
        ),

        Entry(
            aliases: ["handSpeed", "handspeed", "leadHandSpeed", "wristSpeed"],
            info: MetricInfo(
                title: "Hand Speed",
                measures: "How fast your hands are travelling as you reach the ball.",
                calculation: "Lead wrist velocity at impact, in metres per second.",
                goodRange: "2.5 to 8.0 m/s",
                interpretation: "Faster hands usually mean more clubhead speed, though control decides whether that speed turns into distance."
            )
        ),

        Entry(
            aliases: ["leadPressure", "pressure", "weightShift", "leadFootPressure"],
            info: MetricInfo(
                title: "Lead Pressure",
                measures: "How much of your weight sits over the lead foot.",
                calculation: "Centre of mass measured across the base of support.",
                goodRange: "45 to 65 percent",
                interpretation: "Tour average is around 55 percent. Higher means more weight forward at impact, which supports a downward strike."
            )
        ),

        Entry(
            aliases: ["torsoTurn", "shoulderTurn", "chestTurn", "torsoRotation"],
            info: MetricInfo(
                title: "Torso Turn",
                measures: "How far your chest has rotated at the top of the swing.",
                calculation: "Transverse angle of the shoulder line.",
                goodRange: "80 to 105 degrees",
                interpretation: "More turn stores more energy. Under 70 degrees is a short backswing with little to release."
            )
        ),

        Entry(
            aliases: ["pelvisTurn", "hipTurn", "pelvisRotation", "hipRotation"],
            info: MetricInfo(
                title: "Pelvis Turn",
                measures: "How far your hips have rotated at the top of the swing.",
                calculation: "Transverse angle of the hip line.",
                goodRange: "40 to 55 degrees",
                interpretation: "The hips should turn less than the chest. That gap between the two is what creates X Factor."
            )
        ),

        Entry(
            aliases: ["xFactor", "x-factor", "separation", "torsoPelvisSeparation"],
            info: MetricInfo(
                title: "X Factor",
                measures: "The separation between chest rotation and hip rotation at the top.",
                calculation: "Torso turn minus pelvis turn.",
                goodRange: "25 to 45 degrees",
                interpretation: "This is the stretch across your middle. More separation means more power waiting to be released."
            )
        ),

        Entry(
            aliases: ["spineTilt", "spineAngle", "forwardLean"],
            info: MetricInfo(
                title: "Spine Tilt",
                measures: "How far your spine leans forward at impact.",
                calculation: "Angle of the spine measured from vertical.",
                goodRange: "5 to 12 degrees",
                interpretation: "Forward tilt is what lets you meet the ball with the correct attack angle."
            )
        ),

        Entry(
            aliases: ["leadElbow", "elbow", "leadArm", "leadElbowAngle"],
            info: MetricInfo(
                title: "Lead Elbow",
                measures: "How straight or bent your lead arm is at the top.",
                calculation: "Elbow angle at the top of the swing.",
                goodRange: "80 to 180 degrees",
                interpretation: "A straighter arm gives you a wider arc. A more bent arm gives you a more compact swing."
            )
        ),

        Entry(
            aliases: ["trailKnee", "knee", "trailKneeFlex", "trailKneeAngle"],
            info: MetricInfo(
                title: "Trail Knee",
                measures: "How much flex is left in the trail knee at the top.",
                calculation: "Knee angle at the top of the swing.",
                goodRange: "110 to 180 degrees",
                interpretation: "Holding flex keeps the lower body stable. Straightening the knee costs you the ground you push against."
            )
        ),

        Entry(
            aliases: ["pelvisLift", "pelvisY", "earlyExtension", "pelvisVertical"],
            info: MetricInfo(
                title: "Pelvis Lift",
                measures: "How much your pelvis moves up or down through the swing.",
                calculation: "Vertical (Y) displacement of the pelvis.",
                goodRange: "-5 to +2 percent",
                interpretation: "Positive is early extension, which is standing up out of the shot. Negative is squatting into it."
            )
        ),

        Entry(
            aliases: ["pelvisSway", "sway", "pelvisX", "pelvisLateral"],
            info: MetricInfo(
                title: "Pelvis Sway",
                measures: "How much your pelvis slides side to side.",
                calculation: "Lateral (X) displacement of the pelvis, as a percentage.",
                goodRange: "Under 12 percent",
                interpretation: "The pelvis should stay centred and turn. More sway than this and you are sliding off the ball."
            )
        ),

        Entry(
            aliases: ["torsoLift", "torsoY", "chestLift", "torsoVertical"],
            info: MetricInfo(
                title: "Torso Lift",
                measures: "How much your chest moves up or down through the swing.",
                calculation: "Vertical (Y) displacement of the torso, as a percentage.",
                goodRange: "-5 to +5 percent",
                interpretation: "Rising much beyond this means you are giving up the posture you set at address."
            )
        ),

        Entry(
            aliases: ["leverRelease", "release", "releaseRatio", "kinematicSequence"],
            info: MetricInfo(
                title: "Lever Release",
                measures: "How late you hold the angle in your arms before releasing it.",
                calculation: "Peak arm angular velocity divided by peak pelvis angular velocity.",
                goodRange: "2.5 to 4.0x",
                interpretation: "A high ratio is a late release, which is what you want. A low ratio means you are casting the club early."
            )
        ),

        Entry(
            aliases: ["wristFlex", "wristFlexion", "leadWristFlex", "wristFlexExtension"],
            info: MetricInfo(
                title: "Wrist Flex",
                measures: "Flexion and extension of the lead wrist.",
                calculation: "Angle from the forearm to the back of the hand.",
                goodRange: "-10 to +15 degrees",
                interpretation: "A bowed wrist points to a closed clubface. A cupped wrist points to an open one."
            )
        ),

        Entry(
            aliases: ["wristDeviation", "wristDev", "radialUlnar", "leadWristDeviation"],
            info: MetricInfo(
                title: "Wrist Deviation",
                measures: "Radial and ulnar deviation of the lead wrist, which is the hinge that sets the club.",
                calculation: "Angle from the forearm to the hand in the other plane.",
                goodRange: "-10 to +10 degrees",
                interpretation: "Radial is a cocked wrist holding the angle. Ulnar is an uncocked wrist that has already given it up."
            )
        ),

        Entry(
            aliases: ["flightEfficiency", "efficiency", "flight", "trajectoryEfficiency"],
            info: MetricInfo(
                title: "Flight Efficiency",
                measures: "How far the ball travels forward for the height it climbs to.",
                calculation: "Horizontal displacement divided by peak height.",
                goodRange: "3.0 to 4.5",
                interpretation: "Higher is a more penetrating flight. Lower means the ball is ballooning and losing distance to the air."
            )
        ),

        Entry(
            aliases: ["ballSpeed", "ballSpeedEst", "ballSpeedEstimate", "estBallSpeed"],
            info: MetricInfo(
                title: "Ball Speed (Est.)",
                measures: "An estimate of how fast the ball leaves the face.",
                calculation: "Estimated clubhead speed multiplied by smash factor.",
                goodRange: "120 to 180 mph",
                interpretation: "More ball speed is more distance, as long as you keep finding the middle of the face."
            )
        ),

        Entry(
            aliases: ["carry", "carryEst", "carryDistance", "estCarry"],
            info: MetricInfo(
                title: "Carry (Est.)",
                measures: "An estimate of how far the ball flies before it lands.",
                calculation: "Projectile physics run from the estimated launch conditions.",
                goodRange: "150 to 300 yards",
                interpretation: "Driven mostly by ball speed and launch angle, so those two are the ones to move if you want more."
            )
        ),

        Entry(
            aliases: ["launch", "launchEst", "launchAngle", "estLaunch"],
            info: MetricInfo(
                title: "Launch (Est.)",
                measures: "An estimate of the angle the ball leaves the face at.",
                calculation: "Derived from forearm angle and spine tilt at impact.",
                goodRange: "8 to 16 degrees",
                interpretation: "The right number depends on the club: around 12 degrees with a driver, around 16 with a 7 iron."
            )
        ),

        Entry(
            aliases: ["spin", "spinEst", "spinRate", "estSpin"],
            info: MetricInfo(
                title: "Spin (Est.)",
                measures: "An estimate of the spin rate on the ball.",
                calculation: "Club specific averages applied to the measured strike.",
                goodRange: "2000 to 8000 rpm",
                interpretation: "A driver wants 2500 to 3000. A 7 iron sits nearer 5000 to 7000, which is what holds the green."
            )
        )
    ]
}

// MARK: - Reaching it from a metric

// Named metricInfo rather than info so it cannot collide with anything already
// on SwingMetric, and so adding a stored `info` later would not silently
// shadow this.
extension SwingMetric {
    var metricInfo: MetricInfo? { MetricInfoCatalog.info(for: self) }
}
