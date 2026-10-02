package com.dartnative.file_picker

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Entry point for dartnative_file_picker on Android.
 *
 * Registered automatically from this package's `pubspec.yaml` `pluginClass`
 * stanza: the toolchain emits an instantiation in the app's generated
 * registrant, and engine attach calls [onAttachedToEngine] here.
 *
 * It does exactly two things, both required:
 *
 * 1. `System.loadLibrary` — the **only** call site that fires `JNI_OnLoad` for
 *    `libdartnative_file_picker.so`, which is where the C++ bridge caches the
 *    `JavaVM` and its Kotlin method ids. Loading the library over FFI instead
 *    (`DynamicLibrary.open` alone) leaves `g_jvm` NULL and the first JNI
 *    callback dies with `SIGSEGV` in `_JavaVM::GetEnv`.
 * 2. Keeps the application `Context` where [appContext] can read it, which is
 *    how a view-less plugin gets a `Context` without depending on the
 *    framework's Android module.
 *
 * `FlutterPlugin` is the framework's documented Android registration hook. No
 * `MethodChannel` is registered and no message handler is installed: this plugin
 * talks to Dart exclusively over FFI.
 */
class DartNativeFilePickerPlugin : FlutterPlugin {

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        // Give back the URI grants the previous process took so that
        // AccessMode.reference could be read after the picker's activity went
        // away. This is what makes "persistAccess keeps it across restarts"
        // literally true rather than merely documented: without the sweep, a
        // session-scoped grant would quietly outlive the session it was named
        // for. Runs once per process; see SessionGrants.
        SessionGrants.sweepOnce(binding.applicationContext)
        try {
            System.loadLibrary("dartnative_file_picker")
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e(
                TAG,
                "Failed to load libdartnative_file_picker.so: ${e.message}",
            )
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Release open streams rather than leaking them with the engine, then
        // drop the context so nothing holds it after detach.
        reset()
        // The Dart objects that referenced these documents went with the
        // engine, so the grants held for them have no owner left. Releasing
        // here rather than waiting for the next process start keeps the app's
        // persisted-grant list clean while the process lingers.
        SessionGrants.releaseAll(binding.applicationContext)
        appContext = null
    }
}
