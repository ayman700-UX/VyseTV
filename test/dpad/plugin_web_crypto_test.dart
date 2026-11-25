// WebCrypto for plugins (web_crypto.dart): what a script's crypto.subtle asks, done in Dart and
// checked against published test vectors (FIPS 180, RFC 4231, RFC 7914, the GCM spec, NIST SP
// 800-38A). No JavaScript engine needed; t4_journeys_plugins_engine_test.dart runs the same through
// a script's crypto.subtle.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/sources/plugins/web_crypto.dart';

String _fromHex(String hex) => base64Encode([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
String _text(String s) => base64Encode(utf8.encode(s));

void main() {
  test('digests: SHA-1 and SHA-256 of "abc"', () {
    expect(_hex(webCrypto({'op': 'digest', 'hash': 'SHA-256', 'data': _text('abc')})), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(_hex(webCrypto({'op': 'digest', 'hash': 'SHA-1', 'data': _text('abc')})), 'a9993e364706816aba3e25717850c26c9cd0d89d');
  });

  test('HMAC-SHA256 (RFC 4231, case 2)', () {
    expect(
      _hex(webCrypto({'op': 'sign', 'hash': 'SHA-256', 'key': _text('Jefe'), 'data': _text('what do ya want for nothing?')})),
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
    );
  });

  test('PBKDF2-SHA256 (RFC 7914: "passwd", "salt", one round)', () {
    expect(
      _hex(webCrypto({'op': 'pbkdf2', 'hash': 'SHA-256', 'key': _text('passwd'), 'salt': _text('salt'), 'iterations': 1, 'length': 256})),
      '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc',
    );
  });

  test('AES-GCM (the spec\'s case 2): the ciphertext followed by its tag, and back; a wrong tag is refused', () {
    final key = _fromHex('00000000000000000000000000000000'), iv = _fromHex('000000000000000000000000');
    final sealed = webCrypto({'op': 'encrypt', 'alg': 'AES-GCM', 'key': key, 'iv': iv, 'data': _fromHex('00000000000000000000000000000000')});
    expect(_hex(sealed), '0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf');
    expect(_hex(webCrypto({'op': 'decrypt', 'alg': 'AES-GCM', 'key': key, 'iv': iv, 'data': base64Encode(sealed)})), '00000000000000000000000000000000');
    final broken = Uint8List.fromList(sealed)..[31] ^= 1;
    expect(() => webCrypto({'op': 'decrypt', 'alg': 'AES-GCM', 'key': key, 'iv': iv, 'data': base64Encode(broken)}), throwsA(anything));
  });

  test('AES-CBC with PKCS#7 padding (SP 800-38A F.2.1), and AES-CTR (F.5.1)', () {
    final key = _fromHex('2b7e151628aed2a6abf7158809cf4f3c');
    final block = _fromHex('6bc1bee22e409f96e93d7e117393172a');
    final iv = _fromHex('000102030405060708090a0b0c0d0e0f');
    final cbc = webCrypto({'op': 'encrypt', 'alg': 'AES-CBC', 'key': key, 'iv': iv, 'data': block});
    expect(_hex(cbc).substring(0, 32), '7649abac8119b246cee98e9b12e9197d');
    expect(cbc.length, 32, reason: 'a whole block of padding after it');
    expect(base64Encode(webCrypto({'op': 'decrypt', 'alg': 'AES-CBC', 'key': key, 'iv': iv, 'data': base64Encode(cbc)})), block);
    expect(
      _hex(webCrypto({'op': 'encrypt', 'alg': 'AES-CTR', 'key': key, 'iv': _fromHex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'), 'data': block})),
      '874d6191b620e3261bef6864990db6ce',
    );
  });

  test('what it cannot do, it says', () {
    expect(() => webCrypto({'op': 'encrypt', 'alg': 'RSA-OAEP', 'key': '', 'data': ''}), throwsA(isA<UnsupportedError>()));
    expect(() => webCrypto({'op': 'digest', 'hash': 'MD5', 'data': ''}), throwsA(isA<UnsupportedError>()));
    expect(() => webCrypto({'op': 'wrapKey'}), throwsA(isA<UnsupportedError>()));
  });
}
