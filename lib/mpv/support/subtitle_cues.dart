// VyseTV addition (not in upstream).
//
// Subtitle files read into lines with their times, for the one engine that cannot draw
// subtitles itself: the LG webOS one, where the TV's own player shows the picture and the app
// draws the text over it (platform/player_webos.dart). mpv and Media3 read these files
// themselves and never come here.
//
// SubRip (.srt), WebVTT (.vtt) and Advanced SubStation (.ass, .ssa) are understood. A styled
// ASS line keeps its words and loses its styling: positions, colours, karaoke and drawings are
// libass's business, and there is no libass on that engine.

/// One line of a subtitle file: what it says, and from when to when (seconds of the film).
class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);

  final double start;
  final double end;

  /// Plain text; a line break is `\n`.
  final String text;

  @override
  String toString() => '[${start.toStringAsFixed(3)} → ${end.toStringAsFixed(3)}] $text';
}

/// The lines of one subtitle file, in order, asked "what shows at this second?".
class SubtitleCues {
  SubtitleCues(List<SubtitleCue> cues) : cues = List.unmodifiable(cues..sort((a, b) => a.start.compareTo(b.start))) {
    // the longest line bounds how far back from a time one has to look for lines still showing
    var longest = 0.0;
    for (final c in this.cues) {
      if (c.end - c.start > longest) longest = c.end - c.start;
    }
    _longest = longest;
  }

  static final empty = SubtitleCues(<SubtitleCue>[]);

  final List<SubtitleCue> cues;
  late final double _longest;

  bool get isEmpty => cues.isEmpty;

  /// Reads a subtitle file's text. The format is told from the text itself, never from a name.
  /// Nothing readable gives [empty].
  static SubtitleCues parse(String content) {
    var text = content;
    if (text.startsWith('﻿')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final head = text.trimLeft();
    final List<SubtitleCue> cues;
    if (head.startsWith('WEBVTT')) {
      cues = _blocks(text, vtt: true);
    } else if (text.contains('[Script Info]') || text.contains('[Events]') || RegExp(r'^Dialogue:', multiLine: true).hasMatch(text)) {
      cues = _ass(text);
    } else {
      cues = _blocks(text, vtt: false);
    }
    return cues.isEmpty ? empty : SubtitleCues(cues);
  }

  /// What shows at [seconds]: the lines whose time holds it, earliest first, one per row.
  /// Nothing showing is the empty string.
  String textAt(double seconds) {
    if (cues.isEmpty) return '';
    // the first line that starts after `seconds`
    var lo = 0, hi = cues.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= seconds) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final from = seconds - _longest;
    String? one;
    List<String>? many;
    for (var i = lo - 1; i >= 0 && cues[i].start >= from; i--) {
      final c = cues[i];
      if (seconds >= c.end) continue;
      if (one == null) {
        one = c.text;
      } else {
        (many ??= [one]).insert(0, c.text);
      }
    }
    if (many != null) return many.join('\n');
    return one ?? '';
  }

  /// When what shows at [seconds] next changes (a line starts or ends), or null after the last
  /// line. For a clock that wakes only when there is something to change.
  double? nextChangeAfter(double seconds) {
    double? next;
    void take(double t) {
      if (t > seconds && (next == null || t < next!)) next = t;
    }

    var lo = 0, hi = cues.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= seconds) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < cues.length) take(cues[lo].start);
    final from = seconds - _longest;
    for (var i = lo - 1; i >= 0 && cues[i].start >= from; i--) {
      take(cues[i].end);
    }
    return next;
  }

  // ── SubRip and WebVTT: blocks of "time --> time" and the rows under it ──

  static final _timing = RegExp(
    r'^\s*((?:\d+:)?\d{1,2}:\d{1,2}(?:[.,]\d{1,3})?)\s*-->\s*((?:\d+:)?\d{1,2}:\d{1,2}(?:[.,]\d{1,3})?)',
  );

  static List<SubtitleCue> _blocks(String text, {required bool vtt}) {
    final out = <SubtitleCue>[];
    final lines = text.split('\n');
    var i = 0;
    while (i < lines.length) {
      final m = _timing.firstMatch(lines[i]);
      if (m == null) {
        // (WebVTT: a NOTE or STYLE block runs to the next empty row, and is not a line)
        if (vtt && RegExp(r'^(NOTE|STYLE|REGION)\b').hasMatch(lines[i])) {
          while (i < lines.length && lines[i].trim().isNotEmpty) {
            i++;
          }
        }
        i++;
        continue;
      }
      final start = _clock(m[1]!), end = _clock(m[2]!);
      i++;
      final rows = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        // a file with no empty row between its blocks: the next block's timing ends this one
        if (_timing.hasMatch(lines[i])) {
          // (the row before a timing is that block's number; it is not this line's text)
          if (rows.isNotEmpty && RegExp(r'^\s*\d+\s*$').hasMatch(rows.last)) rows.removeLast();
          break;
        }
        rows.add(lines[i]);
        i++;
      }
      final said = _plain(rows.join('\n'));
      if (start != null && end != null && end > start && said.isNotEmpty) out.add(SubtitleCue(start, end, said));
    }
    return out;
  }

  /// `1:02:03,450`, `02:03.45`, `2:03` as seconds.
  static double? _clock(String s) {
    final parts = s.replaceAll(',', '.').split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    var total = 0.0;
    for (final p in parts) {
      final v = double.tryParse(p);
      if (v == null) return null;
      total = total * 60 + v;
    }
    return total;
  }

  /// Markup taken out: `<i>`, `<font ...>`, WebVTT's `<c.class>` and `<00:01.000>`, and the ASS
  /// tags some SubRip files carry (`{\an8}`).
  static String _plain(String s) {
    var t = s.replaceAll(RegExp(r'\{\\[^}]*\}'), '').replaceAll(RegExp(r'</?[A-Za-z0-9:.][^>\n]*>'), '');
    t = t.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&lrm;', '').replaceAll('&rlm;', '');
    return t.split('\n').map((r) => r.trim()).where((r) => r.isNotEmpty).join('\n');
  }

  // ── Advanced SubStation: "Dialogue:" rows under [Events], laid out by its Format row ──

  static List<SubtitleCue> _ass(String text) {
    final out = <SubtitleCue>[];
    // v4+'s usual layout, for a file whose [Events] has no Format row
    var startAt = 1, endAt = 2, textAt = 9, fields = 10;
    for (final raw in text.split('\n')) {
      final line = raw.trimLeft();
      if (line.startsWith('Format:') && line.toLowerCase().contains('text')) {
        final names = line.substring(7).split(',').map((n) => n.trim().toLowerCase()).toList();
        final s = names.indexOf('start'), e = names.indexOf('end'), t = names.indexOf('text');
        if (s >= 0 && e >= 0 && t >= 0) {
          startAt = s;
          endAt = e;
          textAt = t;
          fields = names.length;
        }
        continue;
      }
      if (!line.startsWith('Dialogue:')) continue;
      // the text is the last field and may hold commas of its own
      final parts = line.substring(9).split(',');
      if (parts.length < fields) continue;
      final said = textAt == fields - 1 ? parts.sublist(textAt).join(',') : parts[textAt];
      final start = _clock(parts[startAt].trim()), end = _clock(parts[endAt].trim());
      if (start == null || end == null || end <= start) continue;
      // (a drawing: its "text" is a list of points, not words)
      if (RegExp(r'\{[^}]*\\p[1-9]').hasMatch(said)) continue;
      final plain = said
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', ' ')
          .split('\n')
          .map((r) => r.trim())
          .where((r) => r.isNotEmpty)
          .join('\n');
      if (plain.isNotEmpty) out.add(SubtitleCue(start, end, plain));
    }
    return out;
  }
}
