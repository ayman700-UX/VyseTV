// Your Usenet providers (NNTP servers) and Newznab indexers, and how their search results are
// filtered and sorted: Settings > Usenet. Kept whole in the system keychain (passwords and API
// keys are in it), on this device only: never in plain settings, never synced to your account.
//
// The list order is the hierarchy: providers and indexers are each kept sorted by priority (1 is
// the highest), your own order kept within a priority.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

String _uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// A Usenet provider: an NNTP server and your account on it.
@immutable
class UsenetProvider {
  UsenetProvider({
    String? id,
    this.name = '',
    this.host = '',
    this.port = 563,
    this.tls = true,
    this.username = '',
    this.password = '',
    this.connections = 20,
    this.enabled = true,
    this.priority = 1,
  }) : id = id ?? _uuid();

  final String id;
  final String name;
  final String host;
  final int port;
  final bool tls;
  final String username;
  final String password;

  /// Its connection allowance: how many connections the account allows (1 to 4096).
  final int connections;
  final bool enabled;

  /// 1 (highest) to 5. Providers of one priority share the work; lower ones are backups, asked
  /// only for articles every higher one lacked.
  final int priority;

  static const invalidText = 'Check the name, host, port (1–65535), credentials and connections (1–4096).';

  /// Why it can't be saved or tested, or null.
  String? get problem {
    if (name.trim().isEmpty || host.trim().isEmpty) return invalidText;
    if (port < 1 || port > 65535 || connections < 1 || connections > 4096 || priority < 1 || priority > 5) return invalidText;
    if (RegExp(r'[\s/@?#]').hasMatch(host.trim())) return invalidText;
    if (username.contains(':')) return invalidText;
    if (RegExp('[\r\n\u0000]').hasMatch(username + password)) return invalidText;
    if (Uri.tryParse(serverUrl) == null) return invalidText;
    return null;
  }

  /// The host as an address part: an IPv6 literal in brackets.
  String get _hostPart {
    final h = host.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    return h.contains(':') ? '[$h]' : h;
  }

  static String _enc(String s) => Uri.encodeQueryComponent(s).replaceAll('+', '%20');

  /// What the engine is given: `nntps://user:pass@host:port/connections?priority=N`.
  String get serverUrl {
    final auth = username.isEmpty && password.isEmpty ? '' : '${_enc(username)}:${_enc(password)}@';
    return '${tls ? 'nntps' : 'nntp'}://$auth$_hostPart:$port/$connections?priority=$priority';
  }

  /// The server this account is on: a saved password is kept for the same one only.
  String get identity => '${host.trim().toLowerCase()}|$port|$tls|$username';

  UsenetProvider copyWith({String? name, String? host, int? port, bool? tls, String? username, String? password, int? connections, bool? enabled, int? priority}) =>
      UsenetProvider(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        tls: tls ?? this.tls,
        username: username ?? this.username,
        password: password ?? this.password,
        connections: connections ?? this.connections,
        enabled: enabled ?? this.enabled,
        priority: priority ?? this.priority,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    if (port != 563) 'port': port,
    if (!tls) 'tls': false,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
    if (connections != 20) 'connections': connections,
    if (!enabled) 'enabled': false,
    if (priority != 1) 'priority': priority,
  };

  static UsenetProvider fromJson(Map j) => UsenetProvider(
    id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
    name: '${j['name'] ?? ''}',
    host: '${j['host'] ?? ''}',
    port: (j['port'] as num?)?.toInt() ?? 563,
    tls: j['tls'] as bool? ?? true,
    username: '${j['username'] ?? ''}',
    password: '${j['password'] ?? ''}',
    connections: (j['connections'] as num?)?.toInt() ?? 20,
    enabled: j['enabled'] as bool? ?? true,
    priority: ((j['priority'] as num?)?.toInt() ?? 1).clamp(1, 5),
  );
}

/// A Newznab indexer: where releases are searched, with your API key.
@immutable
class UsenetIndexer {
  UsenetIndexer({
    String? id,
    this.name = '',
    this.apiUrl = '',
    this.apiPath = '',
    this.apiKey = '',
    this.enabled = true,
    this.priority = 1,
    this.fetchLimit,
  }) : id = id ?? _uuid();

  final String id;

  /// Shown on the details line of each release it finds, and in its failure notes.
  final String name;
  final String apiUrl;

  /// Added to [apiUrl] to make the Newznab endpoint ("/api" for a new one; empty: the URL is the
  /// whole endpoint, as indexers saved before the field have it).
  final String apiPath;
  final String apiKey;
  final bool enabled;
  final int priority;

  /// Results read per search: null = Settings' default, 0 = every page, else 1 to 1000.
  final int? fetchLimit;

  static const invalidText = 'Enter a name, a valid HTTP or HTTPS URL and an API path such as /api.';

  static const fetchChoices = <int?>[null, 100, 200, 500, 1000, 0];

  static String fetchLabel(int? n) => switch (n) {
    null => 'Default',
    0 => 'Unlimited',
    _ => '$n',
  };

  /// The Newznab endpoint: [apiUrl] with [apiPath] added (unless it already ends with it), its own
  /// query parameters kept. Null when it isn't a usable http(s) address.
  Uri? get endpoint {
    final u = Uri.tryParse(apiUrl.trim());
    if (u == null || (u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty || u.userInfo.isNotEmpty || u.hasFragment) return null;
    final path = apiPath.trim();
    if (path.isEmpty) return u;
    if (RegExp(r'[?#\\\s]').hasMatch(path)) return null;
    final segs = [for (final s in path.split('/')) if (s.isNotEmpty) s];
    if (segs.any((s) => s == '.' || s == '..')) return null;
    if (segs.isEmpty) return u;
    final have = [for (final s in u.pathSegments) if (s.isNotEmpty) s];
    if (have.length >= segs.length && listEquals(have.sublist(have.length - segs.length), segs)) return u;
    return u.replace(pathSegments: [...have, ...segs]);
  }

  /// The endpoint as lists show it: nothing after "?", where keys can be.
  String get shownEndpoint {
    final e = apiPath.trim().isEmpty ? apiUrl.trim() : (endpoint?.toString() ?? apiUrl.trim());
    final q = e.indexOf('?');
    return q < 0 ? e : e.substring(0, q);
  }

  String? get problem {
    if (name.trim().isEmpty || endpoint == null) return invalidText;
    if (priority < 1 || priority > 5) return invalidText;
    final f = fetchLimit;
    if (f != null && (f < 0 || f > 1000)) return invalidText;
    return null;
  }

  /// The server this key is for: a saved key is kept for the same endpoint only.
  String get identity => endpoint?.toString() ?? apiUrl.trim();

  UsenetIndexer copyWith({String? name, String? apiUrl, String? apiPath, String? apiKey, bool? enabled, int? priority, int? Function()? fetchLimit}) => UsenetIndexer(
    id: id,
    name: name ?? this.name,
    apiUrl: apiUrl ?? this.apiUrl,
    apiPath: apiPath ?? this.apiPath,
    apiKey: apiKey ?? this.apiKey,
    enabled: enabled ?? this.enabled,
    priority: priority ?? this.priority,
    fetchLimit: fetchLimit != null ? fetchLimit() : this.fetchLimit,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'apiUrl': apiUrl,
    if (apiPath.isNotEmpty) 'apiPath': apiPath,
    if (apiKey.isNotEmpty) 'apiKey': apiKey,
    if (!enabled) 'enabled': false,
    if (priority != 1) 'priority': priority,
    'fetchLimit': ?fetchLimit,
  };

  static UsenetIndexer fromJson(Map j) => UsenetIndexer(
    id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
    name: '${j['name'] ?? ''}',
    apiUrl: '${j['apiUrl'] ?? ''}',
    apiPath: '${j['apiPath'] ?? ''}',
    apiKey: '${j['apiKey'] ?? ''}',
    enabled: j['enabled'] as bool? ?? true,
    priority: ((j['priority'] as num?)?.toInt() ?? 1).clamp(1, 5),
    fetchLimit: (j['fetchLimit'] as num?)?.toInt(),
  );
}

/// How results are sorted when no sorting profile is chosen ("Current sorting").
enum UsenetSort {
  quality('Quality'),
  largest('Largest first'),
  smallest('Smallest first'),
  newest('Newest first'),
  indexer('Indexer priority');

  const UsenetSort(this.label);
  final String label;
}

/// The sorting profile: none ("Current sorting", with [UsenetSort]), a built-in preset, or your
/// own (lib/data/usenet/usenet_ranking.dart has what each does).
enum UsenetPreset {
  original('Current sorting'),
  balanced('Balanced'),
  bestQuality('Best quality'),
  smallerFiles('Smaller files'),
  hdSdr('1080p / SDR'),
  custom('Custom');

  const UsenetPreset(this.label);
  final String label;
}

/// Everything Settings > Usenet keeps in the keychain.
@immutable
class UsenetSources {
  const UsenetSources({
    this.firstUseAccepted = false,
    this.providers = const [],
    this.indexers = const [],
    this.sort = UsenetSort.quality,
    this.preset = UsenetPreset.original,
    this.customProfile,
    this.preferredLanguage = '',
    this.minResolution = 0,
    this.maxSizeGb = 0,
    this.maxAgeDays = 0,
    this.maxResults = 50,
    this.defaultFetch = 200,
    this.excludeLowQuality = true,
    this.excludeFullDisc = false,
    this.indexerFallback = false,
    this.hideDuplicates = false,
    this.showReleaseNames = true,
    this.availableFirst = false,
    this.progressiveResults = false,
  });

  /// The notice saying what using your own indexers and providers from this device means was
  /// read and accepted (shown the first time Usenet is turned on).
  final bool firstUseAccepted;
  final List<UsenetProvider> providers;
  final List<UsenetIndexer> indexers;
  final UsenetSort sort;
  final UsenetPreset preset;

  /// Your own sorting profile (JSON, usenet_ranking.dart), kept when another preset is chosen.
  final Map<String, Object?>? customProfile;

  /// "" or a language code put first by a built-in preset.
  final String preferredLanguage;

  /// 0 (no limit), 480, 720, 1080 or 2160.
  final int minResolution;

  /// GiB, 0 = no limit.
  final int maxSizeGb;

  /// Days, 0 = no limit.
  final int maxAgeDays;

  /// Results shown in all (after filters and sorting), 0 = no limit.
  final int maxResults;

  /// Results read per search from an indexer that says nothing of its own: 0 = Automatic, else
  /// 1 to 1000.
  final int defaultFetch;
  final bool excludeLowQuality;
  final bool excludeFullDisc;
  final bool indexerFallback;
  final bool hideDuplicates;
  final bool showReleaseNames;
  final bool availableFirst;
  final bool progressiveResults;

  static const maxProviders = 64;
  static const maxIndexers = 20;
  static const maxTotalConnections = 4096;
  static const languages = ['en', 'ja', 'de', 'fr', 'nl', 'es', 'it', 'pt', 'ko', 'zh', 'hi', 'ru', 'uk', 'ar', 'he', 'pl', 'tr', 'multi', 'dual'];

  /// At least one enabled provider and one enabled indexer.
  bool get usable => providers.any((p) => p.enabled) && indexers.any((i) => i.enabled);

  /// Something set up, enabled or not.
  bool get configured => providers.isNotEmpty && indexers.isNotEmpty;

  /// The results each indexer is asked for per search by default.
  int get defaultFetchLimit => defaultFetch >= 1 && defaultFetch <= 1000 ? defaultFetch : (maxResults == 0 ? 1000 : max(200, maxResults));

  /// What [i] is asked for per search: 0 = every page.
  int fetchFor(UsenetIndexer i) => i.fetchLimit ?? defaultFetchLimit;

  /// The enabled providers' addresses, for the engine, in the hierarchy's order.
  List<String> get serverUrls => [for (final p in providers) if (p.enabled) p.serverUrl];

  String? get problem {
    for (final p in providers) {
      if (p.problem != null) return p.problem;
    }
    for (final i in indexers) {
      if (i.problem != null) return i.problem;
    }
    final total = providers.where((p) => p.enabled).fold(0, (n, p) => n + p.connections);
    if (total > maxTotalConnections) return 'Total connections exceed $maxTotalConnections.';
    if (preset == UsenetPreset.custom && customProfile == null) return 'Save a custom profile before selecting it.';
    if (preferredLanguage.isNotEmpty && !languages.contains(preferredLanguage)) return 'Choose a supported language.';
    return null;
  }

  /// Providers and indexers each in priority order, your order kept within a priority.
  UsenetSources normalized() {
    List<T> byPriority<T>(List<T> l, int Function(T) p) {
      final indexed = [for (var i = 0; i < l.length; i++) (i, l[i])];
      indexed.sort((a, b) {
        final c = p(a.$2).compareTo(p(b.$2));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
      return [for (final x in indexed) x.$2];
    }

    return copyWith(providers: byPriority(providers, (p) => p.priority), indexers: byPriority(indexers, (i) => i.priority));
  }

  UsenetSources copyWith({
    bool? firstUseAccepted,
    List<UsenetProvider>? providers,
    List<UsenetIndexer>? indexers,
    UsenetSort? sort,
    UsenetPreset? preset,
    Map<String, Object?>? Function()? customProfile,
    String? preferredLanguage,
    int? minResolution,
    int? maxSizeGb,
    int? maxAgeDays,
    int? maxResults,
    int? defaultFetch,
    bool? excludeLowQuality,
    bool? excludeFullDisc,
    bool? indexerFallback,
    bool? hideDuplicates,
    bool? showReleaseNames,
    bool? availableFirst,
    bool? progressiveResults,
  }) => UsenetSources(
    firstUseAccepted: firstUseAccepted ?? this.firstUseAccepted,
    providers: providers ?? this.providers,
    indexers: indexers ?? this.indexers,
    sort: sort ?? this.sort,
    preset: preset ?? this.preset,
    customProfile: customProfile != null ? customProfile() : this.customProfile,
    preferredLanguage: preferredLanguage ?? this.preferredLanguage,
    minResolution: minResolution ?? this.minResolution,
    maxSizeGb: maxSizeGb ?? this.maxSizeGb,
    maxAgeDays: maxAgeDays ?? this.maxAgeDays,
    maxResults: maxResults ?? this.maxResults,
    defaultFetch: defaultFetch ?? this.defaultFetch,
    excludeLowQuality: excludeLowQuality ?? this.excludeLowQuality,
    excludeFullDisc: excludeFullDisc ?? this.excludeFullDisc,
    indexerFallback: indexerFallback ?? this.indexerFallback,
    hideDuplicates: hideDuplicates ?? this.hideDuplicates,
    showReleaseNames: showReleaseNames ?? this.showReleaseNames,
    availableFirst: availableFirst ?? this.availableFirst,
    progressiveResults: progressiveResults ?? this.progressiveResults,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    if (firstUseAccepted) 'firstUseAccepted': true,
    'providers': [for (final p in providers) p.toJson()],
    'indexers': [for (final i in indexers) i.toJson()],
    if (sort != UsenetSort.quality) 'sort': sort.name,
    if (preset != UsenetPreset.original) 'preset': preset.name,
    'customProfile': ?customProfile,
    if (preferredLanguage.isNotEmpty) 'preferredLanguage': preferredLanguage,
    if (minResolution != 0) 'minResolution': minResolution,
    if (maxSizeGb != 0) 'maxSizeGb': maxSizeGb,
    if (maxAgeDays != 0) 'maxAgeDays': maxAgeDays,
    if (maxResults != 50) 'maxResults': maxResults,
    if (defaultFetch != 200) 'defaultFetch': defaultFetch,
    if (!excludeLowQuality) 'excludeLowQuality': false,
    if (excludeFullDisc) 'excludeFullDisc': true,
    if (indexerFallback) 'indexerFallback': true,
    if (hideDuplicates) 'hideDuplicates': true,
    if (!showReleaseNames) 'showReleaseNames': false,
    if (availableFirst) 'availableFirst': true,
    if (progressiveResults) 'progressiveResults': true,
  };

  static UsenetSources fromJson(Map j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) => values.where((v) => v.name == name).firstOrNull ?? fallback;
    int num_(String k, int fallback, int lo, int hi) => ((j[k] as num?)?.toInt() ?? fallback).clamp(lo, hi);
    return UsenetSources(
      firstUseAccepted: j['firstUseAccepted'] as bool? ?? false,
      providers: [for (final p in (j['providers'] as List? ?? const []).whereType<Map>()) UsenetProvider.fromJson(p)].take(maxProviders).toList(),
      indexers: [for (final i in (j['indexers'] as List? ?? const []).whereType<Map>()) UsenetIndexer.fromJson(i)].take(maxIndexers).toList(),
      sort: pick(UsenetSort.values, j['sort'], UsenetSort.quality),
      preset: pick(UsenetPreset.values, j['preset'], UsenetPreset.original),
      customProfile: (j['customProfile'] as Map?)?.cast<String, Object?>(),
      preferredLanguage: languages.contains(j['preferredLanguage']) ? '${j['preferredLanguage']}' : '',
      minResolution: const [0, 480, 720, 1080, 2160].contains(j['minResolution']) ? j['minResolution'] as int : 0,
      maxSizeGb: num_('maxSizeGb', 0, 0, 1000),
      maxAgeDays: num_('maxAgeDays', 0, 0, 10000),
      maxResults: num_('maxResults', 50, 0, 500),
      defaultFetch: num_('defaultFetch', 200, 0, 1000),
      excludeLowQuality: j['excludeLowQuality'] as bool? ?? true,
      excludeFullDisc: j['excludeFullDisc'] as bool? ?? false,
      indexerFallback: j['indexerFallback'] as bool? ?? false,
      hideDuplicates: j['hideDuplicates'] as bool? ?? false,
      showReleaseNames: j['showReleaseNames'] as bool? ?? true,
      availableFirst: j['availableFirst'] as bool? ?? false,
      progressiveResults: j['progressiveResults'] as bool? ?? false,
    ).normalized();
  }
}

/// The keychain store of [UsenetSources], and the copy in use.
class UsenetSourcesStore {
  UsenetSourcesStore._();

  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  static const _key = 'usenet.sources.v1';

  /// What Settings > Usenet holds now (empty until [load]).
  static final current = ValueNotifier<UsenetSources>(const UsenetSources());
  static Future<void>? _loading;

  /// Whether the keychain could not be read: then nothing is written over it.
  static bool unreadable = false;

  static Future<void> load() => _loading ??= () async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null && raw.isNotEmpty) current.value = UsenetSources.fromJson(jsonDecode(raw) as Map);
      unreadable = false;
    } catch (_) {
      unreadable = true;
    }
  }();

  /// Saves [s] (put in the hierarchy's order first). Answers why it can't be, or null.
  static Future<String?> save(UsenetSources s) async {
    final n = s.normalized();
    final problem = n.problem;
    if (problem != null) return problem;
    if (n.providers.length > UsenetSources.maxProviders) return 'At most ${UsenetSources.maxProviders} providers.';
    if (n.indexers.length > UsenetSources.maxIndexers) return 'At most ${UsenetSources.maxIndexers} indexers.';
    if (unreadable) return "The keychain couldn't be read, so nothing was saved over it.";
    current.value = n;
    try {
      await _storage.write(key: _key, value: jsonEncode(n.toJson()));
    } catch (_) {
      return "Saved for now, but the keychain didn't take it: it will be gone after a restart.";
    }
    return null;
  }

  /// Forgets everything (Danger Zone).
  static Future<void> clear() async {
    current.value = const UsenetSources();
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }

  @visibleForTesting
  static void debugSet(UsenetSources s) {
    current.value = s.normalized();
    _loading = Future.value();
  }
}
