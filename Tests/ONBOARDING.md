# Native authentication onboarding

The accepted Ray / Flow light belongs to the real macOS application. It is the
final version of `playground/onboarding-shader` (see its `RAY-TO-LOGO-HANDOFF.md`);
the shader is kept in step with the playground minus the comparison styles.
Right-click the menu-bar icon and choose `Replay onboarding` to run it again
without signing out. Replay is disabled while OAuth, session restoration or profile
completion is in flight.

## Flow

All times below are shader seconds; the Flow clock runs 1.5× slower
(`IntroTiming.tempo`), so the whole intro takes 6.0 real seconds.

- Fresh, signed-out launch: the desktop darkens to 62% under a floating amethyst
  light that opens with a few broad shafts and grows fine structure, then fills
  the window brightly. The desktop is fully restored at 1.40–2.02 s. At 1.80–2.55 s
  the 3D light cone turns towards the upper right; at 2.05 s the real titled window
  takes over while the same light keeps moving inside it. From 2.05 to 3.15 s the
  whole field condenses towards the root of the mark and loses power, the dark root
  disc is cut out in the window's surface color, and the seven directions of the
  mark become legible inside the already logo-sized light. Original pigment replaces
  the collected light at 3.17–3.60 s: the exact 92 pt AppIcon mark, static from then on.
  `Welcome to Firstlight` arrives at 3.26–3.60 s under the mark, the bottom
  Continue / Enter button at 3.62–3.95 s; the clock stops at 4.0 s.
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
xcrun swiftc -O App/Interface/Onboarding/IntroPlayback.swift \
  Tests/WelcomeRevealChecks.swift -o /tmp/firstlight-welcome-reveal-checks
/tmp/firstlight-welcome-reveal-checks
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
