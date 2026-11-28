// What a Usenet release's name says: whether it is the film or episode searched for (its title,
// year and episode numbers, or the seasons of a pack), which of two series of one name it is,
// and what it holds (resolution, source, codec, HDR, audio, languages, release group), as the
// built-in Usenet source matches, labels and sorts what your indexers find.
//
// Indexers mis-tag ids and title searches find namesakes, so the name decides.

import 'package:flutter/foundation.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// The time the Usenet source goes by (tests set their own).
class UsenetClock {
  UsenetClock._();

  @visibleForTesting
  static DateTime Function() debugNow = DateTime.now;

  /// Now.
  static DateTime now() => debugNow();

  /// Now, in milliseconds since 1970.
  static int nowMs() => debugNow().millisecondsSinceEpoch;
}

/// Another series with the same name as the one searched for (TMDB's search): when it started,
/// where it is from, and how well known it is.
@immutable
class UsenetNamesake {
  const UsenetNamesake({this.year, this.countries = const [], this.votes = 0});
  final int? year;
  final List<String> countries;
  final int votes;
}

/// What the indexers are asked for: ids, names and years, and for a series the episode.
@immutable
class UsenetSearchRequest {
  const UsenetSearchRequest({
    this.imdbId,
    this.tmdbId,
    this.tvdbId,
    this.title,
    this.originalTitle,
    this.otherTitles,
    this.year,
    this.seasonYear,
    this.lastYear,
    this.countries = const [],
    this.namesakes,
    this.votes,
    this.season,
    this.episode,
    this.series = false,
  });

  /// `tt0944947`.
  final String? imdbId;
  final String? tmdbId;
  final String? tvdbId;
  final String? title;

  /// Its title in its own language, when that differs.
  final String? originalTitle;

  /// A film's other names (alternative titles and translations); null when unknown.
  final List<String>? otherTitles;

  /// A film's release year, or a series' first year.
  final int? year;

  /// The year the searched season aired.
  final int? seasonYear;

  /// A series' last year.
  final int? lastYear;

  /// A series' countries of origin (ISO codes such as US, GB, KR).
  final List<String> countries;

  /// Other series of the same name; null when unknown.
  final List<UsenetNamesake>? namesakes;

  /// The series' vote count on TMDB.
  final int? votes;
  final int? season;
  final int? episode;
  final bool series;

  /// The same request without any id: a search by title.
  UsenetSearchRequest withoutIds() => UsenetSearchRequest(
    title: title,
    originalTitle: originalTitle,
    otherTitles: otherTitles,
    year: year,
    seasonYear: seasonYear,
    lastYear: lastYear,
    countries: countries,
    namesakes: namesakes,
    votes: votes,
    season: season,
    episode: episode,
    series: series,
  );

  /// The same request under other names.
  UsenetSearchRequest named(String? title, String? originalTitle) => UsenetSearchRequest(
    imdbId: imdbId,
    tmdbId: tmdbId,
    tvdbId: tvdbId,
    title: title,
    originalTitle: originalTitle,
    otherTitles: otherTitles,
    year: year,
    seasonYear: seasonYear,
    lastYear: lastYear,
    countries: countries,
    namesakes: namesakes,
    votes: votes,
    season: season,
    episode: episode,
    series: series,
  );
}

// ── spelling ──

const _umlauts = {'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'ø': 'oe'};
const _letters = {'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'ø': 'o', 'đ': 'd', 'ð': 'd', 'ł': 'l', 'þ': 'th', 'ı': 'i'};
const _apostrophes = {0x27, 0x2019, 0x2018, 0x60, 0xB4, 0x2BC};
final _mark = RegExp(r'\p{M}', unicode: true);
final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _ascii = RegExp(r'^[\x00-\x7F]*$');

/// Whether [c] is a letter of the Latin script.
bool isLatinLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0xAA ||
    c == 0xBA ||
    (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7) ||
    (c >= 0x1E00 && c <= 0x1EFF) ||
    (c >= 0x2C60 && c <= 0x2C7F) ||
    (c >= 0xA720 && c <= 0xA7FF) ||
    (c >= 0xAB30 && c <= 0xAB6F) ||
    (c >= 0xFF21 && c <= 0xFF3A) ||
    (c >= 0xFF41 && c <= 0xFF5A);

/// Whether [s] has a Latin letter (indexers search Latin text: `La casa de papel` has,
/// `ペーパー・ハウス` hasn't).
bool hasLatinLetter(String s) => s.runes.any(isLatinLetter);

/// [value] spelled the way release names spell it: `Amélie` → `Amelie`, `Der König der Löwen`
/// → `Der Koenig der Loewen` (with [umlauts] off: `Der Konig der Lowen`), `Straße` → `Strasse`,
/// `Marvel's` → `Marvels`. Marks on letters of other scripts stay (`ガンダム`).
String releaseSpelling(String value, {bool umlauts = true}) {
  if (_ascii.hasMatch(value)) {
    final b = StringBuffer();
    for (final c in value.codeUnits) {
      if (!_apostrophes.contains(c)) b.writeCharCode(c);
    }
    return b.toString();
  }
  final b = StringBuffer();
  for (final r in value.runes) {
    final c = String.fromCharCode(r);
    final l = c.toLowerCase();
    final rep = (umlauts ? _umlauts[l] : null) ?? _letters[l];
    if (rep == null) {
      b.write(c);
    } else {
      b.write(c != l ? '${rep[0].toUpperCase()}${rep.substring(1)}' : rep);
    }
  }
  final decomposed = unorm.nfd(b.toString());
  final kept = StringBuffer();
  var afterLatin = false;
  for (final r in decomposed.runes) {
    if (_mark.hasMatch(String.fromCharCode(r))) {
      if (!afterLatin) kept.writeCharCode(r);
      continue;
    }
    afterLatin = isLatinLetter(r);
    kept.writeCharCode(r);
  }
  final out = StringBuffer();
  for (final r in unorm.nfc(kept.toString()).runes) {
    if (!_apostrophes.contains(r)) out.writeCharCode(r);
  }
  return out.toString();
}

/// [value]'s words as release names spell them, lower case, separated by single spaces: `&`
/// is "and", every run of other characters than letters and digits one space.
String words(String value, {bool umlauts = true}) =>
    releaseSpelling(value, umlauts: umlauts).toLowerCase().replaceAll('&', ' and ').replaceAll(_nonWord, ' ').trim();

/// Whether [a] and [b] are the same name as release names spell them (`Marvel's Daredevil` and
/// `Marvels Daredevil`; never `Suits LA` and `Suits`).
bool sameName(String? a, String? b) {
  if (a == null || b == null) return false;
  final w = words(a);
  return w.isNotEmpty && w == words(b);
}

/// A title as a query: release spelling, every run of other characters than letters and digits
/// one space (`Mission: Impossible – Fallout` → `Mission Impossible Fallout`). Case is kept.
String queryTitle(String title) => releaseSpelling(title).replaceAll(_nonWord, ' ').trim();

// ── words of release names ──

/// Words a title may start with that release names often leave out.
const articles = {'the', 'a', 'an'};

/// Words that start a release name's tags: languages, sources, codecs, editions, services and
/// the country tags.
const releaseTags = {
  'german', 'french', 'truefrench', 'vostfr', 'ita', 'italian', 'spanish', 'castellano', 'latino', 'multi', 'dl', 'dual',
  'dubbed', 'subbed', 'nordic', 'dutch', 'polish', 'russian', 'hindi', 'korean', 'japanese', 'bluray', 'bdrip', 'brrip',
  'webrip', 'web', 'webdl', 'hdtv', 'hdrip', 'dvdrip', 'dvd', 'remux', 'uhd', 'hdr', 'hdr10', 'dv', 'dovi', 'sdr', 'x264',
  'x265', 'h264', 'h265', 'hevc', 'avc', 'xvid', 'av1', 'imax', 'extended', 'unrated', 'remastered', 'proper', 'repack',
  'internal', 'limited', 'directors', 'uncut', 'theatrical', 'cam', 'ts', 'telesync', 'hdcam', 'dvdscr', 'screener', '3d',
  'amzn', 'nf', 'dsnp', 'hmax', 'atvp', 'us', 'uk', 'au', 'ca', 'nz',
};

/// Country tags in release names and the countries they name (`The.Office.UK`).
const countryTags = {'us': 'US', 'uk': 'GB', 'au': 'AU', 'ca': 'CA', 'nz': 'NZ'};

final _year = RegExp(r'^(?:19|20)\d{2}$');
final _releaseYear = RegExp(r'(?<![\p{L}\p{N}])((?:19|20)\d{2})(?![\p{L}\p{N}])', unicode: true);
final _episodeNumber = RegExp(r'^(?:s\d{1,3}(?:e\d{1,4})*|e\d{1,4}|ep\d{1,4}|\d{1,2}x\d{1,3})$');
final _resolutionWord = RegExp(r'^(?:\d{3,4}[pi]|[48]k)$');
final _releaseMarker = RegExp(r'^(?:(?:19|20)\d{2}|s\d{1,3}(?:e\d{1,4})*|e\d{1,4}|\d{1,2}x\d{1,3}|\d{3,4}[pi]|[48]k|\d{1,2}bit|season|complete)$');
final _dayOrMonth = RegExp(r'^\d{1,2}$');

bool _isYear(String w) => _year.hasMatch(w);
bool _isEpisodeNumber(String w) => _episodeNumber.hasMatch(w);
bool _isMarker(String w) => _releaseMarker.hasMatch(w);

/// The years in a release name (`2019` of `1917.2019.1080p`, and `1917` too).
List<int> releaseYears(String title) => [for (final m in _releaseYear.allMatches(title)) int.parse(m[1]!)];

/// The request's names as word lists: its title and original title, each with umlauts spelled
/// out and without.
List<List<String>> titleWordLists(UsenetSearchRequest r) => _titles[r] ??= () {
  final out = <String>[];
  for (final t in [r.title, r.originalTitle]) {
    if (t == null) continue;
    for (final w in [words(t), words(t, umlauts: false)]) {
      if (w.isNotEmpty && !out.contains(w)) out.add(w);
    }
  }
  return [for (final w in out) w.split(' ')];
}();

final _titles = Expando<List<List<String>>>();

/// Whether [name] (a release name's words) names [title] (a title's words): the title at the
/// start (after articles only, for a film; for a series after any words but an episode number,
/// and a one-word title not after articles alone: `The.Batman` isn't `Batman`), followed by
/// nothing, a tag or a marker such as a year, or for a film a subtitle before its year.
bool isNamedAs(List<String> name, List<String> title, {required bool series}) {
  if (title.isEmpty) return false;
  for (var i = 0; i + title.length <= name.length; i++) {
    var same = true;
    for (var k = 0; k < title.length; k++) {
      if (name[i + k] != title[k]) {
        same = false;
        break;
      }
    }
    if (!same) continue;
    final before = name.sublist(0, i);
    final leading = series
        ? !before.any(_isEpisodeNumber) && (title.length > 1 || before.isEmpty || before.any((w) => !articles.contains(w)))
        : before.every(articles.contains);
    if (!leading) continue;
    final after = name.sublist(i + title.length);
    final m = after.indexWhere((w) => releaseTags.contains(w) || _isMarker(w));
    if (after.isEmpty || m == 0 || (!series && m > 0 && _isYear(after[m]))) return true;
  }
  return false;
}

/// Whether a release name's years say it is another film than one of [year]: none within a
/// year of it, and one that isn't a word of the title (`Blade Runner 2049`, `1917`).
bool contradictsYear(String releaseTitle, int year, Iterable<String> titleWords) {
  final years = releaseYears(releaseTitle);
  if (years.isEmpty) return false;
  final words = titleWords.toSet();
  return !years.any((y) => y >= year - 1 && y <= year + 1) && years.any((y) => !words.contains('$y'));
}

// ── episode numbers ──

const _more = r'((?:(?:[ ._]*E|[ ._]*-[ ._]*E?)\d{1,3})+(?=$|[ ._-]))?';
final _episodePatterns = [
  RegExp(r'S(\d{1,3})[ ._-]*E(\d{1,3})(?!\d)' + _more, caseSensitive: false),
  RegExp(r'(?<!\d)(\d{1,2})x(\d{1,3})(?!\d)' + _more, caseSensitive: false),
];
final _clock = RegExp(r'^[ ._-]*\d{1,2}[ ._:-]\d{2}[ ._-]*[AP]\.?M(?![A-Z])', caseSensitive: false);
final _moreEpisode = RegExp(r'([ ._]*-[ ._]*E?|[ ._]*E)(\d{1,3})', caseSensitive: false);

/// One episode numbering in a release name (`S01E02`, `S01E01-03`, `1x04`).
class EpisodeNumbering {
  EpisodeNumbering._(this.match);
  final RegExpMatch match;

  int get season => int.parse(match[1]!);
  int get episode => int.parse(match[2]!);
  int get start => match.start;
  int get end => match.end;

  /// The episodes after the first: each number, and whether a hyphen spans to it (`E01-E03`
  /// spans 1 to 3, `E01E03` lists two). None after a clock time (`S01E02-8-00.A.M`).
  late final List<(int, bool)> more = () {
    final tail = match[3];
    // (the numbering ends with the episodes after the first: the first's digits end where they start)
    final after = match.input.substring(match.end - (tail?.length ?? 0));
    if (_clock.hasMatch(after)) return const <(int, bool)>[];
    if (tail == null || tail.isEmpty) return const <(int, bool)>[];
    final firstDigits = match[2]!.length;
    var previous = episode;
    final out = <(int, bool)>[];
    for (final m in _moreEpisode.allMatches(tail)) {
      final sep = m[1]!;
      final n = int.parse(m[2]!);
      final marked = sep.contains('E') || sep.contains('e');
      if (n <= previous || (!marked && m[2]!.length < firstDigits)) break;
      out.add((n, sep.contains('-')));
      previous = n;
    }
    return out;
  }();

  /// Whether it names [ep]: the first, one listed, or one inside a span.
  bool names(int ep) {
    if (ep == episode) return true;
    var previous = episode;
    for (final (n, ranged) in more) {
      if (ep == n || (ranged && previous <= ep && ep <= n)) return true;
      previous = n;
    }
    return false;
  }
}

/// Every episode numbering in [title], `S01E02` style first, then `1x02` style.
List<EpisodeNumbering> episodeNumberings(String title) => [
  for (final p in _episodePatterns)
    for (final m in p.allMatches(title)) EpisodeNumbering._(m),
];

final _seasonRange = RegExp(r'(?:^|[ ._-])(?:S|Season[ ._-]*)(\d{1,3})[ ._]*-[ ._]*(?:S|Season[ ._-]*)?(\d{1,3})(?=$|[ ._-])', caseSensitive: false);
final _season = RegExp(r'(?:^|[ ._-])(?:S|Season[ ._-]*)(\d{1,3})(?=$|[ ._-])', caseSensitive: false);

/// The seasons a pack's name says it holds (`S01-S03` → 1, 2, 3; `S01.S03` → 1, 3), or none
/// for an episode or a film.
List<int> packSeasons(String title) {
  if (episodeNumberings(title).isNotEmpty) return const [];
  final out = <int>[];
  void add(int s) {
    if (!out.contains(s)) out.add(s);
  }

  for (final m in _seasonRange.allMatches(title)) {
    final first = int.parse(m[1]!), last = int.parse(m[2]!);
    if (last > first && last - first < 50) {
      for (var s = first; s <= last; s++) {
        add(s);
      }
    } else {
      add(first);
      add(last);
    }
  }
  for (final m in _season.allMatches(title)) {
    add(int.parse(m[1]!));
  }
  return out;
}

final _releaseTag = RegExp(
  r'(?:^|[ ._-])(?:(?:2160|1080|720|576|480)[pi]|4k|uhd|web-?dl|web-?rip|blu-?ray|bdrip|hdtv|remux|[xh][ .]?26[45]|hevc|proper|repack)(?=$|[ ._-])',
  caseSensitive: false,
);

/// What one upload's episodes share in their names: the name without its episode number and
/// the episode's own name (`silo.S1E?.2160p.atvp.web-dl…-ntb`), and the episode. Null for
/// packs, names of several episodes and names without numbering.
({String template, int episode})? episodeTemplate(String title) {
  final all = episodeNumberings(title);
  if (all.length != 1 || all.single.more.isNotEmpty) return null;
  final n = all.single;
  final rest = title.substring(n.end);
  final tag = _releaseTag.firstMatch(rest);
  final tags = tag == null ? rest : rest.substring(tag.start);
  return (template: '${title.substring(0, n.start)}S${n.season}E?$tags', episode: n.episode);
}

/// Whether [title] is a release of the film or episode [r] asks for. [idSearch]: found by an id
/// (the indexer vouches for the title; the name's year still decides a film). [requireNumbering]:
/// a series' release must name its episode or season (a name without numbers could be any
/// episode).
bool releaseMatches(String title, UsenetSearchRequest r, {required bool idSearch, bool requireNumbering = false}) {
  final titles = titleWordLists(r);
  if (!idSearch) {
    final name = words(title).split(' ');
    List<String>? named;
    for (final t in titles) {
      if (isNamedAs(name, t, series: r.series)) {
        named = t;
        break;
      }
    }
    if (named == null) return false;
    final year = r.year;
    if (!r.series && year != null && contradictsYear(title, year, named)) return false;
  } else {
    final year = r.year;
    if (!r.series && year != null && contradictsYear(title, year, [for (final t in titles) ...t])) return false;
  }
  if (r.series) {
    final numberings = episodeNumberings(title);
    if (numberings.isNotEmpty) {
      final ep = r.episode;
      return ep != null && numberings.any((n) => n.season == r.season && n.names(ep));
    }
    final packs = packSeasons(title);
    if (packs.isNotEmpty) return packs.contains(r.season);
    return idSearch && !requireNumbering;
  }
  return true;
}

// ── a film's other names ──

final _letter = RegExp(r'\p{L}', unicode: true);

/// Each of [names] as word sets, articles left out: umlauts both ways, and without the letters
/// some posts lose (`Amélie` posted as `Amlie`). Sets without a letter (`1917`) are left out.
List<Set<String>> nameWordSets(Iterable<String?> names) {
  final out = <Set<String>>[];
  for (final name in names) {
    if (name == null) continue;
    final stripped = String.fromCharCodes(name.runes.where((r) => !(r > 0x7F && _letter.hasMatch(String.fromCharCode(r)))));
    for (final spelled in [words(name), words(name, umlauts: false), words(stripped)]) {
      final set = {for (final w in spelled.split(' ')) if (w.isNotEmpty && !articles.contains(w)) w};
      if (!set.any((w) => _letter.hasMatch(w))) continue;
      if (!out.any((s) => setEquals(s, set))) out.add(set);
    }
  }
  return out;
}

/// The words of a release name before its tags and markers, articles left out; none when the
/// name has no year (an obfuscated name is trusted).
Set<String> releaseTitleWords(String title) {
  if (!_releaseYear.hasMatch(title)) return const {};
  final out = <String>{};
  for (final w in words(title).split(' ')) {
    if (w.isEmpty || releaseTags.contains(w) || _isMarker(w)) break;
    if (!articles.contains(w)) out.add(w);
  }
  return out;
}

/// A film's releases found by its id that are really it: the name's year agrees, and when the
/// film's other names are known, the name is one of them (indexers file The Ring (2002) under
/// The Two Towers (2002)).
List<T> filmResultsOf<T>(UsenetSearchRequest movie, List<T> releases, String Function(T) titleOf) {
  final ofYear = [for (final r in releases) if (releaseMatches(titleOf(r), movie, idSearch: true)) r];
  final others = movie.otherTitles;
  if (others == null) return ofYear;
  final own = nameWordSets([movie.title, movie.originalTitle]);
  if (own.isEmpty) return ofYear;
  final names = [...own];
  for (final s in nameWordSets(others)) {
    if (!names.any((n) => setEquals(n, s))) names.add(s);
  }
  return [
    for (final r in ofYear)
      if (() {
        final tw = releaseTitleWords(titleOf(r));
        if (tw.isEmpty) return true;
        if (names.any((n) => n.where(tw.contains).length * 2 > n.length)) return true;
        return own.any((n) => tw.where(n.contains).length * 2 > tw.length);
      }())
        r,
  ];
}

// ── series of one name ──

/// What a release name says of which series it is.
enum SeriesName { another, unknown, own, dated, bare }

/// Which series [title] names, of [show] and its namesakes: another one (another year or
/// country), one whose name isn't the show's (obfuscated), this one (its year or country), one
/// with a year that says nothing either way, or the bare name.
SeriesName seriesNameOf(String title, List<int> packs, UsenetSearchRequest show) {
  final titles = titleWordLists(show);
  final name = [for (final w in words(title).split(' ')) if (w.isNotEmpty) w];
  final own = {for (final t in titles) ...t};
  final marker = name.indexWhere((w) => _isEpisodeNumber(w) || w == 'season');
  final head = marker >= 0 ? name.sublist(0, marker) : name.takeWhile((w) => !releaseTags.contains(w) && !_resolutionWord.hasMatch(w)).toList();
  int? yearAt(int i) {
    if (i < 0 || i >= name.length) return null;
    final w = name[i];
    if (!_isYear(w) || own.contains(w)) return null;
    final next = i + 1 < name.length ? name[i + 1] : null;
    if (next != null && _isYear(next)) return null;
    if (i > 0 && _isYear(name[i - 1]) && !own.contains(name[i - 1])) return null;
    final date = next != null && _dayOrMonth.hasMatch(next) && i + 2 < name.length && _dayOrMonth.hasMatch(name[i + 2]);
    return date ? null : int.parse(w);
  }

  final titleYears = [for (var i = 0; i < head.length; i++) ?yearAt(i)];
  final years = [...titleYears];
  if (marker >= 0) {
    var next = marker;
    while (next < name.length && _isEpisodeNumber(name[next])) {
      next++;
    }
    final y = yearAt(next);
    if (y != null) years.add(y);
  }
  final countries = [for (final w in head) if (!own.contains(w)) ?countryTags[w]];
  final first = show.year;
  bool fits(int y) {
    if (first == null) return true;
    final seasonYear = show.seasonYear;
    if (seasonYear != null) return (y - first).abs() <= 1 || (y - seasonYear).abs() <= 1;
    final last = show.lastYear;
    return y >= first - 1 && (last == null || y <= (last > first ? last : first) + 1);
  }

  final countryOwn = countries.any(show.countries.contains);
  final anotherYear = years.isNotEmpty && !years.any(fits) && packs.length <= 1;
  final namesakes = show.namesakes;
  final anotherCountry = countries.isNotEmpty && !countryOwn && show.countries.isNotEmpty && namesakes != null && namesakes.isNotEmpty;
  if (anotherYear || anotherCountry) return SeriesName.another;
  if (!titles.any((t) => isNamedAs(name, t, series: true))) return SeriesName.unknown;
  if (titleYears.any(fits) || countryOwn) return SeriesName.own;
  if (years.isNotEmpty) return SeriesName.dated;
  return SeriesName.bare;
}

/// A series' releases without those whose names say they are another series of its name.
/// Everything when its first year is unknown.
List<T> seriesResultsOf<T>(UsenetSearchRequest show, List<T> releases, String Function(T) titleOf, List<int> Function(T) packsOf) {
  if (show.year == null) return releases;
  return [for (final r in releases) if (seriesNameOf(titleOf(r), packsOf(r), show) != SeriesName.another) r];
}

/// Minimum votes an older namesake needs, and how many times this series' votes.
const minNamesakeVotes = 10;
const namesakeVoteRatio = 10;

/// When this series is the newer of two of one name and the older is far better known, its
/// bare-named releases are the older series' : they go once one release names this one. Never
/// empties the list by itself.
List<T> withoutNamesakeReleases<T>(UsenetSearchRequest show, List<T> releases, String Function(T) titleOf, List<int> Function(T) packsOf) {
  final year = show.year, votes = show.votes;
  if (year == null || votes == null) return releases;
  final older = (show.namesakes ?? const <UsenetNamesake>[]).any(
    (n) => n.year != null && n.year! < year && n.votes >= minNamesakeVotes && n.votes >= namesakeVoteRatio * votes,
  );
  if (!older) return releases;
  final kinds = [for (final r in releases) seriesNameOf(titleOf(r), packsOf(r), show)];
  if (!kinds.contains(SeriesName.own)) return releases;
  return [for (var i = 0; i < releases.length; i++) if (kinds[i] != SeriesName.bare) releases[i]];
}

// ── what a name says it holds (sorting) ──

/// A release's source, best first.
enum ReleaseQuality { remux, bluray, webDl, webRip, hdtv, dvd, cam, unknown }

extension ReleaseQualityNames on ReleaseQuality {
  /// The name profiles use (`REMUX`, `WEB_DL`).
  String get code => switch (this) {
    ReleaseQuality.remux => 'REMUX',
    ReleaseQuality.bluray => 'BLURAY',
    ReleaseQuality.webDl => 'WEB_DL',
    ReleaseQuality.webRip => 'WEBRIP',
    ReleaseQuality.hdtv => 'HDTV',
    ReleaseQuality.dvd => 'DVD',
    ReleaseQuality.cam => 'CAM',
    ReleaseQuality.unknown => 'UNKNOWN',
  };

  /// What a result's name shows (`Remux`, `WEB-DL`), or null.
  String? get label => switch (this) {
    ReleaseQuality.remux => 'Remux',
    ReleaseQuality.bluray => 'BluRay',
    ReleaseQuality.webDl => 'WEB-DL',
    ReleaseQuality.webRip => 'WEBRip',
    ReleaseQuality.hdtv => 'HDTV',
    ReleaseQuality.dvd => 'DVD',
    ReleaseQuality.cam => 'CAM',
    ReleaseQuality.unknown => null,
  };

  static ReleaseQuality? parse(String code) {
    for (final q in ReleaseQuality.values) {
      if (q.code == code) return q;
    }
    return null;
  }
}

RegExp _token(String v) => RegExp('(?:^|[^a-z0-9])(?:$v)(?:\$|[^a-z0-9])', caseSensitive: false);

final _factsResolution = RegExp(r'(?:^|[^0-9])(2160|1440|1080|720|576|480|360)p?(?:$|[^0-9])');
final _uhd = _token('4k|uhd');
final _cam = _token('cam|hdcam|telesync|telecine|hdts|ts|tc|scr|dvdscr');
final _remux = _token('remux');
final _bluray = _token('blu[ ._-]?ray|b[dr]rip|bdremux|b[dr]mv');
final _webRip = _token('web[ ._-]?rip');
final _webDl = _token('web[ ._-]?dl|webdl');
final _hdtv = _token('hdtv');
final _dvd = _token('dvd|dvdrip|dvdremux');
final _web = _token('web');
final _hevc = _token('hevc|[xh][ ._-]?265|h265');
final _av1 = _token('av1');
final _avc = _token('avc|[xh][ ._-]?264|h264');
final _dv = _token('dv|dovi|dolby[ ._-]?vision');
final _hdr = _token(r'hdr|hdr10|hdr10plus|hdr10\+|hlg');
final _hdrPlus = _token(r'hdr10plus|hdr10\+');
final _sdr = _token('sdr');
final _atmos = _token('atmos');
final _trueHd = _token('true[ ._-]?hd');
final _dtsHd = _token('dts[ ._-]?(?:hd|x)');
final _ddp = _token(r'ddp|e[ ._-]?ac3|dd\+');
final _aac = _token('aac');
final _groupSuffix = RegExp(r'-((?:D-Z0N3)|[a-z0-9][a-z0-9._]{1,31})$', caseSensitive: false);
final _animeGroup = RegExp(r'^\[([a-z][a-z0-9 _-]{1,30})\]', caseSensitive: false);
final _extension = RegExp(r'\.(?:mkv|mp4|m2ts|ts|nzb)$', caseSensitive: false);

/// The language codes and how release names write them.
final languageTokens = <String, RegExp>{
  'en': _token('english|eng|en'),
  'ja': _token('japanese|jpn|ja'),
  'de': _token('german|ger|deu|de'),
  'fr': _token('french|fre|fra|vff|vfq|truefrench|fr'),
  'nl': _token('dutch|nld|nederlands|nl'),
  'es': _token('spanish|spa|castellano|es'),
  'it': _token('italian|ita|it'),
  'pt': _token('portuguese|por|ptbr|pt'),
  'ko': _token('korean|kor|ko'),
  'zh': _token('chinese|chi|zho|mandarin|zh'),
  'hi': _token('hindi|hin|hi'),
  'ru': _token('russian|rus|ru'),
  'uk': _token('ukrainian|ukr'),
  'ar': _token('arabic|ara'),
  'he': _token('hebrew|heb'),
  'pl': _token('polish|pol'),
  'tr': _token('turkish|tur'),
  'multi': _token('multi|multi[ ._-]?audio'),
  'dual': _token('dual|dual[ ._-]?audio'),
};

/// The language codes [text] names (`en`, `ja`, `multi`), in [languageTokens]' order.
List<String> languagesOf(String text) => [
  for (final e in languageTokens.entries)
    if (e.value.hasMatch(text)) e.key,
];

String _bounded(String title) => title.length > 2048 ? title.substring(0, 2048) : title;

/// What a release name says for sorting: resolution, source, codec, HDR, audio, release group
/// and languages.
class RankingFacts {
  RankingFacts._(this.title, this.resolution, this.quality, this.codec, this.visual, this.audio, this.group);

  factory RankingFacts.parse(String title) {
    final bounded = _bounded(title);
    final text = bounded.replaceFirst(_extension, '');
    final r = _factsResolution.firstMatch(text);
    final pixels = r != null ? int.parse(r[1]!) : (_uhd.hasMatch(text) ? 2160 : 0);
    final quality = _cam.hasMatch(text)
        ? ReleaseQuality.cam
        : _remux.hasMatch(text)
        ? ReleaseQuality.remux
        : _bluray.hasMatch(text)
        ? ReleaseQuality.bluray
        : _webRip.hasMatch(text)
        ? ReleaseQuality.webRip
        : _webDl.hasMatch(text)
        ? ReleaseQuality.webDl
        : _hdtv.hasMatch(text)
        ? ReleaseQuality.hdtv
        : _dvd.hasMatch(text)
        ? ReleaseQuality.dvd
        : _web.hasMatch(text)
        ? ReleaseQuality.webDl
        : ReleaseQuality.unknown;
    final dv = _dv.hasMatch(text), hdr = _hdr.hasMatch(text);
    final visual = <String>{
      if (dv) hdr ? 'HDR_DV' : 'DV_ONLY',
      if (dv) 'DV',
      if (hdr) 'HDR',
      if (_hdrPlus.hasMatch(text)) 'HDR10_PLUS',
      if (_sdr.hasMatch(text)) 'SDR',
      if (!dv && !hdr) 'NO_HDR_LABEL',
    };
    final audio = <String>{
      if (_atmos.hasMatch(text)) 'ATMOS',
      if (_trueHd.hasMatch(text)) 'TRUEHD',
      if (_dtsHd.hasMatch(text)) 'DTS_HD',
      if (_ddp.hasMatch(text)) 'DDP',
      if (_aac.hasMatch(text)) 'AAC',
    };
    final group = _groupSuffix.firstMatch(text)?[1] ?? _animeGroup.firstMatch(text)?[1] ?? '';
    final codec = _hevc.hasMatch(text)
        ? 'HEVC'
        : _av1.hasMatch(text)
        ? 'AV1'
        : _avc.hasMatch(text)
        ? 'AVC'
        : 'UNKNOWN';
    return RankingFacts._(bounded, pixels, quality, codec, visual, audio, group);
  }

  /// The name, at most 2048 characters.
  final String title;

  /// 2160, 1440, 1080, 720, 576, 480, 360, or 0 when it doesn't say.
  final int resolution;
  final ReleaseQuality quality;

  /// HEVC, AV1, AVC or UNKNOWN.
  final String codec;

  /// HDR_DV, DV_ONLY, DV, HDR, HDR10_PLUS, SDR, NO_HDR_LABEL.
  final Set<String> visual;

  /// ATMOS, TRUEHD, DTS_HD, DDP, AAC.
  final Set<String> audio;

  /// The release group, or "".
  final String group;

  /// The language codes its name says, read when first asked.
  late final Set<String> languages = languagesOf(title).toSet();
}

// ── what a name says it holds (labels) ──

final _tagYear = RegExp(r'(?<![0-9a-zA-Z])(?:19|20)[0-9]{2}(?![0-9a-zA-Z])');
final _tagEpisode = RegExp(r'(?<![a-z0-9])s[0-9]{1,3}(?:[ ._-]?e[0-9]{1,4})?(?![a-z0-9])', caseSensitive: false);
final _tagResolution = RegExp(r'(?<![0-9a-z])(?:2160|1440|1080|720|576|480|360)[pi](?![a-z0-9])|(?<![a-z0-9])(?:4k|uhd)(?![a-z0-9])', caseSensitive: false);
final _itunes = RegExp(r'(?<![A-Za-z0-9])iT(?![A-Za-z0-9])');

RegExp _label(String v) => RegExp('(?<![a-z0-9])(?:$v)(?![a-z0-9])', caseSensitive: false);

final _services = <(String, RegExp)>[
  ('Prime', _label('amzn')),
  ('Netflix', _label('nf')),
  ('Apple TV+', _label('atvp')),
  ('Disney+', _label('dsnp')),
  ('Max', _label('hmax|max')),
  ('Hulu', _label('hulu')),
  ('Peacock', _label('pcok')),
  ('Paramount+', _label('pmtp')),
  ('Crunchyroll', _label('cr')),
  ('Stan', _label('stan')),
];

RegExp _codecLabel(String v) => RegExp('(?<![a-z0-9])(?:$v)(?:[ ._-]?([1-8])[ ._]([0-2]))?(?![a-z0-9])', caseSensitive: false);

final _audioCodecs = <(String, RegExp)>[
  ('TrueHD', _codecLabel('true[ ._-]?hd')),
  ('DTS:X', _codecLabel('dts[ ._:-]?x')),
  ('DTS-HD MA', _codecLabel('dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?ma')),
  ('DTS-HD', _codecLabel('dts[ ._-]?hd(?:[ ._-]?hra)?')),
  ('DD+', _codecLabel(r'ddp|dd\+|e[ ._-]?ac[ ._-]?3')),
  ('DD', _codecLabel('dd|ac[ ._-]?3')),
  ('DTS', _codecLabel('dts')),
  ('FLAC', _codecLabel('flac')),
  ('LPCM', _codecLabel('l?pcm')),
  ('AAC', _codecLabel('aac')),
  ('Opus', _codecLabel('opus')),
];
final _channels = RegExp(r'(?<![0-9])(?<![0-9][ ._])([1-8])[ ._]([0-2])(?![0-9])(?![ ._][0-9])');
const _layouts = {'1.0', '2.0', '2.1', '5.1', '6.1', '7.1'};
final _channelCount = _label('([2678])ch');
final _atmosLabel = _label('atmos');
final _labelExtension = RegExp(r'\.(?:mkv|mp4|m2ts|ts|nzb)$', caseSensitive: false);
final _trailing = RegExp(r'[-\s]+$');
final _repost = RegExp(
  r'(?:-(?:xpost|repost|postbot|xsp|obfuscated|scrambled|asrequested|alternativetorequested|rakuv[a-z0-9]*|buymore|4p|4planet|chamele0n|whiterev)|\[[^\]]{1,20}\])$',
  caseSensitive: false,
);
final _labelGroup = RegExp(r'-((?:D-Z0N3)|[a-z0-9][a-z0-9._]{1,31})$', caseSensitive: false);
final _webDlEnd = RegExp(r'web-dl$', caseSensitive: false);

/// What a release name says beyond its title: the labels on a result's details line.
class ReleaseLabels {
  ReleaseLabels._(this.service, this.audio, this.languages, this.group);

  factory ReleaseLabels.of(String title) {
    final tags = tagsOf(title);
    String? service;
    if (_itunes.hasMatch(tags)) {
      service = 'iTunes';
    } else {
      for (final (name, re) in _services) {
        if (re.hasMatch(tags)) {
          service = name;
          break;
        }
      }
    }
    String? codec, layout;
    for (final (name, re) in _audioCodecs) {
      final m = re.firstMatch(tags);
      if (m == null) continue;
      codec = name;
      if (m[1] != null) layout = '${m[1]}.${m[2]}';
      break;
    }
    if (layout == null) {
      for (final m in _channels.allMatches(tags)) {
        final l = '${m[1]}.${m[2]}';
        if (_layouts.contains(l)) {
          layout = l;
          break;
        }
      }
    }
    layout ??= switch (_channelCount.firstMatch(tags)?[1]) {
      '2' => '2.0',
      '6' => '5.1',
      '7' => '6.1',
      '8' => '7.1',
      _ => null,
    };
    final audio = [?codec, ?layout, if (_atmosLabel.hasMatch(tags)) 'Atmos'].join(' ');
    final languages = [for (final l in languagesOf(tags.replaceAll(_itunes, ' '))) l.toUpperCase()];
    return ReleaseLabels._(service, audio.isEmpty ? null : audio, languages, _groupOf(title));
  }

  /// Prime, Netflix, Apple TV+, Disney+, Max, Hulu, Peacock, Paramount+, Crunchyroll, Stan or
  /// iTunes.
  final String? service;

  /// `TrueHD 7.1 Atmos`, `DD+ 5.1`, `AAC 2.0`.
  final String? audio;

  /// `DE`, `EN`, `MULTI`.
  final List<String> languages;

  /// The release group, without a reposter's suffix.
  final String? group;

  /// `EN+DE`, or `EN+JA +5` for more than two.
  String? get languagesLabel {
    if (languages.isEmpty) return null;
    if (languages.length <= 2) return languages.join('+');
    return '${languages.take(2).join('+')} +${languages.length - 2}';
  }

  static String? _groupOf(String title) {
    var name = _bounded(title).trim().replaceFirst(_labelExtension, '').replaceFirst(_trailing, '');
    while (true) {
      final next = name.replaceFirst(_repost, '').replaceFirst(_trailing, '');
      if (next == name) break;
      name = next;
    }
    if (_webDlEnd.hasMatch(name)) return null;
    return _labelGroup.firstMatch(name)?[1];
  }
}

/// A release name from where its tags start: its year (after its first character), its season
/// or its resolution, whichever comes first; the whole name when none. Title words (It, Max,
/// Now) are no tags.
String tagsOf(String title) {
  final t = _bounded(title);
  var at = -1;
  for (final m in _tagYear.allMatches(t)) {
    if (m.start > 0) {
      at = m.start;
      break;
    }
  }
  for (final re in [_tagEpisode, _tagResolution]) {
    final m = re.firstMatch(t);
    if (m != null && (at < 0 || m.start < at)) at = m.start;
  }
  return at < 0 ? t : t.substring(at);
}

// ── what a name says it is (filters and badges) ──

final _resolution = RegExp(r'(?<!\d)(2160|1080|720|480|360)p?(?!\d)', caseSensitive: false);
final _fourK = RegExp(r'\b4k\b', caseSensitive: false);
final _lowQuality = RegExp(r'(?:^|[ ._-])(?:cam|hdcam|telesync|telecine|hdts|ts|tc|scr|dvdscr)(?:$|[ ._-])', caseSensitive: false);
final _fullDisc = RegExp(
  r'(?:^|[ ._(\[-])(?:complete[ ._-]+(?:uhd[ ._-]+)?(?:blu-?ray|bd|dvd|mpeg)|bd(?:25|50|66|100)|bdmv|dvd[59]|iso)(?:$|[ ._)\]-])',
  caseSensitive: false,
);
final _notDisc = RegExp(r'(?:^|[ ._-])(?:remux|[xh][ .]?26[45]|av1|re-?encode|[a-z]*rip|web-?dl)(?:$|[ ._-])', caseSensitive: false);
final _dvdDisc = RegExp(r'(?:^|[ ._(\[-])(?:dvd[59r]?|complete[ ._-]+dvd)(?:$|[ ._)\]-])', caseSensitive: false);
final _uhdWord = RegExp(r'(?:^|[ ._(\[-])uhd(?:$|[ ._)\]-])', caseSensitive: false);
final _isoWord = RegExp(r'(?:^|[ ._(\[-])iso(?:$|[ ._)\]-])', caseSensitive: false);

/// A release's resolution for filters and the plain sorts: 2160, 1080, 720, 480, 360 or 0.
int releaseResolution(String title) {
  final m = _resolution.firstMatch(title);
  if (m != null) return int.parse(m[1]!);
  return _fourK.hasMatch(title) ? 2160 : 0;
}

/// A cinema recording, telesync or screener.
bool isLowQuality(String title) => _lowQuality.hasMatch(title);

/// A whole Blu-ray or DVD (its folders or an image), not one video: remuxes and encodes of a
/// disc are single videos.
bool isFullDisc(String title) => _fullDisc.hasMatch(title) && !_notDisc.hasMatch(title);

/// `BLU-RAY`, `UHD BLU-RAY`, `BLU-RAY ISO` or `UHD BLU-RAY ISO` for a whole Blu-ray; null
/// otherwise (and for DVDs).
String? blurayLabelOf(String title) {
  if (!isFullDisc(title) || _dvdDisc.hasMatch(title)) return null;
  final uhd = releaseResolution(title) >= 2160 || _uhdWord.hasMatch(title);
  return '${uhd ? 'UHD BLU-RAY' : 'BLU-RAY'}${_isoWord.hasMatch(title) ? ' ISO' : ''}';
}
