// A Usenet provider's NNTP door, from this device: which of its addresses may be dialled, a
// connection signed in the way the engine signs in, and Settings' "Test provider" on top.
//
// The tuner (nntp_tuner.dart) opens its connections through the same [NntpSession.open], so
// what a test or a tuning run reaches is what playback would reach. Only categories ever leave
// this file: raw errors can echo a password back.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What a provider test or a tuner connection came to.
enum NntpResult {
  success,

  /// No address answered, the connection dropped, or nothing came back in time.
  unreachable,

  /// The secure connection failed (a plain port tried with TLS, a certificate for another name).
  tls,

  /// The provider turned the username or password down.
  auth,

  /// The provider refused the connection itself: its connection limit, a spent block, an
  /// inactive account (greeting not 200/201, or 502 at sign-in).
  refused,

  /// Only local addresses, and "Allow self-hosted servers" is off.
  privateNetwork,
}

/// What a test says, in Settings' words.
String nntpResultText(NntpResult r, {bool anonymous = false}) => switch (r) {
  NntpResult.success => anonymous ? 'Connected. This provider needs no sign-in.' : 'Connected and signed in.',
  NntpResult.unreachable => "Couldn't connect. Check the host, the port and the TLS setting.",
  NntpResult.tls => 'The secure connection failed. Check the TLS setting and the port (usually 563 with TLS, 119 without).',
  NntpResult.auth => 'Sign-in failed. Check the username and the password.',
  NntpResult.refused => 'The provider refused the connection. It may be at its connection limit, or the account may not be active.',
  NntpResult.privateNetwork => 'This is an address on your local network. Turn on Allow self-hosted servers to use it.',
};

/// Which addresses may be dialled ("Allow self-hosted servers", the engine's own rule).
enum AddressKind { public, private, never }

/// [a]'s kind: unspecified, multicast and link-local are never dialled; loopback, private
/// ranges, CGNAT and IPv6 unique-local/site-local only with self-hosted servers allowed;
/// everything else is public. An IPv4-mapped IPv6 address counts as its IPv4 address.
AddressKind addressKind(InternetAddress a) {
  var raw = a.rawAddress;
  if (raw.length == 16) {
    final mapped = raw.sublist(0, 10).every((b) => b == 0) && raw[10] == 0xFF && raw[11] == 0xFF;
    if (mapped) raw = Uint8List.fromList(raw.sublist(12));
  }
  if (raw.length == 4) {
    final (b0, b1) = (raw[0], raw[1]);
    if (raw.every((b) => b == 0)) return AddressKind.never; // 0.0.0.0
    if (b0 >= 224 && b0 <= 239) return AddressKind.never; // multicast 224/4
    if (b0 == 169 && b1 == 254) return AddressKind.never; // link-local
    if (b0 == 127) return AddressKind.private; // loopback
    if (b0 == 10) return AddressKind.private;
    if (b0 == 172 && b1 >= 16 && b1 <= 31) return AddressKind.private;
    if (b0 == 192 && b1 == 168) return AddressKind.private;
    if (b0 == 100 && b1 >= 64 && b1 <= 127) return AddressKind.private; // CGNAT 100.64/10
    return AddressKind.public;
  }
  if (raw.every((b) => b == 0)) return AddressKind.never; // ::
  if (raw[0] == 0xFF) return AddressKind.never; // multicast ff00::/8
  if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0x80) return AddressKind.never; // link-local fe80::/10
  if (raw.sublist(0, 15).every((b) => b == 0) && raw[15] == 1) return AddressKind.private; // ::1
  if (raw[0] == 0xFE && (raw[1] & 0xC0) == 0xC0) return AddressKind.private; // site-local fec0::/10
  if ((raw[0] & 0xFE) == 0xFC) return AddressKind.private; // unique local fc00::/7
  return AddressKind.public;
}

/// The addresses of [host] that may be dialled: never-dialled ones dropped, private ones only
/// when [allowPrivate]. Throws [NntpFailure] (unreachable: no such name; privateNetwork: only
/// local addresses).
Future<List<InternetAddress>> dialableAddresses(String host, {required bool allowPrivate}) async {
  final h = host.trim().replaceAll(RegExp(r'^\[|\]$'), '');
  List<InternetAddress> all;
  try {
    final literal = InternetAddress.tryParse(h);
    all = literal != null ? [literal] : await InternetAddress.lookup(h);
  } catch (_) {
    throw const NntpFailure(NntpResult.unreachable);
  }
  final ok = [
    for (final a in all)
      if (addressKind(a) == AddressKind.public || (allowPrivate && addressKind(a) == AddressKind.private)) a,
  ];
  if (ok.isEmpty) throw NntpFailure(all.isEmpty ? NntpResult.unreachable : NntpResult.privateNetwork);
  return ok;
}

class NntpFailure implements Exception {
  const NntpFailure(this.result);
  final NntpResult result;
  @override
  String toString() => 'NNTP: ${result.name}';
}

/// Where to sign in: what Test provider and the tuner need of a provider.
class NntpTarget {
  const NntpTarget({required this.host, required this.port, required this.tls, this.username = '', this.password = ''});
  final String host;
  final int port;
  final bool tls;
  final String username;
  final String password;
  bool get anonymous => username.isEmpty && password.isEmpty;
}

/// One signed-in NNTP connection, reading replies line by line and bodies to their end.
class NntpSession {
  NntpSession._(this._socket) {
    _sub = _socket.listen(
      (chunk) {
        _buf.add(chunk);
        _wake();
      },
      onError: (Object _) {
        _closed = true;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  bool _closed = false;
  Completer<void>? _waiting;

  /// Read timeout (10 s for a test and a sign-in; the tuner lengthens it while downloading).
  Duration readTimeout = const Duration(seconds: 10);

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _more() async {
    if (_buf.isNotEmpty) {
      final add = _buf.takeBytes();
      _pending = _pending.isEmpty ? add : (BytesBuilder(copy: false)..add(_pending)..add(add)).takeBytes();
      return;
    }
    if (_closed) throw const NntpFailure(NntpResult.unreachable);
    final w = _waiting = Completer<void>();
    await w.future.timeout(readTimeout, onTimeout: () => throw const NntpFailure(NntpResult.unreachable));
    if (_buf.isNotEmpty) {
      final add = _buf.takeBytes();
      _pending = _pending.isEmpty ? add : (BytesBuilder(copy: false)..add(_pending)..add(add)).takeBytes();
    } else if (_closed) {
      throw const NntpFailure(NntpResult.unreachable);
    }
  }

  /// The next reply line, without its line ending (bytes read as Latin-1; at most 1024 kept).
  Future<String> line() async {
    while (true) {
      final nl = _pending.indexOf(10);
      if (nl >= 0) {
        var end = nl;
        if (end > 0 && _pending[end - 1] == 13) end--;
        final text = latin1.decode(_pending.sublist(0, end > 1024 ? 1024 : end));
        _pending = _pending.sublist(nl + 1);
        return text;
      }
      await _more();
    }
  }

  /// A reply's code (its first three characters); a line that doesn't start with one counts as
  /// the connection closing.
  Future<int> code() async {
    final l = await line();
    final c = l.length >= 3 ? int.tryParse(l.substring(0, 3)) : null;
    if (c == null) throw const NntpFailure(NntpResult.unreachable);
    return c;
  }

  void send(String command) => _socket.add(utf8.encode('$command\r\n'));

  /// Reads a multi-line body to its "." line, counting its bytes (nothing is kept).
  Future<int> drainBody() async {
    var n = 0;
    while (true) {
      // ".\r\n" on a line of its own ends it (a dot-stuffed line starts "..")
      final end = _bodyEnd();
      if (end >= 0) {
        n += end;
        _pending = _pending.sublist(end + 3);
        return n;
      }
      // keep the last 4 bytes back, so an end split across reads is still seen
      if (_pending.length > 4) {
        n += _pending.length - 4;
        _pending = _pending.sublist(_pending.length - 4);
      }
      await _more();
    }
  }

  int _bodyEnd() {
    final p = _pending;
    if (p.length >= 3 && p[0] == 0x2E && p[1] == 13 && p[2] == 10) return 0;
    for (var i = 0; i + 4 < p.length; i++) {
      if (p[i] == 10 && p[i + 1] == 0x2E && p[i + 2] == 13 && p[i + 3] == 10) return i + 1;
    }
    return -1;
  }

  /// Says goodbye without waiting for the answer, and closes.
  void quit() {
    try {
      send('QUIT');
    } catch (_) {}
    close();
  }

  void close() {
    _closed = true;
    unawaited(_sub.cancel().catchError((Object _) {}));
    _socket.destroy();
  }

  /// Opens one connection to [t] and signs in, as the engine does: the addresses in order
  /// within one 10 s budget (each attempt at least 2 s, or its fair share of what is left), TLS
  /// checked against the host's name, a 200/201 greeting, then AUTHINFO USER (and PASS on 381).
  static Future<NntpSession> open(NntpTarget t, List<InternetAddress> addresses, {Duration budget = const Duration(seconds: 10)}) async {
    final clock = Stopwatch()..start();
    Socket? raw;
    for (var i = 0; i < addresses.length && raw == null; i++) {
      final left = budget - clock.elapsed;
      if (left <= Duration.zero) break;
      final share = Duration(microseconds: left.inMicroseconds ~/ (addresses.length - i));
      final each = share > const Duration(seconds: 2) ? share : (left < const Duration(seconds: 2) ? left : const Duration(seconds: 2));
      try {
        raw = await Socket.connect(addresses[i], t.port, timeout: each);
      } catch (_) {}
    }
    if (raw == null) throw const NntpFailure(NntpResult.unreachable);
    Socket s = raw;
    if (t.tls) {
      try {
        s = await SecureSocket.secure(raw, host: t.host.replaceAll(RegExp(r'^\[|\]$'), '')).timeout(const Duration(seconds: 10));
      } on TimeoutException {
        raw.destroy();
        throw const NntpFailure(NntpResult.unreachable);
      } on HandshakeException {
        raw.destroy();
        throw const NntpFailure(NntpResult.tls);
      } on TlsException {
        raw.destroy();
        throw const NntpFailure(NntpResult.tls);
      } catch (_) {
        raw.destroy();
        throw const NntpFailure(NntpResult.unreachable);
      }
    }
    final session = NntpSession._(s);
    try {
      final greeting = await session.code();
      if (greeting != 200 && greeting != 201) throw const NntpFailure(NntpResult.refused);
      if (!t.anonymous) {
        session.send('AUTHINFO USER ${t.username}');
        var c = await session.code();
        if (c == 381) {
          session.send('AUTHINFO PASS ${t.password}');
          c = await session.code();
        }
        if (c == 502) throw const NntpFailure(NntpResult.refused);
        if (c != 281) throw const NntpFailure(NntpResult.auth);
      }
      return session;
    } catch (e) {
      session.close();
      if (e is NntpFailure) rethrow;
      if (e is TlsException || e is HandshakeException) throw const NntpFailure(NntpResult.tls);
      throw const NntpFailure(NntpResult.unreachable);
    }
  }
}

/// Settings' "Test provider": one connection, signed in, then QUIT. Answers a category only.
Future<NntpResult> testProvider(NntpTarget t, {required bool allowPrivate}) async {
  try {
    final addresses = await dialableAddresses(t.host, allowPrivate: allowPrivate);
    final s = await NntpSession.open(t, addresses);
    s.quit();
    return NntpResult.success;
  } on NntpFailure catch (f) {
    return f.result;
  } catch (_) {
    return NntpResult.unreachable;
  }
}
