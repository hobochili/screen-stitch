# Development

[Building](#building) · [Signing](#signing) · [Tests](#tests) · [Code layout](#code-layout)

## Building

```sh
./build.sh                          # → build/Screen Stitch.app
./build.sh --install                # also installs it into ~/Applications, quitting and reopening a running copy
./build.sh --install /Applications  # or into another folder
```

Building needs only the Command Line Tools (`xcode-select --install`), not Xcode. `build.sh` compiles every file in
`Sources/` with `swiftc` and draws the app icon with `make-icon.swift`.

> [!NOTE]
> The Command Line Tools don't include the SwiftUI macro plugin, so the code avoids `@State` and keeps view state on the
> `@Observable` model.

## Signing

By default `build.sh` signs the app ad hoc. That works, but macOS ties the Screen Recording, Accessibility and
microphone permissions to the signature, so it asks for them again after every rebuild. To avoid that, run
`./make-signing-cert.sh`. It adds a self-signed "Screen Stitch Local Signing" certificate to your login keychain, and
`build.sh` signs with it from then on, so rebuilds keep their permissions.

When you run `./build.sh --install` from a terminal and the certificate is missing, it offers to run that script for
you. If you say no, it records that in `.no-signing-cert` and doesn't ask again. Delete that file to be asked again, or
run `./make-signing-cert.sh` any time.

The app isn't notarized, so a copy built on one Mac and moved to another is blocked the first time it opens. Allow it
in System Settings › Privacy & Security with **Open Anyway**, or build it on that Mac instead.

## Tests

```sh
./test.sh                   # every test except the ones that record the screen
./test.sh --filter Combine  # arguments go to the test runner
./test.sh --capture         # only the tests that record the screen
```

SwiftPM is broken in some Command Line Tools installs, so `test.sh` builds the test runner with `swiftc` and the
Tools' own copy of Swift Testing. Tests that need FFmpeg make their own sample clips with it, and they're skipped if it
isn't installed.

`--capture` runs the tests that record the real screen with ScreenCaptureKit. These need Screen Recording permission, so
the runner is wrapped as an app signed like Screen Stitch and inherits the installed app's permission. That means you
need the [signing certificate](#signing) and an installed Screen Stitch that's allowed to record. Test windows flash up
while the tests run, so leave the Mac alone for about 10 seconds. Each test's clip is kept in `build/tests/capture`.

## Code layout

| Folder | What's in it |
| :--- | :--- |
| `Sources/App` | The app, its menus, the app delegate and the command line |
| `Sources/Model` | The session (`StitchModel`), clips and formatting |
| `Sources/Recording` | The recording flow from picking to stopping, ScreenCaptureKit, shortcuts and everything drawn on screen |
| `Sources/Video` | Finding FFmpeg, reading clips, drawing title cards and building the command that combines them |
| `Sources/Views` | The SwiftUI windows and sheets |
| `Tests` | Swift Testing suites, run with `test.sh` |
