import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'common.dart';

/// FebBox (febbox.js): films and shows from your own FebBox account. The title is found through
/// Showbox's app API, whose share link names a FebBox folder; the account's "ui" cookie then
/// lists the folder's files and the sizes FebBox has of each.
///
/// Pure Dart, like the other sources: the token is handed in by febbox_account.dart, which
/// keeps it in the keychain.

/// The account's "ui" cookie, once the app has read it. Null: FebBox isn't asked.
String? febboxToken;

/// FebBox can be asked: an account's token is on this device.
bool febboxReady() => (febboxToken ?? '').isNotEmpty;

const _showboxBase = 'https://mbpapi.shegu.net/api/api_client/index/';
const _showboxKey = '123d6cedf626dy54233aa1w6';
const _showboxIv = 'wEiphTn!';
const _showboxAppKey = 'moviebox';
const _showboxDefaults = <String, Object>{
  'CHILD_MODE': '0',
  'APP_VERSION': '11.5',
  'LANG': 'en',
  'PLATFORM': 'android',
  'CHANNEL': 'Website',
  'APPID': '27',
  'VERSION': '129',
  'MEDIUM': 'Website',
};
const _febboxBase = 'https://www.febbox.com';
const _shareBase = 'https://www.showbox.media';
const _appAgent = 'okhttp/3.2.0';
const _febboxHeaders = {'user-agent': sdkUA, 'x-requested-with': 'XMLHttpRequest'};

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

/// febbox.js encryptTripleDES: 3DES in CBC with PKCS7 padding, as base64.
String showboxEncrypt(String text) {
  final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(DESedeEngine()))
    ..init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV(KeyParameter(Uint8List.fromList(utf8.encode(_showboxKey))), Uint8List.fromList(utf8.encode(_showboxIv))),
        null,
      ),
    );
  return base64.encode(cipher.process(Uint8List.fromList(utf8.encode(text))));
}

/// What Showbox's API is posted for [payload] (febbox.js showboxRequest), up to the random
/// token it ends with.
String showboxForm(Map<String, Object?> payload) {
  final enc = showboxEncrypt(json.encode(payload));
  final body = json.encode({'app_key': _md5(_showboxAppKey), 'verify': _md5('${_md5(_showboxAppKey)}$_showboxKey$enc'), 'encrypt_data': enc});
  return Uri(queryParameters: {
    'data': base64.encode(utf8.encode(body)),
    'appid': '${_showboxDefaults['APPID']}',
    'platform': '${_showboxDefaults['PLATFORM']}',
    'version': '${_showboxDefaults['VERSION']}',
    'medium': '${_showboxDefaults['MEDIUM']}',
  }).query;
}

final _rng = Random.secure();

Future<dynamic> _showbox(String module, Map<String, Object?> params) async {
  final form = showboxForm({
    ..._showboxDefaults,
    'expired_date': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60 * 60 * 12,
    'module': module,
    ...params,
  });
  final token = [for (var i = 0; i < 16; i++) _rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  return fetchJson(
    _showboxBase,
    method: 'POST',
    headers: {'Platform': '${_showboxDefaults['PLATFORM']}', 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': _appAgent},
    body: utf8.encode('$form&token$token'),
    timeout: const Duration(seconds: 8),
  );
}

/// febbox.js titleSimilarity.
double febboxTitleMatch(String? a, String? b) {
  String norm(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final na = norm(a), nb = norm(b);
  if (na == nb) return 1;
  if (na.contains(nb) || nb.contains(na)) return .85;
  final wordsA = na.split(' ').toSet(), wordsB = nb.split(' ');
  return wordsB.where(wordsA.contains).length / max(wordsA.length, wordsB.length);
}

/// febbox.js parseQuality: FebBox's word for a size ('4K', '1080P', 'ORG') as VyseTV names it.
/// 'Original' is the file as it was uploaded.
String febboxQuality(String? label) {
  final l = (label ?? '').toLowerCase();
  if (l.contains('2160') || l.contains('4k') || l.contains('uhd')) return '4K';
  for (final n in ['1080', '720', '480', '360']) {
    if (l.contains(n)) return '${n}p';
  }
  if (l == 'org' || l.contains('orig')) return 'Original';
  return 'Auto';
}

/// febbox.js parseFebboxQualityHtml: each size FebBox has of a file, as its page lists them.
List<({String url, String quality})> febboxQualities(String html) => [
  for (final m in RegExp(r'<div[^>]*class="file_quality"[^>]*data-url="([^"]+)"[^>]*data-quality="([^"]+)"', caseSensitive: false).allMatches(html))
    (url: m[1]!.replaceAll('&amp;', '&'), quality: m[2]!),
];

/// Who a token belongs to, and how much of the account's traffic is left.
class FebBoxUser {
  const FebBoxUser({required this.name, this.vip = false, this.limitMb = 0, this.usedMb = 0});
  final String name;
  final bool vip;
  final num limitMb;
  final num usedMb;

  num get leftMb => max(0, limitMb - usedMb);

  static String _size(num mb) => mb >= 1024 ? '${(mb / 1024).toStringAsFixed(mb >= 10240 ? 0 : 1)} GB' : '${mb.round()} MB';

  /// 'ayman · VIP · 82 GB of 100 GB left'.
  String get describe => [name, if (vip) 'VIP', if (limitMb > 0) '${_size(leftMb)} of ${_size(limitMb)} left'].join(' · ');
}

/// A token as people paste it: the cookie's value, without "ui=", quotes or the ";" after it.
String febboxTidy(String raw) {
  var t = raw.trim();
  final named = RegExp(r'(?:^|[;\s])ui=([^;\s]+)').firstMatch(t);
  if (named != null) t = named[1]!;
  return t.replaceAll(RegExp('^["\']+|["\';]+\$'), '').trim();
}

/// febbox.js validateFebboxToken: the account [token] belongs to, or null when FebBox doesn't
/// take it (wrong, cut short, or signed out since). Throws when FebBox can't be reached, so a
/// good token is never called a bad one on a bad connection.
Future<FebBoxUser?> febboxUser(String token) async {
  final t = febboxTidy(token);
  if (t.isEmpty) return null;
  final r = await fetchRaw(
    '$_febboxBase/console/user_cards',
    headers: {..._febboxHeaders, 'cookie': 'ui=$t', 'accept': 'application/json, text/javascript, */*; q=0.01'},
    timeout: const Duration(seconds: 8),
  );
  if (r.statusCode >= 500) throw HttpException('FebBox answered ${r.statusCode}');
  if (r.statusCode < 200 || r.statusCode >= 300) return null;
  final dynamic data;
  try {
    data = json.decode(utf8.decode(r.bodyBytes, allowMalformed: true));
  } on FormatException {
    return null; // (its sign-in page, not an answer)
  }
  if (dig(data, ['code']) != 1 || !truthy(dig(data, ['data']))) return null;
  final user = dig(data, ['data', 'user']), flow = dig(data, ['data', 'flow']);
  num n(dynamic v) => v is num ? v : (num.tryParse('${v ?? ''}') ?? 0);
  return FebBoxUser(
    name: '${firstTruthy([dig(user, ['username']), dig(user, ['email'])]) ?? 'Your account'}',
    vip: truthy(dig(user, ['is_vip'])),
    limitMb: n(dig(flow, ['traffic_limit_mb'])),
    usedMb: n(dig(flow, ['traffic_usage_mb'])),
  );
}

bool _isDir(dynamic f) => f is Map && (f['is_dir'] == 1 || f['is_dir'] == '1' || f['is_dir'] == true);
String _name(dynamic f) => '${dig(f, ['file_name']) ?? ''}'.toLowerCase();

/// The folder of season [s] among [files]: named for it exactly, then with it in its name (as a
/// whole number: "Season 1" is not "Season 10"), then, as febbox.js does, the first folder.
dynamic febboxSeason(List<dynamic> files, int s) {
  final dirs = files.where(_isDir).toList();
  final pad = '$s'.padLeft(2, '0');
  final named = RegExp('season\\s*0*$s(?!\\d)');
  return dirs.where((f) => _name(f) == 'season $s' || _name(f) == 's$pad').firstOrNull ?? dirs.where((f) => named.hasMatch(_name(f))).firstOrNull ?? dirs.firstOrNull;
}

/// Episode [e] of season [s] among a season folder's [files]: by its name (s01e05, 1x05,
/// "episode 5", ep05, e05; the number whole, so e01 is not e010), then, as febbox.js does, by
/// its place in the folder.
dynamic febboxEpisode(List<dynamic> files, int s, int e) {
  final list = files.where((f) => !_isDir(f)).toList();
  final ep = '$e'.padLeft(2, '0'), sp = '$s'.padLeft(2, '0');
  final named = RegExp('s${sp}e$ep(?!\\d)|s${s}e$ep(?!\\d)|(?<!\\d)${s}x$ep(?!\\d)|episode\\s*0*$e(?!\\d)|ep$ep(?!\\d)|e$ep(?!\\d)');
  final hit = list.where((f) => named.hasMatch(_name(f))).firstOrNull;
  if (hit != null) return hit;
  list.sort((a, b) => _name(a).compareTo(_name(b)));
  return e >= 1 && e <= list.length ? list[e - 1] : null;
}

/// The size a link starts on, as febbox.js sorts them: 1080p, then 4K, 720p, the original file,
/// and the small ones. The others are in the player's Quality menu.
const _startOrder = ['1080p', '4K', '720p', 'Original', '480p', '360p', 'Auto'];

Future<List<FoundStream>> febbox(FilmQuery q) async {
  final token = febboxTidy(febboxToken ?? '');
  if (token.isEmpty) return const [];
  try {
    final meta = await getTmdbMetadata(q.id, q.isTv);
    final title = meta.title.isNotEmpty ? meta.title : meta.originalTitle;
    if (title.isEmpty) return const [];

    final search = await _showbox('Search5', {'keyword': title, 'type': q.isTv ? 'tv' : 'movie', 'page': 1, 'pagelimit': 10});
    final results = dig(search, ['data']);
    if (results is! List || results.isEmpty) return const [];
    final wanted = q.isTv ? 2 : 1;
    dynamic best;
    var bestScore = 0.0;
    for (final r in results) {
      var score = febboxTitleMatch(title, str(dig(r, ['title'])));
      score += dig(r, ['box_type']) == wanted ? .2 : -.15;
      if (meta.year != null && truthy(dig(r, ['year'])) && '${dig(r, ['year'])}' == '${meta.year}') score += .15;
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    if (best == null || bestScore < .5) return const [];

    final share = await fetchJson(
      '$_shareBase/index/share_link?id=${dig(best, ['id'])}&type=${firstTruthy([dig(best, ['box_type'])]) ?? wanted}',
      headers: {'User-Agent': _appAgent},
      timeout: const Duration(seconds: 6),
    );
    final shareKey = '${dig(share, ['data', 'link']) ?? ''}'.split('/').last;
    if (shareKey.isEmpty) return const [];

    final headers = {..._febboxHeaders, 'cookie': 'ui=$token', 'referer': '$_febboxBase/share/$shareKey'};
    Future<List<dynamic>> filesIn(Object parent) async {
      final r = await fetchJson('$_febboxBase/file/file_share_list?share_key=$shareKey&pwd=&parent_id=$parent&is_html=0', headers: headers, timeout: const Duration(seconds: 8));
      return (dig(r, ['data', 'file_list']) as List?) ?? const [];
    }

    final top = await filesIn(0);
    if (top.isEmpty) return const [];
    var targets = <dynamic>[];
    if (q.isTv) {
      final folder = febboxSeason(top, q.season ?? 1);
      if (folder == null) return const [];
      final episode = febboxEpisode(await filesIn('${dig(folder, ['fid'])}'), q.season ?? 1, q.episode ?? 1);
      if (episode == null) return const [];
      targets = [episode];
    } else {
      targets = top.where((f) => !_isDir(f)).take(3).toList();
    }

    final hls = <FoundStream>[], files = <FoundStream>[];
    for (final file in targets) {
      try {
        final r = await fetchJson('$_febboxBase/console/video_quality_list?fid=${dig(file, ['fid'])}', headers: headers, timeout: const Duration(seconds: 8));
        final sizes = <({String label, String url})>[];
        for (final s in febboxQualities('${dig(r, ['html']) ?? ''}')) {
          if (!s.url.startsWith('http')) continue;
          final label = febboxQuality(s.quality);
          if (s.url.contains('.m3u8')) {
            hls.add(FoundStream(url: s.url, server: 'FebBox', quality: label, type: 'hls'));
          } else if (!sizes.any((x) => x.label == label)) {
            sizes.add((label: label, url: s.url));
          }
        }
        if (sizes.isEmpty) continue;
        final start = ([...sizes]..sort((a, b) => _startOrder.indexOf(a.label).compareTo(_startOrder.indexOf(b.label)))).first;
        files.add(FoundStream(
          url: start.url,
          server: 'FebBox',
          quality: start.label,
          type: start.url.toLowerCase().contains('.mkv') ? 'mkv' : 'mp4',
          qualities: sizes.length > 1 ? sizes : const [],
        ));
      } catch (_) {}
    }
    return [...hls, ...files];
  } catch (_) {
    return const [];
  }
}
