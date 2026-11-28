// Sorting profiles' patterns: RE2's syntax, matched in time proportional to the text.

import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/usenet/usenet_pattern.dart';

bool m(String pattern, String text) => UsenetPattern.tryCompile(pattern)!.hasMatch(text);

void main() {
  test('finds anywhere, ignoring case', () {
    expect(m('remux', 'Film.2160p.BluRay.REMUX-GRP'), isTrue);
    expect(m('S[0-9]+E[0-9]+', 'Show.S01E02.1080p'), isTrue);
    expect(m('S[0-9]+E[0-9]+', 'Film.2020.1080p'), isFalse);
    expect(m(r'^film\.', 'Film.2020'), isTrue);
    expect(m(r'^2020', 'Film.2020'), isFalse);
    expect(m(r'grp$', 'Film-GRP'), isTrue);
    expect(m(r'grp$', 'Film-GRP.mkv'), isFalse);
    expect(m(r'(?:^|[ ._-])(?:repack[0-9]*|proper[0-9]*)(?:$|[ ._-])', 'Film.2020.REPACK2.1080p'), isTrue);
    expect(m(r'(?:^|[ ._-])(?:upscaled?|ai[ ._-]?enhanced|ai[ ._-]?upscale)(?:$|[ ._-])', 'Film.2020.AI.Upscale.2160p'), isTrue);
    expect(m(r'(?:^|[ ._-])(?:upscaled?|ai[ ._-]?enhanced|ai[ ._-]?upscale)(?:$|[ ._-])', 'Film.2020.Upscaledx.2160p'), isFalse);
  });

  test('classes, counts, alternation, escapes', () {
    expect(m(r'\d{5}p', 'Film.1080p'), isFalse);
    expect(m(r'\d{3,4}p', 'Film.1080p'), isTrue);
    expect(m(r'x26[45]', 'Film.x265'), isTrue);
    expect(m(r'[^a-z]hdr', 'Film.HDR'), isTrue);
    expect(m(r'\bdv\b', 'Film.DV.HDR'), isTrue);
    expect(m(r'\bdv\b', 'Film.DVD'), isFalse);
    expect(m(r'web(-dl|rip)', 'Film.WEBRip'), isTrue);
    expect(m(r'a{2}b', 'aab'), isTrue);
    expect(m(r'a{2}b', 'ab'), isFalse);
    expect(m(r'\.mkv', 'film.mkv'), isTrue);
    expect(m(r'\.mkv', 'filmxmkv'), isFalse);
    expect(m(r'[[:digit:]]+bit', '10bit'), isTrue);
    expect(m(r'(?-i)GRP', 'grp'), isFalse);
    expect(m(r'(?P<g>abc)', 'xabcx'), isTrue);
    expect(m(r'\QA.B\E', 'AxB'), isFalse);
    expect(m(r'\QA.B\E', 'a.b'), isTrue);
    expect(m(r'\pL+\d', 'ä1'), isTrue);
  });

  test('refuses lookaround, backreferences and broken patterns', () {
    for (final p in [r'(?<=x)y', r'(?<!x)y', r'x(?=y)', r'x(?!y)', r'(x)\1', '[', '(', ')', '*a', 'a**', r'\', r'\q']) {
      expect(UsenetPattern.tryCompile(p), isNull, reason: p);
      expect(UsenetPattern.problemOf(p), isNotNull, reason: p);
    }
    expect(UsenetPattern.problemOf(r'(a+)+b'), isNull);
  });

  test('never backtracks', () {
    final p = UsenetPattern.tryCompile(r'(a+)+b')!;
    final text = 'a' * 2048;
    final watch = Stopwatch()..start();
    expect(p.hasMatch(text), isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    final nested = UsenetPattern.tryCompile(r'(.*a){12}x')!;
    expect(nested.hasMatch(text), isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
  });
}
