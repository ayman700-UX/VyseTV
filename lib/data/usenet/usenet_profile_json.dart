// Your own sorting profile for built-in Usenet results, as Settings > Usenet keeps it
// (UsenetSources.customProfile, the JSON usenet_ranking.dart reads): its parts and their names,
// what is wrong with one in words a person can act on, and the shared form a profile is copied
// and pasted in. Settings' profile editor and Edit on your phone both go through here; what a
// profile does to the results is the ranking's (RankingProfile, RankingEngine).

import 'dart:convert';

import 'usenet_pattern.dart' show UsenetPattern;
import 'usenet_ranking.dart' show RankingPresets, RankingProfile;
import 'usenet_sources.dart' show UsenetPreset;

abstract final class UsenetProfileJson {
  /// What each sorting profile does, as Settings says it.
  static String presetDescription(UsenetPreset p) => switch (p) {
    UsenetPreset.original => 'Keeps the sort order chosen below and your search limits.',
    UsenetPreset.balanced => 'Quality tiers and trusted release groups, preferring films under 30 GB and episodes under 5 GB. Larger releases stay available.',
    UsenetPreset.bestQuality => 'Remuxes, high-quality encodes and trusted release groups first. 1080p remuxes rank above 4K WEB-DL. No preferred size.',
    UsenetPreset.smallerFiles => 'Prefers 1080p WEB releases and efficient codecs, with films under 12 GB and episodes under 2 GB. Larger ones stay below.',
    UsenetPreset.hdSdr =>
      'Prefers 1080p and 720p releases without HDR or Dolby Vision labels, with a lift for AVC video and AAC or Dolby Digital Plus sound. '
          "Other formats stay as alternatives. A label can't promise that a release plays.",
    UsenetPreset.custom => 'Your own quality tiers, priorities and scoring rules.',
  };

  /// The audio languages a release name can carry, by code.
  static const languageNames = {
    'en': 'English',
    'ja': 'Japanese',
    'de': 'German',
    'fr': 'French',
    'nl': 'Dutch',
    'es': 'Spanish',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'hi': 'Hindi',
    'ru': 'Russian',
    'uk': 'Ukrainian',
    'ar': 'Arabic',
    'he': 'Hebrew',
    'pl': 'Polish',
    'tr': 'Turkish',
    'multi': 'Multiple audio languages',
    'dual': 'Dual audio',
  };

  static String languageLabel(String code) => code.isEmpty ? 'No language preference' : (languageNames[code] ?? code);

  /// A profile's own name, for lists ("Custom" when it has none).
  static String nameOf(Map<String, Object?>? p) {
    final n = p?['name'];
    return n is String && n.trim().isNotEmpty ? n.trim() : 'Custom';
  }

  /// What a profile can sort by, in the order they are offered.
  static const sortKeys = ['TIER', 'SCORE', 'LANGUAGE', 'RESOLUTION', 'QUALITY', 'SIZE', 'AGE', 'INDEXER', 'SIZE_PREFERENCE'];

  static const keyLabels = {
    'TIER': 'Quality tier',
    'SCORE': 'Rule score',
    'LANGUAGE': 'Preferred language',
    'RESOLUTION': 'Resolution',
    'QUALITY': 'Source quality',
    'SIZE': 'Size',
    'AGE': 'Posted date',
    'INDEXER': 'Indexer priority',
    'SIZE_PREFERENCE': 'Within preferred size',
  };

  /// How each key reads highest first and lowest first.
  static String directionLabel(String key, bool descending) => switch (key) {
    'SIZE' => descending ? 'Largest first' : 'Smallest first',
    'AGE' => descending ? 'Newest first' : 'Oldest first',
    'RESOLUTION' => descending ? 'Highest first' : 'Lowest first',
    'INDEXER' => descending ? 'Highest priority first' : 'Lowest priority first',
    'SIZE_PREFERENCE' => descending ? 'Within the size first' : 'Larger ones first',
    _ => descending ? 'Highest first' : 'Lowest first',
  };

  static const qualities = ['REMUX', 'BLURAY', 'WEB_DL', 'WEBRIP', 'HDTV', 'DVD', 'CAM', 'UNKNOWN'];

  static const qualityLabels = {
    'REMUX': 'Remux',
    'BLURAY': 'Blu-ray',
    'WEB_DL': 'WEB-DL',
    'WEBRIP': 'WEBRip',
    'HDTV': 'HDTV',
    'DVD': 'DVD',
    'CAM': 'CAM',
    'UNKNOWN': 'Unknown',
  };

  /// Resolutions a tier can name (0: none in the release's name).
  static const resolutions = [2160, 1440, 1080, 720, 576, 480, 360, 0];

  static String resolutionLabel(int r) => r == 0 ? 'Unknown' : (r == 2160 ? '4K' : '${r}p');

  static const fields = ['TITLE', 'GROUP', 'QUALITY', 'RESOLUTION', 'CODEC', 'VISUAL', 'AUDIO', 'LANGUAGE', 'INDEXER', 'SIZE_GB', 'AGE_DAYS', 'MEDIA_TYPE'];

  static const fieldLabels = {
    'TITLE': 'Release name',
    'GROUP': 'Release group',
    'QUALITY': 'Source quality',
    'RESOLUTION': 'Resolution',
    'CODEC': 'Video codec',
    'VISUAL': 'Visual tag',
    'AUDIO': 'Audio tag',
    'LANGUAGE': 'Language',
    'INDEXER': 'Indexer name',
    'SIZE_GB': 'Size (GB)',
    'AGE_DAYS': 'Age in days',
    'MEDIA_TYPE': 'Media type',
  };

  /// Fields compared as numbers.
  static const numericFields = {'RESOLUTION', 'SIZE_GB', 'AGE_DAYS'};

  static const operatorLabels = {
    'IS': 'Is one of',
    'IS_NOT': 'Is not one of',
    'CONTAINS': 'Contains',
    'MATCHES': 'Matches regex',
    'AT_LEAST': 'At least',
    'AT_MOST': 'At most',
  };

  /// The comparisons [field] takes.
  static List<String> operatorsFor(String field) => numericFields.contains(field) ? const ['IS', 'IS_NOT', 'AT_LEAST', 'AT_MOST'] : const ['IS', 'IS_NOT', 'CONTAINS', 'MATCHES'];

  static const actions = ['BOOST', 'EXCLUDE', 'REQUIRE'];

  static const actionLabels = {'BOOST': 'Add score', 'EXCLUDE': 'Exclude matches', 'REQUIRE': 'Require matches'};

  /// What a condition's value can be, for the fields with a fixed set.
  static const valuesHint =
      'Use commas between values for Is one of and Is not one of. Quality: REMUX, BLURAY, WEB_DL, WEBRIP, HDTV, DVD, CAM, UNKNOWN. '
      'Codec: HEVC, AVC, AV1, UNKNOWN. Visual: HDR, DV, HDR_DV, DV_ONLY, HDR10_PLUS, SDR, NO_HDR_LABEL (no HDR or Dolby Vision label found). '
      'Audio: ATMOS, TRUEHD, DTS_HD, DDP, AAC. Media type: movie, series. A regex ignores case and has no lookaround or backreferences.';

  /// A profile with nothing of its own yet: no tiers or rules, sorted by the preferred size,
  /// tier, rule score, language, then smallest first.
  static Map<String, Object?> empty() => normalize(RankingPresets.custom.toJson());

  /// The Balanced preset as a profile of your own to change: its quality tiers, its release group
  /// rules and its sizes (30 GB films, 5 GB episodes).
  static Map<String, Object?> balanced() => normalize(RankingPresets.balanced.copyWith(name: 'My profile').toJson());

  static Map<String, Object?> _rule(String name, int score, List<(String, String, String)> conditions) => {
    'name': name,
    'enabled': true,
    'action': 'BOOST',
    'score': score,
    'matchAny': false,
    'conditions': [for (final (f, o, v) in conditions) {'field': f, 'operator': o, 'value': v}],
    'minimumRemaining': 0,
  };

  /// A new rule: adds 100 to releases of a group you name.
  static Map<String, Object?> newRule() => _rule('Rule name', 100, [('GROUP', 'IS', '')]);

  /// A new condition: the release name contains something.
  static Map<String, Object?> newCondition() => {'field': 'TITLE', 'operator': 'CONTAINS', 'value': ''};

  /// A new tier: any resolution, any quality.
  static Map<String, Object?> newTier() => {'name': 'Tier name', 'resolutions': <Object?>[], 'qualities': <Object?>[]};

  /// A copy of [p] that shares nothing with it.
  static Map<String, Object?> copy(Map<String, Object?> p) => (jsonDecode(jsonEncode(p)) as Map).cast<String, Object?>();

  static String _str(Object? v) => v is String ? v : '';
  static List<Object?> _list(Object? v) => v is List ? v : const [];
  static num _num(Object? v, num fallback) => v is num ? v : fallback;

  /// [p] with every part present (a part left out reads as a new profile's), each in its own
  /// type. What is wrong with it stays for [problem] to say.
  static Map<String, Object?> normalize(Map<String, Object?> p) => {
    'version': p['version'] ?? 1,
    'name': p.containsKey('name') ? _str(p['name']) : 'My profile',
    'tiers': [
      for (final t in _list(p['tiers']))
        if (t is Map)
          {
            'name': _str(t['name']),
            'resolutions': [for (final r in _list(t['resolutions'])) if (r is num) r.toInt()],
            'qualities': [for (final q in _list(t['qualities'])) if (q is String) q.toUpperCase()],
          },
    ],
    'sort': p.containsKey('sort')
        ? [
            for (final s in _list(p['sort']))
              if (s is Map) {'key': _str(s['key']), 'descending': s['descending'] is bool ? s['descending'] : true},
          ]
        : [for (final s in RankingProfile.defaultSort) s.toJson()],
    'preferredLanguages': [for (final l in _list(p['preferredLanguages'])) if (l is String) l.trim().toLowerCase()],
    'preferredMovieSizeGb': _num(p['preferredMovieSizeGb'], 0),
    'preferredEpisodeSizeGb': _num(p['preferredEpisodeSizeGb'], 0),
    'topPerBucket': _num(p['topPerBucket'], 3),
    'rules': [
      for (final r in _list(p['rules']))
        if (r is Map)
          {
            'name': r.containsKey('name') ? _str(r['name']) : 'New rule',
            'enabled': r['enabled'] is bool ? r['enabled'] : true,
            'action': r.containsKey('action') ? _str(r['action']) : 'BOOST',
            'score': _num(r['score'], 100),
            'matchAny': r['matchAny'] is bool ? r['matchAny'] : false,
            'conditions': [
              for (final c in _list(r['conditions']))
                if (c is Map)
                  {
                    'field': c.containsKey('field') ? _str(c['field']) : 'TITLE',
                    'operator': c.containsKey('operator') ? _str(c['operator']) : 'CONTAINS',
                    'value': '${c['value'] ?? ''}',
                  },
            ],
            'minimumRemaining': _num(r['minimumRemaining'], 0),
          },
    ],
  };

  /// Why a regex can't be used, or null. Profiles match on a linear-time engine
  /// (UsenetPattern): no lookaround and no backreferences.
  static String? regexProblem(String s) {
    if (s.length > 256) return 'A regex is at most 256 characters.';
    if (RegExp(r'\(\?<?[=!]').hasMatch(s)) return 'A regex here cannot look ahead or behind.';
    if (RegExp(r'\\[1-9]|\\k<').hasMatch(s)) return 'A regex here cannot refer back to a group.';
    final bad = UsenetPattern.problemOf(s);
    return bad == null ? null : "This regex can't be used: $bad";
  }

  static bool _int(Object? v) => v is int || (v is num && v == v.roundToDouble() && v.isFinite);

  /// What is wrong with quality tier [t], or null.
  static String? tierProblem(Map t) {
    final n = _str(t['name']).trim();
    if (n.isEmpty || n.length > 80) return 'Give it a name of 1 to 80 characters.';
    final res = _list(t['resolutions']);
    if (res.length > 10 || res.any((r) => !resolutions.contains(r))) return 'Resolutions are 2160, 1440, 1080, 720, 576, 480, 360 or 0, at most 10.';
    final q = _list(t['qualities']);
    if (q.any((x) => !qualities.contains(x)) || q.toSet().length != q.length) return 'Qualities are ${qualities.join(', ')}, each once.';
    return null;
  }

  /// What is wrong with condition [c], or null.
  static String? conditionProblem(Map c) {
    final field = _str(c['field']);
    final op = _str(c['operator']);
    final value = _str(c['value']);
    if (!fields.contains(field)) return 'Choose what it looks at.';
    if (!operatorsFor(field).contains(op)) return '${fieldLabels[field]} can be ${[for (final o in operatorsFor(field)) operatorLabels[o]!.toLowerCase()].join(', ')}.';
    if (value.trim().isEmpty) return 'Give it a value.';
    if (value.length > 512) return 'A value is at most 512 characters.';
    if (numericFields.contains(field)) {
      final v = num.tryParse(value.trim());
      if (v == null || !v.isFinite || v < 0) return '${fieldLabels[field]} takes one number, 0 or more.';
    }
    if (op == 'MATCHES') return regexProblem(value);
    return null;
  }

  /// What is wrong with rule [r], or null.
  static String? ruleProblem(Map r) {
    final n = _str(r['name']).trim();
    if (n.isEmpty || n.length > 80) return 'Give it a name of 1 to 80 characters.';
    if (!actions.contains(r['action'])) return 'Its action is Add score, Exclude matches or Require matches.';
    final score = r['score'];
    if (!_int(score) || (score as num) < -10000 || score > 10000) return 'The score is -10000 to 10000.';
    final min = r['minimumRemaining'];
    if (!_int(min) || (min as num) < 0 || min > 200) return 'The minimum remaining is 0 to 200.';
    final conditions = _list(r['conditions']);
    if (conditions.isEmpty || conditions.length > 8) return 'Give it 1 to 8 conditions.';
    for (final (j, c) in conditions.indexed) {
      final bad = c is Map ? conditionProblem(c) : 'Choose what it looks at.';
      if (bad != null) return 'Condition ${j + 1}: $bad';
    }
    return null;
  }

  /// What is wrong with profile [p] (a normalized one), in a sentence, or null.
  static String? problem(Map<String, Object?> p) {
    if (p['version'] != 1) return 'Unsupported profile version. Only version 1 can be read.';
    final name = _str(p['name']).trim();
    if (name.isEmpty || name.length > 80) return 'Give the profile a name of 1 to 80 characters.';
    final tiers = _list(p['tiers']);
    if (tiers.length > 24) return 'A profile has at most 24 quality tiers.';
    for (final (i, t) in tiers.indexed) {
      final m = t as Map;
      final n = _str(m['name']).trim();
      final bad = tierProblem(m);
      if (bad != null) return 'Tier ${i + 1}${n.isEmpty ? '' : ' ($n)'}: $bad';
    }
    final sort = _list(p['sort']);
    if (sort.isEmpty) return 'Sort by at least one thing.';
    final keys = [for (final s in sort) _str((s as Map)['key'])];
    if (keys.any((k) => !sortKeys.contains(k))) return 'Sort by ${keyLabels.values.join(', ')} only.';
    if (keys.toSet().length != keys.length) return 'Sort by each thing once.';
    final langs = _list(p['preferredLanguages']);
    if (langs.length > 24) return 'At most 24 preferred languages.';
    if (langs.any((l) => l is! String || !RegExp(r'^[a-z]{2,8}$').hasMatch(l))) return 'Languages are codes of 2 to 8 letters, like en or ja.';
    for (final k in const ['preferredMovieSizeGb', 'preferredEpisodeSizeGb']) {
      final v = p[k];
      if (v is! num || !v.isFinite || v < 0 || v > 1000) return 'Preferred sizes are 0 to 1000 GB.';
    }
    final top = p['topPerBucket'];
    if (!_int(top) || (top as num) < 0 || top > 20) return 'Top results per category is 0 to 20.';
    final rules = _list(p['rules']);
    if (rules.length > 80) return 'A profile has at most 80 rules.';
    for (final (i, r) in rules.indexed) {
      final m = r as Map;
      final n = _str(m['name']).trim();
      final bad = ruleProblem(m);
      if (bad != null) return 'Rule ${i + 1}${n.isEmpty ? '' : ' ($n)'}: $bad';
    }
    // what the ranking itself reads is what is kept
    if (RankingProfile.fromJson(p) == null) return "This profile can't be used. Check its tiers and rules.";
    return null;
  }

  static const format = 'vysetv.sorting-profile';

  /// [p] as text to keep or share: no provider passwords or indexer keys are in a profile.
  static String export(Map<String, Object?> p) => const JsonEncoder.withIndent('  ').convert({'format': format, 'version': 1, 'profile': p});

  /// The profile in pasted [text] (shared from VyseTV, or a bare profile), normalized, or why it
  /// can't be read.
  static ({Map<String, Object?>? profile, String? problem}) parse(String text) {
    if (text.length > 60000) return (profile: null, problem: 'That is too long for a sorting profile.');
    Object? j;
    try {
      j = jsonDecode(text.trim());
    } catch (_) {
      return (profile: null, problem: "That isn't a sorting profile. Paste all of what was copied.");
    }
    if (j is! Map) return (profile: null, problem: "That isn't a sorting profile. Paste all of what was copied.");
    Object? inner = j;
    if (j.containsKey('profile')) {
      final f = j['format'];
      if (f is! String || !(f.endsWith('sorting-profile') || f.endsWith('stream-ranking'))) return (profile: null, problem: "That isn't a sorting profile.");
      if (j['version'] != 1) return (profile: null, problem: 'Unsupported profile version. Only version 1 can be read.');
      inner = j['profile'];
    }
    if (inner is! Map) return (profile: null, problem: "That isn't a sorting profile.");
    final p = normalize(inner.cast<String, Object?>());
    final bad = problem(p);
    return bad == null ? (profile: p, problem: null) : (profile: null, problem: bad);
  }

  /// "3 tiers, 5 rules".
  static String summary(Map<String, Object?> p) {
    final t = _list(p['tiers']).length, r = _list(p['rules']).length;
    return '$t ${t == 1 ? 'tier' : 'tiers'}, $r ${r == 1 ? 'rule' : 'rules'}';
  }
}
