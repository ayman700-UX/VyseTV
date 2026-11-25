// WebCrypto for plugins: what a script's `crypto.subtle` asks (the prelude in js_plugins.dart sends
// it over the bridge, the way `http()` goes) is done here: AES-GCM, AES-CBC and AES-CTR, SHA
// digests, HMAC and PBKDF2. A browser has it, and some scrapers decrypt their links with it ("WebCrypto
// subtle missing — cannot decrypt" in the plugin log before).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

/// One `crypto.subtle` step. [m] holds `op` (encrypt, decrypt, digest, sign, pbkdf2), the
/// algorithm (`alg`, `hash`, `tagLength`, `iterations`, `length`) and its bytes in base64 (`key`,
/// `data`, `iv`, `aad`, `salt`). Returns the answer's bytes; throws, with a reason fit for the
/// plugin's log, on what it can't do (a wrong key or tag included).
Uint8List webCrypto(Map<String, dynamic> m) {
  Uint8List b(String k) => m[k] == null ? Uint8List(0) : base64Decode('${m[k]}');
  final op = '${m['op']}';
  switch (op) {
    case 'digest':
      return Uint8List.fromList(_hash('${m['hash']}').convert(b('data')).bytes);
    case 'sign':
      return Uint8List.fromList(crypto.Hmac(_hash('${m['hash']}'), b('key')).convert(b('data')).bytes);
    case 'pbkdf2':
      final bits = (m['length'] as num?)?.toInt() ?? 256;
      final hash = '${m['hash']}';
      final d = pc.PBKDF2KeyDerivator(pc.HMac(_digest(hash), hash == 'SHA-384' || hash == 'SHA-512' ? 128 : 64))
        ..init(pc.Pbkdf2Parameters(b('salt'), (m['iterations'] as num?)?.toInt() ?? 1, bits ~/ 8));
      return d.process(b('key'));
    case 'encrypt':
    case 'decrypt':
      final enc = op == 'encrypt';
      final key = pc.KeyParameter(b('key'));
      switch ('${m['alg']}') {
        case 'AES-GCM':
          final tag = (m['tagLength'] as num?)?.toInt() ?? 128;
          // (WebCrypto's ciphertext is followed by the tag, as GCM here reads and writes it)
          return (pc.GCMBlockCipher(pc.AESEngine())..init(enc, pc.AEADParameters(key, tag, b('iv'), b('aad')))).process(b('data'));
        case 'AES-CBC':
          return (pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()))
                ..init(enc, pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>, Null>(pc.ParametersWithIV(key, b('iv')), null)))
              .process(b('data'));
        case 'AES-CTR':
          return (pc.CTRStreamCipher(pc.AESEngine())..init(enc, pc.ParametersWithIV(key, b('iv')))).process(b('data'));
      }
      throw UnsupportedError('crypto.subtle: ${m['alg']} is not supported (AES-GCM, AES-CBC, AES-CTR are)');
  }
  throw UnsupportedError('crypto.subtle: $op is not supported');
}

crypto.Hash _hash(String name) => switch (name) {
  'SHA-1' => crypto.sha1,
  'SHA-256' => crypto.sha256,
  'SHA-384' => crypto.sha384,
  'SHA-512' => crypto.sha512,
  _ => throw UnsupportedError('crypto.subtle: hash $name is not supported'),
};

pc.Digest _digest(String name) => switch (name) {
  'SHA-1' => pc.SHA1Digest(),
  'SHA-256' => pc.SHA256Digest(),
  'SHA-384' => pc.SHA384Digest(),
  'SHA-512' => pc.SHA512Digest(),
  _ => throw UnsupportedError('crypto.subtle: hash $name is not supported'),
};
