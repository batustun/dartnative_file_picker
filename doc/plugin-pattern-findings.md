# DartNative Plugin Pattern Findings

Engineering traceability note for `dartnative_file_picker`. Everything below was
read from source in the current official repository and the installed SDK, not
from articles or memory. Verified 2026-10-02 against:

- Repo: `github.com/DartNative/dartnative` @ `main`, pushed 2026-10-01 (shallow clone)
- SDK: `dn` 1.0.0 stable, channel stable, framework revision `113c27aacb2`
  (2026-09-28), engine `868544bcca`, Tools Dart 3.12.0
- API-surface package: `~/zero/bin/cache/pkg/dartnative` (declarations only;
  the real implementation ships compiled in the artifact)
- Registry: `dartpub.dev` (Presence Network Inc.), publisher guide

## 0. Identity check — which DartNative is this?

Two unrelated projects share the name. This package targets the **current** one:

| | Current (targeted) | Older, unrelated |
|---|---|---|
| Org / repo | `DartNative/dartnative` | `dart-native/dart_native` |
| Nature | Full UI framework: Dart on the platform main thread driving UIKit / Android Views, Yoga layout | A Dart↔ObjC/Java interop bridge, a Flutter Channel replacement |
| Registry | dartpub.dev, `dn` CLI | pub.dev, `build_runner` codegen |
| Activity | pushed 2026-10-01 | last pushed 2024-05-21, pub release ~3 years old |

The mission brief named `DartNative/dartnative`; that repo exists and is the
active one, so the brief was accurate. The GitHub org exposes exactly one public
repo (`dartnative`); the per-plugin repos referenced on dartpub plugin pages
(e.g. `DartNative/dartnative_share`) are **not** public — `GET
/repos/DartNative/dartnative_share` returns 404. First-party plugin folders live
inside the monorepo under `plugins/`.

## 1. First-party plugins inspected

34 first-party plugins are documented under `plugins/`. Only **one ships full
source** — the rest are README + example only, because the core plugins ship as
maintained binaries with the subscription ("We don't take PRs on the core").

| Plugin | Source available | Why it was relevant |
|---|---|---|
| **`dartnative_share`** | **Full** (Dart + Swift + Kotlin + C++ + podspec + gradle + CMake + manifest) | The single complete first-party reference. Pure-FFI (view-less) plugin that **presents a system view controller** (`UIActivityViewController`) and an **Android chooser Intent**, handles **files**, and delivers an **async result back to Dart**. Structurally the same problem as a document picker. This is the primary architectural model. |
| `dartnative_media_picker` | README + example | Closest *functional* sibling (a picker). Source of the API-ergonomics convention and the cancel contract: `showMediaPicker(...) → Future<List<MediaFile>>`, empty list on cancel. Also documents the "declare no permission of your own" stance. |
| `dartnative_path_provider` | README + example | Decided the `copyToCache` architecture (see §9). Shows the synchronous-FFI house style and the Android minSdk 26 requirement. |
| `dartnative_permissions` | README + example | Named in the docs as one of three plugins that take results through the framework's `DNCallbackFire` rather than their own pointer (see §6). |
| `dartnative_video_player`, `dartnative_webview`, `dartnative_google_maps` | README + example | Named in `plugin_development.md` as the canonical **view** plugins. Confirmed my plugin is *not* one: no `NativeElement`, no `ViewType`, no `PluginMutation`. |

Framework-internal reference: `lib/src/widgets/native_media_picker.dart` in the
`dartnative` package is the core's own picker API surface
(`showMediaPicker({required BuildContext context, ...})`).

## 2. Plugin layout (authoritative, from `dartnative_share`)

```text
<plugin>/
├── pubspec.yaml                 # `dartnative:` stanza — plugin + registrant blocks
├── LICENSE, README.md, THIRD_PARTY_NOTICES
├── lib/<plugin>.dart            # library + exports
├── lib/src/*.dart               # public API + FFI bindings class
├── ios/<plugin>.podspec         # s.source_files = 'Classes/**/*.swift'
├── ios/Classes/DN*.swift        # @_cdecl FFI entry points
├── android/build.gradle         # com.android.library + externalNativeBuild cmake
├── android/CMakeLists.txt       # add_library(<name> SHARED ...cpp)
├── android/src/main/AndroidManifest.xml
├── android/src/main/kotlin/<pkg>/DNxxxBridge.kt          # @Keep top-level fns
├── android/src/main/kotlin/<pkg>/DartNativeXxxPlugin.kt  # FlutterPlugin
├── android/src/main/cpp/dn_xxx_bridge.cpp                # JNI_OnLoad + extern "C"
└── example/                     # a dn app with a path dependency
```

## 3. `pubspec.yaml` plugin metadata (copied from `dartnative_share`)

```yaml
environment:
  sdk: ^3.9.0-0
dependencies:
  dartnative: ^1.0.0
  ffi: ^2.1.0
publish_to: 'none'      # the registry is dartpub.dev, NOT pub.dev

dartnative:
  plugin:
    platforms:
      ios:
        ffiPlugin: true                     # iOS: ALWAYS ffiPlugin: true
      android:
        package: com.dartnative.<name>      # Android: ALWAYS package+pluginClass,
        pluginClass: DartNativeXxxPlugin    # NEVER ffiPlugin: true
  registrant:
    imports:
      - package:<name>/<name>.dart
    calls:
      - XxxFFIBindings.loadSymbols();
```

`android: ffiPlugin: true` is explicitly forbidden: it bundles the `.so` without
emitting a `System.loadLibrary` call, so `JNI_OnLoad` never fires, `g_jvm` stays
NULL and the first JNI callback dies with `SIGSEGV` in `_JavaVM::GetEnv`.

The `registrant` block is how the plugin is discovered — there is no central
registry. `dn pub get` regenerates the app's
`lib/dartnative_plugin_registrant.dart`, whose `registerAll()` the app calls as
the first line of `main()`.

## 4. Dart → iOS bridge

`@_cdecl("DNSymbolName")` Swift functions compiled into the app binary via
CocoaPods; Dart resolves them with `DynamicLibrary.process()`. The plugin pod
must **not** `import dartnative_ios` (circular pod dependency) — framework
symbols are resolved at runtime with
`dlsym(dlopen(nil, RTLD_NOLOAD), ...)`, or `dlsym(RTLD_DEFAULT /* bitPattern: -2 */, ...)`.

## 5. Dart → Android bridge

Two layers, both mandatory:

- **A — JVM load**: a Kotlin `FlutterPlugin` (`io.flutter.embedding.engine.plugins.FlutterPlugin`)
  whose `onAttachedToEngine` calls `System.loadLibrary("<name>")`. This is the
  only call site that fires `JNI_OnLoad`. It is auto-instantiated by the
  generated registrant because of the `pluginClass` stanza.
- **B — Dart symbol lookup**: `DynamicLibrary.open('lib<name>.so')`.

`loadSymbols()` must open with `Platform.isAndroid ? open(...) : process()` and
must begin with a `Platform.is…` guard, because `registerAll()` runs on every
platform.

> Honest note on "zero Flutter": DartNative runs on a forked Flutter engine, and
> the documented Android registration hook *is* `FlutterPlugin`. So the accurate
> claim is **no `MethodChannel`, no `package:flutter` import, no Flutter plugin
> messaging** — not "no Flutter artifact anywhere". `FlutterPlugin` here does
> nothing but load a library; the docs are explicit: "Do not register
> `MethodChannel`s... dartnative plugins communicate exclusively over FFI."

## 6. Async callback pattern — the dispatcher slot ("option 3")

Required whenever native calls Dart **after** the FFI call returned. The hazard
is hot restart (`R`): Dart deletes every callback trampoline while native work
continues; calling a deleted pointer aborts with `Callback invoked after it has
been deleted`.

Contract (from `plugin_async_callbacks.md`, as implemented in `dartnative_share`):

1. **One** `Pointer.fromFunction` dispatcher for the whole plugin; every call
   carries an int `token`; Dart routes token → `Completer`/handler.
2. Native stores the address in **one** slot variable and registers it once:
   - iOS: `DNRegisterAsyncDispatcherSlot(&slot)` — the framework zeroes the slot
     *before* the old isolate dies.
   - Android: capture `DN_IsolateGen()` next to the pointer; the framework bumps
     the counter before teardown.
3. **Re-read / re-compare before every fire**, and always fire on the **main
   thread**. Never copy the address into a closure or per-object field.

Payload convention: `(token, type, one string)` with JSON in the string; errors
travel *inside* the payload (e.g. `{"__error":...}`) and are thrown Dart-side
after decoding; one-shot results keep a `Completer` in the token map.

`DNCallbackFire.fire*` (Android) would inherit the framework's protection for
free, and `media_picker`/`permissions`/`webview` use it — but it lives in
`dartnative_android`, which this plugin deliberately does not depend on (§8).
So this plugin implements the documented slot pattern directly, exactly as
`dartnative_share` does.

**String lifetime rule**: `NativeCallable.listener` (async) requires native
`strdup` + Dart `calloc.free`. `Pointer.fromFunction` is **synchronous**, so a
stack-scoped buffer is safe and Dart copies during the call. `dartnative_share`
uses `Pointer.fromFunction` + `withCString`, no ownership transfer. This plugin
does the same.

## 7. Threading model — the decisive fact

`architecture.md`: "Every layer runs on the same thread. There are no queues, no
bridges, no thread hops." Dart runs on the **platform main thread**. The JNI
bridge confirms it in a comment: delivery happens "on the main thread (= the
Dart isolate's thread) ... the call is synchronous".

Consequences adopted here:
- No thread hop is invented for its own sake; FFI calls are direct and synchronous.
- Native UI presentation is already on the right thread, but every entry point
  still hops with `DispatchQueue.main.async` / `Handler(mainLooper).post` to be
  correct when called from elsewhere, matching `dartnative_share`.
- **Heavy file I/O must not run on that thread** — it is the UI thread. Reads and
  copies therefore run on a native background queue/executor and only the
  delivery hops back to main. This is the one place the plugin deliberately adds
  a thread, and the reason is UI jank, not habit.

## 8. iOS UIViewController acquisition / presentation

`dartnative_share` does **not** walk the controller hierarchy. It:
1. finds the `UIWindowScene` whose `activationState == .foregroundActive`
   (falling back to the first scene) — scene-aware, no `keyWindow`;
2. creates its **own** `UIWindow` at `windowLevel = .normal + 1` with a private
   host `UIViewController`, and presents from that host;
3. tears the window down on dismissal and restores the previous key window.

Rationale given in-source: UIKit dismisses a presented controller together with
its presenter, so a modal that presents-and-closes in the same tap would take
the sheet down with it. A dedicated window makes the picker system UI over the
app. This plugin adopts the same pattern — it is both the house convention and a
strictly safer answer to "never present over a controller that is not in a window
hierarchy" than top-most traversal.

## 9. Android Activity acquisition — and the gap this plugin had to fill

Available from the framework (`compileOnly project(':dartnative_android')`):
`DNNavigator.activity()`, `DNAppContext.get()`, `DNPluginRegistry`,
`DNViewRegistry`, `DNActivityHooks` (only `onUserLeaveHint` + PiP).

**There is no Activity-result hook anywhere in DartNative.** A repo-wide search
for `onActivityResult`, `startActivityForResult`, `ActivityResultLauncher`,
`registerForActivityResult` across all `*.md`, `*.kt`, `*.dart` returns **zero
matches**. `ACTION_OPEN_DOCUMENT` fundamentally needs a result, so the plugin
must supply its own mechanism.

Two further constraints decided the design:

- `plugin_development.md` §4 Step 1: a plugin that depends on
  `project(':dartnative_android')` "builds and runs inside an app but **cannot
  yet produce its own Android archive for publishing**". `dn plugin build` finds
  that module only inside the DartNative source tree.
- §10 A4 / §4 Step 1 explicitly direct view-less plugins to take the `Context`
  from the plugin binding instead: "A plugin without a view does not need it".

So: **no `dartnative_android` dependency.** The `Context` comes from
`FlutterPluginBinding.applicationContext` (documented pattern A2), and the
Activity result is obtained from a **transparent proxy `Activity` owned by this
plugin**, declared in its own manifest and launched with `FLAG_ACTIVITY_NEW_TASK`.
It calls `startActivityForResult`, receives `onActivityResult`, hands the result
to the bridge and finishes.

This is a deliberate, documented deviation from `dartnative_share` (which uses
`DNNavigator` and therefore the framework dependency). The deviation is required
for a *community* plugin that must be publishable via `dn plugin publish`, and it
also removes the "no Activity available" failure mode share logs. The hot-restart
guard still uses `DN_IsolateGen()`, resolved at runtime via
`dlsym(RTLD_DEFAULT, ...)` — no compile-time coupling.

`copyToCache` likewise needs no `dartnative_path_provider`: the native side
already owns its cache directory (`context.cacheDir`,
`FileManager….cachesDirectory`), the copy is performed natively, and only the
resulting path crosses to Dart. Adding a commercial dependency to learn a path
native already knows would be gratuitous coupling for consumers.

### 9a. The cost of the proxy: activity-scoped URI grants

The proxy is not free, and the price is not obvious until it is measured on real
hardware. A URI permission delivered in an activity result is owned by the
activity that received it, and AOSP revokes it when that activity leaves the
history stack:

```java
// frameworks/base/services/core/java/com/android/server/wm/ActivityRecord.java
void removeFromHistory(String reason) {
    ...
    cleanUpActivityServices();
    removeUriPermissionsLocked();   // uriPermissions.removeUriPermissions()
}
```

The proxy hands the result to the bridge and finishes at once, so the grant is
gone milliseconds later. Device finding F9, on a physical Galaxy S23 Ultra
(Android 16 / API 36): every read after the pick failed with `SecurityException`
in `reference` mode, for a local Downloads document and a Drive document alike,
while `persistAccess: true` worked. The emulator had passed the same case, which
makes this a worked example of why the matrix in `doc/manual-test-matrix.md`
insists on hardware.

Flutter's own plugins never meet this because they receive the result on the
**host** activity through `addActivityResultListener`, whose grant lives as long
as the app is in the foreground. That hook is the thing DartNative does not have,
so the proxy is unavoidable and the grant lifetime has to be solved rather than
inherited.

What the ecosystem does instead, read from source rather than from docs:

- `file_selector_android` (Flutter team) takes no persistable grant at all. In
  `FileSelectorApiImpl.toFileResponse` it reads the whole document into a
  `byte[]` **and** copies it to the cache via
  `FileUtils.getPathFromCopyOfFileFromUri`, both inside the activity-result
  callback. It never hands a URI to Dart, and returns `null` when the provider
  reports no size.
- `image_picker_android` copies in the same way.
- `file_picker` (`packages/file_picker_android`) copies every selection into
  `cacheDir/file_picker/<millis>/<name>` in `FileUtils.openFileStream`, and
  exposes the grant question in its public API:

  ```dart
  enum AndroidSAFGrant {
    /// Grant permission to the requested URI for the current request only.
    transient,          // the default
    /// Grant permission to the requested URI, until permission is explicitly revoked.
    lifetime,
  }
  ```

  Only `lifetime` reaches `takePersistableUriPermission`, and only then is an
  `AndroidSAFHandle` (the URI) returned at all.

Android offers exactly three sanctioned ways to keep a picked document readable
past the receiving activity: take a persistable grant, copy the bytes inside the
grant window, or hold the open `ParcelFileDescriptor`. Forwarding the grant to a
`Service` is not a fourth: the owner is `ServiceRecord.StartItem`, whose
`removeUriPermissionsLocked()` runs when the start item completes, so holding a
grant that way means a service that is never stopped, which on API 26+ means a
foreground notification.

Copying is what this package exists to avoid, and holding a file descriptor
blocks the pick while a cloud provider downloads. So `reference` mode takes the
persistable grant and owns its lifetime: `SessionGrants` records whether a grant
is the caller's (`persistAccess: true`) or the session's, and releases the
session's on the next process start and on engine detach. The cap matters too:

```java
// UriGrantsManagerService
private static final int MAX_PERSISTED_URI_GRANTS = 512;
// maybePrunePersistedUriGrantsLocked() sorts by PersistedTimeComparator and
// releases the oldest until the count is under the limit.
```

The ledger evicts its own oldest entry at 256 so that the OS pruner never gets to
choose a victim silently.

## 10. Native ↔ Dart memory ownership rules adopted

| Crossing | Allocator | Freed by | Note |
|---|---|---|---|
| Dart → native `const char*` args | Dart (`toNativeUtf8`) | Dart in `finally` | native copies synchronously during the call |
| Dart → native `const char**` arrays | Dart (`calloc`) | Dart in `finally` (elements **and** array) | per `dartnative_share._withFileArgs` |
| native → Dart dispatcher payload | native (stack / Kotlin `jstring`) | nobody — not transferred | dispatcher is `Pointer.fromFunction` = synchronous; Dart copies in-call |
| native → Dart byte chunk | native (reused buffer) | native | valid only for the duration of the call; Dart copies into `Uint8List` immediately |
| native read handles | native | Dart calls `…Close(handle)`; also force-closed on hot-restart reset | `try/finally` on the Dart side |
| JNI local refs | JNI | explicit `DeleteLocalRef` | per `dn_share_bridge.cpp` |
| iOS security scope | native | balanced `stop…` for every successful `start…` | never held open past the operation, except an explicit persisted bookmark |

One deliberate shape change: the dispatcher payload is **length-delimited bytes**
(`const uint8_t*, int32 len`) rather than a NUL-terminated C string. JSON events
travel as UTF-8 bytes and file chunks travel as raw bytes through the *same*
single slot, so binary data needs no base64 inflation and the plugin still obeys
"one dispatcher pointer, one slot, one registration".

## 11. Error / cancel conventions observed

- Cancellation is **not** an error: `showMediaPicker` returns `[]`, and
  `dartnative_share` models dismissal as a `ShareResultStatus`, never a throw.
- Native failure is reported as a typed status, not a bare `Exception`.
- Degrade, never crash: `dartnative_share` wraps its optional symbol lookups in
  `try/catch` and reports `unavailable` if a stale native build lacks them.

## 12. Commands verified to exist (`dn --help`, `dn help <cmd>`)

Verified present: `dn analyze` (has `--fatal-infos`/`--fatal-warnings`, default
on), `dn test`, `dn pub get|add|outdated`, `dn plugin build`, `dn plugin sync`,
`dn plugin publish` (alias `dn publish`), `dn build`, `dn run`, `dn doctor`,
`dn clean`, `dn login`/`dn logout`, `dn create`, `dn run-tool`, `dn devices`.

**Verified NOT to exist** — not used anywhere in this repo: `dn publish
--dry-run` (no dry-run flag of any kind), `dn format`, `dn fmt`, `dn lint`.
Formatting therefore goes through the SDK's own Dart: `~/zero/bin/dart format`.
`dn plugin build` is the closest safe pre-publication gate: it produces the iOS
`.xcframework` + Android `.aar` + Dart bindings into `dist/` without contacting
the registry.

## 13. dartpub publication requirements (publisher guide)

Public GitHub repo you own; license MIT, BSD-3-Clause or Apache-2.0 (copyleft
rejected); package name lowercase snake_case, 2–32 chars, globally unique;
registration reserves the name and the page stays unlisted until it has a README,
an `example/`, and a published version; `dn plugin publish` builds the binary,
pushes `README.md` + `example/` as the Readme/Example tabs and archives the
source; the `CHANGELOG.md` section matching the version becomes the release
notes; `dn plugin sync` re-pushes docs without rebuilding.

`dartnative_file_picker` does not appear in the dartpub catalog (34 first-party +
~30 community plugins listed), so the name is free. There is a first-party
`dartnative_media_picker`, which is photos/videos — a different job from
documents.
