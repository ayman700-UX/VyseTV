package com.vyse.player.exoplayer

import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceException
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap

/**
 * VyseTV: Media3's loader, told how long to keep asking a link that has gone quiet. The rule is
 * [SlowLinkPolicy]'s; this is where Media3 asks it.
 *
 * With no patience set (the app has not said how long to wait) it is Media3's own policy, to the
 * letter. With one, the count of tries no longer ends a load by itself: every error is decided in
 * [getRetryDelayMsFor], where a timeout is retried for as long as the patience allows and
 * anything else for as many tries as Media3 gives it. What Media3 never retries (a file that is
 * not there, one it cannot parse) is still never retried.
 */
@UnstableApi
internal class SlowLinkLoadErrorPolicy(
  private val clock: () -> Long = { SystemClock.elapsedRealtime() }
) : DefaultLoadErrorHandlingPolicy() {

  /** How long a silent link is asked again, in ms. 0: Media3's own rule. Set from any thread. */
  @Volatile
  var patienceMs: Long = 0L

  private val runs = ConcurrentHashMap<Long, SlowLinkPolicy.Run>()

  /** The last run that ended a load, for the report card: "silent for 62 s over 6 tries". */
  @Volatile
  var lastGivenUp: String? = null
    private set

  override fun getMinimumLoadableRetryCount(dataType: Int): Int =
    if (patienceMs > 0L) Int.MAX_VALUE else super.getMinimumLoadableRetryCount(dataType)

  override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
    val usual = super.getRetryDelayMsFor(loadErrorInfo)
    val patience = patienceMs
    if (patience <= 0L || usual == C.TIME_UNSET) return usual

    val now = clock()
    val taskId = loadErrorInfo.loadEventInfo.loadTaskId
    if (runs.size > MAX_TRACKED_LOADS) runs.clear()
    val run = SlowLinkPolicy.next(runs[taskId], loadErrorInfo.loadEventInfo.bytesLoaded, now)
    runs[taskId] = run

    val slow = isTimeout(loadErrorInfo.exception)
    val usualRetries = super.getMinimumLoadableRetryCount(loadErrorInfo.mediaLoadData.dataType)
    if (SlowLinkPolicy.retries(slow, run, now, patience, usualRetries)) return usual

    runs.remove(taskId)
    if (slow) {
      lastGivenUp = "silent for ${SlowLinkPolicy.stalledForMs(run, now) / 1000} s over ${run.errors} tries"
    }
    return C.TIME_UNSET
  }

  override fun onLoadTaskConcluded(loadTaskId: Long) {
    runs.remove(loadTaskId)
    super.onLoadTaskConcluded(loadTaskId)
  }

  /** A new video: what an earlier one was given up for is not about this one. */
  fun reset() {
    runs.clear()
    lastGivenUp = null
  }

  private companion object {
    const val MAX_TRACKED_LOADS = 64

    /** A read or a connection that timed out, however deep in the error it sits. */
    fun isTimeout(error: Throwable?): Boolean {
      var cause = error
      var depth = 0
      while (cause != null && depth < 12) {
        if (cause is SocketTimeoutException) return true
        if (cause is DataSourceException && cause.reason == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT) return true
        cause = cause.cause
        depth++
      }
      return false
    }
  }
}
