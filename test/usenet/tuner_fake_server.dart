// A small NNTP server on 127.0.0.1 for the tuner's tests: greeting, sign-in, BODY with a fixed
// ~100 KB dot-stuffed body (or 430 when the articles are "missing"), QUIT. It keeps count of
// connections open, the most at once, sign-ins refused past its limit, and connections signed in
// and then closed without QUIT ("abandoned": what a provider holds against an account).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FakeProvider {
  FakeProvider({this.limit, this.missing = false, this.silentAt, this.greeting = '200 welcome', this.passReply = '281 ok', this.bodyDelay});

  /// Signed-in connections allowed at once; past it the password answer is 502.
  final int? limit;

  /// Every article is missing (430).
  final bool missing;

  /// Connections (1-based, in the order they arrived) that never get a greeting.
  final Set<int>? silentAt;

  /// Every connection gets no greeting while this is on.
  bool silent = false;
  final String greeting;
  final String passReply;

  /// A pause before each body (a slow provider).
  final Duration? bodyDelay;

  late final ServerSocket _server;
  int get port => _server.port;

  int connections = 0; // ever
  int open = 0;
  int peak = 0;
  int signedIn = 0; // now
  int peakSignedIn = 0;
  int refused = 0;
  int abandoned = 0;
  int quits = 0;
  int bodies = 0;
  final silentOpen = <int>{};
  final silentClosed = <int>{};

  static final Uint8List body = _makeBody();

  static Uint8List _makeBody() {
    final b = BytesBuilder();
    for (var i = 0; i < 800; i++) {
      // some lines start with a stuffed dot, as yEnc lines can
      b.add(utf8.encode(i % 17 == 0 ? '..${'y' * 125}\r\n' : '${'x' * 126}\r\n'));
    }
    return b.takeBytes();
  }

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve, onError: (Object _) {});
  }

  Future<void> close() => _server.close();

  void _serve(Socket sock) {
    final c = _Conn(sock, ++connections);
    open++;
    if (open > peak) peak = open;
    c.silent = silent || (silentAt?.contains(c.number) ?? false);
    if (c.silent) silentOpen.add(c.number);
    void done() {
      if (c.gone) return;
      c.gone = true;
      open--;
      if (c.authed && !c.quit) {
        signedIn--;
        abandoned++;
      }
      if (c.silent) silentClosed.add(c.number);
    }

    if (!c.silent) c.say(greeting);
    var buf = <int>[];
    var queue = Future<void>.value();
    sock.listen(
      (chunk) {
        if (c.silent) return;
        buf.addAll(chunk);
        while (true) {
          final nl = buf.indexOf(10);
          if (nl < 0) break;
          final cmd = utf8.decode(buf.sublist(0, nl), allowMalformed: true).trim();
          buf = buf.sublist(nl + 1);
          queue = queue.then((_) => _answer(cmd, c));
        }
      },
      onDone: () {
        done();
        sock.destroy();
      },
      onError: (Object _) {
        done();
        sock.destroy();
      },
      cancelOnError: true,
    );
  }

  Future<void> _answer(String cmd, _Conn c) async {
    final up = cmd.toUpperCase();
    if (c.quit) return;
    if (up.startsWith('AUTHINFO USER')) {
      c.say('381 password please');
    } else if (up.startsWith('AUTHINFO PASS')) {
      if (limit != null && signedIn >= limit!) {
        refused++;
        c.say('502 too many connections');
      } else {
        if (passReply.startsWith('281')) {
          c.authed = true;
          signedIn++;
          if (signedIn > peakSignedIn) peakSignedIn = signedIn;
        }
        c.say(passReply);
      }
    } else if (up == 'QUIT') {
      quits++;
      c.quit = true;
      if (c.authed) signedIn--;
      c.say('205 bye');
      try {
        await c.sock.flush();
      } catch (_) {}
      await c.sock.close().catchError((Object _) => c.sock);
    } else if (up.startsWith('BODY ')) {
      final id = cmd.substring(5).trim();
      if (bodyDelay != null) await Future<void>.delayed(bodyDelay!);
      if (missing) {
        c.say('430 no such article');
      } else {
        bodies++;
        try {
          c.sock.add(utf8.encode('222 0 $id\r\n'));
          c.sock.add(body);
          c.sock.add(utf8.encode('.\r\n'));
          await c.sock.flush();
        } catch (_) {}
      }
    } else {
      c.say('500 unknown command');
    }
  }
}

class _Conn {
  _Conn(this.sock, this.number);
  final Socket sock;
  final int number;
  bool silent = false, authed = false, quit = false, gone = false;

  void say(String line) {
    try {
      sock.add(utf8.encode('$line\r\n'));
    } catch (_) {}
  }
}

/// An NZB of [count] segments served over HTTP on 127.0.0.1 (or [status] instead).
class FakeNzbServer {
  FakeNzbServer({this.count = 120, this.status = 200});
  final int count;
  final int status;
  late final HttpServer _http;
  String? userAgent;

  String get url => 'http://127.0.0.1:${_http.port}/test.nzb';

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) async {
      userAgent = req.headers.value(HttpHeaders.userAgentHeader);
      req.response.statusCode = status;
      if (status == 200) {
        req.response.write('<?xml version="1.0" encoding="UTF-8"?>\n<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">\n<file subject="test"><segments>\n');
        for (var i = 1; i <= count; i++) {
          req.response.write('<segment bytes="100000" number="$i">part$i.test@vyse</segment>\n');
        }
        req.response.write('</segments></file></nzb>\n');
      }
      await req.response.close();
    });
  }

  Future<void> close() => _http.close(force: true);
}
