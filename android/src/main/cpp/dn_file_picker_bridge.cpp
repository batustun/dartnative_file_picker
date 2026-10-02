/**
 * dn_file_picker_bridge.cpp — dartnative_file_picker Android JNI/C bridge.
 *
 * Architecture:
 *   Dart (main thread) ──[FFI]──► extern "C" DNFilePicker*  ──[JNI]──► Kotlin
 *   Kotlin (main thread) ──[JNI]──► nativeDeliver ──► the Dart dispatcher
 *
 * JNI_OnLoad caches the JavaVM and the Kotlin top-level method ids. It is fired
 * by System.loadLibrary in DartNativeFilePickerPlugin.onAttachedToEngine; a
 * library pulled in by dlopen alone would leave g_jvm NULL and crash on the
 * first callback.
 *
 * Kotlin top-level functions compile into a class named after the file, so the
 * lookup target is com/dartnative/file_picker/DNFilePickerBridgeKt.
 */

#include <jni.h>

#include <android/log.h>
#include <cstdint>
#include <dlfcn.h>

#define LOG_TAG "DNFilePicker"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ─── Global state ────────────────────────────────────────────────────────────

static JavaVM *g_jvm = nullptr;
static jclass g_bridgeClass = nullptr;
static jmethodID g_setDispatcher = nullptr;
static jmethodID g_reset = nullptr;
static jmethodID g_pick = nullptr;
static jmethodID g_open = nullptr;
static jmethodID g_readNext = nullptr;
static jmethodID g_close = nullptr;
static jmethodID g_copyToCache = nullptr;
static jmethodID g_release = nullptr;
static jmethodID g_resolve = nullptr;

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * The JNIEnv for the calling thread.
 *
 * Every FFI entry point is invoked from the Dart isolate's thread, which is the
 * main thread and is already attached to the JVM, so GetEnv suffices and no
 * AttachCurrentThread dance is needed.
 */
static JNIEnv *getEnv() {
    if (!g_jvm) return nullptr;
    JNIEnv *env = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return nullptr;
    }
    return env;
}

static jmethodID safeGet(JNIEnv *env, jclass cls, const char *name, const char *sig) {
    jmethodID mid = env->GetStaticMethodID(cls, name, sig);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return nullptr;
    }
    return mid;
}

static jstring toJString(JNIEnv *env, const char *s) {
    return s ? env->NewStringUTF(s) : nullptr;
}

/** Clears any pending Java exception so it cannot surface at a random later JNI call. */
static void clearPending(JNIEnv *env) {
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
}

// ─── JNI_OnLoad ──────────────────────────────────────────────────────────────

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/) {
    g_jvm = vm;
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    jclass cls = env->FindClass("com/dartnative/file_picker/DNFilePickerBridgeKt");
    if (!cls) {
        LOGE("JNI_OnLoad: class DNFilePickerBridgeKt not found");
        return JNI_ERR;
    }
    g_bridgeClass = static_cast<jclass>(env->NewGlobalRef(cls));
    env->DeleteLocalRef(cls);

    g_setDispatcher = safeGet(env, g_bridgeClass, "setDispatcher", "(J)V");
    g_reset = safeGet(env, g_bridgeClass, "reset", "()V");
    g_pick = safeGet(env, g_bridgeClass, "pick", "(JLjava/lang/String;)V");
    g_open = safeGet(env, g_bridgeClass, "open", "(JLjava/lang/String;)V");
    g_readNext = safeGet(env, g_bridgeClass, "readNext", "(JJI)V");
    g_close = safeGet(env, g_bridgeClass, "close", "(J)V");
    g_copyToCache = safeGet(env, g_bridgeClass, "copyToCache",
                            "(JLjava/lang/String;Ljava/lang/String;)V");
    g_release = safeGet(env, g_bridgeClass, "release", "(JLjava/lang/String;)V");
    g_resolve = safeGet(env, g_bridgeClass, "resolve", "(JLjava/lang/String;)V");

    // Every one of these is required: unlike an optional feature that can
    // degrade, a missing entry point here means the plugin cannot work at all,
    // and failing loudly at load beats a silent no-op per call.
    if (!g_setDispatcher || !g_reset || !g_pick || !g_open || !g_readNext ||
        !g_close || !g_copyToCache || !g_release || !g_resolve) {
        LOGE("JNI_OnLoad: a DNFilePickerBridge method was not found");
        return JNI_ERR;
    }

    LOGI("JNI_OnLoad OK");
    return JNI_VERSION_1_6;
}

// ─── FFI entry points (called from Dart) ─────────────────────────────────────

extern "C" __attribute__((visibility("default")))
void DNFilePickerSetDispatcher(int64_t callbackPtr) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_setDispatcher) return;
    env->CallStaticVoidMethod(g_bridgeClass, g_setDispatcher, static_cast<jlong>(callbackPtr));
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerReset() {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_reset) return;
    env->CallStaticVoidMethod(g_bridgeClass, g_reset);
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerPick(int64_t token, const char *requestJson) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_pick) return;
    jstring jJson = toJString(env, requestJson);
    env->CallStaticVoidMethod(g_bridgeClass, g_pick, static_cast<jlong>(token), jJson);
    if (jJson) env->DeleteLocalRef(jJson);
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerOpen(int64_t token, const char *uri) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_open) return;
    jstring jUri = toJString(env, uri);
    env->CallStaticVoidMethod(g_bridgeClass, g_open, static_cast<jlong>(token), jUri);
    if (jUri) env->DeleteLocalRef(jUri);
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerReadNext(int64_t token, int64_t handle, int32_t chunkSize) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_readNext) return;
    env->CallStaticVoidMethod(g_bridgeClass, g_readNext, static_cast<jlong>(token),
                              static_cast<jlong>(handle), static_cast<jint>(chunkSize));
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerClose(int64_t handle) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_close) return;
    env->CallStaticVoidMethod(g_bridgeClass, g_close, static_cast<jlong>(handle));
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerCopyToCache(int64_t token, const char *uri, const char *preferredName) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_copyToCache) return;
    jstring jUri = toJString(env, uri);
    jstring jName = toJString(env, preferredName);
    env->CallStaticVoidMethod(g_bridgeClass, g_copyToCache, static_cast<jlong>(token),
                              jUri, jName);
    if (jUri) env->DeleteLocalRef(jUri);
    if (jName) env->DeleteLocalRef(jName);
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerRelease(int64_t token, const char *uri) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_release) return;
    jstring jUri = toJString(env, uri);
    env->CallStaticVoidMethod(g_bridgeClass, g_release, static_cast<jlong>(token), jUri);
    if (jUri) env->DeleteLocalRef(jUri);
    clearPending(env);
}

extern "C" __attribute__((visibility("default")))
void DNFilePickerResolve(int64_t token, const char *uri) {
    JNIEnv *env = getEnv();
    if (!env || !g_bridgeClass || !g_resolve) return;
    jstring jUri = toJString(env, uri);
    env->CallStaticVoidMethod(g_bridgeClass, g_resolve, static_cast<jlong>(token), jUri);
    if (jUri) env->DeleteLocalRef(jUri);
    clearPending(env);
}

// ─── Kotlin externals (delivery into Dart) ───────────────────────────────────

/**
 * Reads the framework's isolate-generation counter.
 *
 * Bumped BEFORE the old isolate dies on hot restart, so the Kotlin generation
 * gate drops a delivery that would otherwise call a freed trampoline. Resolved
 * with dlsym at runtime, which is what lets this plugin avoid a compile-time
 * dependency on the framework's Android module.
 */
extern "C" JNIEXPORT jlong JNICALL
Java_com_dartnative_file_1picker_DNFilePickerBridgeKt_nativeIsolateGen(JNIEnv *, jclass) {
    using GenFn = uint64_t (*)();
    static GenFn fn = reinterpret_cast<GenFn>(dlsym(RTLD_DEFAULT, "DN_IsolateGen"));
    return fn ? static_cast<jlong>(fn()) : 0;
}

/**
 * Invokes the Dart dispatcher: (token, type, payload bytes, length).
 *
 * Called on the main thread (= the Dart isolate's thread) with the generation
 * already checked. The call is synchronous and Dart copies the bytes during it,
 * so the buffer is borrowed, never transferred: nothing here is freed by Dart
 * and nothing leaks.
 *
 * The payload is length-delimited rather than NUL-terminated so that JSON
 * replies and raw file chunks can share one dispatcher without base64.
 */
extern "C" JNIEXPORT void JNICALL
Java_com_dartnative_file_1picker_DNFilePickerBridgeKt_nativeDeliver(
        JNIEnv *env, jclass, jlong ptr, jlong token, jint type, jbyteArray payload) {
    if (!ptr) return;
    using DispatchFn = void (*)(int64_t, int32_t, const uint8_t *, int32_t);
    auto dispatch = reinterpret_cast<DispatchFn>(ptr);

    if (payload == nullptr) {
        dispatch(static_cast<int64_t>(token), static_cast<int32_t>(type), nullptr, 0);
        return;
    }

    const jsize length = env->GetArrayLength(payload);
    // GetByteArrayElements may copy, but it is the portable choice: the Dart
    // callback can run arbitrary Dart code, and holding a critical section
    // across that would be illegal.
    jbyte *bytes = env->GetByteArrayElements(payload, nullptr);
    if (!bytes) {
        clearPending(env);
        dispatch(static_cast<int64_t>(token), static_cast<int32_t>(type), nullptr, 0);
        return;
    }
    dispatch(static_cast<int64_t>(token), static_cast<int32_t>(type),
             reinterpret_cast<const uint8_t *>(bytes), static_cast<int32_t>(length));
    env->ReleaseByteArrayElements(payload, bytes, JNI_ABORT);  // read-only, discard
}
