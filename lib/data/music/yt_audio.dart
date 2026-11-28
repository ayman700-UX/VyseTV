// VyseTV addition (not in upstream).
//
// A song's sound from YouTube Music, looked up by VyseTV itself. Translated from the Kotlin of
// an open-source music player's lookup (Metrolist's InnerTubeX library, GPL-3.0): the part of it
// that needs nothing but a plain request.
//
// What is taken from it:
//  * the clients that answer with a song's sound as a plain address: no token, no player script
//    to run on the address. Its VISIONOS profiles, and IOS_PRODUCER (a 360p video with its sound)
//    as the last resort;
//  * the request to /youtubei/v1/player (endpoint, headers, body), and the checks on the answer
//    (playable, the song asked for, no DRM, an address on YouTube's own servers, no `n` left to
//    transform);
//  * its choice of format: Opus in WebM by default, AAC in MP4 where Opus is a trap (Samsung's
//    and LG's own players, see [YtAudio.wantsAac]);
//  * when an address stops being served (the earliest of the three times YouTube gives), and a
//    short cache of what was found, dropped when a song broke.
//
// What is not taken, on purpose: proof-of-origin tokens and the WebView that makes them, the
// player script it runs for signed addresses, SABR streaming, and moving to another client when
// YouTube asks to confirm you're not a bot. A bot check ends the lookup ([YtBotCheck]), as it
// did before this file.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/platform/tizen_tv.dart';
import '../../core/platform/webos.dart';
import '../net.dart';

/// A song's sound as found: its address, the user agent to fetch it with (null: none needed),
/// when YouTube stops serving it, and which format it is.
typedef YtAudioFound = ({String url, String? userAgent, DateTime? expires, int itag, String mimeType, String client});

/// YouTube asked to confirm this device is not a bot: nothing more is asked for the song.
class YtBotCheck implements Exception {
  const YtBotCheck(this.reason);
  final String reason;

  @override
  String toString() => 'YouTube asked to confirm this is not a bot: $reason';
}

/// One of YouTube's clients, as the lookup presents itself.
@immutable
class YtClient {
  const YtClient({
    required this.key,
    required this.name,
    required this.version,
    required this.id,
    required this.userAgent,
    this.osName,
    this.osVersion,
    this.deviceMake,
    this.deviceModel,
    this.platform,
    this.musicEndpoint = false,
    this.needsVisitor = false,
    this.acceptsAnyStatus = false,
    this.mediaNeedsAgent = true,
  });

  /// The profile's own name (for the log and the report).
  final String key;
  final String name;
  final String version;

  /// Sent as X-YouTube-Client-Name.
  final int id;
  final String userAgent;
  final String? osName, osVersion, deviceMake, deviceModel, platform;

  /// Asked at music.youtube.com (else www.youtube.com).
  final bool musicEndpoint;

  /// Answers only with a visitor id ([YtAudio] fetches one).
  final bool needsVisitor;

  /// Its answer is judged by its formats, whatever its status says.
  final bool acceptsAnyStatus;

  /// Its addresses are fetched with its user agent.
  final bool mediaNeedsAgent;

  String get host => musicEndpoint ? 'music.youtube.com' : 'www.youtube.com';

  /// The request's body for [videoId].
  Map<String, Object?> body(String videoId, {String? visitor}) => {
    'context': {
      'client': {
        'clientName': name,
        'clientVersion': version,
        'osName': ?osName,
        'osVersion': ?osVersion,
        'deviceMake': ?deviceMake,
        'deviceModel': ?deviceModel,
        'platform': ?platform,
        'gl': 'US',
        'hl': 'en',
        'visitorData': ?visitor,
      },
    },
    'videoId': videoId,
    'contentCheckOk': true,
    'racyCheckOk': true,
    if (!musicEndpoint) 'videoCheckOk': true,
  };

  /// The request's headers.
  Map<String, String> headers({String? visitor}) => {
    'Content-Type': 'application/json',
    'X-Goog-Api-Format-Version': '1',
    'X-YouTube-Client-Name': '$id',
    'X-YouTube-Client-Version': version,
    'Origin': 'https://$host',
    'X-Origin': 'https://$host',
    'Referer': 'https://$host/',
    'Accept-Language': 'en-US,en;q=0.9',
    'X-Goog-Visitor-Id': ?visitor,
    'User-Agent': userAgent,
  };
}

/// VyseTV's own lookup of a song's sound (see the top of the file).
class YtAudio {
  YtAudio._();

  static final instance = YtAudio._();

  /// The clients, in the order they are asked. VISIONOS 0.1 answers with a song's sound only
  /// with a visitor id, and is skipped when none could be had.
  static const clients = <YtClient>[
    YtClient(
      key: 'VISIONOS_0_1',
      name: 'VISIONOS',
      version: '0.1',
      id: 101,
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15',
      osName: 'VISION_OS',
      osVersion: '1.3',
      deviceMake: 'Apple',
      deviceModel: 'RealityDevice14,1',
      platform: 'MOBILE',
      musicEndpoint: true,
      needsVisitor: true,
      acceptsAnyStatus: true,
      mediaNeedsAgent: false,
    ),
    YtClient(
      key: 'VISIONOS',
      name: 'VISIONOS',
      version: '1.02',
      id: 101,
      userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
      osName: 'visionOS',
      osVersion: '26.5.23O471',
      deviceMake: 'Apple',
      deviceModel: 'RealityDevice17,1',
      musicEndpoint: true,
      mediaNeedsAgent: false,
    ),
    // (a 360p video with low-quality AAC: only when nothing else answered)
    YtClient(
      key: 'IOS_PRODUCER',
      name: 'IOS_PRODUCER',
      version: '0.10',
      id: 92,
      userAgent: 'com.google.ios.youtubeproducer/0.10 (iPhone16,2; U; CPU iOS 18_6_2 like Mac OS X;)',
      osName: 'iPhone',
      osVersion: '18.6.2.22G100',
      deviceMake: 'Apple',
      deviceModel: 'iPhone16,2',
    ),
  ];

  /// Whether this device's player is given AAC in MP4 rather than Opus in WebM: Samsung's and
  /// LG's own players. Opus in WebM is a trap on Samsung's (Jellyfin's Samsung app has open
  /// issues on it, and a Samsung tester's music never played); AAC in MP4 is the one format
  /// every TV player takes.
  static bool get wantsAac => debugWantsAac ?? (TizenTv.isTv || WebOS.isTv);

  @visibleForTesting
  static bool? debugWantsAac;

  /// Tests: answers the requests in place of YouTube (method, address, headers, body).
  @visibleForTesting
  static Future<(int, String)> Function(String method, Uri url, Map<String, String> headers, String? body)? debugHttp;

  // ── the visitor id ──

  String? _visitor;
  DateTime _visitorAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _visitorFailedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _visitorAsk;

  /// The visitor id YouTube gives any browser that opens it, kept for twelve hours. One for the
  /// app, never changed to get past anything.
  Future<String?> visitor() {
    final now = DateTime.now();
    if (_visitor != null && now.difference(_visitorAt) < const Duration(hours: 12)) return Future.value(_visitor);
    if (now.difference(_visitorFailedAt) < const Duration(seconds: 30)) return Future.value(_visitor);
    return _visitorAsk ??= () async {
      try {
        final v = await _fetchVisitor().timeout(const Duration(seconds: 15));
        if (v != null) {
          _visitor = v;
          _visitorAt = DateTime.now();
        } else {
          _visitorFailedAt = DateTime.now();
        }
        return _visitor;
      } catch (_) {
        _visitorFailedAt = DateTime.now();
        return _visitor;
      } finally {
        _visitorAsk = null;
      }
    }();
  }

  static const _webAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0';

  Future<String?> _fetchVisitor() async {
    try {
      final (status, text) = await _send('GET', Uri.parse('https://www.youtube.com/sw.js_data'),
          {'User-Agent': _webAgent, 'Accept': 'application/json,text/plain,*/*'}, null, const Duration(seconds: 4));
      if (status == 200) {
        final v = visitorFromSwData(text);
        if (v != null) return v;
      }
    } catch (_) {}
    final (status, page) = await _send('GET', Uri.parse('https://music.youtube.com/'), {'User-Agent': _webAgent, 'Accept-Language': 'en-US,en;q=0.9'}, null, const Duration(seconds: 10));
    return status == 200 ? visitorFromPage(page) : null;
  }

  /// The visitor id in YouTube's sw.js_data answer: JSON after its first line, at [0][2][0][0][13].
  @visibleForTesting
  static String? visitorFromSwData(String text) {
    final nl = text.indexOf('\n');
    if (nl < 0) return null;
    try {
      final j = jsonDecode(text.substring(nl + 1));
      final v = ((((j as List)[0] as List)[2] as List)[0] as List)[0] as List;
      final id = v[13];
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// The visitor id in a YouTube Music page.
  @visibleForTesting
  static String? visitorFromPage(String page) => RegExp(r'"(?:VISITOR_DATA|visitorData)"\s*:\s*"([^"]+)"').firstMatch(page)?.group(1);

  // ── the lookup ──

  final _found = <String, YtAudioFound>{};

  /// Forgets what was found for [videoId]: its address broke, and the next ask must be fresh.
  void forget(String videoId) => _found.removeWhere((k, _) => k.startsWith('$videoId|'));

  /// [videoId]'s sound, or null when none of the clients had an address for it. Throws
  /// [YtBotCheck] when YouTube asked to confirm this is not a bot. [fresh]: never from the
  /// cache. [aac]: AAC in MP4 first (by default where this device's player wants it).
  Future<YtAudioFound?> find(String videoId, {bool fresh = false, bool? aac}) async {
    final wantAac = aac ?? wantsAac;
    final key = '$videoId|${wantAac ? 'mp4' : 'auto'}';
    final kept = _found[key];
    if (!fresh && kept != null && (kept.expires == null || DateTime.now().isBefore(kept.expires!.subtract(const Duration(seconds: 10))))) return kept;
    _found.remove(key);
    String? id;
    var idAsked = false;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    for (final client in clients) {
      if (DateTime.now().isAfter(deadline)) break;
      if (client.needsVisitor) {
        if (!idAsked) {
          idAsked = true;
          final test = debugVisitor;
          id = test != null ? test() : await visitor();
        }
        if (id == null) continue;
      }
      final r = await _ask(client, videoId, visitor: client.needsVisitor ? id : null, aac: wantAac);
      if (r != null) {
        _keep(key, r);
        return r;
      }
    }
    return null;
  }

  /// Tests: the visitor id, in place of YouTube's.
  @visibleForTesting
  static String? Function()? debugVisitor;

  void _keep(String key, YtAudioFound r) {
    _found[key] = r;
    while (_found.length > 64) {
      _found.remove(_found.keys.first);
    }
  }

  /// One client's answer for [videoId]: its sound, or null to ask the next one.
  Future<YtAudioFound?> _ask(YtClient client, String videoId, {String? visitor, required bool aac}) async {
    final url = Uri.parse('https://${client.host}/youtubei/v1/player?prettyPrint=false');
    (int, String) answer;
    try {
      answer = await _send('POST', url, client.headers(visitor: visitor), jsonEncode(client.body(videoId, visitor: visitor)), const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[YtAudio] ${client.key} $videoId: $e');
      return null;
    }
    final (status, text) = answer;
    if (status != 200) {
      debugPrint('[YtAudio] ${client.key} $videoId: HTTP $status');
      return null;
    }
    return readAnswer(client, videoId, text, aac: aac);
  }

  /// What [client]'s answer [text] for [videoId] gives: its sound, null for nothing usable (the
  /// next client is asked), or [YtBotCheck].
  @visibleForTesting
  static YtAudioFound? readAnswer(YtClient client, String videoId, String text, {required bool aac, DateTime? now}) {
    final Map<String, dynamic> j;
    try {
      final d = jsonDecode(text);
      if (d is! Map<String, dynamic>) return null;
      j = d;
    } catch (_) {
      return null;
    }
    final playability = j['playabilityStatus'];
    final status = playability is Map ? '${playability['status'] ?? ''}' : '';
    final reason = playability is Map ? '${playability['reason'] ?? ''}' : '';
    if (isBotCheck(status, reason)) throw YtBotCheck(reason);
    if (status != 'OK' && !client.acceptsAnyStatus) return null;
    // (an answer for another song, or one under DRM, is not this song's)
    final details = j['videoDetails'];
    if (details is Map && details['videoId'] != null && details['videoId'] != videoId) return null;
    if (_drm.hasMatch(text)) return null;
    final streaming = j['streamingData'];
    if (streaming is! Map) return null;
    final adaptive = streaming['adaptiveFormats'];
    final picked = pickAudio(adaptive is List ? adaptive : const [], aac: aac) ??
        // (IOS_PRODUCER's video with its sound, when it is all there is)
        _progressive(streaming['formats']);
    if (picked == null) return null;
    final at = now ?? DateTime.now();
    final address = '${picked['url']}&cpn=${playbackNonce()}';
    return (
      url: address,
      userAgent: client.mediaNeedsAgent ? client.userAgent : null,
      expires: expiryOf(address, streaming['expiresInSeconds'], now: at),
      itag: (picked['itag'] as num?)?.toInt() ?? -1,
      mimeType: '${picked['mimeType'] ?? ''}',
      client: client.key,
    );
  }

  static final _drm = RegExp(r'"(?:contentProtection|drmFamilies|drmParams|licenseInfos|widevine|fairplay|playready)"', caseSensitive: false);

  /// YouTube's "Sign in to confirm you're not a bot".
  @visibleForTesting
  static bool isBotCheck(String status, String reason) =>
      status == 'LOGIN_REQUIRED' && RegExp(r"\bbot\b|confirm you(?:'|’)?re not", caseSensitive: false).hasMatch(reason);

  /// The best of [formats] to play as sound (Metrolist's selector): audio only, with a plain
  /// address on YouTube's servers that has no `n` left to transform; the file's original
  /// language track if it says which. By default the best Opus in WebM, else the best of any;
  /// with [aac] the best AAC in MP4, else the best of any.
  @visibleForTesting
  static Map<String, dynamic>? pickAudio(List<dynamic> formats, {required bool aac}) {
    final audio = <Map<String, dynamic>>[
      for (final f in formats)
        if (f is Map<String, dynamic> && f['width'] == null && '${f['mimeType'] ?? ''}'.startsWith('audio/') && f['url'] is String && playableAddress(f['url'] as String)) f,
    ];
    if (audio.isEmpty) return null;
    final originals = audio.where((f) => f['audioTrack'] is Map && (f['audioTrack'] as Map)['audioIsDefault'] == true).toList();
    final pool = originals.isNotEmpty ? originals : audio;
    Map<String, dynamic>? best(Iterable<Map<String, dynamic>> of) {
      Map<String, dynamic>? top;
      for (final f in of) {
        if (top == null || score(f) > score(top)) top = f;
      }
      return top;
    }

    final kind = aac ? 'audio/mp4' : 'audio/webm';
    return best(pool.where((f) => '${f['mimeType']}'.startsWith(kind))) ?? best(pool);
  }

  /// Metrolist's score for a sound format: the container first (WebM, then MP4), then two
  /// channels over others, then the bitrate and the sample rate.
  @visibleForTesting
  static int score(Map<String, dynamic> f) {
    final mime = '${f['mimeType'] ?? ''}';
    final codec = mime.startsWith('audio/webm') ? 100 : (mime.startsWith('audio/mp4') ? 50 : 0);
    final channels = (f['audioChannels'] as num?)?.toInt();
    final channelBonus = channels == 2 ? 50000 : (channels == 1 ? 0 : 25000);
    final bitrate = (f['bitrate'] as num?)?.toInt() ?? 0;
    final rate = int.tryParse('${f['audioSampleRate'] ?? ''}') ?? 0;
    return codec * 1000000 + channelBonus + bitrate + math.min(math.max(rate, 0), 48000) ~/ 10;
  }

  /// A video with its sound (`formats`), the one with the highest bitrate.
  static Map<String, dynamic>? _progressive(Object? formats) {
    Map<String, dynamic>? top;
    for (final f in formats is List ? formats : const []) {
      if (f is! Map<String, dynamic> || f['width'] == null || f['audioSampleRate'] == null) continue;
      final url = f['url'];
      if (url is! String || !playableAddress(url)) continue;
      if (top == null || ((f['bitrate'] as num?) ?? 0) > ((top['bitrate'] as num?) ?? 0)) top = f;
    }
    return top;
  }

  /// An address the player can be given as it is: https on YouTube's own servers, its
  /// `/videoplayback`, with no `n` still to transform (that needs YouTube's player script).
  @visibleForTesting
  static bool playableAddress(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https' || (u.hasPort && u.port != 443)) return false;
    if (!(u.host.endsWith('.googlevideo.com') || u.host.endsWith('.youtube.com'))) return false;
    if (u.path != '/videoplayback') return false;
    return !RegExp(r'[?&]n=[^&]+').hasMatch(url);
  }

  /// When [url] stops being served: the earliest of its `expire`, an `/expire/<n>/` in its
  /// path, and [inSeconds] from [now].
  @visibleForTesting
  static DateTime? expiryOf(String url, Object? inSeconds, {DateTime? now}) {
    final times = <DateTime>[];
    final u = Uri.tryParse(url);
    final e = int.tryParse(u?.queryParameters['expire'] ?? '');
    if (e != null) times.add(DateTime.fromMillisecondsSinceEpoch(e * 1000));
    final p = RegExp(r'/expire/(\d+)(?:/|$)').firstMatch(u?.path ?? '');
    final pe = p == null ? null : int.tryParse(p.group(1)!);
    if (pe != null) times.add(DateTime.fromMillisecondsSinceEpoch(pe * 1000));
    final s = inSeconds is num ? inSeconds.toInt() : int.tryParse('${inSeconds ?? ''}');
    if (s != null && s > 0) times.add((now ?? DateTime.now()).add(Duration(seconds: s)));
    if (times.isEmpty) return null;
    times.sort();
    return times.first;
  }

  static final _random = math.Random();
  static const _nonceLetters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';

  /// A playback nonce (`cpn`), sixteen letters, as every YouTube player adds to an address.
  @visibleForTesting
  static String playbackNonce() => String.fromCharCodes([for (var i = 0; i < 16; i++) _nonceLetters.codeUnitAt(_random.nextInt(_nonceLetters.length))]);

  static Future<(int, String)> _send(String method, Uri url, Map<String, String> headers, String? body, Duration limit) async {
    final hook = debugHttp;
    if (hook != null) return hook(method, url, headers, body);
    final r = await (method == 'POST' ? netClient.post(url, headers: headers, body: body) : netClient.get(url, headers: headers)).timeout(limit);
    return (r.statusCode, utf8.decode(r.bodyBytes, allowMalformed: true));
  }
}
