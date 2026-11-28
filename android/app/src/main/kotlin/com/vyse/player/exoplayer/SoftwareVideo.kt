package com.vyse.player.exoplayer

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegLibrary
import java.util.concurrent.ConcurrentHashMap

/**
 * VyseTV addition (not in upstream).
 *
 * When Media3 may decode a video with FFmpeg, in this app's processor, instead of with the
 * device's own decoders (MediaCodec): Settings > Playback > Video decoding. The decoder is
 * nextlib's FfmpegVideoRenderer (io.github.anilbeesetti.nextlib, GPL-3.0), on the FFmpeg the
 * app already carries for mpv.
 *
 *  - [AUTO] (the default): only a video that no decoder on this device takes as it is (10-bit
 *    H.264, VC-1 or AV1 on a TV without one, MPEG-4 Part 2 on some), and only up to 1080p.
 *    Bigger than that a TV's processor can't keep up, and such a video goes on to mpv as it did
 *    before this decoder was here.
 *  - [HARDWARE]: never (the device's decoders, then mpv).
 *  - [SOFTWARE]: every video FFmpeg can decode, the device's decoders left out for it. For a TV
 *    whose decoders show a black or broken picture; slow at 4K.
 *
 * Asked each time Media3 matches a video to a decoder, so a change takes effect from the next
 * video, without the player being made again.
 */
@OptIn(UnstableApi::class)
internal object SoftwareVideo {
  const val AUTO = "auto"
  const val HARDWARE = "hardware"
  const val SOFTWARE = "software"

  /** Set by Flutter (ExoPlayerPlugin "setVideoDecoding"). */
  @Volatile
  var mode: String = AUTO
    set(value) {
      field = if (value == HARDWARE || value == SOFTWARE) value else AUTO
    }

  /** The app's context, which Media3 asks for when it checks a decoder (set by VyseRenderersFactory). */
  @Volatile
  var context: Context? = null

  /** 1080p, with the 8 lines a codec rounds 1080 up to. */
  private const val AUTO_MAX_PIXELS = 1920L * 1088L

  /** Whether the FFmpeg decoder may take [format] (its own checks come first: codec, DRM). */
  fun allows(format: Format): Boolean = when (mode) {
    HARDWARE -> false
    SOFTWARE -> true
    else -> autoAllows(format)
  }

  /** Whether the device's decoders are to leave [format] to the FFmpeg decoder (Software only). */
  fun leftToSoftware(format: Format): Boolean {
    if (mode != SOFTWARE || format.cryptoType != C.CRYPTO_TYPE_NONE) return false
    val mime = format.sampleMimeType ?: return false
    return runCatching { FfmpegLibrary.supportsFormat(mime) }.getOrDefault(false)
  }

  private fun autoAllows(format: Format): Boolean {
    val w = format.width
    val h = format.height
    // (a size not said, as in some streams' lists: not guessed at)
    if (w <= 0 || h <= 0 || w.toLong() * h > AUTO_MAX_PIXELS) return false
    return !deviceTakes(format)
  }

  private val asked = ConcurrentHashMap<String, Boolean>()

  /**
   * Whether a decoder on this device, hardware or Android's own software ones, takes [format]
   * as it is (its profile, level, size and rate); for Dolby Vision, also the decoder of the
   * layer under it that Media3 falls back to.
   */
  private fun deviceTakes(format: Format): Boolean {
    val mime = format.sampleMimeType ?: return true
    val key = "$mime|${format.codecs}|${format.width}x${format.height}|${format.frameRate}|${format.colorInfo?.colorTransfer}"
    return asked.getOrPut(key) {
      runCatching {
        // (no context yet: the device is taken to have one, and nothing changes)
        val app = context ?: return@runCatching true
        val alternative = MediaCodecUtil.getAlternativeCodecMimeType(format)
        val decoders = MediaCodecUtil.getDecoderInfos(mime, false, false) +
          (if (alternative != null) MediaCodecUtil.getDecoderInfos(alternative, false, false) else emptyList())
        decoders.any { runCatching { it.isFormatSupported(app, format) }.getOrDefault(false) }
      }.getOrDefault(true)
    }
  }
}
