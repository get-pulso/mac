# Native authentication onboarding

The accepted Ray / Flow light belongs to the real macOS application. It is the
final version of `playground/onboarding-shader` (see its `RAY-TO-LOGO-HANDOFF.md`);
the shader is kept in step with the playground minus the comparison styles.
Right-click the menu-bar icon and choose `Replay onboarding` to run it again
without signing out. Replay is disabled while OAuth, session restoration or profile
completion is in flight.

## Flow

With a soundtrack, the authored real-time pacing below follows the audio clock
scaled by 4.25 / 5.56. Audio stays at 1x; the window handoff lands at 5.56 seconds.
The bass energy crest is at 4.905882 seconds, with the final reveal haptic
(3.75 pacing seconds). The recording and visual clock retain their positions.
Only 02 Warm analog is available. Replay onboarding in the menu-bar context menu
uses the existing replay route and keeps the account signed in. There is no
onboarding sound or preview section in Settings. The visual timer ends
before the 16.08-second recording, whose tail continues until completion unless
the scene is closed, skipped or interrupted. Reduce Motion and instant reopening
are silent. Missing audio falls back to the original pacing below.

System-audio muting was removed at the user's request. Intro playback has no
system-audio capture permission, tap, aggregate device or hardware volume writes.

All times below are shader seconds. The clock plays them through
`IntroTiming.pacing`, a monotone cubic map from real seconds: for the first real
second only the desktop darkens, the light is then born slowly (shader 0.06–1.75 s
over real 1.0–4.0 s), the real window appears quickly (shader 2.05 s at real 4.25 s),
the light settles into the mark with a long soft ease (real 4.25–5.6 s), pigment is
quick (real 5.95 s) and the welcome choreography plays at an even 0.85 shader
seconds per real second afterwards. `IntroTiming.realDuration` is the total.
The mark is 72 pt. Once the light has become it, the shader hands the static mark
to a plain image of the same asset in the same rect the moment pigment finishes
(shader 3.02–3.14 s, a short cross-fade), so the crisp mark is on screen right
after the crop: crisp at Retina, and in the same layer as the name, so the two move
as one piece; the shader then holds a markless frame and stops redrawing. Once
settled in the centre, the name `Firstlight` slides out
from behind it to the right (shader 3.70–4.25 s, ease-out) through a soft transparent
edge at the mark's side (44 pt, closing to the gap as the last letter comes out, so
nothing of the name stays faded), so its last letters appear first, the pair
kept centred; the pair then rises with a quintic ease-in-out
to the header line 44 pt from the top and shrinks to a 40 pt mark (4.35–4.95 s)
and stays there (`WelcomeLayout`, one set of numbers for the shader's rect and the
SwiftUI name). The title, plain `Welcome` because the name is already in the
header, takes the centre at 5.00–5.30 s, its subtitle follows on its own at 5.38–5.68 s, the
button arrives at 5.78–6.15 s: one after another. The
shader's `exit` uniform (soften and fade the settled mark) exists but is unused
by this choreography.
The desktop dimming is authored in real seconds: 0 → 72% over 0–1.1 s, restored at
3.3–4.05 s, before the window appears.

- Fresh, signed-out launch: the desktop darkens to 72%, then the amethyst light
  opens as shoots, never as a sweep
  around a circle: one broad shoot grows down out of the source with the
  light gathered at its travelling tip (shader 0.06–0.20 s). It keeps its
  direction and turns about its own axis: it narrows as it comes edge-on while a
  highlight crosses it (0.16–0.38 s), so it reads as a living blade rather than a
  wedge switching on and off, then it goes quickly (0.38–0.46 s). It is the strong
  stroke of the opening: it reaches further than the shoots that follow and carries
  more light. A second opens on the upper-right diagonal while the first is still
  standing (0.28–0.42 s) at seven tenths of its width, length and brightness, so
  the two hand over without a pause, and the rest unfold around it (0.46–0.68 s, a
  fixed order per direction).
  There is no plate behind any of it: the emitter itself only lights as the field
  expands, so the opening is the shoot and nothing else. A young
  shoot is genuinely short, about half the reach, not a clipped long one. The
  emitter itself is not gated: the source glows from the first frame and the
  shoots leave it. The pacing map holds this stretch: the first shoot alone spans
  about 1.9 real seconds. The shafts are broad at first and grow fine
  structure, and they are a brush rather than an even compass rose: each keeps its
  own length and the ones sweeping downwards are the long bristles. The spread
  closes as the light fills the window brightly. The desktop is fully restored at 1.40–2.02 s. At 1.80–2.55 s
  the 3D light cone turns towards the upper right; at 2.05 s the real titled window
  takes over while the same light keeps moving inside it. From 2.05 to 3.15 s the
  whole field condenses towards the root of the mark and loses power, the dark root
  disc is cut out in the window's surface color, and the seven directions of the
  mark become legible inside the already logo-sized light. Original pigment replaces
  the collected light at 3.15–3.32 s: the exact AppIcon mark, static from then on.
  The clock stops at 6.15 s.
  Both click and Return call the existing Google OAuth action directly.
  Welcome content is absent from the animation proxy and inaccessible during prewarming.
  Reduce Motion reveals the final arrangement immediately.
- The window stays open for loading, network errors, retry, code/MFA and profile completion.
  An expanded form owns the whole window; the mark leaves the pane with the title.
- As soon as Clerk reports an active session after Google/verification, onboarding
  closes and the real 350 pt menu-bar panel opens, before awaiting `userInfo()`.
  No completed-account screen or profile loader is painted in the onboarding window.
  Slow profile requests and retryable errors stay in the panel. Only a successful
  `userInfo()` sets the account ID and replaces completion with the dashboard.
  Dismissing the panel while it loads does not reopen it on success.
- At app launch, restored accounts stay in welcome with their avatar and a
  `Continue as Name` button. Confirmation opens the menu-bar popover without Google.
  The account is shown only after an active Clerk session and successful `userInfo()`.
  Normal menu-bar clicks after continuing do not replay welcome; explicit replay
  always reruns the full intro, even if welcome is already open.
  Signed-out menu-bar clicks open the same login window.
- Closing login leaves the menu-bar app running and keeps authentication state intact.
- The first completed intro sets `firstlight.onboarding.opal.introSeen` (the key is
  kept from the first shipped intro so existing installs do not replay it).
  Reopening sign-in is instant.
- Escape skips the effect; in the native login window it closes the window.
  App deactivation, display changes, hide/sleep, Reduce Motion and Metal failure restore the desktop.
- Native traffic lights, resizing, corners and shadows are supplied by AppKit.

The only routing changes are in `AppDelegate`, `WindowManager`, `AppView` and the
existing signed-out cleanup path. Clerk callbacks, pending invites, Google OAuth
and account verification still use the original `NativeSession` / `LoginViewModel`.
Clerk's existing presentation anchor resolves the key onboarding NSWindow.

## Build

From `mac/`, regenerate the Xcode project after adding files. The Metal source is
a folder resource, compiled at runtime; the optional Metal build toolchain is not required.
`icon-1024.png` is bundled by reference as a plain resource: the light condenses into
the original mark sampled from that file. `FIRSTLIGHT_SKIP_SWIFTFORMAT=YES` prevents
whole-tree formatting of parallel work.

```sh
FIRSTLIGHT_SKIP_SWIFTFORMAT=YES Scripts/run-local-signed.sh
```

## Isolated verification

Uses the production shader, view and window controller with inert content and an
isolated preferences suite. No sign-out, real account, Clerk, tracker or network access.
The window checks briefly display/dim the desktop; avoid switching apps during the
first seven seconds, since switching intentionally ends the effect.

```sh
mkdir -p /tmp/FirstlightOnboardingChecks.app/Contents/MacOS \
  /tmp/FirstlightOnboardingChecks.app/Contents/Resources/OnboardingShaders
cp App/Resources/OnboardingShaders/Waves.metal \
  /tmp/FirstlightOnboardingChecks.app/Contents/Resources/OnboardingShaders/Waves.metal
cp App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png \
  /tmp/FirstlightOnboardingChecks.app/Contents/Resources/icon-1024.png
xcrun swiftc -O -swift-version 5 \
  App/Interface/Onboarding/OnboardingSound.swift \
  App/Interface/Onboarding/IntroPlayback.swift \
  App/Interface/Onboarding/MetalOnboardingShaderView.swift \
  App/Interface/Onboarding/RayLogo.swift \
  App/Interface/Onboarding/RayPalette.swift \
  App/Interface/Onboarding/OnboardingView.swift \
  App/Interface/Onboarding/OnboardingWindowController.swift \
  Tests/OnboardingShaderChecks.swift Tests/NativeOnboardingChecks.swift \
  -o /tmp/FirstlightOnboardingChecks.app/Contents/MacOS/FirstlightOnboardingChecks
/tmp/FirstlightOnboardingChecks.app/Contents/MacOS/FirstlightOnboardingChecks
```

Checks 321 GPU frames at two sizes / scales: premultiplied alpha, clear carrier
edges, motion, pixel-identical native handoff from 2.05 s, the static original mark
with nothing outside it, 60 Hz continuity and the dimming timeline; then dimming,
handoff, 14 pt standard window controls, resize, close/reopen, cancellation races,
interruption and fallback cleanup. Pass `--window-only` to skip pixel tests while
iterating on lifecycle behavior. Frames: `/tmp/firstlight-integrated-ray-frames`.
The playground's deeper audits (condensation, lamp turn, ending controls) run
against the same shader from `playground/onboarding-shader`.

Welcome timing and cancellation checks:

```sh
xcrun swiftc -O App/Interface/Onboarding/OnboardingSound.swift \
  App/Interface/Onboarding/IntroPlayback.swift \
  App/Interface/Onboarding/RayLogo.swift App/Interface/Onboarding/WelcomeLayout.swift \
  App/Interface/Onboarding/RayPalette.swift App/Interface/Onboarding/MetalOnboardingShaderView.swift \
  App/Services/NativeHaptics.swift \
  Tests/WelcomeRevealChecks.swift -o /tmp/firstlight-welcome-reveal-checks
/tmp/firstlight-welcome-reveal-checks
xcrun swiftc App/Interface/Onboarding/OnboardingSound.swift \
  Tests/OnboardingSoundChecks.swift -o /tmp/firstlight-sound-checks
/tmp/firstlight-sound-checks /tmp/firstlight-derived-local/Build/Products/Debug/Firstlight.app
xcrun swiftc -O App/Helpers/WelcomeAccount.swift \
  Tests/WelcomeAccountChecks.swift -o /tmp/firstlight-welcome-account-checks
/tmp/firstlight-welcome-account-checks
xcrun swiftc -O App/Interface/Status/StatusItemMenu.swift \
  Tests/NativeStatusMenuChecks.swift -o /tmp/firstlight-native-menu-checks
/tmp/firstlight-native-menu-checks
xcrun swiftc -parse-as-library -O Tests/SignInHandoffContracts.swift \
  -o /tmp/firstlight-signin-handoff-checks
/tmp/firstlight-signin-handoff-checks
```

The handoff source contracts check that the menu-bar panel opens before the profile
request suspends, account access still waits for verification, and replay preserves
the session. The menu checks execute real NSMenu actions, including replay guards.

For visual inspection of the real Debug bundle, `--preview-onboarding` displays an
explicitly labeled, inert sign-in preview using the production Continue button.
Click and Enter increment a visible preview counter without starting OAuth.
Add `--preview-signed-in` to verify the returning-account button with a labeled fixture.
It uses separate preferences and
bypasses Clerk, tracker, storage and the updater. It is not a real authentication
test and is not included in Release builds. A complete live Google sign-in still
requires the user's own account interaction; never sign out their account to test it.
