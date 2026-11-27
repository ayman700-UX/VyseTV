// VyseTV addition (not in upstream).
//
// For the LG webOS engine (platform/player_webos.dart). There the TV's own player fetches the
// video, and it cannot be told which HTTP headers to send: its load call only knows a referer,
// a user agent and cookies, and whether those are honoured for an app like this one is not
// written down anywhere. A link that needs its host's headers (an Authorization, an Origin, a
// Referer) is opened through here instead: the TV asks 127.0.0.1, and this asks the real
// address with the headers, passing bytes and ranges through untouched.
//
// Mostly plain files come here: the film player's playlists already go through the app's own
// relay (data/playback/stream_proxy.dart), which rewrites the addresses inside them. A playlist
// that does come here (a Live TV channel's) still finds its parts: what it names beside
// itself, or from the top of its host, is asked of the same host with the same headers (see
// _addressOf). Parts it names by a whole address are fetched by the TV itself, without them.

import 'dart:async';
import 'dart:io';

import 'relay_log.dart';

class HeaderRelay {
  HeaderRelay._();
  static final instance = HeaderRelay._();

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final _targets = <String, _Target>{};
  var _next = 0;
  _Target? _latest; // the link opened last: who a request with no token of its own is for

  final _client = HttpClient()
    ..autoUncompress = false
    ..idleTimeout = const Duration(seconds: 30)
    ..connectionTimeout = const Duration(seconds: 15);

  Future<HttpServer> _start() => _starting ??= () async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle);
    return _server = s;
  }();

  /// An address on this device that answers as [url] does when asked with [headers].
  ///
  /// It is the real address's own path under a number of its own
  /// (`http://127.0.0.1:<port>/r/7/live/ch1/index.m3u8`). So a player that tells a file's kind
  /// from its name still can, and what a playlist names beside itself (`seg/001.ts`,
  /// `../key.bin`) lands under the same number, from where it is found again ([_addressOf]).
  Future<String> wrap(String url, Map<String, String> headers) async {
    final s = await _start();
    final uri = Uri.parse(url);
    RelayLog.instance.start();
    final token = '${++_next}';
    final target = _latest = _targets[token] = _Target(uri, Map.of(headers));
    // (what was opened long ago is dropped: a player opens a handful of links, not hundreds)
    while (_targets.length > 32) {
      _targets.remove(_targets.keys.first);
    }
    return 'http://127.0.0.1:${s.port}/r/$token${target.path}';
  }

  /// The real address a request to this relay stands for, and whose headers go with it.
  ///
  /// `/r/<number>/<the link's path>` is the link itself. Anything else under that number is
  /// something a playlist pointed to beside itself: the same steps are taken from where the
  /// link really is (after its redirects). A path with no number at all is one a playlist named
  /// from the top of its host (`/hls/001.ts`): the link opened last is the one playing, so it
  /// is asked of that link's host.
  ({Uri uri, _Target target, bool itself})? _addressOf(Uri asked) {
    final seg = asked.pathSegments;
    if (seg.isNotEmpty && seg[0] == 'r') {
      final target = seg.length >= 2 ? _targets[seg[1]] : null;
      if (target == null) return null;
      final under = asked.path.substring('/r/${seg[1]}'.length);
      final path = under.isEmpty ? '/' : under;
      if (path == target.path) return (uri: target.uri, target: target, itself: true);
      final at = target.base.resolve(_steps(from: target.path, to: path));
      return (uri: asked.hasQuery ? at.replace(query: asked.query) : at, target: target, itself: false);
    }
    final latest = _latest;
    if (latest == null) return null;
    final base = latest.base;
    return (
      uri: Uri(scheme: base.scheme, userInfo: base.userInfo, host: base.host, port: base.hasPort ? base.port : null, path: asked.path, query: asked.hasQuery ? asked.query : null),
      target: latest,
      itself: false,
    );
  }

  /// The way from one path's folder to another path, as a playlist would write it:
  /// from `/live/ch1/index.m3u8` to `/live/key.bin` it is `../key.bin`.
  static String _steps({required String from, required String to}) {
    final folder = from.split('/')..removeLast();
    final there = to.split('/');
    var same = 0;
    while (same < folder.length && same < there.length - 1 && folder[same] == there[same]) {
      same++;
    }
    final up = folder.length - same;
    // ("./" first: a name with a colon in it would otherwise read as an address of its own)
    return '${up == 0 ? './' : '../' * up}${there.sublist(same).join('/')}';
  }

  /// Headers the TV's request may carry on to the real address.
  static const _forward = {'range', 'if-range', 'accept', 'accept-language'};

  /// Headers of the real answer the TV gets back. (Never a length-changing one this relay
  /// does not honour: bodies are passed as they came.)
  static const _back = {
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
    'content-encoding',
    'last-modified',
    'etag',
    'cache-control',
    'content-disposition',
  };

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final log = RelayLog.instance;
    log.files++;
    String host = '';
    try {
      final found = _addressOf(req.uri);
      host = found?.uri.host ?? '';
      if (found == null || (req.method != 'GET' && req.method != 'HEAD')) {
        res.statusCode = found == null ? HttpStatus.notFound : HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }
      final target = found.target;
      final out = await _client.openUrl(req.method, found.uri);
      out.followRedirects = true;
      out.maxRedirects = 8;
      req.headers.forEach((name, values) {
        if (_forward.contains(name.toLowerCase())) out.headers.set(name, values.join(', '));
      });
      target.headers.forEach((name, value) => out.headers.set(name, value));
      final up = await out.close();
      // (where the link really is: what a playlist names beside itself is beside that)
      if (found.itself && up.redirects.isNotEmpty) {
        var at = target.uri;
        for (final r in up.redirects) {
          at = at.resolveUri(r.location);
        }
        target.base = at;
      }
      if (up.statusCode >= 400) log.trouble('file', 'HTTP ${up.statusCode}', host: host);
      res.statusCode = up.statusCode;
      up.headers.forEach((name, values) {
        if (_back.contains(name.toLowerCase())) res.headers.set(name, values.join(', '));
      });
      // (the body is passed as it came, whatever its encoding: nothing here may re-chunk it)
      res.contentLength = up.contentLength;
      if (req.method == 'HEAD') {
        await up.drain<void>();
        await res.close();
        return;
      }
      await res.addStream(up);
      await res.close();
    } catch (e) {
      // the TV stopped reading (a seek asks again from elsewhere), or the address failed
      if (e is! HttpException || !e.message.contains('Connection closed')) log.trouble('file', e.runtimeType.toString(), host: host);
      try {
        res.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Tests: stops the server and forgets what was opened.
  Future<void> debugReset() async {
    await _server?.close(force: true);
    _server = null;
    _starting = null;
    _targets.clear();
    _latest = null;
  }
}

class _Target {
  _Target(this.uri, this.headers) : base = uri;

  /// The link as it was handed over.
  final Uri uri;
  final Map<String, String> headers;

  /// Its path, as it stands under the link's number on this relay.
  String get path => uri.path.isEmpty ? '/' : uri.path;

  /// Where it really is, once a redirect has said so.
  Uri base;
}
