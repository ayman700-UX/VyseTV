// The subtitle reader of the LG webOS engine (lib/mpv/support/subtitle_cues.dart): the TV's own
// player shows the picture there and the app draws the text, so it has to read the files itself.
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/mpv/support/subtitle_cues.dart';

void main() {
  group('SubRip', () {
    const srt = '''
1
00:00:01,000 --> 00:00:03,500
Hello <i>there</i>.

2
00:00:04,000 --> 00:00:06,000
{\\an8}Up top
second row

3
01:02:03,250 --> 01:02:05,000
<font color="#ffff00">Late</font>
''';

    test('lines, times and plain text', () {
      final cues = SubtitleCues.parse(srt).cues;
      expect(cues, hasLength(3));
      expect(cues[0].start, 1.0);
      expect(cues[0].end, 3.5);
      expect(cues[0].text, 'Hello there.');
      expect(cues[1].text, 'Up top\nsecond row');
      expect(cues[2].start, closeTo(3723.25, 1e-9));
      expect(cues[2].text, 'Late');
    });

    test('what shows at a time', () {
      final s = SubtitleCues.parse(srt);
      expect(s.textAt(0.5), '');
      expect(s.textAt(1.0), 'Hello there.');
      expect(s.textAt(3.49), 'Hello there.');
      expect(s.textAt(3.5), ''); // a line is gone at its end
      expect(s.textAt(5), 'Up top\nsecond row');
      expect(s.textAt(4000), '');
    });

    test('when it next changes', () {
      final s = SubtitleCues.parse(srt);
      expect(s.nextChangeAfter(0), 1.0);
      expect(s.nextChangeAfter(1.0), 3.5);
      expect(s.nextChangeAfter(3.5), 4.0);
      expect(s.nextChangeAfter(6.0), closeTo(3723.25, 1e-9));
      expect(s.nextChangeAfter(4000), isNull);
    });

    test('Windows line ends, a byte order mark, and blocks with no empty row between them', () {
      final s = SubtitleCues.parse('﻿1\r\n00:00:01,000 --> 00:00:02,000\r\nOne\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nTwo\r\n');
      expect(s.cues.map((c) => c.text), ['One', 'Two']);
      expect(s.textAt(3.5), 'Two');
    });
  });

  group('WebVTT', () {
    const vtt = '''
WEBVTT

NOTE this is not a line
it runs to the empty row

STYLE
::cue { color: lime }

intro
00:01.000 --> 00:02.500 line:10% align:start
<v Anna>Short <c.loud>times</c></v>

00:00:03.000 --> 00:00:05.000
Fish &amp; chips
''';

    test('lines, short times, cue settings, notes and styles left out', () {
      final cues = SubtitleCues.parse(vtt).cues;
      expect(cues, hasLength(2));
      expect(cues[0].start, 1.0);
      expect(cues[0].end, 2.5);
      expect(cues[0].text, 'Short times');
      expect(cues[1].text, 'Fish & chips');
    });
  });

  group('Advanced SubStation', () {
    const ass = '''
[Script Info]
Title: test

[V4+ Styles]
Format: Name, Fontname, Fontsize
Style: Default,Arial,40

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}Hello{\\i0}, world
Dialogue: 0,0:00:02.00,0:00:04.00,Top,,0,0,0,,{\\an8\\pos(10,20)}Sign\\Nsecond row
Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}
Comment: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,not shown
''';

    test('words kept, styling dropped, commas in the text kept, drawings and comments left out', () {
      final cues = SubtitleCues.parse(ass).cues;
      expect(cues, hasLength(2));
      expect(cues[0].text, 'Hello, world');
      expect(cues[0].start, 1.0);
      expect(cues[1].text, 'Sign\nsecond row');
    });

    test('lines that overlap show together, the earlier one first', () {
      final s = SubtitleCues.parse(ass);
      expect(s.textAt(1.5), 'Hello, world');
      expect(s.textAt(2.5), 'Hello, world\nSign\nsecond row');
      expect(s.textAt(3.5), 'Sign\nsecond row');
      expect(s.nextChangeAfter(1.5), 2.0);
      expect(s.nextChangeAfter(2.5), 3.0);
    });

    test('a file with another column order is read by its Format row', () {
      final s = SubtitleCues.parse('[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.00,0:00:02.00,Just, this\n');
      expect(s.cues.single.text, 'Just, this');
    });
  });

  test('nothing readable is empty, and asking it is safe', () {
    for (final junk in ['', 'not a subtitle file', '<html></html>']) {
      final s = SubtitleCues.parse(junk);
      expect(s.isEmpty, isTrue);
      expect(s.textAt(1), '');
      expect(s.nextChangeAfter(0), isNull);
    }
  });

  test('a long line still shows while short ones come and go inside it', () {
    final s = SubtitleCues([
      const SubtitleCue(0, 100, 'long'),
      for (var i = 1; i < 50; i++) SubtitleCue(i * 2.0, i * 2.0 + 1, 'short $i'),
    ]);
    expect(s.textAt(60.5), 'long\nshort 30');
    expect(s.textAt(61.5), 'long');
    expect(s.textAt(100), '');
  });
}
