# dartnative_file_picker_example

A **dartnative** app, scaffolded by `dn create`. It ships with correct iOS +
Android runner glue (so it renders instead of white-screening) and is ready for a
branded splash + app icon.

## Run it

```sh
dn pub get
dn run -d <device-id>
```

dartnative apps require a license. Subscribe at
[dartpub.dev/framework](https://dartpub.dev/framework), copy your license key
(`dnk_...`) from the Framework panel, and configure it once:

```sh
dn config --license-key dnk_...
```

After that `dn run` just works, on every platform. (Prefer not to store the
key? Pass it per run instead: `dn run --dart-define=DN_LICENSE_KEY=dnk_...`.)

Always use **`dn`** for run/build/pub commands — not the underlying SDK CLI.

## Make it yours

- **Your UI** — edit `lib/main.dart`.
- **App icon + launch logo** — replace `assets/dn-logo.png` with your logo, then
  regenerate icon **and** splash in one step:
  ```sh
  dart run tool/generate_app_assets.dart --source=assets/dn-logo.png --bg=#000000
  ```
  (Splash only: `dart run dartnative_splash:setup`.)
- **Plugins** — browse **[dartpub.dev](https://dartpub.dev)**. Add a package to
  `pubspec.yaml`, run `dn pub get`, and import it — pure-Dart packages and
  dartnative plugins both work as-is.

## Don't touch (unless you know the runtime)

These files are the dartnative runner glue — they're why the app renders:
`ios/Runner/{AppDelegate,SceneDelegate}.swift` + the scene block in `Info.plist`,
and `android/.../{Application,MainActivity}.kt` + the Material3 themes in
`android/app/src/main/res/values*/styles.xml`.

> Dependency paths in `pubspec.yaml` assume this app sits beside
> `dartnative_framework`. Fix them if you created it elsewhere.

## This example is also the device-validation harness

Every observable value is echoed to the Dart log under a `DNFP-TEST` prefix, and
some buttons exist to exercise a specific edge rather than to look good:
**Unknown ext (enforced)** proves `allowedExtensions` is enforced and not merely
passed to the picker, **Two at once** proves the one-picker guard releases,
**Pick from a modal** proves the picker outlives a modal that dismisses itself,
and **stream 32K / stream 1M** make the per-chunk round-trip cost measurable.

That instrumentation is why the results in `../doc/validation/` have numbers in
them instead of ticks. `dn screenshot` does not work on a physical iPhone and the
libimobiledevice screenshot service is unavailable on iOS 26, so the log is the
measurement channel. Borrow the API usage freely; the logging and the
`_keepUriAfterRelease` flag are harness scaffolding, not patterns to copy.
