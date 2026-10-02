# Contributing

Thanks for helping. This is a DartNative plugin, so the toolchain is `dn`, not
`flutter` or `dart`.

## Environment

| | |
|---|---|
| DartNative SDK | `dn` 1.0.0 or later. Install: `curl -fsSL https://cdn.dartnative.com/install.sh \| sh` |
| Android | Android SDK **36** plus build-tools, and NDK 28.2.13676358. `dn doctor` reports what is missing. |
| iOS | **macOS with Xcode only.** Xcode cannot run anywhere else, so iOS changes cannot be validated on Windows or Linux. |
| Devices | a real Android device and a real iPhone for the manual matrix. Emulators and the simulator do not exercise cloud providers. |

Building and testing is free. A dartpub.dev subscription is only needed to ship
your own apps, not to work on this plugin or run its example.

## Use `dn`, never plain pub

DartNative packages ship with the SDK and are not on pub.dev, so `dart pub get`
and `dart test` **fail** here with a version-solving error. Use:

```bash
dn pub get
dn analyze
dn test
```

Formatting is the one exception, because no `dn format` exists. Use the SDK's own
Dart so everyone formats identically:

```bash
~/zero/bin/dart format .
```

## The local quality gate

```bash
./tool/check.sh
```

It stops at the first failure and runs, in order: a format check, `dn pub get`,
`dn analyze`, `dn test`, `dn plugin build` (which compiles **both** native
sides), then the example app for Android and, on macOS, for iOS.

Run it before opening a pull request. There is no CI on this repository by
design, so the local gate is the gate.

`tool/check.sh --fast` skips the example app builds, which is the slow part, for
a quick loop while editing Dart.

## Tests

Unit tests use `package:test` and live in `test/`. DartNative has no widget-test
harness yet, which shapes the design: the pure-Dart core imports no framework
code and no `dart:ffi`, so it is fully testable on the Dart VM.

- Filters, MIME resolution, the request envelope, the reply decoder, the result
  model and the error model are all directly testable. Add tests there.
- `PlatformFile` depends on a `FileResourceGateway` interface, so its behaviour
  is tested with a fake. See `test/platform_file_test.dart`.
- Please do not add mocking infrastructure to raise the test count. A test that
  pins real behaviour is worth ten that restate the implementation.

Anything that genuinely needs a device goes in the manual matrix below instead of
being faked.

## Native changes

`dn plugin build` is what proves native code compiles:

```bash
dn plugin build --owner <your-github-login>
```

It produces `dist/` with an iOS `.xcframework` and an Android `.aar`. It does not
contact the registry, so it is safe to run freely.

Android specifics: this plugin deliberately does **not** depend on
`project(':dartnative_android')`, because a plugin that does cannot produce its
own publishable Android archive. Keep it that way: take the `Context` from the
`FlutterPluginBinding` and resolve framework symbols with `dlsym` at runtime.

If native code calls Dart back, it must go through the single dispatcher slot.
Read `doc/plugin-pattern-findings.md` §6 first. Then **test it with a hot
restart**: start an operation, press capital `R` mid-flight, and confirm the app
neither crashes nor wedges.

## Manual device checks

Native UI and cloud providers cannot be unit-tested. The full matrix is in
`doc/manual-test-matrix.md`. At minimum, for any change that touches native code,
run the example app on a real device of the affected platform and verify: single
pick, multiple pick, cancel, a cloud document, `copyToCache`, a streamed read of
something large, and a hot restart with the picker open.

Say in the pull request which of these you ran, on what device and OS version,
and which you did not.

## Pull requests

- One concern per pull request.
- `./tool/check.sh` passes.
- Public API changes come with Dartdoc, a README update, and a CHANGELOG entry
  under an `## Unreleased` heading.
- Keep the honesty rules of this package: no invented filesystem paths, no
  swallowed errors, no `catch (_) {}`, no claim in the docs that the code does not
  deliver. If a platform cannot do something, document the difference instead of
  emulating it badly.
- Explain *why* in the commit message. The *what* is in the diff.

## Formatting and style

`package:lints/recommended.yaml` plus the additions in `analysis_options.yaml`.
Note that `dn analyze` treats infos **and** warnings as fatal by default, so the
analyzer must be completely clean, and `public_member_api_docs` is on: every
exported member needs a doc comment.

Comments explain the non-obvious, especially at the FFI boundary: who allocates,
who frees, which thread, and what happens on hot restart.
