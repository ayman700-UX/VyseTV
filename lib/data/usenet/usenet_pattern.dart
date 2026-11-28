// Patterns written in a sorting profile ("Title matches …"), matched in time proportional to
// the text whatever they say. Dart's own regular expressions backtrack: a pattern like `(a+)+b`
// over a long release name would freeze the app. These are compiled to a small program run
// over every position of the text at once (a Pike machine), the way RE2 matches, and they take
// RE2's syntax: no lookaround and no backreferences, which are refused when the profile is
// saved.

/// A profile's pattern, ready to be matched. Case is ignored.
class UsenetPattern {
  UsenetPattern._(this._program);

  final List<_Op> _program;

  /// The most instructions one pattern may compile to (counted repeats are written out).
  static const maxProgram = 8000;

  /// [source] compiled, or null when it isn't a pattern this engine takes (lookaround,
  /// backreferences, an unclosed bracket, a repeat with nothing to repeat, or too large).
  static UsenetPattern? tryCompile(String source) {
    try {
      final parser = _Parser(source);
      final node = parser.parse();
      final program = <_Op>[];
      _emit(node, program);
      program.add(const _Match());
      if (program.length > maxProgram) return null;
      return UsenetPattern._(program);
    } on FormatException {
      return null;
    }
  }

  /// Why [source] can't be used, or null when it can.
  static String? problemOf(String source) {
    try {
      final parser = _Parser(source);
      final node = parser.parse();
      final program = <_Op>[];
      _emit(node, program);
      if (program.length + 1 > maxProgram) return 'The pattern is too large.';
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// Whether the pattern is found anywhere in [text].
  bool hasMatch(String text) {
    final cs = text.runes.toList();
    final marks = List<int>.filled(_program.length, -1);
    var current = <int>[];
    var next = <int>[];
    for (var pos = 0; pos <= cs.length; pos++) {
      if (_add(current, 0, pos, cs, marks)) return true;
      if (pos == cs.length) break;
      final c = cs[pos];
      for (final pc in current) {
        final op = _program[pc];
        if (op is _Char && op.test(c) && _add(next, pc + 1, pos + 1, cs, marks)) return true;
      }
      final t = current;
      current = next;
      next = t..clear();
    }
    return false;
  }

  /// Adds the thread at [start] for position [pos] to [list], following jumps, splits and
  /// assertions; true when one of them reaches the match.
  bool _add(List<int> list, int start, int pos, List<int> cs, List<int> marks) {
    final stack = <int>[start];
    while (stack.isNotEmpty) {
      final pc = stack.removeLast();
      if (marks[pc] == pos) continue;
      marks[pc] = pos;
      final op = _program[pc];
      switch (op) {
        case _Match():
          return true;
        case _Jump(:final to):
          stack.add(to);
        case _Split(:final a, :final b):
          stack
            ..add(b)
            ..add(a);
        case _Assert(:final kind):
          if (_holds(kind, pos, cs)) stack.add(pc + 1);
        case _Char():
          list.add(pc);
      }
    }
    return false;
  }

  static bool _word(int? c) =>
      c != null && ((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F);

  static bool _holds(_AssertKind kind, int pos, List<int> cs) {
    final prev = pos > 0 ? cs[pos - 1] : null;
    final cur = pos < cs.length ? cs[pos] : null;
    return switch (kind) {
      _AssertKind.beginText => pos == 0,
      _AssertKind.endText => pos == cs.length,
      _AssertKind.beginLine => pos == 0 || prev == 0x0A,
      _AssertKind.endLine => pos == cs.length || cur == 0x0A,
      _AssertKind.wordBoundary => _word(prev) != _word(cur),
      _AssertKind.notWordBoundary => _word(prev) == _word(cur),
    };
  }

  static void _emit(_Node node, List<_Op> out) {
    if (out.length > maxProgram) throw const FormatException('The pattern is too large.');
    switch (node) {
      case _Empty():
        break;
      case _CharNode(:final pred):
        out.add(_Char(pred));
      case _AssertNode(:final kind):
        out.add(_Assert(kind));
      case _Concat(:final items):
        for (final n in items) {
          _emit(n, out);
        }
      case _Alt(:final branches):
        final jumps = <int>[];
        for (var i = 0; i < branches.length; i++) {
          if (i < branches.length - 1) {
            final split = out.length;
            out.add(const _Split(0, 0));
            _emit(branches[i], out);
            jumps.add(out.length);
            out.add(const _Jump(0));
            out[split] = _Split(split + 1, out.length);
          } else {
            _emit(branches[i], out);
          }
        }
        for (final j in jumps) {
          out[j] = _Jump(out.length);
        }
      case _Repeat(:final node, :final min, :final max):
        for (var i = 0; i < min; i++) {
          _emit(node, out);
        }
        if (max < 0) {
          final split = out.length;
          out.add(const _Split(0, 0));
          _emit(node, out);
          out.add(_Jump(split));
          out[split] = _Split(split + 1, out.length);
        } else {
          final splits = <int>[];
          for (var i = min; i < max; i++) {
            splits.add(out.length);
            out.add(const _Split(0, 0));
            _emit(node, out);
          }
          for (final s in splits) {
            out[s] = _Split(s + 1, out.length);
          }
        }
    }
  }
}

// ── the program ──

sealed class _Op {
  const _Op();
}

class _Match extends _Op {
  const _Match();
}

class _Jump extends _Op {
  const _Jump(this.to);
  final int to;
}

class _Split extends _Op {
  const _Split(this.a, this.b);
  final int a;
  final int b;
}

enum _AssertKind { beginText, endText, beginLine, endLine, wordBoundary, notWordBoundary }

class _Assert extends _Op {
  const _Assert(this.kind);
  final _AssertKind kind;
}

class _Char extends _Op {
  const _Char(this.pred);
  final _Pred pred;
  bool test(int c) => pred.test(c);
}

// ── what one character may be ──

int _lower(int c) {
  if (c < 0x80) return c >= 0x41 && c <= 0x5A ? c + 32 : c;
  final s = String.fromCharCode(c).toLowerCase();
  return s.runes.length == 1 ? s.runes.first : c;
}

int _upper(int c) {
  if (c < 0x80) return c >= 0x61 && c <= 0x7A ? c - 32 : c;
  final s = String.fromCharCode(c).toUpperCase();
  return s.runes.length == 1 ? s.runes.first : c;
}

abstract class _Pred {
  const _Pred();
  bool test(int c);
}

class _Lit extends _Pred {
  _Lit(this.c, this.fold)
      : lower = fold ? _lower(c) : c,
        upper = fold ? _upper(c) : c;
  final int c;
  final int lower;
  final int upper;
  final bool fold;
  @override
  bool test(int x) => x == c || (fold && (x == lower || x == upper));
}

class _AnyChar extends _Pred {
  const _AnyChar(this.newline);
  final bool newline;
  @override
  bool test(int c) => newline || c != 0x0A;
}

class _Range {
  const _Range(this.from, this.to);
  final int from;
  final int to;
}

/// A bracketed set, or a class escape such as `\d`.
class _Set extends _Pred {
  _Set(this.ranges, this.extra, {required this.negated, required this.fold});
  final List<_Range> ranges;
  final List<_Pred> extra;
  final bool negated;
  final bool fold;

  bool _inRanges(int c) {
    for (final r in ranges) {
      if (c >= r.from && c <= r.to) return true;
    }
    for (final p in extra) {
      if (p.test(c)) return true;
    }
    return false;
  }

  @override
  bool test(int c) {
    final hit = _inRanges(c) || (fold && (_inRanges(_lower(c)) || _inRanges(_upper(c))));
    return hit != negated;
  }
}

/// A Unicode property (`\pL`, `\p{Greek}`), tested with Dart's engine on one character, which
/// can't backtrack.
class _Property extends _Pred {
  _Property(this.re, this.negated);
  final RegExp re;
  final bool negated;
  @override
  bool test(int c) => re.hasMatch(String.fromCharCode(c)) != negated;
}

// ── the pattern as parsed ──

sealed class _Node {
  const _Node();
}

class _Empty extends _Node {
  const _Empty();
}

class _CharNode extends _Node {
  const _CharNode(this.pred);
  final _Pred pred;
}

class _AssertNode extends _Node {
  const _AssertNode(this.kind);
  final _AssertKind kind;
}

class _Concat extends _Node {
  const _Concat(this.items);
  final List<_Node> items;
}

class _Alt extends _Node {
  const _Alt(this.branches);
  final List<_Node> branches;
}

class _Repeat extends _Node {
  const _Repeat(this.node, this.min, this.max);
  final _Node node;
  final int min;
  final int max; // -1: no limit
}

const _digits = [_Range(0x30, 0x39)];
const _wordChars = [_Range(0x30, 0x39), _Range(0x41, 0x5A), _Range(0x5F, 0x5F), _Range(0x61, 0x7A)];
const _spaces = [_Range(0x09, 0x0A), _Range(0x0C, 0x0D), _Range(0x20, 0x20)];

const _posix = <String, List<_Range>>{
  'alnum': [_Range(0x30, 0x39), _Range(0x41, 0x5A), _Range(0x61, 0x7A)],
  'alpha': [_Range(0x41, 0x5A), _Range(0x61, 0x7A)],
  'ascii': [_Range(0x00, 0x7F)],
  'blank': [_Range(0x09, 0x09), _Range(0x20, 0x20)],
  'cntrl': [_Range(0x00, 0x1F), _Range(0x7F, 0x7F)],
  'digit': [_Range(0x30, 0x39)],
  'graph': [_Range(0x21, 0x7E)],
  'lower': [_Range(0x61, 0x7A)],
  'print': [_Range(0x20, 0x7E)],
  'punct': [_Range(0x21, 0x2F), _Range(0x3A, 0x40), _Range(0x5B, 0x60), _Range(0x7B, 0x7E)],
  'space': [_Range(0x09, 0x0D), _Range(0x20, 0x20)],
  'upper': [_Range(0x41, 0x5A)],
  'word': _wordChars,
  'xdigit': [_Range(0x30, 0x39), _Range(0x41, 0x46), _Range(0x61, 0x66)],
};

class _Parser {
  _Parser(String source) : cs = source.runes.toList();

  final List<int> cs;
  var i = 0;

  // the flags in force: case ignored (always on: profiles match ignoring case), ^ and $ at
  // line ends, . matching a line break
  var fold = true;
  var multiLine = false;
  var dotAll = false;

  bool get _end => i >= cs.length;
  int get _peek => cs[i];
  bool _at(String ch) => !_end && cs[i] == ch.codeUnitAt(0);

  Never _fail(String why) => throw FormatException(why);

  _Node parse() {
    final node = _alternation();
    if (!_end) _fail('A closing parenthesis has no opening one.');
    return node;
  }

  _Node _alternation() {
    final branches = [_concatenation()];
    while (_at('|')) {
      i++;
      branches.add(_concatenation());
    }
    return branches.length == 1 ? branches.first : _Alt(branches);
  }

  _Node _concatenation() {
    final items = <_Node>[];
    while (!_end && !_at('|') && !_at(')')) {
      final atom = _atom();
      if (atom == null) continue;
      items.add(_quantified(atom));
    }
    if (items.isEmpty) return const _Empty();
    return items.length == 1 ? items.first : _Concat(items);
  }

  /// A repeat count at [i] (`{2}`, `{2,}`, `{2,5}`): its bounds and where it ends, or null when
  /// the brace is a plain character.
  (int, int, int)? _counted() {
    if (!_at('{')) return null;
    var j = i + 1;
    int? number() {
      final from = j;
      while (j < cs.length && cs[j] >= 0x30 && cs[j] <= 0x39) {
        j++;
      }
      return j == from ? null : int.tryParse(String.fromCharCodes(cs.sublist(from, j)));
    }

    final min = number();
    if (min == null) return null;
    var max = min;
    if (j < cs.length && cs[j] == 0x2C) {
      j++;
      if (j < cs.length && cs[j] == 0x7D) {
        max = -1;
      } else {
        final m = number();
        if (m == null) return null;
        max = m;
      }
    }
    if (j >= cs.length || cs[j] != 0x7D) return null;
    if (min > 1000 || max > 1000 || (max >= 0 && max < min)) _fail('A repeat count is out of range.');
    return (min, max, j + 1);
  }

  bool get _quantifierNext => _at('*') || _at('+') || _at('?') || _counted() != null;

  _Node _quantified(_Node atom) {
    int min, max;
    if (_at('*') || _at('+') || _at('?')) {
      final c = _peek;
      i++;
      min = c == 0x2B ? 1 : 0;
      max = c == 0x3F ? 1 : -1;
    } else {
      final counted = _counted();
      if (counted == null) return atom;
      min = counted.$1;
      max = counted.$2;
      i = counted.$3;
    }
    if (_at('?')) i++; // lazy: the same for whether it matches at all
    if (_quantifierNext) _fail('A repeat follows another repeat.');
    return _Repeat(atom, min, max);
  }

  _Node? _atom() {
    final c = _peek;
    switch (c) {
      case 0x28: // (
        return _group();
      case 0x5B: // [
        return _CharNode(_bracket());
      case 0x2E: // .
        i++;
        return _CharNode(_AnyChar(dotAll));
      case 0x5E: // ^
        i++;
        return _AssertNode(multiLine ? _AssertKind.beginLine : _AssertKind.beginText);
      case 0x24: // $
        i++;
        return _AssertNode(multiLine ? _AssertKind.endLine : _AssertKind.endText);
      case 0x5C: // \
        return _escape();
      case 0x2A || 0x2B || 0x3F: // * + ?
        _fail('A repeat has nothing to repeat.');
      case 0x7B: // {
        if (_counted() != null) _fail('A repeat has nothing to repeat.');
        i++;
        return _CharNode(_Lit(c, fold));
      default:
        i++;
        return _CharNode(_Lit(c, fold));
    }
  }

  /// `(…)`, `(?:…)`, `(?P<name>…)`, `(?flags)` and `(?flags:…)`. Null for a bare flag change.
  _Node? _group() {
    i++; // (
    final savedFold = fold, savedMultiLine = multiLine, savedDotAll = dotAll;
    if (_at('?')) {
      i++;
      if (_end) _fail('An unfinished group.');
      if (_at('=') || _at('!')) _fail('Lookahead is not supported.');
      if (_at('<') && i + 1 < cs.length && (cs[i + 1] == 0x3D || cs[i + 1] == 0x21)) _fail('Lookbehind is not supported.');
      if (_at('P') || _at('<')) {
        if (_at('P')) i++;
        if (!_at('<')) _fail('An unfinished group name.');
        i++;
        final from = i;
        while (!_end && !_at('>')) {
          final ch = _peek;
          final ok = (ch >= 0x30 && ch <= 0x39) || (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == 0x5F;
          if (!ok) _fail('A group name may hold only letters, digits and _.');
          i++;
        }
        if (_end || i == from) _fail('An unfinished group name.');
        i++; // >
      } else {
        // flags: i, m, s, U, with - turning off
        var on = true;
        var any = false;
        while (!_end && !_at(')') && !_at(':')) {
          final f = _peek;
          i++;
          switch (f) {
            case 0x2D:
              if (!on) _fail('A flag group has two minus signs.');
              on = false;
            case 0x69:
              fold = on;
              any = true;
            case 0x6D:
              multiLine = on;
              any = true;
            case 0x73:
              dotAll = on;
              any = true;
            case 0x55:
              any = true; // ungreedy: the same for whether it matches at all
            default:
              _fail('An unknown flag.');
          }
        }
        if (_end) _fail('An unfinished group.');
        if (_at(')')) {
          if (!any) _fail('An empty flag group.');
          i++;
          return null; // in force until the enclosing group ends
        }
        i++; // :
      }
    }
    final inner = _alternation();
    if (!_at(')')) _fail('A group is not closed.');
    i++;
    fold = savedFold;
    multiLine = savedMultiLine;
    dotAll = savedDotAll;
    return inner;
  }

  _Pred _bracket() {
    i++; // [
    var negated = false;
    if (_at('^')) {
      negated = true;
      i++;
    }
    final ranges = <_Range>[];
    final extra = <_Pred>[];
    var first = true;
    while (true) {
      if (_end) _fail('A bracket is not closed.');
      if (_at(']') && !first) {
        i++;
        break;
      }
      first = false;
      // [:alpha:]
      if (_at('[') && i + 1 < cs.length && cs[i + 1] == 0x3A) {
        final close = String.fromCharCodes(cs.sublist(i)).indexOf(':]');
        if (close > 1) {
          var name = String.fromCharCodes(cs.sublist(i + 2, i + close));
          var neg = false;
          if (name.startsWith('^')) {
            neg = true;
            name = name.substring(1);
          }
          final set = _posix[name];
          if (set == null) _fail('An unknown character class.');
          i += close + 2;
          if (neg) {
            extra.add(_Set(set, const [], negated: true, fold: false));
          } else {
            ranges.addAll(set);
          }
          continue;
        }
      }
      int lo;
      if (_at('\\')) {
        final e = _classEscape();
        if (e is _Pred) {
          extra.add(e);
          continue;
        }
        lo = e as int;
      } else {
        lo = _peek;
        i++;
      }
      if (_at('-') && i + 1 < cs.length && cs[i + 1] != 0x5D) {
        i++;
        int hi;
        if (_at('\\')) {
          final e = _classEscape();
          if (e is! int) _fail('A range ends in a class.');
          hi = e;
        } else {
          hi = _peek;
          i++;
        }
        if (hi < lo) _fail('A range is backwards.');
        ranges.add(_Range(lo, hi));
      } else {
        ranges.add(_Range(lo, lo));
      }
    }
    return _Set(ranges, extra, negated: negated, fold: fold);
  }

  /// An escape inside brackets: a character (int) or a class (_Pred).
  Object _classEscape() {
    i++; // \
    if (_end) _fail('A pattern ends in a backslash.');
    final c = _peek;
    final cls = _classOf(c);
    if (cls != null) {
      i++;
      return cls;
    }
    if (c == 0x70 || c == 0x50) return _property();
    return _escapedChar();
  }

  _Pred? _classOf(int c) => switch (c) {
    0x64 => _Set(_digits, const [], negated: false, fold: false), // d
    0x44 => _Set(_digits, const [], negated: true, fold: false), // D
    0x77 => _Set(_wordChars, const [], negated: false, fold: false), // w
    0x57 => _Set(_wordChars, const [], negated: true, fold: false), // W
    0x73 => _Set(_spaces, const [], negated: false, fold: false), // s
    0x53 => _Set(_spaces, const [], negated: true, fold: false), // S
    _ => null,
  };

  _Pred _property() {
    final negated = _peek == 0x50;
    i++;
    String name;
    if (_at('{')) {
      final close = String.fromCharCodes(cs.sublist(i)).indexOf('}');
      if (close < 0) _fail('An unfinished property.');
      name = String.fromCharCodes(cs.sublist(i + 1, i + close));
      i += close + 1;
    } else {
      if (_end) _fail('An unfinished property.');
      name = String.fromCharCode(_peek);
      i++;
    }
    var neg = negated;
    if (name.startsWith('^')) {
      neg = !neg;
      name = name.substring(1);
    }
    if (!RegExp(r'^[A-Za-z_]+$').hasMatch(name)) _fail('An unknown property.');
    try {
      final general = name.length <= 2 || name == 'Any';
      final re = name == 'Any' ? RegExp(r'^[\s\S]$', unicode: true) : RegExp('^\\p{${general ? name : 'Script=$name'}}\$', unicode: true);
      return _Property(re, neg);
    } on FormatException {
      _fail('An unknown property.');
    }
  }

  /// The character an escape stands for, at [i] after the backslash.
  int _escapedChar() {
    final c = _peek;
    i++;
    switch (c) {
      case 0x74:
        return 0x09; // t
      case 0x6E:
        return 0x0A; // n
      case 0x72:
        return 0x0D; // r
      case 0x66:
        return 0x0C; // f
      case 0x76:
        return 0x0B; // v
      case 0x61:
        return 0x07; // a
      case 0x78: // x
        if (_at('{')) {
          final close = String.fromCharCodes(cs.sublist(i)).indexOf('}');
          if (close < 0) _fail('An unfinished hex escape.');
          final v = int.tryParse(String.fromCharCodes(cs.sublist(i + 1, i + close)), radix: 16);
          if (v == null || v > 0x10FFFF) _fail('A bad hex escape.');
          i += close + 1;
          return v;
        }
        if (i + 2 > cs.length) _fail('A bad hex escape.');
        final v = int.tryParse(String.fromCharCodes(cs.sublist(i, i + 2)), radix: 16);
        if (v == null) _fail('A bad hex escape.');
        i += 2;
        return v;
    }
    if (c >= 0x30 && c <= 0x39) _fail('Backreferences are not supported.');
    final letter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    if (letter) _fail('An unknown escape.');
    return c; // punctuation stands for itself
  }

  _Node _escape() {
    i++; // \
    if (_end) _fail('A pattern ends in a backslash.');
    final c = _peek;
    final cls = _classOf(c);
    if (cls != null) {
      i++;
      return _CharNode(cls);
    }
    switch (c) {
      case 0x62: // b
        i++;
        return const _AssertNode(_AssertKind.wordBoundary);
      case 0x42: // B
        i++;
        return const _AssertNode(_AssertKind.notWordBoundary);
      case 0x41: // A
        i++;
        return const _AssertNode(_AssertKind.beginText);
      case 0x7A: // z
        i++;
        return const _AssertNode(_AssertKind.endText);
      case 0x70 || 0x50: // p P
        return _CharNode(_property());
      case 0x51: // Q … \E: literal text
        i++;
        final items = <_Node>[];
        while (!_end) {
          if (_at('\\') && i + 1 < cs.length && cs[i + 1] == 0x45) {
            i += 2;
            break;
          }
          items.add(_CharNode(_Lit(_peek, fold)));
          i++;
        }
        return items.isEmpty ? const _Empty() : (items.length == 1 ? items.first : _Concat(items));
    }
    return _CharNode(_Lit(_escapedChar(), fold));
  }
}
