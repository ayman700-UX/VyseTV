package com.vyse.player.exoplayer

/**
 * VyseTV: how long Media3 keeps asking a link that has stopped sending before it gives the video
 * up (and the plugin hands it to mpv).
 *
 * Media3's own rule counts tries: an error, three more goes, then the video is given up. A read
 * that gets nothing for 10 seconds is an error, so a link that falls silent is given about 43
 * seconds (four reads and the pauses between them), whoever is serving it. mpv is told how long
 * to wait by the app (`network-timeout`): 60 seconds, 120 for a torrent, whose local server holds
 * a read open while the pieces under it arrive. So the same slow link that mpv would have sat
 * out was handed over by Media3, and a film that only Media3 plays as Dolby Vision on a TV went
 * to the other engine for the rest of that player.
 *
 * With a patience set, a link that is only slow (reads or connections timing out, nothing else)
 * is asked again for as long as mpv would have waited. Every other kind of error keeps Media3's
 * count, and a link is never given fewer goes than Media3 would give it.
 *
 * The decisions are here, apart from Media3, so they can be read and run on their own.
 * [SlowLinkLoadErrorPolicy] plugs them into Media3's loader.
 */
internal object SlowLinkPolicy {

  /** The longest one read waits for data (the HTTP factories' read timeout). */
  const val READ_TIMEOUT_MS = 10_000L

  /** The longest a patience can be: ten minutes, whatever is asked for. */
  const val MAX_PATIENCE_MS = 600_000L

  /**
   * A run of errors with nothing arriving in between.
   *
   * [bytes] is what the load had read when the run's latest error came, [errors] how many errors
   * the run has, [sinceMs] when its first one came.
   */
  data class Run(val bytes: Long, val errors: Int, val sinceMs: Long)

  /**
   * The run an error belongs to. Media3 counts a load's errors itself, but hands its count over
   * before it has taken progress into account, so progress is told here by the bytes: more read
   * than at the last error means data arrived in between, and a new run starts.
   */
  fun next(previous: Run?, bytesLoaded: Long, nowMs: Long): Run =
    if (previous == null || bytesLoaded > previous.bytes) {
      Run(bytes = bytesLoaded, errors = 1, sinceMs = nowMs)
    } else {
      previous.copy(errors = previous.errors + 1)
    }

  /** How long the link has sent nothing: the run so far, and the read its first error ended. */
  fun stalledForMs(run: Run, nowMs: Long): Long = (nowMs - run.sinceMs).coerceAtLeast(0L) + READ_TIMEOUT_MS

  /**
   * Whether the load is tried again after this error.
   *
   * [slow]: the error is a timeout. [usualRetries] is Media3's own count for this kind of load
   * (3, or 6 for a live stream). A timeout is retried while the link has been silent for less
   * than [patienceMs]; anything is retried while the run is within Media3's count.
   */
  fun retries(slow: Boolean, run: Run, nowMs: Long, patienceMs: Long, usualRetries: Int): Boolean {
    if (run.errors <= usualRetries) return true
    return slow && patienceMs > 0L && stalledForMs(run, nowMs) < patienceMs
  }

  /** mpv's `network-timeout` (seconds, as text) as a patience; 0 for anything that is not one. */
  fun patienceMs(networkTimeout: String?): Long {
    val seconds = networkTimeout?.trim()?.toDoubleOrNull() ?: return 0L
    if (seconds.isNaN() || seconds <= 0.0) return 0L
    return (seconds * 1000.0).toLong().coerceIn(0L, MAX_PATIENCE_MS)
  }
}
