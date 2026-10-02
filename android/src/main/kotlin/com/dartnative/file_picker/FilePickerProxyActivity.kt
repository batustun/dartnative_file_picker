package com.dartnative.file_picker

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log

/**
 * A transparent activity whose only job is to run one `startActivityForResult`
 * round trip for the Storage Access Framework picker.
 *
 * ## Why this exists
 *
 * DartNative exposes no Activity-result hook: there is no `onActivityResult`
 * plumbing, no `ActivityAware` equivalent, and `DNActivityHooks` covers only
 * `onUserLeaveHint` and Picture-in-Picture. `Intent.ACTION_OPEN_DOCUMENT` is
 * meaningless without its result, so this plugin brings its own activity rather
 * than depending on the framework's Android module — which, per the framework
 * docs, would stop the plugin from producing a publishable Android archive.
 *
 * The user never sees it: the theme is translucent and it finishes as soon as the
 * system picker returns.
 *
 * ## Lifecycle
 *
 * The Dart request token travels in the launching intent and is re-saved in
 * [onSaveInstanceState], so a configuration change or a low-memory kill during
 * the system picker cannot cross-wire the reply. If the process is killed
 * outright the Dart side is gone too, and the isolate-generation gate in
 * [deliver] drops the delivery.
 *
 * Exactly one outcome is reported, by [report], whichever way this activity ends.
 */
internal class FilePickerProxyActivity : Activity() {

    private var token: Long = NO_TOKEN
    private var launched = false
    private var reported = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        token = savedInstanceState?.getLong(EXTRA_TOKEN, NO_TOKEN)
            ?: intent.getLongExtra(EXTRA_TOKEN, NO_TOKEN)
        launched = savedInstanceState?.getBoolean(EXTRA_LAUNCHED, false) ?: false

        if (token == NO_TOKEN) {
            Log.w(TAG, "proxy activity started without a token")
            finish()
            return
        }

        // On a recreation the picker is already up; waiting for its result is
        // the whole job, so do not launch a second one.
        if (launched) return

        val pickerIntent = intent.getParcelableExtra<Intent>(EXTRA_INTENT)
        if (pickerIntent == null) {
            Log.w(TAG, "proxy activity started without a picker intent")
            report(emptyList())
            finish()
            return
        }

        // Defence in depth. This activity is android:exported="false", so only
        // this app can start it, and the intent it forwards is always one that
        // pick() built. But it DOES start an Intent that arrived in an extra, so
        // it refuses to start anything other than the action it exists to run:
        // if that guarantee is ever weakened, this activity still cannot be
        // turned into a way to launch arbitrary intents with the app's identity.
        if (pickerIntent.action != Intent.ACTION_OPEN_DOCUMENT) {
            Log.w(TAG, "refusing to start an unexpected action: ${pickerIntent.action}")
            report(emptyList())
            finish()
            return
        }

        try {
            launched = true
            startActivityForResult(pickerIntent, REQUEST_CODE)
        } catch (e: android.content.ActivityNotFoundException) {
            // No DocumentsUI on this device or profile: a real, reportable
            // condition rather than a crash.
            Log.w(TAG, "no activity can handle ACTION_OPEN_DOCUMENT: ${e.message}")
            report(emptyList())
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putLong(EXTRA_TOKEN, token)
        outState.putBoolean(EXTRA_LAUNCHED, launched)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE) return

        if (resultCode != RESULT_OK || data == null) {
            // Cancellation: a normal outcome, reported as an empty selection.
            report(emptyList())
            finish()
            return
        }
        report(extractUris(data))
        finish()
    }

    /**
     * Reports once, whatever happens.
     *
     * Covers the paths that bypass [onActivityResult] entirely: a missing
     * intent, no handler for the action, or the activity being finished by the
     * system before the picker returned.
     */
    override fun finish() {
        report(emptyList())
        super.finish()
        // No transition animation: this activity is invisible, and an animation
        // would show a flash of nothing.
        overridePendingTransition(0, 0)
    }

    private fun report(uris: List<Uri>) {
        if (reported) return
        reported = true
        onPickResult(token, uris)
    }

    internal companion object {
        private const val REQUEST_CODE = 0x4650 // 'FP'
        private const val NO_TOKEN = -1L
        private const val EXTRA_TOKEN = "com.dartnative.file_picker.TOKEN"
        private const val EXTRA_INTENT = "com.dartnative.file_picker.INTENT"
        private const val EXTRA_LAUNCHED = "com.dartnative.file_picker.LAUNCHED"

        /**
         * Starts the proxy activity for [token] with [pickerIntent].
         *
         * Launched from the application context with `FLAG_ACTIVITY_NEW_TASK`,
         * because this plugin has no handle on the current Activity.
         *
         * The manifest deliberately leaves this activity on the app's **default
         * task affinity**, so `NEW_TASK` joins the app's existing task rather
         * than creating one. That is required for correct task and
         * return-destination behaviour: with an empty affinity the proxy lived
         * in a task of its own, and finishing itself tore down a task that was
         * not the user's, returning them to the wrong place.
         *
         * It is **not** what keeps a picked document readable. Finding F9
         * measured the opposite: the transient URI permission from
         * `ACTION_OPEN_DOCUMENT` is owned by the receiving **activity**, not by
         * its task, and is lost when that activity leaves the history stack
         * (`ActivityRecord.removeFromHistory` -> `removeUriPermissionsLocked`).
         * This proxy finishes as soon as it has the result, so no task
         * arrangement preserves that grant.
         *
         * Durable `reference`-mode access comes from a **read-only persistable**
         * URI grant, taken while the transient one still exists, with
         * [SessionGrants] owning the lifetime of every grant the caller did not
         * ask to persist.
         *
         * Throws if no activity can be started; the caller reports that.
         */
        fun launch(context: Context, token: Long, pickerIntent: Intent) {
            val intent = Intent(context, FilePickerProxyActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                putExtra(EXTRA_TOKEN, token)
                putExtra(EXTRA_INTENT, pickerIntent)
            }
            context.startActivity(intent)
        }
    }
}

/**
 * Collects every selected document from a picker result.
 *
 * A multi-selection arrives through [Intent.getClipData] while a single
 * selection arrives through [Intent.getData], and some providers set both — so
 * both are read and duplicates by URI are collapsed. Duplicates the *user*
 * chose are preserved: that happens at the `clipData` level and is a real
 * selection, not an artifact.
 */
internal fun extractUris(data: Intent): List<Uri> {
    val clip = data.clipData
    if (clip != null && clip.itemCount > 0) {
        val uris = ArrayList<Uri>(clip.itemCount)
        for (i in 0 until clip.itemCount) {
            clip.getItemAt(i).uri?.let { uris.add(it) }
        }
        if (uris.isNotEmpty()) return uris
    }
    return data.data?.let { listOf(it) } ?: emptyList()
}
