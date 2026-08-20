import Foundation

/*
  Coaching cues.

  One fault, one sentence, one thing to go and do. Every cue is written to be
  said out loud to somebody standing over a ball, which is why none of them
  contain a biomechanics term. The internal_ field is the explanation of what
  actually happened, and it lives behind a disclosure rather than on the front
  of the screen, because a beginner who is handed a mechanism instead of an
  instruction has been given homework rather than help.

  Three registers per fault:
    cue         what to feel or do, phrased around the body
    distal      the same fix phrased around the club or the ball
    constraint  a setup that makes the fault physically hard to commit

  Distal cues are withheld until a golfer has recorded enough swings to have a
  feel for their own movement. An external focus outperforms an internal one in
  the motor learning literature, but only once there is something to attach it
  to, so DISTAL_AFTER_SWINGS gates it.

  Translated from packages/core/src/cues.ts.

  CueEntry, CueResult and CueFocus all live in CoreTypes.swift. This file used
  to declare its own nested CueEntry with identical fields, which meant two
  types with one name and a compiler that had to guess which one a call site
  meant. The nested copy is gone.
*/

public enum Cues {

    public static let DISTAL_AFTER_SWINGS = 40

    public static let CUES: [String: CueEntry] = [
        "upper-body-first": CueEntry(
            cue: "Start down by pushing the ground away with your front foot, and let the club fall on its own.",
            distal: "Swing the clubhead out toward a spot a few feet in front of the ball, on your target line.",
            constraint: "Feet together, then step toward the target as you swing down. The step has to happen first.",
            internal_: "Your chest reached top speed before your hips did, which reverses the order speed is meant to travel in."
        ),
        "all-at-once": CueEntry(
            cue: "Let the clubhead be the last thing to arrive at the ball.",
            distal: "Sling the clubhead past your hands and out toward the target.",
            constraint: "Swing at half speed and try to make the clubhead feel late. Ten of those before any full swing.",
            internal_: "Hips, chest and arms all peaked together, so nothing handed speed on to anything else."
        ),
        "arms-before-chest": CueEntry(
            cue: "Keep the club pointing behind you for longer, then let it go.",
            distal: "Throw the clubhead out past the ball toward the target, not down at the ball.",
            constraint: "Pump down to hip height twice and stop, then swing on the third. Watch where the club is.",
            internal_: "Your hips led correctly, then your arms overtook your torso instead of waiting for it."
        ),
        "rushed-backswing": CueEntry(
            cue: "Two beats going back, one beat coming down. Let the metronome set it, not your hands.",
            distal: "Take it back slowly enough that you could stop the club at the top without wobbling.",
            constraint: "Say \"one, two\" out loud on the way back and \"three\" on the way down. Every swing.",
            internal_: "Your backswing was too quick relative to your downswing, which leaves no time to change direction properly."
        ),
        "reverse-pivot": CueEntry(
            cue: "Press down into your back foot as the club goes back, like you are screwing it into the ground.",
            distal: "Feel the ground push back at you from the trail side at the top.",
            constraint: "Make backswings with your front foot lifted off the ground. You cannot lean the wrong way.",
            internal_: "Your weight moved toward the target during the backswing instead of away from it."
        ),
        "no-weight-shift": CueEntry(
            cue: "Push the ground toward the target as the club changes direction.",
            distal: "Finish with all your weight stacked over your front foot and the ball long gone.",
            constraint: "Step into the shot. Start with feet together and step toward the target as you swing.",
            internal_: "Your weight stayed where it started through the downswing rather than moving to the front foot."
        ),
        "head-sway": CueEntry(
            cue: "Keep the ball sitting in the same place in your vision the whole way back.",
            distal: "Let the ball stay still in your eyes while everything else turns around it.",
            constraint: "Swing with your back against a doorframe, or have somebody hold a club lightly against your trail hip.",
            internal_: "Your head moved sideways across the swing rather than staying over the ball."
        ),
        "no-separation": CueEntry(
            cue: "Turn your shirt buttons away from the target while your belt buckle stays looking at the ball.",
            distal: "Feel the club get further behind you at the top without your belt moving.",
            constraint: "Cross your arms over your chest, hold a club against your shoulders, and turn. Hips stay quiet.",
            internal_: "Your chest and hips turned as one block, so there was no stretch stored between them."
        ),
        "lost-stretch": CueEntry(
            cue: "Let your belt buckle start toward the target while the club is still finishing its backswing.",
            distal: "Feel the club being left behind as your front side starts to clear.",
            constraint: "Pump drill. Get to the top, start down to hip height, back to the top, then swing.",
            internal_: "The separation you built at the top disappeared as soon as you changed direction."
        ),
        "short-turn": CueEntry(
            cue: "Get the clubhead all the way behind your back shoulder before you change direction.",
            distal: "At the top, the club should be pointing somewhere near your target.",
            constraint: "Cross-arm turns against a wall until the range of motion is there. If it is not, this is a mobility job, not a swing job.",
            internal_: "Your backswing stopped short of the range you have available."
        ),
        "spine-drift": CueEntry(
            cue: "Keep your backside touching an imaginary chair right through the strike.",
            distal: "Stay down long enough to see the club leave the ground after the ball.",
            constraint: "Set up with your backside lightly against a wall or a chair and swing without losing contact until after impact.",
            internal_: "You came up out of your setup posture during the downswing, which changes how far you are from the ball at the strike."
        ),
        "narrow-takeaway": CueEntry(
            cue: "Push the clubhead low along the ground for the first foot of the takeaway.",
            distal: "Send the clubhead as far away from the ball as you can before it starts up.",
            constraint: "Put a headcover a foot behind the ball on your target line and sweep it away as you take the club back.",
            internal_: "Your hands lifted the club rather than swinging it back, which narrows the arc early."
        ),
        "unbalanced-finish": CueEntry(
            cue: "Finish with your weight on the outside of your front shoe and hold it while you count to three.",
            distal: "Hold the finish until the ball has stopped rolling.",
            constraint: "Hit shots at half speed and do not let yourself take a step. If you step, that swing did not count.",
            internal_: "You finished falling forward onto the front foot rather than balanced over it."
        ),
        "falling-finish": CueEntry(
            cue: "Hold your finish until the ball lands.",
            distal: "Watch the ball all the way down from a finish you have not moved out of.",
            constraint: "Feet together, swing at half speed. You cannot fall over without noticing.",
            internal_: "You could not hold the finish position, which usually means the swing was faster than your balance could carry."
        ),
        "stance-narrow": CueEntry(
            cue: "Set your feet so a club laid across your toes reaches roughly armpit to armpit.",
            distal: "Stand wide enough that you can hold a balanced finish while the ball is still in the air.",
            constraint: "Lay a club on the ground across your toes and check it before every swing for one session.",
            internal_: "Your stance was narrower than your shoulders, which gives balance less base to work with."
        )
    ]

    /* Fallback when a category is weak but no named fault fired. Says the true
       thing, which is that this is the weakest area, rather than inventing a
       fault to have something to talk about. */
    public static let GENERIC_CUES: [CategoryKey: CueEntry] = [
        .sequencing: CueEntry(
            cue: "Let the clubhead be the last thing to arrive.",
            distal: "Sling the clubhead out toward the target after the ball.",
            constraint: "Half speed swings where the club feels late. Ten of them.",
            internal_: "Sequencing is the weakest of your four categories in this swing."
        ),
        .rotation: CueEntry(
            cue: "Turn your shirt buttons further away from the target going back.",
            distal: "Get the club pointing at your target at the top.",
            constraint: "Cross-arm turns, club across the shoulders, hips quiet.",
            internal_: "Rotation is the weakest of your four categories in this swing."
        ),
        .balance: CueEntry(
            cue: "Press into the ground and finish with your weight over your front foot.",
            distal: "Hold the finish until the ball lands.",
            constraint: "Feet together, half speed, no stepping.",
            internal_: "Balance is the weakest of your four categories in this swing."
        ),
        .finish: CueEntry(
            cue: "Hold your finish until the ball lands.",
            distal: "Watch the ball down without moving out of the finish.",
            constraint: "Hold every finish for a slow count of three.",
            internal_: "Your finish position is the weakest of your four categories in this swing."
        )
    ]

    public static func cueFor(faultId: String, category: CategoryKey? = nil, swingCount: Int = 0) -> CueResult? {
        guard let entry = CUES[faultId] ?? category.flatMap({ GENERIC_CUES[$0] }) else { return nil }
        let useDistal = swingCount >= DISTAL_AFTER_SWINGS && entry.distal != nil
        return CueResult(
            cue: useDistal ? entry.distal! : entry.cue,
            constraint: entry.constraint,
            internal_: entry.internal_,
            focus: useDistal ? .distal : .proximal
        )
    }

    /* Any fault the diagnosis can fire that has no cue written for it. A fault
       with no cue is a headline with nothing underneath it, so this exists to
       be checked rather than to be discovered by a golfer. */
    public static func missingCues(faultIds: [String]) -> [String] {
        faultIds.filter { CUES[$0] == nil }
    }
}
