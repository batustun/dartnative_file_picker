# Upstream report: generated pod declares Commercial license and DartNative authorship

**Status: prepared, not sent.** Written for the DartNative SDK maintainers. It is
kept in the repository as the evidence record behind the packaging note in
`CHANGELOG.md`, and it is not published or filed anywhere without the owner
asking for that.

Classification for this package's own release process:
**KNOWN UPSTREAM DARTNATIVE TOOLING/METADATA ISSUE.** Not a 0.1.0 blocker. The
package's own licensing documents are correct, the false statement is not
repeated in the README or any package-owned metadata, no third-party code is
vendored under an incorrect license, and publication does not require the
package author to write the incorrect field themselves.

---

## Environment

```
DartNative 1.0.0 • framework edition 7ae291321d3045cd • channel stable
Framework • revision 113c27aacb2 • 2026-09-28 23:54:06 +0200
Engine • hash 868544bccad64b70d0c00cfc5010440dae673b94 (revision 2baa73665c)
```

Plugin: `dartnative_file_picker` 0.1.0, a community plugin licensed **MIT**.

## Reproduction

```bash
dn plugin build --owner <github-login>
grep -E "s\.(summary|homepage|license|author)" dist/<name>-<version>/<name>.podspec
```

## Generated fields

From `dist/dartnative_file_picker-0.1.0/dartnative_file_picker.podspec`, which is
the pod that ships inside the publishable archive:

```ruby
s.summary          = 'dartnative_file_picker (prebuilt binary, distributed via dartpub).'
s.homepage         = 'https://dartpub.dev/plugins/dartnative_file_picker'
s.license          = { :type => 'Commercial' }
s.author           = { 'DartNative' => 'hello@dartnative.com' }
```

## Expected fields, and the source they should come from

The package already declares all four correctly in its own
`ios/dartnative_file_picker.podspec`, which `dn plugin build` does read for other
purposes:

```ruby
s.summary          = 'Native document picker for DartNative (UIDocumentPickerViewController).'
s.homepage         = 'https://github.com/batustun/dartnative_file_picker'
s.license          = { :type => 'MIT', :file => '../LICENSE' }
s.author           = { 'Batuhan Ustun' => 'https://github.com/batustun' }
```

`pubspec.yaml` additionally carries `repository:` and `issue_tracker:`, and the
archive ships a correct MIT `LICENSE` file beside the pod that contradicts it.

## Provenance

`packages/flutter_tools/lib/src/commands/plugin_build.dart`, the consumer-podspec
template, lines 2320-2326:

```dart
  return '''
Pod::Spec.new do |s|
  s.name             = '$name'
  s.version          = '$version'
  s.summary          = '$name (prebuilt binary, distributed via dartpub).'
  s.homepage         = 'https://dartpub.dev/plugins/$name'
  s.license          = { :type => 'Commercial' }
  s.author           = { 'DartNative' => 'hello@dartnative.com' }
  s.platform         = :ios, '$minIos'
```

Only `$name`, `$version` and `$minIos` are interpolated. The same file carries a
second hardcoded block for the engine placeholder pod at lines 541-544
(`:type => 'BSD'`, `'DartNative Team' => 'dev@dartnative.com'`).

## Why a package author cannot safely correct it

1. **No input exists.** The generator is called as

   ```dart
   consumerPodspec(
     name: ctx.name, version: ctx.version, minIos: podspec.minIos,
     frameworksRuby: podspec.frameworksRuby, librariesRuby: podspec.librariesRuby,
     dependencies: podspec.dependencies, vendored: xcframework != null,
     dynamicFramework: dynamicFramework, ...)
   ```

   There is no `license`, `author`, `homepage` or `summary` parameter, so the
   values cannot be supplied even though the source podspec is parsed for
   `minIos`, `frameworksRuby` and `dependencies`.

2. **The file is overwritten unconditionally.** At
   `plugin_build.dart:1610` the archive's pod is written with

   ```dart
   pkg.childFile('${ctx.name}.podspec').writeAsStringSync(consumerPodspec(...))
   ```

   so a correct package-owned podspec is replaced on every build. Editing the
   generated file afterwards would be undone by the next `dn plugin build`, and
   `dn plugin publish` builds the binary itself, so there is no point in the
   publication flow at which a package author could inject the right values and
   have them survive.

3. **Patching the SDK is not a package-level fix.** Correcting
   `~/zero/packages/flutter_tools/...` changes the developer's local toolchain,
   not the package, and would silently diverge every plugin built on that
   machine. This package deliberately does not do it.

## Suggested fix

Thread the four fields through `consumerPodspec`, defaulting to the current
values so first-party behaviour is unchanged, and read them from the plugin's own
`ios/<name>.podspec` (already parsed) or from `pubspec.yaml`. A narrower fix that
would also be sufficient: omit `license` and `author` from the generated pod
entirely when the plugin ships a `LICENSE` file whose contents do not match the
DartNative commercial license, rather than asserting a wrong value.

## Impact

CocoaPods metadata only. The license actually granted to consumers is the one in
the `LICENSE` file, which is correct and ships in the same archive. The practical
harm is that automated license scanners and anyone reading the pod will be told a
community MIT plugin is commercially licensed and authored by DartNative.
