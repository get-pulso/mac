# Native authentication onboarding

The accepted Cloud / Opal effect now belongs to the real macOS application.
There is no Edge mode. Right-click the menu-bar icon and choose `Replay onboarding`
to run Cloud / Opal again without signing out. Replay is disabled while OAuth,
session restoration or profile completion is in flight.

## Flow

- Fresh, signed-out launch: desktop dims, Cloud expands into a real titled window,
  then a separate 5.1-second welcome timeline starts: P rises from below, stays
  fully visible for 1.4 seconds, moves up
  and disappears completely; `Welcome to Pulso` replaces it in the center, then
  the bottom Continue / Enter button appears. The logo and heading never overlap.
  Both click and Return call the existing Google OAuth action directly.
  Welcome content is absent from the animation proxy and inaccessible during prewarming.
  Reduce Motion reveals the final arrangement immediately.
- The window stays open for loading, network errors, retry, code/MFA and profile completion.
- As soon as Clerk reports an active session after Google/verification, onboarding
  closes and the real 350 pt menu-bar panel opens, before awaiting `userInfo()`.
  No completed-account screen or profile loader is painted in the Opal window.
  Slow profile requests and retryable errors stay in the panel. Only a successful
  `userInfo()` sets the account ID and replaces completion with the dashboard.
  Dismissing the panel while it loads does not reopen it on success.
- At app launch, restored accounts stay in welcome with their avatar and a
  `Continue as Name` button. Confirmation opens the menu-bar popover without Google.
  The account is shown only after an active Clerk session and successful `userInfo()`.
  Normal menu-bar clicks after continuing do not replay welcome; explicit replay
  always reruns the full Cloud intro, even if welcome is already open.
  Signed-out menu-bar clicks open the same login window.
- Closing login leaves the menu-bar app running and keeps authentication state intact.
- The first completed intro sets `pulso.onboarding.opal.introSeen`. Reopening sign-in is instant.
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
`PULSO_SKIP_SWIFTFORMAT=YES` prevents whole-tree formatting of parallel work.

```sh
PULSO_SKIP_SWIFTFORMAT=YES Scripts/run-local-signed.sh
```

## Isolated verification

Uses the production shader, view and window controller with inert content and an
isolated preferences suite. No sign-out, real account, Clerk, tracker or network access.
The window checks briefly display/dim the desktop; avoid switching apps during the
first six seconds, since switching intentionally ends the effect.

```sh
mkdir -p /tmp/PulsoOnboardingChecks.app/Contents/MacOS \
  /tmp/PulsoOnboardingChecks.app/Contents/Resources/OnboardingShaders
cp App/Resources/OnboardingShaders/Waves.metal \
  /tmp/PulsoOnboardingChecks.app/Contents/Resources/OnboardingShaders/Waves.metal
xcrun swiftc -O -swift-version 5 \
  App/Interface/Onboarding/IntroPlayback.swift \
  App/Interface/Onboarding/MetalOnboardingShaderView.swift \
  App/Interface/Onboarding/OnboardingView.swift \
  App/Interface/Onboarding/OnboardingWindowController.swift \
  Tests/OnboardingShaderChecks.swift Tests/NativeOnboardingChecks.swift \
  -o /tmp/PulsoOnboardingChecks.app/Contents/MacOS/PulsoOnboardingChecks
/tmp/PulsoOnboardingChecks.app/Contents/MacOS/PulsoOnboardingChecks
```

Checks 40 GPU frames at two sizes / scales, premultiplied alpha, flowing gas,
native unmasked corners, dimming, handoff, 14 pt standard window controls,
resize, close/reopen, cancellation races, interruption and fallback cleanup.
Pass `--window-only` to skip pixel tests while iterating on lifecycle behavior.

Welcome timing and cancellation checks:

```sh
xcrun swiftc -O App/Interface/Onboarding/IntroPlayback.swift \
  Tests/WelcomeRevealChecks.swift -o /tmp/pulso-welcome-reveal-checks
/tmp/pulso-welcome-reveal-checks
xcrun swiftc -O App/Helpers/WelcomeAccount.swift \
  Tests/WelcomeAccountChecks.swift -o /tmp/pulso-welcome-account-checks
/tmp/pulso-welcome-account-checks
xcrun swiftc -O App/Interface/Status/StatusItemMenu.swift \
  Tests/NativeStatusMenuChecks.swift -o /tmp/pulso-native-menu-checks
/tmp/pulso-native-menu-checks
xcrun swiftc -parse-as-library -O Tests/SignInHandoffContracts.swift \
  -o /tmp/pulso-signin-handoff-checks
/tmp/pulso-signin-handoff-checks
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
