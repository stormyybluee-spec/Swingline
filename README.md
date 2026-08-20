# Swingline, consolidated source

The final source for the Swingline iOS app, every file carrying all changes from
Phases 1 through 6 applied in order. This is a source tree, not a packaged
.xcodeproj. Drop the folders into your existing Swingline Xcode project (or a
fresh iOS 17 SwiftUI app target) and make sure every file is a member of the app
target.

## What is here

- App/ app entry, state and settings, persistence, the record and legacy models.
- Core/ the engine: geometry, biomechanics, phases, sequencing, scoring,
  diagnosis, validity, the pose provider protocol, the honesty layer (DeviceTier,
  SessionQuality), and the ballistics estimators.
- Views/ every SwiftUI screen and the shared components, theme, overlays, the
  3D rig, playback, and the settings sheets.
- Vision/ the Vision backed pose provider, including the live stabilisation.
- Resources/Info.plist with the four required privacy usage strings.

## Phase coverage

- Phase 1, honesty layer: DeviceTier, SessionQuality, FPS adaptive smoothing in
  Geometry, view gated metrics, the measurement badge in AnalysisView.
- Phase 2, the medium: pelvis and torso lift, sway and thrust, lever arm release,
  the per frame paths and SwingSeries.fillStability.
- Phase 3, ballistics and grip: BallPhysicsModel, BallFlightEstimator, the wrist
  proxies, the estimate cards, and the schematic trajectory in TraceOverlay.
- Phase 4: settings reorganised into Profile, App guide, Settings; the drill card;
  the share card estimates; and the estimate persistence on SwingRecord.
- Phase 6: manual exposure controls in the record drawer and CaptureViewModel,
  and live skeleton stabilisation (jump clamp plus a short moving average) in the
  Vision provider.

Deferred and intentionally excluded: the audio impact detector, video export with
burned in overlays, and the paywall.

## Honest caveats

The ball flight figures (ball speed, carry, launch, spin) are club average model
estimates driven by one measured input, the hand speed at impact, plus the club
you pick in Profile. They are always labelled Est., their confidence dot reflects
how well you were tracked rather than how good the guess is, and the traced arc is
a schematic of the flight shape, not the real path of the ball. This is not a
launch monitor.

This source has been checked structurally but not compiled. There is no Swift
toolchain in the environment it was assembled in, so brace and paren balance, the
absence of duplicate type definitions, the framework imports, and the house style
were verified by static scan. The final compile, and any warning cleanup, happens
in your Xcode. A couple of files sit in a different folder than a cosmetic reading
of the plan would put them (for example Theme.swift is under App/); folder location
does not affect compilation, so they were left where they are.

House rule respected throughout: no em dashes, and no semicolon statement
terminators, anywhere in the code.
