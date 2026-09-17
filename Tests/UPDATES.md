# Update presentation checks

Run the signed app through the canonical launcher:

```sh
cd mac
FIRSTLIGHT_SKIP_SWIFTFORMAT=YES ./Scripts/run-local-signed.sh --update-diagnostics -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO
```

The debug fixture uses the same update view as Settings and checks the real
Sparkle feed. It does not select **Update** or install the offered release.
It exercises cancellation, timeout, no-update and incompatible-update results,
network errors, download/extraction progress, callback ownership, and retrying
an installation after application termination was cancelled.

It also creates the real onboarding controller with isolated preferences and
inert content. The authentication anchor must be visible, key, main, and on the
active Space before the fixture closes it. It does not start Clerk or Google
authentication. A real browser sign-in across Spaces still needs manual checking.

Read the results from Console, subsystem `sh.firstlight.mac`, category
`UpdateDiagnostics`, or:

```sh
log show --last 5m --style compact --predicate 'subsystem == "sh.firstlight.mac" AND category == "UpdateDiagnostics"'
```

Run `./Scripts/run-local-signed.sh` without the diagnostic argument to return to
normal local development. The fixture is excluded from Release builds.
