// How the built-in Usenet source puts releases in order: your filters (size, age, resolution,
// cinema recordings, whole discs), then either the plain sort Settings > Usenet names
// ("Current sorting") or a sorting profile: a built-in preset (Balanced, Best quality, Smaller
// files, 1080p / SDR) or your own. A profile sorts by quality tiers, rule scores (well-known
// release groups, lossless audio…), languages and a preferred size, keeps a few of each kind at
// the top for variety, and can leave out what you never want when enough else remains.
//
// Whatever the order, releases known to play come first when you ask for that, and releases
// known to be gone go last.

import 'package:flutter/foundation.dart';

import 'usenet_names.dart';
import 'usenet_pattern.dart';
import 'usenet_release.dart';
import 'usenet_sources.dart';

const _gib = 1073741824.0;

/// What a profile sorts by.
enum RankingKey { tier, score, language, resolution, quality, size, age, indexer, sizePreference }

/// What a profile's rule looks at.
enum RankingField { title, group, quality, resolution, codec, visual, audio, language, indexer, sizeGb, ageDays, mediaType }

/// How a rule's condition compares.
enum RankingOperator { equals, notEquals, contains, matches, atLeast, atMost }

/// What a rule does: adds its score, leaves matching releases out, or keeps only those.
enum RankingAction { boost, exclude, require }

String _code(Enum e) => switch (e) {
  RankingKey.sizePreference => 'SIZE_PREFERENCE',
  RankingField.sizeGb => 'SIZE_GB',
  RankingField.ageDays => 'AGE_DAYS',
  RankingField.mediaType => 'MEDIA_TYPE',
  RankingOperator.equals => 'IS',
  RankingOperator.notEquals => 'IS_NOT',
  RankingOperator.atLeast => 'AT_LEAST',
  RankingOperator.atMost => 'AT_MOST',
  _ => e.name.toUpperCase(),
};

T? _parse<T extends Enum>(List<T> values, Object? code) {
  for (final v in values) {
    if (_code(v) == code) return v;
  }
  return null;
}

/// The name a profile's JSON gives [e] (`SIZE_PREFERENCE`, `IS_NOT`, `REMUX`).
String rankingCode(Enum e) => e is ReleaseQuality ? e.code : _code(e);

/// One quality tier: the resolutions and sources it takes (empty: any).
@immutable
class RankingTier {
  const RankingTier(this.name, {this.resolutions = const [], this.qualities = const []});
  final String name;
  final List<int> resolutions;
  final List<ReleaseQuality> qualities;

  bool takes(RankingFacts f) => (resolutions.isEmpty || resolutions.contains(f.resolution)) && (qualities.isEmpty || qualities.contains(f.quality));

  Map<String, Object?> toJson() => {
    'name': name,
    if (resolutions.isNotEmpty) 'resolutions': resolutions,
    if (qualities.isNotEmpty) 'qualities': [for (final q in qualities) q.code],
  };

  static RankingTier? fromJson(Object? j) {
    if (j is! Map || j['name'] is! String) return null;
    final qualities = <ReleaseQuality>[];
    for (final q in (j['qualities'] as List? ?? const [])) {
      final v = ReleaseQualityNames.parse('$q');
      if (v == null) return null;
      qualities.add(v);
    }
    return RankingTier(
      j['name'] as String,
      resolutions: [for (final r in (j['resolutions'] as List? ?? const [])) if (r is num) r.toInt()],
      qualities: qualities,
    );
  }
}

/// One sorting step, larger first unless not [descending].
@immutable
class RankingSort {
  const RankingSort(this.key, {this.descending = true});
  final RankingKey key;
  final bool descending;

  Map<String, Object?> toJson() => {'key': _code(key), if (!descending) 'descending': false};

  static RankingSort? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = _parse(RankingKey.values, j['key']);
    return key == null ? null : RankingSort(key, descending: j['descending'] as bool? ?? true);
  }
}

const _numericFields = {RankingField.sizeGb, RankingField.ageDays, RankingField.resolution};

/// One condition of a rule: a field, how it compares and the value (a comma-separated list for
/// "is" and "is not", a pattern for "matches").
@immutable
class RankingCondition {
  const RankingCondition(this.field, this.operator, this.value);
  final RankingField field;
  final RankingOperator operator;
  final String value;

  /// Why it can't be saved, or null.
  String? get problem {
    if (value.trim().isEmpty || value.length > 512) return 'Conditions need a value of at most 512 characters.';
    final numeric = _numericFields.contains(field);
    final ordered = operator == RankingOperator.atLeast || operator == RankingOperator.atMost;
    if (numeric ? !(ordered || operator == RankingOperator.equals || operator == RankingOperator.notEquals) : ordered) {
      return 'That comparison is not available for this field.';
    }
    if (numeric) {
      final n = double.tryParse(value.trim());
      if (n == null || !n.isFinite || n < 0) return 'Enter a positive number or zero.';
    }
    if (operator == RankingOperator.matches) {
      if (value.length > 256) return 'Patterns may hold at most 256 characters.';
      if (UsenetPattern.problemOf(value) != null) return 'Invalid pattern. Use regular expressions without lookaround or backreferences.';
    }
    return null;
  }

  Map<String, Object?> toJson() => {'field': _code(field), 'operator': _code(operator), 'value': value};

  static RankingCondition? fromJson(Object? j) {
    if (j is! Map) return null;
    final field = _parse(RankingField.values, j['field'] ?? 'TITLE');
    final op = _parse(RankingOperator.values, j['operator'] ?? 'CONTAINS');
    if (field == null || op == null) return null;
    return RankingCondition(field, op, '${j['value'] ?? ''}');
  }
}

/// A rule of a profile: its conditions (all, or any with [matchAny]) and what it does. A filter
/// ([RankingAction.exclude] or [RankingAction.require]) applies only when at least
/// [minimumRemaining] releases not known to fail would remain (0: always).
@immutable
class RankingRule {
  const RankingRule(
    this.name, {
    this.enabled = true,
    this.action = RankingAction.boost,
    this.score = 100,
    this.matchAny = false,
    this.conditions = const [],
    this.minimumRemaining = 0,
  });
  final String name;
  final bool enabled;
  final RankingAction action;
  final int score;
  final bool matchAny;
  final List<RankingCondition> conditions;
  final int minimumRemaining;

  String? get problem {
    if (name.trim().isEmpty || name.length > 80) return 'Each rule needs a name of at most 80 characters.';
    if (score < -10000 || score > 10000) return 'Rule scores must be between -10000 and 10000.';
    if (conditions.isEmpty || conditions.length > 8) return 'Each rule needs 1 to 8 conditions.';
    if (minimumRemaining < 0 || minimumRemaining > 200) return 'Minimum remaining results must be between 0 and 200.';
    for (final c in conditions) {
      final p = c.problem;
      if (p != null) return p;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'name': name,
    if (!enabled) 'enabled': false,
    if (action != RankingAction.boost) 'action': _code(action),
    if (score != 100) 'score': score,
    if (matchAny) 'matchAny': true,
    'conditions': [for (final c in conditions) c.toJson()],
    if (minimumRemaining != 0) 'minimumRemaining': minimumRemaining,
  };

  static RankingRule? fromJson(Object? j) {
    if (j is! Map) return null;
    final action = _parse(RankingAction.values, j['action'] ?? 'BOOST');
    if (action == null) return null;
    final conditions = <RankingCondition>[];
    for (final c in (j['conditions'] as List? ?? const [])) {
      final v = RankingCondition.fromJson(c);
      if (v == null) return null;
      conditions.add(v);
    }
    return RankingRule(
      '${j['name'] ?? 'New rule'}',
      enabled: j['enabled'] as bool? ?? true,
      action: action,
      score: (j['score'] as num?)?.toInt() ?? 100,
      matchAny: j['matchAny'] as bool? ?? false,
      conditions: conditions,
      minimumRemaining: (j['minimumRemaining'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A sorting profile: data only (tiers, sorting steps, languages, preferred sizes, rules).
@immutable
class RankingProfile {
  const RankingProfile({
    this.version = 1,
    this.name = 'My profile',
    this.tiers = const [],
    this.sort = defaultSort,
    this.preferredLanguages = const [],
    this.preferredMovieSizeGb = 0,
    this.preferredEpisodeSizeGb = 0,
    this.topPerBucket = 3,
    this.rules = const [],
  });

  static const defaultSort = [
    RankingSort(RankingKey.sizePreference),
    RankingSort(RankingKey.tier),
    RankingSort(RankingKey.score),
    RankingSort(RankingKey.language),
    RankingSort(RankingKey.size, descending: false),
  ];

  final int version;
  final String name;
  final List<RankingTier> tiers;
  final List<RankingSort> sort;

  /// Language codes (`en`, `ja`, `multi`), the first preferred most.
  final List<String> preferredLanguages;

  /// GiB a film's or an episode's release should stay under (0: no preference).
  final double preferredMovieSizeGb;
  final double preferredEpisodeSizeGb;

  /// The first this many of each resolution and source lead; the rest follow them (0: none).
  final int topPerBucket;
  final List<RankingRule> rules;

  /// The index of the first tier [f] belongs to, or -1.
  int tierOf(RankingFacts f) => tiers.indexWhere((t) => t.takes(f));

  static const _resolutions = {0, 360, 480, 576, 720, 1080, 1440, 2160};

  /// Why it can't be used, or null.
  String? get problem {
    if (version != 1) return 'Unsupported profile version.';
    if (name.trim().isEmpty || name.length > 80) return 'Profile name must contain 1 to 80 characters.';
    if (tiers.length > 24) return 'Use at most 24 quality tiers.';
    for (final t in tiers) {
      if (t.name.trim().isEmpty || t.name.length > 80) return 'Each tier needs a short name.';
      if (t.resolutions.length > 10 || !t.resolutions.every(_resolutions.contains)) return 'Invalid tier resolution.';
      if (t.qualities.toSet().length != t.qualities.length) return 'A quality appears twice in a tier.';
    }
    if (sort.isEmpty || sort.length > RankingKey.values.length || sort.map((s) => s.key).toSet().length != sort.length) {
      return 'Choose distinct sorting priorities.';
    }
    if (preferredLanguages.length > 24 || !preferredLanguages.every(RegExp(r'^[a-z]{2,8}$').hasMatch)) {
      return 'Languages must use lowercase codes such as en, ja or multi.';
    }
    bool size(double v) => v.isFinite && v >= 0 && v <= 1000;
    if (!size(preferredMovieSizeGb) || !size(preferredEpisodeSizeGb)) return 'Preferred sizes must be between 0 and 1000 GB.';
    if (topPerBucket < 0 || topPerBucket > 20) return 'Results per category must be between 0 and 20; 0 turns the limit off.';
    if (rules.length > 80) return 'Use at most 80 rules.';
    for (var i = 0; i < rules.length; i++) {
      final p = rules[i].problem;
      if (p != null) return 'Rule ${i + 1} (${rules[i].name.length > 80 ? rules[i].name.substring(0, 80) : rules[i].name}): $p';
    }
    return null;
  }

  RankingProfile copyWith({String? name, List<RankingTier>? tiers, List<RankingSort>? sort, List<String>? preferredLanguages, double? preferredMovieSizeGb, double? preferredEpisodeSizeGb, int? topPerBucket, List<RankingRule>? rules}) =>
      RankingProfile(
        version: version,
        name: name ?? this.name,
        tiers: tiers ?? this.tiers,
        sort: sort ?? this.sort,
        preferredLanguages: preferredLanguages ?? this.preferredLanguages,
        preferredMovieSizeGb: preferredMovieSizeGb ?? this.preferredMovieSizeGb,
        preferredEpisodeSizeGb: preferredEpisodeSizeGb ?? this.preferredEpisodeSizeGb,
        topPerBucket: topPerBucket ?? this.topPerBucket,
        rules: rules ?? this.rules,
      );

  /// The JSON kept as UsenetSources.customProfile.
  Map<String, Object?> toJson() => {
    'version': version,
    'name': name,
    if (tiers.isNotEmpty) 'tiers': [for (final t in tiers) t.toJson()],
    'sort': [for (final s in sort) s.toJson()],
    if (preferredLanguages.isNotEmpty) 'preferredLanguages': preferredLanguages,
    if (preferredMovieSizeGb != 0) 'preferredMovieSizeGb': preferredMovieSizeGb,
    if (preferredEpisodeSizeGb != 0) 'preferredEpisodeSizeGb': preferredEpisodeSizeGb,
    'topPerBucket': topPerBucket,
    if (rules.isNotEmpty) 'rules': [for (final r in rules) r.toJson()],
  };

  /// A profile from its JSON, or null when it isn't one (or isn't valid).
  static RankingProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      final tiers = <RankingTier>[];
      for (final t in (j['tiers'] as List? ?? const [])) {
        final v = RankingTier.fromJson(t);
        if (v == null) return null;
        tiers.add(v);
      }
      final sort = <RankingSort>[];
      for (final s in (j['sort'] as List? ?? [for (final s in defaultSort) s.toJson()])) {
        final v = RankingSort.fromJson(s);
        if (v == null) return null;
        sort.add(v);
      }
      final rules = <RankingRule>[];
      for (final r in (j['rules'] as List? ?? const [])) {
        final v = RankingRule.fromJson(r);
        if (v == null) return null;
        rules.add(v);
      }
      final p = RankingProfile(
        version: (j['version'] as num?)?.toInt() ?? 1,
        name: '${j['name'] ?? 'My profile'}',
        tiers: tiers,
        sort: sort,
        preferredLanguages: [for (final l in (j['preferredLanguages'] as List? ?? const [])) '$l'],
        preferredMovieSizeGb: (j['preferredMovieSizeGb'] as num?)?.toDouble() ?? 0,
        preferredEpisodeSizeGb: (j['preferredEpisodeSizeGb'] as num?)?.toDouble() ?? 0,
        topPerBucket: (j['topPerBucket'] as num?)?.toInt() ?? 3,
        rules: rules,
      );
      return p.problem == null ? p : null;
    } catch (_) {
      return null;
    }
  }
}

/// The built-in presets, exactly as they sort.
class RankingPresets {
  RankingPresets._();

  static RankingCondition _is(RankingField f, String v) => RankingCondition(f, RankingOperator.equals, v);

  static RankingRule _groups(String name, String qualities, String groups, int score) =>
      RankingRule(name, score: score, conditions: [_is(RankingField.quality, qualities), _is(RankingField.group, groups)]);

  static const _compressed = 'aXXo,MeGusta,mSD,mHD,nHD,nSD,YIFY,YTS';
  static const upscale = r'(?:^|[ ._-])(?:upscaled?|ai[ ._-]?enhanced|ai[ ._-]?upscale)(?:$|[ ._-])';
  static const repack = r'(?:^|[ ._-])(?:repack[0-9]*|proper[0-9]*)(?:$|[ ._-])';

  /// The rules every preset has.
  static final baseRules = <RankingRule>[
    _groups('Remux • leading groups', 'REMUX', '3L,ATELiER,BiZKiT,BLURANiUM,BMF,CiNEPHiLES,FraMeSToR,PiRAMiDHEAD,PmP,WiLDCAT,ZQ', 300),
    _groups('Remux • established groups', 'REMUX', 'NCmt,playBD,SiCFoI,SURFINBIRD,TEPES', 200),
    _groups('Remux • other recommended groups', 'REMUX', '12GaugeShotgun,decibeL,EPSiLON,HiFi,iFT,KRaLiMaRKo,NTb,PTP,SumVision,TOA,TRiToN', 100),
    _groups(
      'WEB • leading groups',
      'WEB_DL,WEBRIP',
      'ABBIE,AJP69,APEX,PAXA,PEXA,XEPA,BLUTONiUM,BYNDR,CMRG,CRFW,CRUD,FLUX,GNOME,HONE,KiNGS,Kitsune,MADSKY,NOSiViD,NTb,NTG,RAWR,SiC,TEPES,TheFarm,ZoroSenpai',
      300,
    ),
    _groups('WEB • established groups', 'WEB_DL,WEBRIP', 'dB,Flights,MiU,monkee,MZABI,PHOENiX,playWEB,SbR,SMURF,TOMMY,XEBEC,4KBEC,CEBEX', 200),
    _groups('WEB • other recommended groups', 'WEB_DL,WEBRIP', 'BLOOM,Dooky,GNOMiSSiON,NINJACENTRAL,NPMS,ROCCaT,SiGMA,SLiGNOME,SwAgLaNdEr', 100),
    _groups(
      'Blu-ray • leading groups',
      'BLURAY',
      'ATELiER,BBQ,BMF,c0kE,Chotab,CRiSC,CtrlHD,D-Z0N3,Dariush,decibeL,DON,EbP,EDPH,Geek,LolHD,NCmt,PTer,TayTO,TDD,TnP,VietHD,ZQ,ZoroSenpai,MainFrame,W4NK3R',
      250,
    ),
    RankingRule('Avoid heavily compressed groups when alternatives exist', action: RankingAction.exclude, minimumRemaining: 5, conditions: [_is(RankingField.group, _compressed)]),
    const RankingRule(
      'Avoid labelled upscales when alternatives exist',
      action: RankingAction.exclude,
      minimumRemaining: 5,
      conditions: [RankingCondition(RankingField.title, RankingOperator.matches, upscale)],
    ),
    RankingRule('Heavily compressed release group', score: -1000, conditions: [_is(RankingField.group, _compressed)]),
    const RankingRule('Repack / proper', score: 15, conditions: [RankingCondition(RankingField.title, RankingOperator.matches, repack)]),
    RankingRule('Hybrid HDR / Dolby Vision', score: 10, conditions: [_is(RankingField.visual, 'HDR_DV')]),
    RankingRule('Lossless / immersive audio', score: 10, conditions: [_is(RankingField.audio, 'ATMOS,TRUEHD,DTS_HD')]),
    const RankingRule('Upscale / AI label', score: -500, conditions: [RankingCondition(RankingField.title, RankingOperator.matches, upscale)]),
  ];

  static const _hd = [ReleaseQuality.remux, ReleaseQuality.bluray, ReleaseQuality.webDl, ReleaseQuality.webRip, ReleaseQuality.hdtv];

  static const qualityTiers = [
    RankingTier('4K remux', resolutions: [2160], qualities: [ReleaseQuality.remux]),
    RankingTier('4K Blu-ray encode', resolutions: [2160], qualities: [ReleaseQuality.bluray]),
    RankingTier('1080p remux', resolutions: [1080], qualities: [ReleaseQuality.remux]),
    RankingTier('4K WEB-DL', resolutions: [2160], qualities: [ReleaseQuality.webDl]),
    RankingTier('4K WEBRip', resolutions: [2160], qualities: [ReleaseQuality.webRip]),
    RankingTier('1080p Blu-ray encode', resolutions: [1080], qualities: [ReleaseQuality.bluray]),
    RankingTier('1080p WEB-DL', resolutions: [1080], qualities: [ReleaseQuality.webDl]),
    RankingTier('1080p WEBRip', resolutions: [1080], qualities: [ReleaseQuality.webRip]),
    RankingTier('720p and HD', resolutions: [720], qualities: _hd),
    RankingTier('Other known HD', resolutions: [2160, 1440, 1080], qualities: _hd),
  ];

  static const smallerTiers = [
    RankingTier('1080p WEB-DL', resolutions: [1080], qualities: [ReleaseQuality.webDl]),
    RankingTier('1080p WEBRip', resolutions: [1080], qualities: [ReleaseQuality.webRip]),
    RankingTier('1080p Blu-ray encode', resolutions: [1080], qualities: [ReleaseQuality.bluray]),
    RankingTier('4K WEB-DL', resolutions: [2160], qualities: [ReleaseQuality.webDl]),
    RankingTier('4K WEBRip', resolutions: [2160], qualities: [ReleaseQuality.webRip]),
    RankingTier('720p and HD', resolutions: [720], qualities: _hd),
    RankingTier('1080p remux', resolutions: [1080], qualities: [ReleaseQuality.remux]),
    RankingTier('4K Blu-ray encode', resolutions: [2160], qualities: [ReleaseQuality.bluray]),
    RankingTier('4K remux', resolutions: [2160], qualities: [ReleaseQuality.remux]),
  ];

  static const hdSdrTiers = [
    RankingTier('1080p WEB-DL', resolutions: [1080], qualities: [ReleaseQuality.webDl]),
    RankingTier('1080p Blu-ray encode', resolutions: [1080], qualities: [ReleaseQuality.bluray]),
    RankingTier('1080p WEBRip', resolutions: [1080], qualities: [ReleaseQuality.webRip]),
    RankingTier('720p and HD', resolutions: [720], qualities: [ReleaseQuality.webDl, ReleaseQuality.bluray, ReleaseQuality.webRip, ReleaseQuality.hdtv]),
    ...qualityTiers,
  ];

  static final balanced = RankingProfile(name: 'Balanced', tiers: qualityTiers, preferredMovieSizeGb: 30, preferredEpisodeSizeGb: 5, topPerBucket: 3, rules: baseRules);

  static final bestQuality = RankingProfile(
    name: 'Best Quality',
    tiers: qualityTiers,
    topPerBucket: 4,
    sort: const [RankingSort(RankingKey.tier), RankingSort(RankingKey.score), RankingSort(RankingKey.language), RankingSort(RankingKey.size)],
    rules: baseRules,
  );

  static final smallerFiles = RankingProfile(
    name: 'Smaller Files',
    tiers: smallerTiers,
    preferredMovieSizeGb: 12,
    preferredEpisodeSizeGb: 2,
    topPerBucket: 2,
    rules: [...baseRules, RankingRule('Efficient video codec', score: 30, conditions: [_is(RankingField.codec, 'HEVC,AV1')])],
  );

  static final hdSdr = RankingProfile(
    name: '1080p / SDR',
    tiers: hdSdrTiers,
    preferredMovieSizeGb: 12,
    preferredEpisodeSizeGb: 2,
    topPerBucket: 2,
    sort: const [
      RankingSort(RankingKey.score),
      RankingSort(RankingKey.sizePreference),
      RankingSort(RankingKey.tier),
      RankingSort(RankingKey.language),
      RankingSort(RankingKey.size, descending: false),
    ],
    rules: [
      ...baseRules,
      const RankingRule(
        'Prefer HD without HDR or Dolby Vision labels',
        score: 3000,
        conditions: [
          RankingCondition(RankingField.resolution, RankingOperator.atLeast, '720'),
          RankingCondition(RankingField.resolution, RankingOperator.atMost, '1080'),
          RankingCondition(RankingField.visual, RankingOperator.equals, 'NO_HDR_LABEL'),
        ],
      ),
      RankingRule('Prefer AVC video', score: 30, conditions: [_is(RankingField.codec, 'AVC')]),
      RankingRule('Prefer AAC or Dolby Digital Plus audio', score: 20, conditions: [_is(RankingField.audio, 'AAC,DDP')]),
    ],
  );

  /// A new profile of your own: no tiers or rules yet.
  static const custom = RankingProfile();

  /// The preset [p]'s profile (null for Current sorting and Custom).
  static RankingProfile? of(UsenetPreset p) => switch (p) {
    UsenetPreset.balanced => balanced,
    UsenetPreset.bestQuality => bestQuality,
    UsenetPreset.smallerFiles => smallerFiles,
    UsenetPreset.hdSdr => hdSdr,
    UsenetPreset.original || UsenetPreset.custom => null,
  };

  /// The profile [s] sorts by: null for Current sorting; a preset with the preferred language
  /// put first; your own profile (null when it isn't a valid one).
  static RankingProfile? active(UsenetSources s) {
    if (s.preset == UsenetPreset.original) return null;
    if (s.preset == UsenetPreset.custom) return _custom(s.customProfile);
    final p = of(s.preset)!;
    final lang = s.preferredLanguage;
    if (lang.isEmpty) return p;
    return _withLanguage['${s.preset.name}|$lang'] ??=
        p.copyWith(preferredLanguages: [lang], sort: [const RankingSort(RankingKey.language), ...p.sort.where((x) => x.key != RankingKey.language)]);
  }

  static final _withLanguage = <String, RankingProfile>{};

  static Map<String, Object?>? _customJson;
  static RankingProfile? _customProfile;

  static RankingProfile? _custom(Map<String, Object?>? j) {
    if (j == null) return null;
    if (identical(j, _customJson)) return _customProfile;
    _customJson = j;
    return _customProfile = RankingProfile.fromJson(j);
  }
}

/// A release as a profile sees it.
class RankingCandidate<T> {
  RankingCandidate(this.value, this.facts, this.key, {this.sizeBytes, this.publishedAt, this.indexer = '', this.mediaType = 'movie', this.reliability = 1, this.indexerOrder = 0});
  final T value;
  final RankingFacts facts;

  /// Its identity (the NZB's address): the last tie-breaker.
  final String key;

  /// Bytes of one episode or of the film; null when unknown (a pack not yet counted).
  final int? sizeBytes;
  final int? publishedAt;
  final String indexer;

  /// `movie` or `series`.
  final String mediaType;

  /// 0 known to play (first), 1, 2 known to fail (last).
  final int reliability;

  /// Its indexer's place in your list.
  final int indexerOrder;
}

/// A ranked release: its score, its tier's name and the rules it matched, and whether it was
/// moved down for variety.
class RankingResult<T> {
  RankingResult(this.candidate, this.score, this.tier, this.matches, {this.overflow = false});
  final RankingCandidate<T> candidate;
  final int score;
  final String? tier;
  final List<String> matches;
  final bool overflow;
}

class _Condition {
  _Condition(this.source)
      : values = {for (final v in source.value.split(',')) v.trim().toLowerCase()},
        number = double.tryParse(source.value.trim()),
        pattern = source.operator == RankingOperator.matches ? UsenetPattern.tryCompile(source.value) : null,
        lowered = source.value.toLowerCase();
  final RankingCondition source;
  final Set<String> values;
  final double? number;
  final UsenetPattern? pattern;
  final String lowered;

  bool matches<T>(RankingCandidate<T> c, int now) {
    final f = c.facts;
    if (_numericFields.contains(source.field)) {
      final double? v = switch (source.field) {
        RankingField.resolution => f.resolution.toDouble(),
        RankingField.sizeGb => c.sizeBytes == null ? null : c.sizeBytes! / _gib,
        RankingField.ageDays => c.publishedAt == null ? null : (now - c.publishedAt! < 0 ? 0 : now - c.publishedAt!) / 86400000,
        _ => null,
      };
      final n = number;
      if (v == null || n == null) return false;
      return switch (source.operator) {
        RankingOperator.equals => v == n,
        RankingOperator.notEquals => v != n,
        RankingOperator.atLeast => v >= n,
        RankingOperator.atMost => v <= n,
        _ => false,
      };
    }
    final Iterable<String> actual = switch (source.field) {
      RankingField.title => [f.title],
      RankingField.group => [if (f.group.isNotEmpty) f.group],
      RankingField.quality => [f.quality.code],
      RankingField.codec => [f.codec],
      RankingField.visual => f.visual,
      RankingField.audio => f.audio,
      RankingField.language => f.languages,
      RankingField.indexer => [if (c.indexer.isNotEmpty) c.indexer],
      RankingField.mediaType => [c.mediaType],
      _ => const [],
    };
    if (actual.isEmpty) return false;
    return switch (source.operator) {
      RankingOperator.equals => actual.any((a) => values.contains(a.toLowerCase())),
      RankingOperator.notEquals => !actual.any((a) => values.contains(a.toLowerCase())),
      RankingOperator.contains => actual.any((a) => a.toLowerCase().contains(lowered)),
      RankingOperator.matches => pattern != null && actual.any(pattern!.hasMatch),
      _ => false,
    };
  }
}

class _Rule {
  _Rule(this.source) : conditions = [for (final c in source.conditions) _Condition(c)];
  final RankingRule source;
  final List<_Condition> conditions;

  bool matches<T>(RankingCandidate<T> c, int now) =>
      source.matchAny ? conditions.any((x) => x.matches(c, now)) : conditions.every((x) => x.matches(c, now));
}

const _qualityValues = {
  ReleaseQuality.remux: 7,
  ReleaseQuality.bluray: 6,
  ReleaseQuality.webDl: 5,
  ReleaseQuality.webRip: 4,
  ReleaseQuality.hdtv: 3,
  ReleaseQuality.dvd: 2,
  ReleaseQuality.cam: 1,
};

/// A profile compiled (its patterns built once), ranking candidates.
class RankingEngine {
  RankingEngine._(this.profile)
      : _scoring = [for (final r in profile.rules) if (r.enabled && r.action == RankingAction.boost) _Rule(r)],
        _filtering = [for (final r in profile.rules) if (r.enabled && r.action != RankingAction.boost) _Rule(r)];

  final RankingProfile profile;
  final List<_Rule> _scoring;
  final List<_Rule> _filtering;

  static final _cache = <RankingProfile, RankingEngine>{};

  /// [profile]'s engine (the last 8 are kept).
  static RankingEngine of(RankingProfile profile) {
    final hit = _cache.remove(profile);
    final engine = hit ?? RankingEngine._(profile);
    _cache[profile] = engine;
    while (_cache.length > 8) {
      _cache.remove(_cache.keys.first);
    }
    return engine;
  }

  /// [candidates] in the profile's order: its filters, then its sort (known failures last, an
  /// unknown value after a known one either way), then variety.
  List<RankingResult<T>> rank<T>(List<RankingCandidate<T>> candidates, {int? now}) {
    final at = now ?? UsenetClock.nowMs();
    var accepted = candidates;
    for (final rule in _filtering) {
      final keep = rule.source.action == RankingAction.require;
      final filtered = [for (final c in accepted) if (rule.matches(c, at) == keep) c];
      final min = rule.source.minimumRemaining;
      if (min == 0 || filtered.where((c) => c.reliability < 2).length >= min) accepted = filtered;
    }
    final ranked = <(RankingResult<T>, Map<RankingKey, double?>)>[];
    for (final c in accepted) {
      final matching = [for (final r in _scoring) if (r.matches(c, at)) r];
      final score = matching.fold(0, (n, r) => n + r.source.score);
      final tier = profile.tierOf(c.facts);
      final langs = profile.preferredLanguages;
      final language = langs.isEmpty ? -1 : langs.indexWhere(c.facts.languages.contains);
      final preferred = c.mediaType == 'series' ? profile.preferredEpisodeSizeGb : profile.preferredMovieSizeGb;
      final size = c.sizeBytes;
      final keys = <RankingKey, double?>{
        RankingKey.tier: (tier < 0 ? 0 : profile.tiers.length - tier).toDouble(),
        RankingKey.score: score.toDouble(),
        RankingKey.language: (language < 0 ? 0 : langs.length - language).toDouble(),
        RankingKey.sizePreference: preferred > 0 && size != null && size > preferred * _gib ? 0 : 1,
        RankingKey.resolution: c.facts.resolution > 0 ? c.facts.resolution.toDouble() : null,
        RankingKey.quality: _qualityValues[c.facts.quality]?.toDouble(),
        RankingKey.size: size?.toDouble(),
        RankingKey.age: c.publishedAt?.toDouble(),
        RankingKey.indexer: -c.indexerOrder.toDouble(),
      };
      ranked.add((RankingResult(c, score, tier < 0 ? null : profile.tiers[tier].name, [for (final r in matching) r.source.name]), keys));
    }
    ranked.sort((l, r) {
      var d = l.$1.candidate.reliability.compareTo(r.$1.candidate.reliability);
      for (final s in profile.sort) {
        if (d != 0) break;
        final a = l.$2[s.key], b = r.$2[s.key];
        d = a == null && b == null
            ? 0
            : a == null
            ? 1
            : b == null
            ? -1
            : a.compareTo(b) * (s.descending ? -1 : 1);
      }
      if (d == 0) d = l.$1.candidate.facts.title.toLowerCase().compareTo(r.$1.candidate.facts.title.toLowerCase());
      if (d == 0) d = l.$1.candidate.key.compareTo(r.$1.candidate.key);
      return d;
    });
    final results = [for (final r in ranked) r.$1];
    if (profile.topPerBucket == 0) return results;
    final counts = <(int, int, ReleaseQuality), int>{};
    final leaders = <RankingResult<T>>[];
    final overflow = <RankingResult<T>>[];
    for (final r in results) {
      final c = r.candidate;
      final key = (c.reliability, c.facts.resolution, c.facts.quality);
      final n = counts[key] ?? 0;
      counts[key] = n + 1;
      if (n < profile.topPerBucket) {
        leaders.add(r);
      } else {
        overflow.add(RankingResult(c, r.score, r.tier, r.matches, overflow: true));
      }
    }
    return stableSorted([...leaders, ...overflow], (a, b) => a.candidate.reliability.compareTo(b.candidate.reliability));
  }
}

/// [items] sorted by [compare], equal ones kept in their order.
List<T> stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final d = compare(a.$2, b.$2);
    return d != 0 ? d : a.$1.compareTo(b.$1);
  });
  return [for (final x in indexed) x.$2];
}

/// The filters, the order and the limit of Settings > Usenet applied to releases.
class UsenetArrange {
  UsenetArrange._();

  /// [releases] as listed: without what the filters leave out (passworded always), in the
  /// order of the sorting profile or the plain sort, each NZB once, at most the result limit.
  /// [seasonEpisodes]: each season's episode count (a pack's size per episode); [series]: a
  /// series' search; [rank]: 0 known to play (first), 1, 2 known to fail (last).
  static List<UsenetRelease> arrange(
    List<UsenetRelease> releases,
    UsenetSources config, {
    int? now,
    Map<int, int>? seasonEpisodes,
    bool series = false,
    int Function(UsenetRelease r)? rank,
  }) {
    final at = now ?? UsenetClock.nowMs();
    final order = {for (var i = 0; i < config.indexers.length; i++) config.indexers[i].id: i};
    int orderOf(UsenetRelease r) => order[r.indexerId] ?? 0x7FFFFFFF;
    int rankOf(UsenetRelease r) => rank?.call(r) ?? 1;
    final maxBytes = config.maxSizeGb * 1024 * 1024 * 1024;
    final filtered = [
      for (final r in releases)
        if (!r.passworded &&
            !(config.excludeLowQuality && r.lowQuality) &&
            !(config.excludeFullDisc && r.fullDisc) &&
            (config.minResolution == 0 || r.resolution >= config.minResolution) &&
            (config.maxSizeGb == 0 || (r.episodeSize(seasonEpisodes) >= 1 && r.episodeSize(seasonEpisodes) <= maxBytes)) &&
            (config.maxAgeDays == 0 || (r.publishedAt > 0 && at - r.publishedAt <= config.maxAgeDays * 86400000)))
          r,
    ];
    final limit = config.maxResults == 0 ? null : config.maxResults;
    final profile = RankingPresets.active(config);
    if (profile != null) {
      final seen = <String>{};
      final candidates = <RankingCandidate<UsenetRelease>>[];
      for (final r in filtered) {
        if (!seen.add(r.nzbUrl)) continue;
        final size = r.episodeSize(seasonEpisodes);
        candidates.add(
          RankingCandidate(
            r,
            r.facts,
            r.nzbUrl,
            sizeBytes: size > 0 && r.episodeShareKnown(seasonEpisodes) ? size : null,
            publishedAt: r.publishedAt > 0 ? r.publishedAt : null,
            indexer: r.indexerName,
            mediaType: series ? 'series' : 'movie',
            reliability: rankOf(r),
            indexerOrder: orderOf(r),
          ),
        );
      }
      final ranked = RankingEngine.of(profile).rank(candidates, now: at);
      return [for (final x in (limit == null ? ranked : ranked.take(limit))) x.candidate.value];
    }
    int primary(UsenetRelease a, UsenetRelease b) => switch (config.sort) {
      UsenetSort.quality => b.resolution.compareTo(a.resolution),
      UsenetSort.largest => b.episodeSize(seasonEpisodes).compareTo(a.episodeSize(seasonEpisodes)),
      UsenetSort.smallest => _smallFirst(a.episodeSize(seasonEpisodes)).compareTo(_smallFirst(b.episodeSize(seasonEpisodes))),
      UsenetSort.newest => b.publishedAt.compareTo(a.publishedAt),
      UsenetSort.indexer => orderOf(a).compareTo(orderOf(b)),
    };
    final sorted = stableSorted(filtered, (a, b) {
      for (final d in [
        rankOf(a).compareTo(rankOf(b)),
        primary(a, b),
        orderOf(a).compareTo(orderOf(b)),
        b.resolution.compareTo(a.resolution),
        b.episodeSize(seasonEpisodes).compareTo(a.episodeSize(seasonEpisodes)),
        a.title.compareTo(b.title),
        a.nzbUrl.compareTo(b.nzbUrl),
      ]) {
        if (d != 0) return d;
      }
      return 0;
    });
    final seen = <String>{};
    final out = <UsenetRelease>[];
    for (final r in sorted) {
      if (!seen.add(r.nzbUrl)) continue;
      out.add(r);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  static int _smallFirst(int size) => size > 0 ? size : 0x7FFFFFFFFFFFFFFF;

  static final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

  /// One copy of each release several indexers found ("Hide repeated releases"): of those that
  /// pass the filters on their own, the one from the indexer highest in your list.
  static List<UsenetRelease> withoutDuplicates(List<UsenetRelease> releases, UsenetSources config, {int? now, Map<int, int>? seasonEpisodes, bool series = false}) {
    final order = {for (var i = 0; i < config.indexers.length; i++) config.indexers[i].id: i};
    final groups = <String, List<UsenetRelease>>{};
    for (final r in releases) {
      groups.putIfAbsent(r.title.toLowerCase().replaceAll(_nonWord, ' ').trim(), () => []).add(r);
    }
    return [
      for (final copies in groups.values)
        () {
          final passing = [for (final c in copies) if (arrange([c], config, now: now, seasonEpisodes: seasonEpisodes, series: series).isNotEmpty) c];
          final pool = passing.isEmpty ? copies : passing;
          var best = pool.first;
          for (final c in pool.skip(1)) {
            if ((order[c.indexerId] ?? 0x7FFFFFFF) < (order[best.indexerId] ?? 0x7FFFFFFF)) best = c;
          }
          return best;
        }(),
    ];
  }
}
