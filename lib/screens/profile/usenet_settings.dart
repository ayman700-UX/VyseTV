part of 'profile_page.dart';

// ───────────────────────── Usenet ─────────────────────────
//
// Settings → Usenet: built-in Usenet, VyseTV's own source of Usenet releases. Your Newznab
// indexers are searched from this device, and what they find plays straight from your NNTP
// providers through the Usenet engine (lib/data/usenet). The master switch is the built-in
// Usenet addon's own on and off (Settings → Addons shows the same one). Providers, indexers,
// filters and sorting are kept in the keychain (UsenetSourcesStore); the engine's settings are
// this device's (AppSettings.usenet*). Every change is saved as it is made.

const _usenetGood = Color(0xFF3DDC97);
const _usenetCaution = Color(0xFFFFC23A);

const _usenetProviderHint = 'Providers of the same priority share the work. Lower priorities are only asked for articles the higher ones are missing.';
const _usenetIndexerHint = "Enter the indexer's address; the API path (usually /api) is added to it. Newznab indexers work, and Prowlarr and NZBHydra too.";
const _usenetIndexerPriorityHint =
    'Priority orders your indexers. It decides which copy of a repeated release is kept when Hide repeated releases is on, '
    'and which indexers are searched first when Search lower priorities only as fallback is on.';
const _usenetFetchHint =
    'Results read per search from this indexer before the filters. Unlimited reads every page there is, which can take longer and uses more API hits. '
    'NZBHydra counts as one indexer.';

/// Why the last save of your Usenet sources didn't go through, for the line under them.
final _usenetSaveError = ValueNotifier<String?>(null);

/// Whether built-in Usenet is on: the built-in addon's own switch.
bool get _usenetOn => Addons.list.value.where((a) => a.manifestUrl == Addon.usenet.manifestUrl).firstOrNull?.enabled ?? false;

String _usenetPriorityLabel(int n) => n == 1 ? '1 (highest)' : (n == 5 ? '5 (lowest)' : '$n');

final _usenetPriorities = [for (var n = 1; n <= 5; n++) (n, _usenetPriorityLabel(n))];

/// Saves [next] as your Usenet sources. Null when it was saved, or when it took effect but the
/// keychain didn't keep it (the line under the sources says so). Otherwise why it wasn't saved:
/// [own] callers show that themselves (an editor, under its fields); for the rest the line does.
Future<String?> _storeUsenet(UsenetSources next, {bool own = false}) async {
  final problem = await UsenetSourcesStore.save(next);
  if (problem == null) {
    _usenetSaveError.value = null;
    return null;
  }
  final applied = jsonEncode(UsenetSourcesStore.current.value.toJson()) == jsonEncode(next.normalized().toJson());
  if (applied || !own) _usenetSaveError.value = problem;
  return applied ? null : problem;
}

/// Turns built-in Usenet on or off, here or in Settings → Addons. The first time it goes on, a
/// notice says what using your own indexers and providers from this device means: Cancel leaves
/// it off (and the notice comes again next time). Turning it off never asks.
Future<void> _setUsenetOn(BuildContext context, bool on) async {
  if (!on) {
    Addons.setEnabled(Addon.usenet, false);
    return;
  }
  await UsenetSourcesStore.load();
  if (!UsenetSourcesStore.current.value.firstUseAccepted) {
    if (!context.mounted) return;
    final yes = await showDialog<bool>(context: context, builder: (_) => const _UsenetNotice()) ?? false;
    if (!yes) return;
    final problem = await _storeUsenet(UsenetSourcesStore.current.value.copyWith(firstUseAccepted: true), own: true);
    if (problem != null) {
      if (context.mounted) showToast(context, Text(problem, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)), icon: Icons.error_outline_rounded);
      return;
    }
  }
  Addons.setEnabled(Addon.usenet, true);
}

/// Settings → Addons: the built-in Usenet row's switch goes through [_setUsenetOn] (the notice);
/// every other addon's is set as it is.
void _setAddonOn(BuildContext context, Addon a, bool on) {
  if (a.manifestUrl == Addon.usenet.manifestUrl) {
    unawaited(_setUsenetOn(context, on));
  } else {
    Addons.setEnabled(a, on);
  }
}

/// Settings → Addons → Usenet's settings button: this page's Usenet tab.
void _openUsenetTab(BuildContext context) => context.findAncestorStateOfType<_ProfilePageState>()?._pick(_Tab.usenet);

/// A sheet of fields: a dialog, or on a phone a sheet from the bottom (on the root navigator,
/// so the navbar never covers its foot).
Future<T?> _showUsenetSheet<T>(BuildContext context, Widget child, {double maxWidth = 540}) {
  if (Layout.isPhone(context)) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF0B0D16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (context) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: child),
    );
  }
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .65),
    builder: (context) => Dialog(
      backgroundColor: const Color(0xFF0B0D16),
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: VyseColors.stroke)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    ),
  );
}

/// One of a few values, in a list: the one in use is ticked, and a D-pad starts on it. Answers
/// the value picked (in a record, as it can be null), or null when closed.
Future<(T,)?> _pickOne<T>(BuildContext context, {required String title, String? subtitle, required List<(T, String)> options, required T current}) => showDialog<(T,)>(
  context: context,
  builder: (ctx) => _UDialog(
    title: title,
    subtitle: subtitle,
    close: 'Cancel',
    children: [
      for (final (v, label) in options)
        DpadStart(
          start: v == current,
          child: _UOption(
            title: label,
            selected: v == current,
            trailing: v == current ? const Icon(Icons.check_rounded, size: 18, color: VyseColors.accent) : null,
            onTap: () => Navigator.of(ctx).pop((v,)),
          ),
        ),
    ],
  ),
);

Future<bool> _confirmUsenetDelete(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete source', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: const Text('Remove this source, and its saved password or API key, from this device?', style: TextStyle(color: VyseColors.textDim, height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete source', style: TextStyle(color: _danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    ) ??
    false;

/// The notice shown before built-in Usenet is first turned on. True: Turn on.
class _UsenetNotice extends StatelessWidget {
  const _UsenetNotice();

  static const _points = [
    "Your indexers and providers see this device's IP address, as they would with any other app you use at home.",
    'API keys and logins stay on this device, in its keychain. They never go to your VyseTV account.',
    'Every search uses API hits on each indexer that is on. Give indexers with low limits a lower priority, and turn on Search lower priorities only as fallback.',
    'Each indexer and provider still applies its own rules and limits.',
  ];

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: VyseColors.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: const Text('Built-in Usenet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "VyseTV connects to your indexers and Usenet providers straight from this device, with your own accounts. Nothing goes through a VyseTV server or anyone else's.",
              style: TextStyle(fontSize: 14, color: VyseColors.text, height: 1.4),
            ),
            const SizedBox(height: 6),
            for (final p in _points)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(top: 8),
                      decoration: const BoxDecoration(color: VyseColors.accent, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(p, style: const TextStyle(fontSize: 13.5, color: VyseColors.textDim, height: 1.4))),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      TextButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('Turn on', style: TextStyle(fontWeight: FontWeight.w800, color: VyseColors.accent)),
      ),
    ],
  );
}

/// Settings → Addons, under the built-in Usenet row: what it still needs before it can search.
class _UsenetAddonNote extends StatefulWidget {
  const _UsenetAddonNote({required this.on});
  final bool on;

  @override
  State<_UsenetAddonNote> createState() => _UsenetAddonNoteState();
}

class _UsenetAddonNoteState extends State<_UsenetAddonNote> {
  @override
  void initState() {
    super.initState();
    UsenetSourcesStore.load();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UsenetSources>(
    valueListenable: UsenetSourcesStore.current,
    builder: (context, s, _) {
      final text = !s.configured
          ? 'Add a provider and an indexer in Settings > Usenet to use it.'
          : (widget.on && !s.usable ? 'Turn on at least one provider and one indexer in Settings > Usenet to search.' : null);
      if (text == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: TextStyle(fontSize: 12.5, color: widget.on ? _usenetCaution : VyseColors.textDim, height: 1.35)),
      );
    },
  );
}

// ── the tab ──

class _UsenetTab extends StatefulWidget {
  const _UsenetTab();

  @override
  State<_UsenetTab> createState() => _UsenetTabState();
}

class _UsenetTabState extends State<_UsenetTab> {
  /// Which sections are open, kept while VyseTV runs. Closed at first, but for providers and
  /// indexers while there are none: what still has to be set up opens by itself.
  static final _open = <String, bool>{};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    Addons.start();
    UsenetSourcesStore.load().then((_) {
      if (!mounted) return;
      final s = UsenetSourcesStore.current.value;
      _open.putIfAbsent('providers', () => s.providers.isEmpty);
      _open.putIfAbsent('indexers', () => s.indexers.isEmpty);
      setState(() => _loaded = true);
    });
  }

  bool _isOpen(String id) => _open[id] ?? false;
  void _flip(String id) => setState(() => _open[id] = !_isOpen(id));

  UsenetSources get _now => UsenetSourcesStore.current.value;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([UsenetSourcesStore.current, Addons.list, _usenetSaveError]),
    builder: (context, _) {
      final s = _now;
      final error = _usenetSaveError.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!UsenetEngine.supported)
            const _UBanner(
              icon: Icons.info_outline_rounded,
              text: "This device can't run the Usenet engine, so Usenet releases don't play here. Your providers and indexers are kept all the same.",
            ),
          if (!_loaded)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (UsenetSourcesStore.unreadable)
            const _UBanner(
              bad: true,
              icon: Icons.error_outline_rounded,
              text: "Your Usenet sources couldn't be read from this device's keychain, so they can't be shown or changed. Restart VyseTV and try again.",
            )
          else ...[
            _master(context, s),
            _providers(context, s),
            _indexers(context, s),
            _search(context, s),
          ],
          if (error != null) _UBanner(bad: true, icon: Icons.error_outline_rounded, text: error),
          _playback(context),
          _diagnostics(),
        ],
      );
    },
  );

  // ── built-in Usenet on or off ──

  Widget _master(BuildContext context, UsenetSources s) {
    final on = _usenetOn;
    return _UCard(
      title: 'Built-in Usenet',
      subtitle: 'Your own Newznab indexers find releases, and your own Usenet providers play them, straight from this device.',
      children: [
        _URow(
          title: 'Search built-in indexers',
          subtitle:
              "Usenet results show with your addons' sources (with Streaming mode off). Logins and API keys stay in this device's keychain and never go to your VyseTV account.",
          trailing: _Switch(value: on, onChanged: (v) => unawaited(_setUsenetOn(context, v))),
        ),
        if (on && !s.usable) const _UWarn('Add and turn on at least one provider and one indexer to search.'),
        if (PlatformDetector.isTV() && PhoneSession.available)
          _URow(
            title: 'Set up from your phone',
            subtitle: 'Type server addresses, passwords and API keys on your phone instead of with the remote.',
            control: _SmallButton(label: 'Edit on your phone', icon: Icons.qr_code_2_rounded, onTap: () => showPhoneEditDialog(context)),
          ),
      ],
    );
  }

  // ── providers ──

  Widget _providers(BuildContext context, UsenetSources s) {
    final n = s.providers.length, on = s.providers.where((p) => p.enabled).length;
    return _UFold(
      icon: Icons.dns_outlined,
      title: 'NNTP providers',
      summary: n == 0 ? 'None added yet' : '$n ${n == 1 ? 'provider' : 'providers'}, $on on',
      open: _isOpen('providers'),
      onToggle: () => _flip('providers'),
      children: [
        for (final (i, p) in s.providers.indexed)
          _USourceRow(
            title: p.name,
            subtitle: '${i + 1}. ${p.host}:${p.port} • ${p.connections} ${p.connections == 1 ? 'connection' : 'connections'} • Priority ${p.priority}',
            on: p.enabled,
            onTap: () => _providerOptions(context, p),
          ),
        if (n < UsenetSources.maxProviders)
          _UAddRow(title: 'Add NNTP provider', subtitle: _usenetProviderHint, onTap: () => _editProvider(context, null))
        else
          const _UWarn('That is as many providers as there can be (64).'),
      ],
    );
  }

  Future<void> _editProvider(BuildContext context, UsenetProvider? p) async {
    final r = await _showUsenetSheet<_UEditorExit>(context, _UProviderEditor(provider: p));
    if (r == _UEditorExit.phone && context.mounted) await showPhoneEditDialog(context);
  }

  Future<void> _providerOptions(BuildContext context, UsenetProvider p) async {
    final list = _now.providers;
    final i = list.indexWhere((x) => x.id == p.id);
    if (i < 0) return;
    final a = await showDialog<_USourceAction>(
      context: context,
      builder: (_) => _USourceOptions(
        name: p.name,
        priority: p.priority,
        enabled: p.enabled,
        canUp: i > 0 && list[i - 1].priority == p.priority,
        canDown: i + 1 < list.length && list[i + 1].priority == p.priority,
        tune: true,
      ),
    );
    if (a == null || !context.mounted) return;
    UsenetProvider? saved() => _now.providers.where((x) => x.id == p.id).firstOrNull;
    List<UsenetProvider> changed(UsenetProvider Function(UsenetProvider) f) => [for (final x in _now.providers) x.id == p.id ? f(x) : x];
    switch (a) {
      case _USourceAction.edit:
        final now = saved();
        if (now != null) await _editProvider(context, now);
      case _USourceAction.priority:
        final r = await _pickOne<int>(context, title: 'Priority', subtitle: _usenetProviderHint, options: _usenetPriorities, current: p.priority);
        if (r != null) await _storeUsenet(_now.copyWith(providers: changed((x) => x.copyWith(priority: r.$1))));
      case _USourceAction.tune:
        // the saved provider is measured, never what an editor holds
        final now = saved();
        if (now == null) return;
        // (Apply saves the port, the encryption and the connections it found itself)
        await showConnectionTuner(context, now);
      case _USourceAction.toggle:
        await _storeUsenet(_now.copyWith(providers: changed((x) => x.copyWith(enabled: !x.enabled))));
      case _USourceAction.up || _USourceAction.down:
        final l = [..._now.providers];
        final at = l.indexWhere((x) => x.id == p.id);
        final to = at + (a == _USourceAction.up ? -1 : 1);
        if (at < 0 || to < 0 || to >= l.length || l[to].priority != l[at].priority) return;
        l.insert(to, l.removeAt(at));
        await _storeUsenet(_now.copyWith(providers: l));
      case _USourceAction.delete:
        if (!await _confirmUsenetDelete(context)) return;
        await _storeUsenet(_now.copyWith(providers: [for (final x in _now.providers) if (x.id != p.id) x]));
    }
  }

  // ── indexers ──

  Widget _indexers(BuildContext context, UsenetSources s) => ValueListenableBuilder<int>(
    valueListenable: Newznab.instance.changed,
    builder: (context, _, _) {
      final n = s.indexers.length, on = s.indexers.where((x) => x.enabled).length;
      // (a row's pause, problem or counts left; Newznab says when one changes, a pause's end too)
      final rows = <Widget>[];
      for (final (i, x) in s.indexers.indexed) {
        final status = Newznab.instance.statusLine(x);
        rows.add(
          _USourceRow(
            title: x.name,
            subtitle: ['${i + 1}. ${x.shownEndpoint}', 'Priority ${x.priority}', ?status].join(' • '),
            on: x.enabled,
            onTap: () => _indexerOptions(context, x),
          ),
        );
      }
      return _UFold(
        icon: Icons.manage_search_rounded,
        title: 'Newznab indexers',
        summary: n == 0 ? 'None added yet' : '$n ${n == 1 ? 'indexer' : 'indexers'}, $on on',
        open: _isOpen('indexers'),
        onToggle: () => _flip('indexers'),
        children: [
          ...rows,
          if (n < UsenetSources.maxIndexers)
            _UAddRow(title: 'Add Newznab indexer', subtitle: _usenetIndexerHint, onTap: () => _editIndexer(context, null))
          else
            const _UWarn('That is as many indexers as there can be (20).'),
          _URow(
            title: 'Search lower priorities only as fallback',
            subtitle: 'Off: every indexer is searched. On: lower-priority indexers are searched only when the higher ones find nothing, which saves API hits.',
            trailing: _Switch(value: s.indexerFallback, onChanged: (v) => unawaited(_storeUsenet(_now.copyWith(indexerFallback: v)))),
          ),
          _URow(
            title: 'Hide repeated releases',
            subtitle: 'A release found by several indexers is listed once, from the indexer with the highest priority.',
            trailing: _Switch(value: s.hideDuplicates, onChanged: (v) => unawaited(_storeUsenet(_now.copyWith(hideDuplicates: v)))),
          ),
        ],
      );
    },
  );

  Future<void> _editIndexer(BuildContext context, UsenetIndexer? x) async {
    final r = await _showUsenetSheet<_UEditorExit>(context, _UIndexerEditor(indexer: x));
    if (r == _UEditorExit.phone && context.mounted) await showPhoneEditDialog(context);
  }

  Future<void> _indexerOptions(BuildContext context, UsenetIndexer x) async {
    final list = _now.indexers;
    final i = list.indexWhere((y) => y.id == x.id);
    if (i < 0) return;
    final a = await showDialog<_USourceAction>(
      context: context,
      builder: (_) => _USourceOptions(
        name: x.name,
        priority: x.priority,
        enabled: x.enabled,
        canUp: i > 0 && list[i - 1].priority == x.priority,
        canDown: i + 1 < list.length && list[i + 1].priority == x.priority,
        tune: false,
      ),
    );
    if (a == null || !context.mounted) return;
    List<UsenetIndexer> changed(UsenetIndexer Function(UsenetIndexer) f) => [for (final y in _now.indexers) y.id == x.id ? f(y) : y];
    switch (a) {
      case _USourceAction.edit:
        final now = _now.indexers.where((y) => y.id == x.id).firstOrNull;
        if (now != null) await _editIndexer(context, now);
      case _USourceAction.priority:
        final r = await _pickOne<int>(context, title: 'Priority', subtitle: _usenetIndexerPriorityHint, options: _usenetPriorities, current: x.priority);
        if (r != null) await _storeUsenet(_now.copyWith(indexers: changed((y) => y.copyWith(priority: r.$1))));
      case _USourceAction.tune:
        return;
      case _USourceAction.toggle:
        await _storeUsenet(_now.copyWith(indexers: changed((y) => y.copyWith(enabled: !y.enabled))));
      case _USourceAction.up || _USourceAction.down:
        final l = [..._now.indexers];
        final at = l.indexWhere((y) => y.id == x.id);
        final to = at + (a == _USourceAction.up ? -1 : 1);
        if (at < 0 || to < 0 || to >= l.length || l[to].priority != l[at].priority) return;
        l.insert(to, l.removeAt(at));
        await _storeUsenet(_now.copyWith(indexers: l));
      case _USourceAction.delete:
        if (!await _confirmUsenetDelete(context)) return;
        await _storeUsenet(_now.copyWith(indexers: [for (final y in _now.indexers) if (y.id != x.id) y]));
    }
  }

  // ── search results ──

  Widget _search(BuildContext context, UsenetSources s) {
    final custom = s.customProfile;
    final builtIn = s.preset != UsenetPreset.original && s.preset != UsenetPreset.custom;
    final auto = s.maxResults == 0 ? 1000 : (s.maxResults > 200 ? s.maxResults : 200);
    String presetName(UsenetPreset p) => p == UsenetPreset.custom ? UsenetProfileJson.nameOf(custom) : p.label;

    Future<void> pick(String title, String? subtitle, List<int> choices, int current, String Function(int) label, UsenetSources Function(UsenetSources, int) apply) async {
      final options = [...choices];
      if (!options.contains(current)) {
        options
          ..add(current)
          ..sort();
      }
      final r = await _pickOne<int>(context, title: title, subtitle: subtitle, options: [for (final v in options) (v, label(v))], current: current);
      if (r != null) await _storeUsenet(apply(_now, r.$1));
    }

    Widget toggle(String title, String? subtitle, bool value, UsenetSources Function(UsenetSources, bool) apply) =>
        _URow(title: title, subtitle: subtitle, trailing: _Switch(value: value, onChanged: (v) => unawaited(_storeUsenet(apply(_now, v)))));

    String noLimit(int v, String Function(int) f) => v == 0 ? 'No limit' : f(v);

    return _UFold(
      icon: Icons.filter_list_rounded,
      title: 'Search results',
      summary: 'Sorting, quality, size and age filters',
      open: _isOpen('search'),
      onToggle: () => _flip('search'),
      children: [
        _URow(
          title: 'Sorting profile',
          subtitle: UsenetProfileJson.presetDescription(s.preset),
          control: _UPick(
            value: presetName(s.preset),
            onTap: () async {
              final r = await _pickOne<UsenetPreset>(
                context,
                title: 'Sorting profile',
                subtitle: 'How built-in Usenet results are ordered. Other sources keep their own order.',
                options: [for (final p in UsenetPreset.values) if (p != UsenetPreset.custom || custom != null) (p, presetName(p))],
                current: s.preset,
              );
              if (r != null) await _storeUsenet(_now.copyWith(preset: r.$1));
            },
          ),
        ),
        if (builtIn)
          _URow(
            title: 'Preferred language',
            subtitle: 'Releases labelled with this audio language come before quality and size. Other and unlabelled releases stay available.',
            control: _UPick(
              value: UsenetProfileJson.languageLabel(s.preferredLanguage),
              onTap: () async {
                final r = await _pickOne<String>(
                  context,
                  title: 'Preferred language',
                  options: [('', UsenetProfileJson.languageLabel('')), for (final c in UsenetSources.languages) (c, UsenetProfileJson.languageLabel(c))],
                  current: s.preferredLanguage,
                );
                if (r != null) await _storeUsenet(_now.copyWith(preferredLanguage: r.$1));
              },
            ),
          ),
        _URow(
          title: 'Your own sorting profile',
          subtitle: custom == null
              ? 'Quality tiers, priorities and scoring rules of your own. Once it is saved, it is the sorting profile.'
              : '${UsenetProfileJson.nameOf(custom)}: ${UsenetProfileJson.summary(custom)}. ${s.preset == UsenetPreset.custom ? 'In use.' : 'Pick it above to use it.'}',
          control: _SmallButton(label: custom == null ? 'Create' : 'Edit', icon: custom == null ? Icons.add_rounded : Icons.edit_outlined, onTap: () => _editProfile(context)),
        ),
        if (PlatformDetector.isTV() && PhoneSession.available)
          _URow(
            title: 'Edit sorting from your phone',
            subtitle: 'Choose a profile and a language on your phone, or paste a profile of your own there.',
            control: _SmallButton(label: 'Edit on your phone', icon: Icons.qr_code_2_rounded, onTap: () => showPhoneEditDialog(context)),
          ),
        if (s.preset == UsenetPreset.original)
          _URow(
            title: 'Sort results',
            control: _UPick(
              value: _usenetSortLabel(s.sort),
              onTap: () async {
                final r = await _pickOne<UsenetSort>(
                  context,
                  title: 'Sort results',
                  options: [for (final o in UsenetSort.values) (o, _usenetSortLabel(o))],
                  current: s.sort,
                );
                if (r != null) await _storeUsenet(_now.copyWith(sort: r.$1));
              },
            ),
          ),
        _URow(
          title: 'Minimum resolution',
          control: _UPick(
            value: noLimit(s.minResolution, (v) => '${v}p'),
            onTap: () => pick('Minimum resolution', null, const [0, 480, 720, 1080, 2160], s.minResolution, (v) => noLimit(v, (v) => '${v}p'), (n, v) => n.copyWith(minResolution: v)),
          ),
        ),
        _URow(
          title: 'Maximum release size',
          control: _UPick(
            value: noLimit(s.maxSizeGb, (v) => '$v GB'),
            onTap: () => pick('Maximum release size', 'A season pack counts per episode when the season says how many it has.', const [0, 5, 10, 20, 40, 80, 120, 200], s.maxSizeGb,
                (v) => noLimit(v, (v) => '$v GB'), (n, v) => n.copyWith(maxSizeGb: v)),
          ),
        ),
        _URow(
          title: 'Maximum release age',
          control: _UPick(
            value: noLimit(s.maxAgeDays, (v) => '$v days'),
            onTap: () => pick('Maximum release age', null, const [0, 30, 90, 365, 1000, 3000, 5000], s.maxAgeDays, (v) => noLimit(v, (v) => '$v days'), (n, v) => n.copyWith(maxAgeDays: v)),
          ),
        ),
        _URow(
          title: 'Maximum results',
          subtitle: "Results shown in all, from every indexer, after the filters and sorting. An indexer's own fetch limit stays as it is.",
          control: _UPick(
            value: noLimit(s.maxResults, (v) => '$v'),
            onTap: () => pick('Maximum results', null, const [0, 10, 25, 50, 100, 200, 500], s.maxResults, (v) => noLimit(v, (v) => '$v'), (n, v) => n.copyWith(maxResults: v)),
          ),
        ),
        _URow(
          title: 'Default fetch limit',
          subtitle: 'Results read per search from each indexer that has no limit of its own. Each page is an API hit. Auto follows Maximum results above 200, up to 1000.',
          control: _UPick(
            value: s.defaultFetch == 0 ? 'Auto ($auto)' : '${s.defaultFetch}',
            onTap: () => pick('Default fetch limit', null, const [0, 100, 200, 500, 1000], s.defaultFetch, (v) => v == 0 ? 'Auto ($auto)' : '$v', (n, v) => n.copyWith(defaultFetch: v)),
          ),
        ),
        toggle('Exclude CAM, telesync and screener releases', null, s.excludeLowQuality, (n, v) => n.copyWith(excludeLowQuality: v)),
        toggle(
          'Exclude full Blu-ray and DVD discs',
          "Hides whole-disc releases. A Blu-ray disc plays from its main film; a DVD disc doesn't play. Remuxes of a disc always show.",
          s.excludeFullDisc,
          (n, v) => n.copyWith(excludeFullDisc: v),
        ),
        toggle(
          'Show results as each indexer answers',
          'Off: the list shows once every indexer has answered, or after 5 seconds if one is slow, and fills in from there. On: it grows and reorders as each answers.',
          s.progressiveResults,
          (n, v) => n.copyWith(progressiveResults: v),
        ),
        toggle(
          'Show available releases first',
          'Releases marked AVAILABLE played lately with your providers, here or in another episode of the same pack. On: they come first whatever the sorting, and fallback tries them first.',
          s.availableFirst,
          (n, v) => n.copyWith(availableFirst: v),
        ),
        toggle(
          'Show release names',
          "Each result shows its release name above its details. Hidden, the release group ends the details.",
          s.showReleaseNames,
          (n, v) => n.copyWith(showReleaseNames: v),
        ),
      ],
    );
  }

  Future<void> _editProfile(BuildContext context) async {
    final saved = _now.customProfile;
    final p = await _showUsenetSheet<Map<String, Object?>>(
      context,
      _URankingEditor(initial: saved ?? UsenetProfileJson.balanced(), fresh: saved == null),
      maxWidth: 760,
    );
    if (p == null) return;
    await _storeUsenet(_now.copyWith(customProfile: () => p, preset: UsenetPreset.custom));
  }

  // ── playback and engine ──

  Widget _playback(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      AppSettings.usenetAllowPrivate,
      AppSettings.usenetSearchUserAgent,
      AppSettings.usenetDownloadUserAgent,
      AppSettings.usenetFallback,
      AppSettings.usenetFallbackMax,
      AppSettings.usenetHoleFilling,
      AppSettings.usenetMaxMissing,
      AppSettings.usenetMaxConsecutiveMissing,
      AppSettings.usenetPrefetch,
      AppSettings.usenetCacheNzb,
      AppSettings.usenetFastMkv,
      AppSettings.usenetFastNzb,
      AppSettings.usenetPrewarm,
      AppSettings.usenetProfile,
      AppSettings.usenetReadAhead,
      AppSettings.usenetMaxConnections,
    ]),
    builder: (context, _) {
      final missing = AppSettings.usenetMaxMissing.value.clamp(1, 50);
      final inRow = AppSettings.usenetMaxConsecutiveMissing.value.clamp(1, missing < 10 ? missing : 10);
      String automatic(int v) => v == 0 ? 'Automatic' : '$v';

      Future<void> pick(Setting<int> setting, String title, String? subtitle, List<int> choices, String Function(int) label, {void Function(int)? also}) async {
        final options = [...choices];
        if (!options.contains(setting.value)) {
          options
            ..add(setting.value)
            ..sort();
        }
        final r = await _pickOne<int>(context, title: title, subtitle: subtitle, options: [for (final v in options) (v, label(v))], current: setting.value);
        if (r == null) return;
        setting.set(r.$1);
        also?.call(r.$1);
      }

      final profile = AppSettings.usenetProfile.value;
      const profiles = [('low-memory', 'Low memory'), ('balanced', 'Balanced'), ('throughput', 'High throughput')];
      final profileName = profiles.where((p) => p.$1 == profile).firstOrNull?.$2 ?? 'Balanced';

      return _UFold(
        icon: Icons.tune_rounded,
        title: 'Playback and engine',
        summary: 'Fallback, missing articles, startup and connections',
        open: _isOpen('playback'),
        onToggle: () => _flip('playback'),
        children: [
          _URow(
            title: 'Allow self-hosted servers',
            subtitle:
                'Lets providers, and NZB and provider addresses from addons, be on your local network or this device. Only for addons and services you trust. '
                'Link-local addresses stay blocked. Applies to the next stream.',
            trailing: _Toggle(AppSettings.usenetAllowPrivate),
          ),
          _uaRow(
            context,
            AppSettings.usenetSearchUserAgent,
            'Search User-Agent',
            'How VyseTV names itself to indexers: searches, capability checks and Test indexer. Change it only if an indexer asks for another.',
          ),
          _uaRow(
            context,
            AppSettings.usenetDownloadUserAgent,
            'NZB download User-Agent',
            "How VyseTV names itself when it downloads an NZB. An addon's own User-Agent comes first. Change it only if an indexer asks for another.",
          ),
          _URow(
            title: 'Automatic Usenet fallback',
            subtitle: "When a Usenet release won't play, the next Usenet results are tried, up to the attempts below. Torrents and other sources never switch by themselves.",
            trailing: _Toggle(AppSettings.usenetFallback),
          ),
          _URow(
            title: 'Maximum fallback attempts',
            subtitle: 'Up to this many other releases are tried (1 to 50), all within two minutes of preparing. Applies from the next pick.',
            control: _UPick(
              value: '${AppSettings.usenetFallbackMax.value.clamp(1, 50)}',
              onTap: () => pick(AppSettings.usenetFallbackMax, 'Maximum fallback attempts', null, [for (var n = 1; n <= 50; n++) n], (v) => '$v'),
            ),
          ),
          _URow(
            title: 'Fill missing articles',
            subtitle: 'Carries on through small gaps in a damaged video. What is missing can glitch the picture or sound, and some videos still fail. Applies to the next stream.',
            trailing: _Toggle(AppSettings.usenetHoleFilling),
          ),
          if (AppSettings.usenetHoleFilling.value) ...[
            _URow(
              title: 'Maximum missing articles',
              subtitle: 'In all, across one playback (1 to 50). Lower turns damaged releases away sooner.',
              control: _UPick(
                value: '$missing',
                onTap: () => pick(
                  AppSettings.usenetMaxMissing,
                  'Maximum missing articles',
                  null,
                  [for (var n = 1; n <= 50; n++) n],
                  (v) => '$v',
                  // never more in a row than in all
                  also: (v) {
                    if (AppSettings.usenetMaxConsecutiveMissing.value > v) AppSettings.usenetMaxConsecutiveMissing.set(v);
                  },
                ),
              ),
            ),
            _URow(
              title: 'Maximum missing in a row',
              subtitle: 'The largest gap allowed at once (1 to 10). Lower allows only smaller gaps. Header articles a video needs are never filled.',
              control: _UPick(
                value: '$inRow',
                onTap: () => pick(AppSettings.usenetMaxConsecutiveMissing, 'Maximum missing in a row', null, [for (var n = 1; n <= (missing < 10 ? missing : 10); n++) n], (v) => '$v'),
              ),
            ),
          ],
          _URow(
            title: 'Prefetch the first Usenet result',
            subtitle: 'Prepares the first Usenet result as soon as the sources list shows, and keeps it ready for up to two minutes. Uses provider connections and some data.',
            trailing: _Toggle(AppSettings.usenetPrefetch),
          ),
          _URow(
            title: 'Cache NZB files',
            subtitle: 'Keeps NZB files of up to 64 MB each, 256 MB in all, across restarts. One unused for 14 days goes, and the least used go first when room is needed. Turned off, the ones kept are deleted.',
            trailing: _Toggle(AppSettings.usenetCacheNzb),
          ),
          _URow(
            title: 'Fast MKV start',
            subtitle: 'Prepares the start of a video and its seek index together. Uses a little more data and memory. Applies to the next stream.',
            trailing: _Toggle(AppSettings.usenetFastMkv),
          ),
          _URow(
            title: 'Fast NZB fetch',
            subtitle: 'Asks for NZB files compressed, so playback starts sooner. Applies to the next stream.',
            trailing: _Toggle(AppSettings.usenetFastNzb),
          ),
          _URow(
            title: 'Pre-warm the Usenet engine',
            subtitle: 'Keeps the engine ready while you browse. Uses extra memory; by itself it opens no provider connections.',
            trailing: _Switch(
              value: AppSettings.usenetPrewarm.value,
              onChanged: (v) {
                AppSettings.usenetPrewarm.set(v);
                if (v) unawaited(UsenetEngine.instance.foregrounded());
              },
            ),
          ),
          _URow(
            title: 'Performance profile',
            subtitle: 'How much memory the engine works with, and how far it reads ahead. Applies to the next stream.',
            control: _UPick(
              value: profileName,
              onTap: () async {
                final r = await _pickOne<String>(context, title: 'Performance profile', options: profiles, current: profile);
                if (r != null) AppSettings.usenetProfile.set(r.$1);
              },
            ),
          ),
          _URow(
            title: 'Read-ahead segments',
            subtitle: "How many upcoming segments are prepared, within the profile's memory.",
            control: _UPick(
              value: automatic(AppSettings.usenetReadAhead.value),
              onTap: () => pick(AppSettings.usenetReadAhead, 'Read-ahead segments', null, const [0, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 256, 512], automatic),
            ),
          ),
          _URow(
            title: 'Maximum connections',
            subtitle: "In all, across your providers. Automatic: each provider's own connection allowance, or what an addon's servers say.",
            control: _UPick(
              value: automatic(AppSettings.usenetMaxConnections.value),
              onTap: () => pick(
                AppSettings.usenetMaxConnections,
                'Maximum connections',
                'The highest priority gets its share first; each lower one keeps one connection for when it is needed.',
                const [0, 4, 8, 12, 16, 20, 24, 32, 40, 50, 60, 80, 100, 150, 200, 300, 500],
                automatic,
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _uaRow(BuildContext context, Setting<String> setting, String title, String subtitle) {
    final mine = setting.value.trim();
    final shown = mine.isEmpty || !UsenetPlay.validUserAgent(mine) ? '${UsenetPlay.defaultUserAgent} (default)' : mine;
    return _URow(
      title: title,
      subtitle: subtitle,
      control: _UPick(
        value: shown,
        icon: Icons.edit_outlined,
        onTap: () => showDialog<void>(context: context, builder: (_) => _UUserAgentDialog(setting: setting, title: title, subtitle: subtitle)),
      ),
    );
  }

  // ── diagnostics ──

  Widget _diagnostics() => _UFold(
    icon: Icons.insights_rounded,
    title: 'Diagnostics',
    summary: 'Startup timings and source statistics',
    open: _isOpen('diagnostics'),
    onToggle: () => _flip('diagnostics'),
    apart: true,
    children: const [UsenetDiagnosticsCard(), UsenetStatisticsSection()],
  );
}

String _usenetSortLabel(UsenetSort s) => switch (s) {
  UsenetSort.quality => 'Best resolution first',
  UsenetSort.largest => 'Largest first',
  UsenetSort.smallest => 'Smallest first',
  UsenetSort.newest => 'Newest first',
  UsenetSort.indexer => 'Indexer priority',
};

// ── building blocks ──

/// A titled card of Usenet settings (as a Settings section, with room for rows that press).
class _UCard extends StatelessWidget {
  const _UCard({required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.4)),
        if (subtitle != null) ...[const SizedBox(height: 5), Text(subtitle!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35))],
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: VyseColors.stroke)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke, indent: 10, endIndent: 10),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// A section that opens and closes: its header (what it is, a summary) is one press.
class _UFold extends StatelessWidget {
  const _UFold({required this.icon, required this.title, required this.summary, required this.open, required this.onToggle, this.children = const [], this.apart = false});
  final IconData icon;
  final String title;
  final String summary;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  /// What it holds comes under its header as items of their own (reports a remote reaches one
  /// by one), not inside its card.
  final bool apart;

  @override
  Widget build(BuildContext context) {
    final header = Pressable(
      onTap: onToggle,
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: hovered ? .04 : 0), borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: VyseColors.accent.withValues(alpha: .13), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 19, color: VyseColors.accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -.2)),
                  const SizedBox(height: 3),
                  Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.3)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AnimatedRotation(
              turns: open ? .5 : 0,
              duration: Lean.time(const Duration(milliseconds: 200)),
              child: const Icon(Icons.expand_more_rounded, color: VyseColors.textDim),
            ),
          ],
        ),
      ),
    );
    final card = BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: VyseColors.stroke));
    if (apart) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(decoration: card, child: header),
            if (open)
              for (final c in children) Padding(padding: const EdgeInsets.only(top: 12), child: c),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            if (open) ...[
              const Divider(height: 1, thickness: 1, color: VyseColors.stroke),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const Divider(height: 1, thickness: 1, color: VyseColors.stroke, indent: 10, endIndent: 10),
                      children[i],
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A setting: what it is, and its control. A small one ([trailing], a switch) stays beside the
/// words; a wider one ([control], a value to pick or a button) goes under them when the row is
/// narrow.
class _URow extends StatelessWidget {
  const _URow({required this.title, this.subtitle, this.trailing, this.control});
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? control;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
    child: LayoutBuilder(
      builder: (context, c) {
        final below = control != null && c.maxWidth < 460;
        final words = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35)),
            ],
          ],
        );
        final side = trailing ?? (below ? null : control);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Expanded(child: words), if (side != null) ...[const SizedBox(width: 16), side]]),
            if (below) ...[const SizedBox(height: 12), control!],
          ],
        );
      },
    ),
  );
}

/// The value in use, to press for the others.
class _UPick extends StatelessWidget {
  const _UPick({required this.value, required this.onTap, this.icon = Icons.expand_more_rounded});
  final String value;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => Container(
      constraints: const BoxConstraints(maxWidth: 230),
      padding: const EdgeInsets.fromLTRB(14, 9, 9, 9),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: hovered ? .12 : .07), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(value, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 5),
          Icon(icon, size: 17, color: VyseColors.textDim),
        ],
      ),
    ),
  );
}

/// A provider or an indexer in its list: press it for what can be done with it.
class _USourceRow extends StatelessWidget {
  const _USourceRow({required this.title, required this.subtitle, required this.on, required this.onTap});
  final String title;
  final String subtitle;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.fromLTRB(10, 11, 6, 11),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: hovered ? .05 : 0), borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim),
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _Kind(on ? 'On' : 'Off', on ? Icons.check_rounded : Icons.block_rounded),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right_rounded, size: 20, color: VyseColors.textFaint),
          ],
        ),
      ),
    ),
  );
}

class _UAddRow extends StatelessWidget {
  const _UAddRow({required this.title, required this.subtitle, required this.onTap});
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.fromLTRB(10, 11, 10, 11),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: hovered ? .05 : 0), borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(color: VyseColors.accent.withValues(alpha: .15), shape: BoxShape.circle),
              child: const Icon(Icons.add_rounded, size: 19, color: VyseColors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _UWarn extends StatelessWidget {
  const _UWarn(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 12, 10, 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber_rounded, size: 17, color: _usenetCaution),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13, color: _usenetCaution, height: 1.35))),
      ],
    ),
  );
}

class _UBanner extends StatelessWidget {
  const _UBanner({required this.icon, required this.text, this.bad = false});
  final IconData icon;
  final String text;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final color = bad ? _danger : VyseColors.accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5, color: VyseColors.text, height: 1.4))),
        ],
      ),
    );
  }
}

/// A short list in a dialog: options, a choice, an action each.
class _UDialog extends StatelessWidget {
  const _UDialog({required this.title, required this.children, this.subtitle, this.close = 'Close'});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final String close;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: VyseColors.surfaceHi,
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: VyseColors.stroke)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(subtitle!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.35)),
              ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(close)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _UOption extends StatelessWidget {
  const _UOption({required this.title, required this.onTap, this.icon, this.subtitle, this.value, this.trailing, this.danger = false, this.selected = false});
  final IconData? icon;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final bool danger;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Pressable(
      onTap: onTap,
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: selected ? VyseColors.accent.withValues(alpha: .14) : Colors.white.withValues(alpha: hovered ? .06 : 0),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 19, color: danger ? _danger : VyseColors.textDim),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: selected ? FontWeight.w800 : FontWeight.w600, color: danger ? _danger : VyseColors.text),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.3)),
                  ],
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
              ),
            ],
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
      ),
    ),
  );
}

/// How a switch looks, inside something that is pressed as a whole.
class _USwitchLook extends StatelessWidget {
  const _USwitchLook(this.on);
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
    width: 42,
    height: 24,
    padding: const EdgeInsets.all(3),
    alignment: on ? Alignment.centerRight : Alignment.centerLeft,
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: on ? VyseColors.accent : Colors.white.withValues(alpha: .14)),
    child: Container(width: 18, height: 18, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
  );
}

enum _USourceAction { edit, priority, tune, toggle, up, down, delete }

/// What can be done with a provider or an indexer.
class _USourceOptions extends StatelessWidget {
  const _USourceOptions({required this.name, required this.priority, required this.enabled, required this.canUp, required this.canDown, required this.tune});
  final String name;
  final int priority;
  final bool enabled;
  final bool canUp;
  final bool canDown;

  /// A provider's: Tune connections.
  final bool tune;

  @override
  Widget build(BuildContext context) {
    void pick(_USourceAction a) => Navigator.of(context).pop(a);
    return _UDialog(
      title: name,
      children: [
        _UOption(icon: Icons.edit_outlined, title: 'Edit', onTap: () => pick(_USourceAction.edit)),
        _UOption(icon: Icons.low_priority_rounded, title: 'Priority', value: _usenetPriorityLabel(priority), onTap: () => pick(_USourceAction.priority)),
        if (tune)
          _UOption(
            icon: Icons.speed_rounded,
            title: 'Tune connections',
            subtitle: 'Find the connection limit, port and connection allowance that work best on this network',
            onTap: () => pick(_USourceAction.tune),
          ),
        _UOption(
          icon: enabled ? Icons.toggle_on_outlined : Icons.toggle_off_outlined,
          title: 'On',
          subtitle: enabled ? 'Used for searching and playing' : 'Kept, but not used',
          trailing: _USwitchLook(enabled),
          onTap: () => pick(_USourceAction.toggle),
        ),
        if (canUp) _UOption(icon: Icons.arrow_upward_rounded, title: 'Move up', onTap: () => pick(_USourceAction.up)),
        if (canDown) _UOption(icon: Icons.arrow_downward_rounded, title: 'Move down', onTap: () => pick(_USourceAction.down)),
        _UOption(icon: Icons.delete_outline_rounded, title: 'Delete source', danger: true, onTap: () => pick(_USourceAction.delete)),
      ],
    );
  }
}

// ── editors ──

/// How an editor was left: saved, or for the phone (Set up from your phone).
enum _UEditorExit { saved, phone }

/// An editor's sheet: its title, its fields (they scroll), and its messages and buttons, which
/// stay in view under them.
class _USheetBody extends StatelessWidget {
  const _USheetBody({required this.title, required this.fields, required this.actions, this.subtitle, this.footer = const []});
  final String title;
  final String? subtitle;
  final List<Widget> fields;
  final List<Widget> footer;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -.4)),
            if (subtitle != null) ...[const SizedBox(height: 6), Text(subtitle!, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.4))],
          ],
        ),
      ),
      Flexible(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < fields.length; i++) ...[if (i > 0) const SizedBox(height: 16), fields[i]],
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in footer) Padding(padding: const EdgeInsets.only(bottom: 10), child: f),
            Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions),
          ],
        ),
      ),
    ],
  );
}

/// A line under an editor's fields: a problem, a result, or what is happening.
class _UMessage extends StatelessWidget {
  const _UMessage(this.text, {this.bad = false, this.good = false, this.busy = false});
  final String text;
  final bool bad;
  final bool good;
  final bool busy;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (busy)
        const Padding(padding: EdgeInsets.only(top: 1), child: SizedBox.square(dimension: 15, child: CircularProgressIndicator(strokeWidth: 2)))
      else
        Icon(bad ? Icons.error_outline_rounded : (good ? Icons.check_circle_rounded : Icons.info_outline_rounded), size: 17, color: bad ? _danger : (good ? _usenetGood : VyseColors.textDim)),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: bad ? _danger : VyseColors.textDim, height: 1.35))),
    ],
  );
}

/// A text box with its name above it. The keyboard's Next goes to the box below.
class _UField extends StatelessWidget {
  const _UField({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboard,
    this.obscure = false,
    this.onReveal,
    this.formatters,
    this.last = false,
    this.maxLength,
    this.onSubmitted,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboard;
  final bool obscure;

  /// Shows or hides what is typed (a password, a key): only when asked.
  final VoidCallback? onReveal;
  final List<TextInputFormatter>? formatters;
  final bool last;
  final int? maxLength;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 6),
        child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: VyseColors.textDim)),
      ),
      TextField(
        controller: controller,
        keyboardType: keyboard,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: [...?formatters, if (maxLength != null) LengthLimitingTextInputFormatter(maxLength)],
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
        onTapOutside: dismissKeyboard,
        style: const TextStyle(fontSize: 14.5),
        cursorColor: VyseColors.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 14),
          isDense: true,
          filled: true,
          fillColor: Colors.white.withValues(alpha: .05),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          suffixIcon: onReveal == null
              ? null
              : IconButton(
                  tooltip: obscure ? 'Show' : 'Hide',
                  iconSize: 18,
                  color: VyseColors.textDim,
                  onPressed: onReveal,
                  icon: Icon(obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VyseColors.stroke)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: VyseColors.stroke)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: VyseColors.accent.withValues(alpha: .7), width: 1.5)),
        ),
      ),
    ],
  );
}

/// In a new provider's or indexer's editor on a TV: type it on the phone instead.
class _UPhoneRow extends StatelessWidget {
  const _UPhoneRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VyseColors.accent.withValues(alpha: hovered ? .14 : .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VyseColors.accent.withValues(alpha: .35)),
      ),
      child: const Row(
        children: [
          Icon(Icons.qr_code_2_rounded, size: 22, color: VyseColors.accent),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Set up from your phone', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                SizedBox(height: 3),
                Text(
                  'Type server addresses, passwords and API keys on your phone instead of with the remote.',
                  style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Add or edit an NNTP provider. Test provider signs in with what is typed, before anything is
/// saved; its answer shows only while the fields still hold what was tested.
class _UProviderEditor extends StatefulWidget {
  const _UProviderEditor({this.provider});
  final UsenetProvider? provider;

  @override
  State<_UProviderEditor> createState() => _UProviderEditorState();
}

class _UProviderEditorState extends State<_UProviderEditor> {
  late final UsenetProvider _base = widget.provider ?? UsenetProvider();
  late final _name = TextEditingController(text: _base.name);
  late final _host = TextEditingController(text: _base.host);
  late final _port = TextEditingController(text: '${_base.port}');
  late final _user = TextEditingController(text: _base.username);
  late final _pass = TextEditingController(text: _base.password);
  late final _conn = TextEditingController(text: '${_base.connections}');
  late bool _tls = _base.tls;
  bool _reveal = false;
  String? _error;
  bool _testing = false;
  bool _saving = false;
  String? _tested; // the fields the result below is for
  String? _result;
  bool _resultOk = false;

  List<TextEditingController> get _all => [_name, _host, _port, _user, _pass, _conn];

  @override
  void initState() {
    super.initState();
    for (final c in _all) {
      c.addListener(_edited);
    }
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _edited() {
    if (mounted) setState(() => _error = null);
  }

  String get _fields => [for (final c in _all) c.text, '$_tls'].join('\u0000');

  UsenetProvider get _draft => _base.copyWith(
    name: _name.text.trim(),
    host: _host.text.trim(),
    port: int.tryParse(_port.text.trim()) ?? 0,
    tls: _tls,
    username: _user.text,
    password: _pass.text,
    connections: int.tryParse(_conn.text.trim()) ?? 0,
  );

  /// TLS on or off, and the usual port with it when the port is still a usual one.
  void _setTls(bool on) => setState(() {
    _tls = on;
    final p = _port.text.trim();
    if (p == '119' || p == '563') _port.text = on ? '563' : '119';
  });

  Future<void> _test() async {
    if (_testing) return;
    final d = _draft;
    final bad = d.problem;
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
      _tested = _fields;
      _result = null;
    });
    final target = NntpTarget(host: d.host, port: d.port, tls: d.tls, username: d.username, password: d.password);
    final r = await testProvider(target, allowPrivate: AppSettings.usenetAllowPrivate.value);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = nntpResultText(r, anonymous: target.anonymous);
      _resultOk = r == NntpResult.success;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final d = _draft;
    final bad = d.problem;
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    final s = UsenetSourcesStore.current.value;
    final list = [...s.providers];
    final i = list.indexWhere((x) => x.id == d.id);
    if (i >= 0) {
      list[i] = d;
    } else {
      list.add(d);
    }
    setState(() => _saving = true);
    final problem = await _storeUsenet(s.copyWith(providers: list), own: true);
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _saving = false;
        _error = problem;
      });
      return;
    }
    Navigator.of(context).pop(_UEditorExit.saved);
  }

  @override
  Widget build(BuildContext context) {
    final fresh = widget.provider == null;
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return _USheetBody(
      title: fresh ? 'Add NNTP provider' : 'Edit NNTP provider',
      subtitle: "Your Usenet provider's news server, and your account on it.",
      fields: [
        if (fresh && PlatformDetector.isTV() && PhoneSession.available) _UPhoneRow(onTap: () => Navigator.of(context).pop(_UEditorExit.phone)),
        _UField(controller: _name, label: 'Name', hint: 'My provider', maxLength: 80),
        _UField(controller: _host, label: 'Server host', hint: 'news.example.com', keyboard: TextInputType.url, maxLength: 253),
        _UField(controller: _port, label: 'Port', hint: '563', keyboard: TextInputType.number, formatters: digits, maxLength: 5),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Use TLS', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text('A secure connection: usually port 563, or 119 without', style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.3)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _Switch(value: _tls, onChanged: _setTls),
          ],
        ),
        _UField(controller: _user, label: 'Username', maxLength: 500),
        _UField(controller: _pass, label: 'Password', obscure: !_reveal, onReveal: () => setState(() => _reveal = !_reveal), maxLength: 500),
        _UField(controller: _conn, label: 'Connection allowance', hint: '20', keyboard: TextInputType.number, formatters: digits, maxLength: 4, last: true, onSubmitted: _save),
        const Text(
          "How many connections your account allows at once (1 to 4096). Tune connections, in the provider's options once it is saved, finds the number that works best.",
          style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35),
        ),
      ],
      footer: [
        if (_error != null) _UMessage(_error!, bad: true),
        if (_testing)
          const _UMessage('Connecting to the provider…', busy: true)
        else if (_result != null && _tested == _fields)
          _UMessage(_result!, bad: !_resultOk, good: _resultOk),
      ],
      actions: [
        _SmallButton(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
        _SmallButton(label: _testing ? 'Testing…' : 'Test provider', icon: Icons.wifi_tethering_rounded, onTap: _test),
        _SmallButton(label: _saving ? 'Saving…' : 'Save', icon: Icons.check_rounded, primary: true, onTap: _save),
      ],
    );
  }
}

String _usenetFetchLabel(int? n) => switch (n) {
  null => 'Use global setting',
  0 => 'Unlimited',
  _ => '$n',
};

/// Add or edit a Newznab indexer. Test indexer asks it for its capabilities and one result with
/// what is typed, before anything is saved (one API hit).
class _UIndexerEditor extends StatefulWidget {
  const _UIndexerEditor({this.indexer});
  final UsenetIndexer? indexer;

  @override
  State<_UIndexerEditor> createState() => _UIndexerEditorState();
}

class _UIndexerEditorState extends State<_UIndexerEditor> {
  late final UsenetIndexer _base = widget.indexer ?? UsenetIndexer(apiPath: '/api');
  late final _name = TextEditingController(text: _base.name);
  late final _url = TextEditingController(text: _base.apiUrl);
  late final _path = TextEditingController(text: _base.apiPath);
  late final _key = TextEditingController(text: _base.apiKey);
  late int? _fetch = _base.fetchLimit;
  bool _reveal = false;
  String? _error;
  bool _testing = false;
  bool _saving = false;
  String? _tested;
  String? _result;
  bool _resultOk = false;

  List<TextEditingController> get _all => [_name, _url, _path, _key];

  @override
  void initState() {
    super.initState();
    for (final c in _all) {
      c.addListener(_edited);
    }
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _edited() {
    if (mounted) setState(() => _error = null);
  }

  String get _fields => [for (final c in _all) c.text].join('\u0000');

  UsenetIndexer get _draft => _base.copyWith(name: _name.text.trim(), apiUrl: _url.text.trim(), apiPath: _path.text.trim(), apiKey: _key.text.trim(), fetchLimit: () => _fetch);

  Future<void> _test() async {
    if (_testing) return;
    final d = _draft;
    final bad = d.problem;
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
      _tested = _fields;
      _result = null;
    });
    final r = await Newznab.instance.test(d);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = r.message;
      _resultOk = r.ok;
    });
  }

  Future<void> _pickFetch() async {
    final r = await _pickOne<int?>(
      context,
      title: 'Fetch limit',
      subtitle: _usenetFetchHint,
      options: [for (final n in const <int?>[null, 0, 100, 200, 500, 1000]) (n, _usenetFetchLabel(n))],
      current: _fetch,
    );
    if (r != null && mounted) setState(() => _fetch = r.$1);
  }

  Future<void> _save() async {
    if (_saving) return;
    final d = _draft;
    final bad = d.problem;
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    final s = UsenetSourcesStore.current.value;
    final list = [...s.indexers];
    final i = list.indexWhere((x) => x.id == d.id);
    if (i >= 0) {
      list[i] = d;
    } else {
      list.add(d);
    }
    setState(() => _saving = true);
    final problem = await _storeUsenet(s.copyWith(indexers: list), own: true);
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _saving = false;
        _error = problem;
      });
      return;
    }
    Navigator.of(context).pop(_UEditorExit.saved);
  }

  @override
  Widget build(BuildContext context) {
    final fresh = widget.indexer == null;
    return _USheetBody(
      title: fresh ? 'Add Newznab indexer' : 'Edit Newznab indexer',
      subtitle: _usenetIndexerHint,
      fields: [
        if (fresh && PlatformDetector.isTV() && PhoneSession.available) _UPhoneRow(onTap: () => Navigator.of(context).pop(_UEditorExit.phone)),
        _UField(controller: _name, label: 'Name', hint: 'My indexer', maxLength: 80),
        _UField(controller: _url, label: 'URL', hint: 'https://indexer.example', keyboard: TextInputType.url, maxLength: 2000),
        _UField(controller: _path, label: 'API path', hint: '/api', keyboard: TextInputType.url, maxLength: 200),
        _UField(controller: _key, label: 'API key', obscure: !_reveal, onReveal: () => setState(() => _reveal = !_reveal), maxLength: 500, last: true, onSubmitted: _save),
        LayoutBuilder(
          builder: (context, c) {
            final words = const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Fetch limit', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                SizedBox(height: 3),
                Text(_usenetFetchHint, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35)),
              ],
            );
            final pick = _UPick(value: _usenetFetchLabel(_fetch), onTap: _pickFetch);
            return c.maxWidth < 420
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [words, const SizedBox(height: 10), pick])
                : Row(children: [Expanded(child: words), const SizedBox(width: 14), pick]);
          },
        ),
      ],
      footer: [
        if (_error != null) _UMessage(_error!, bad: true),
        if (_testing)
          const _UMessage('Checking indexer capabilities…', busy: true)
        else if (_result != null && _tested == _fields)
          _UMessage(_result!, bad: !_resultOk, good: _resultOk),
      ],
      actions: [
        _SmallButton(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
        _SmallButton(label: _testing ? 'Testing…' : 'Test indexer', icon: Icons.wifi_tethering_rounded, onTap: _test),
        _SmallButton(label: _saving ? 'Saving…' : 'Save', icon: Icons.check_rounded, primary: true, onTap: _save),
      ],
    );
  }
}

/// Search User-Agent or NZB download User-Agent: what VyseTV is called there. Shown with what is
/// sent now; saving VyseTV's own (or nothing) goes back to following it.
class _UUserAgentDialog extends StatefulWidget {
  const _UUserAgentDialog({required this.setting, required this.title, required this.subtitle});
  final Setting<String> setting;
  final String title;
  final String subtitle;

  @override
  State<_UUserAgentDialog> createState() => _UUserAgentDialogState();
}

class _UUserAgentDialogState extends State<_UUserAgentDialog> {
  late final _text = TextEditingController(text: _sent);
  String? _error;

  String get _sent {
    final v = widget.setting.value.trim();
    return v.isEmpty || !UsenetPlay.validUserAgent(v) ? UsenetPlay.defaultUserAgent : v;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final t = _text.text.trim();
    if (!UsenetPlay.validUserAgent(t)) {
      setState(() => _error = 'Use plain text on one line, up to 256 characters.');
      return;
    }
    widget.setting.set(t.isEmpty || t == UsenetPlay.defaultUserAgent ? '' : t);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: VyseColors.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    title: Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.subtitle, style: const TextStyle(color: VyseColors.textDim, height: 1.4)),
            const SizedBox(height: 14),
            TextField(
              controller: _text,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [LengthLimitingTextInputFormatter(300)],
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
              onTapOutside: dismissKeyboard,
              cursorColor: VyseColors.accent,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'User-Agent',
                hintText: UsenetPlay.defaultUserAgent,
                hintStyle: const TextStyle(color: VyseColors.textFaint, fontSize: 14),
                errorText: _error,
                errorMaxLines: 2,
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          widget.setting.set('');
          Navigator.of(context).pop();
        },
        child: const Text('Reset to default'),
      ),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      TextButton(onPressed: _save, child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700))),
    ],
  );
}

// ── your own sorting profile ──

/// A part of the profile editor: its name, what it does, and its controls.
class _UBlock extends StatelessWidget {
  const _UBlock({required this.title, this.subtitle, this.child});
  final String title;
  final String? subtitle;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
      if (subtitle != null) ...[const SizedBox(height: 4), Text(subtitle!, style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35))],
      if (child != null) ...[const SizedBox(height: 10), child!],
    ],
  );
}

/// One of several to pick together (a language, a resolution).
class _UChip extends StatelessWidget {
  const _UChip({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, _) => AnimatedContainer(
      duration: Lean.time(const Duration(milliseconds: 160)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: on ? VyseColors.accent.withValues(alpha: .18) : Colors.white.withValues(alpha: hovered ? .09 : .05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: on ? VyseColors.accent.withValues(alpha: .55) : VyseColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (on) ...[const Icon(Icons.check_rounded, size: 14, color: VyseColors.accent), const SizedBox(width: 5)],
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: on ? VyseColors.text : VyseColors.textDim)),
        ],
      ),
    ),
  );
}

/// A numbered line in one of the profile's lists: what it is (pressed to change it, when it
/// can be), and its buttons, beside it or under it when narrow.
class _UListRow extends StatelessWidget {
  const _UListRow({required this.number, required this.title, required this.actions, this.subtitle, this.onTap});
  final int number;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: VyseColors.accent.withValues(alpha: .16)),
      child: Text('$number', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: VyseColors.accent)),
    );
    Widget words(bool hovered) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: hovered ? .06 : 0), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: VyseColors.textDim, height: 1.3)),
          ],
        ],
      ),
    );
    final main = onTap == null ? words(false) : Pressable(onTap: onTap, builder: (context, hovered, _) => words(hovered));
    final buttons = Wrap(spacing: 2, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: actions);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 500
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [badge, const SizedBox(width: 6), Expanded(child: main)]),
                  const SizedBox(height: 4),
                  Align(alignment: Alignment.centerRight, child: buttons),
                ],
              )
            : Row(children: [badge, const SizedBox(width: 6), Expanded(child: main), const SizedBox(width: 8), buttons]),
      ),
    );
  }
}

String _usenetGb(num v) => v == 0 ? 'No preference' : '${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(1)} GB';

/// Your own sorting profile: languages, sizes, how results are sorted, quality tiers and rules.
/// Answers the profile to save, or null when left.
class _URankingEditor extends StatefulWidget {
  const _URankingEditor({required this.initial, required this.fresh});
  final Map<String, Object?> initial;

  /// No profile was saved yet: offer a start.
  final bool fresh;

  @override
  State<_URankingEditor> createState() => _URankingEditorState();
}

class _URankingEditorState extends State<_URankingEditor> {
  late Map<String, dynamic> _p = _own(widget.initial);
  late final _name = TextEditingController(text: '${_p['name']}');
  String? _error;
  String? _note;
  bool _noteBad = false;

  /// A copy of [p] of our own to change (plain JSON: lists and maps that can grow).
  static Map<String, dynamic> _own(Map<String, Object?> p) => jsonDecode(jsonEncode(UsenetProfileJson.normalize(p))) as Map<String, dynamic>;

  List<dynamic> get _tiers => _p['tiers'] as List<dynamic>;
  List<dynamic> get _sort => _p['sort'] as List<dynamic>;
  List<dynamic> get _rules => _p['rules'] as List<dynamic>;
  List<dynamic> get _langs => _p['preferredLanguages'] as List<dynamic>;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _set(void Function() change) => setState(() {
    change();
    _error = null;
  });

  void _start(Map<String, Object?> p) => setState(() {
    _p = _own(p);
    _name.text = '${_p['name']}';
    _error = null;
  });

  Map<String, Object?> get _current => UsenetProfileJson.normalize({..._p, 'name': _name.text.trim()});

  bool _sorts(String key) => _sort.any((e) => (e as Map)['key'] == key);

  /// A score rule needs Rule score in the sorting: it goes second when it isn't there.
  void _scoreKey(Map rule) {
    if (rule['action'] == 'BOOST' && !_sorts('SCORE')) _sort.insert(_sort.isEmpty ? 0 : 1, {'key': 'SCORE', 'descending': true});
  }

  Future<void> _pickNum(String title, String key, List<num> choices, String Function(num) label) async {
    final current = _p[key] as num;
    final options = [...choices];
    if (!options.contains(current)) {
      options
        ..add(current)
        ..sort();
    }
    final r = await _pickOne<num>(context, title: title, options: [for (final v in options) (v, label(v))], current: current);
    if (r != null) _set(() => _p[key] = r.$1);
  }

  Future<Map<String, dynamic>?> _editTier(Map tier) => _showUsenetSheet<Map<String, dynamic>>(context, _UTierEditor(tier: tier));

  Future<Map<String, dynamic>?> _editRule(Map rule) => _showUsenetSheet<Map<String, dynamic>>(context, _URuleEditor(rule: rule), maxWidth: 640);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: UsenetProfileJson.export(_current)));
    if (!mounted) return;
    setState(() {
      _note = 'Copied. Paste it into VyseTV on another device, or keep it somewhere safe.';
      _noteBad = false;
    });
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final r = UsenetProfileJson.parse(d?.text ?? '');
    if (!mounted) return;
    if (r.profile == null) {
      setState(() {
        _note = r.problem;
        _noteBad = true;
      });
      return;
    }
    _start(r.profile!);
    setState(() {
      _note = 'Pasted. Look it over, then Save to use it.';
      _noteBad = false;
    });
  }

  void _save() {
    final p = _current;
    final bad = UsenetProfileJson.problem(p);
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    Navigator.of(context).pop(p);
  }

  String _tierText(Map t) {
    final res = [for (final r in t['resolutions'] as List) UsenetProfileJson.resolutionLabel((r as num).toInt())];
    final q = [for (final x in t['qualities'] as List) UsenetProfileJson.qualityLabels[x] ?? '$x'];
    return '${res.isEmpty ? 'Any resolution' : res.join(', ')} · ${q.isEmpty ? 'any quality' : q.join(', ')}';
  }

  String _ruleTitle(Map r) {
    final what = switch (r['action']) {
      'EXCLUDE' => 'Exclude matches',
      'REQUIRE' => 'Require matches',
      _ => 'Score: ${(r['score'] as num).toInt()}',
    };
    return '${r['name']} · $what${r['enabled'] == false ? ' · Off' : ''}';
  }

  String _ruleText(Map r) => [
    for (final c in r['conditions'] as List)
      '${UsenetProfileJson.fieldLabels[(c as Map)['field']] ?? c['field']} ${(UsenetProfileJson.operatorLabels[c['operator']] ?? '${c['operator']}').toLowerCase()} ${c['value']}',
  ].join(r['matchAny'] == true ? ', or ' : ', and ');

  Widget _move(List<dynamic> list, int i) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _IconAction(icon: Icons.arrow_upward_rounded, tooltip: 'Move up', onTap: i == 0 ? null : () => _set(() => list.insert(i - 1, list.removeAt(i)))),
      _IconAction(icon: Icons.arrow_downward_rounded, tooltip: 'Move down', onTap: i == list.length - 1 ? null : () => _set(() => list.insert(i + 1, list.removeAt(i)))),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final tv = PlatformDetector.isTV();
    final top = (_p['topPerBucket'] as num).toInt();
    final unused = UsenetProfileJson.sortKeys.where((k) => !_sorts(k)).toList();
    final codes = [...UsenetSources.languages, for (final l in _langs) if (!UsenetSources.languages.contains(l)) '$l'];
    return _USheetBody(
      title: 'Your own sorting profile',
      subtitle: 'How built-in Usenet results are ordered while this is the sorting profile. Other sources keep their own order.',
      fields: [
        if (widget.fresh)
          _UBlock(
            title: 'Start from',
            subtitle: 'Balanced has quality tiers and trusted release groups to build on.',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SmallButton(label: 'Balanced', icon: Icons.auto_awesome_rounded, onTap: () => _start(UsenetProfileJson.balanced())),
                _SmallButton(label: 'An empty profile', onTap: () => _start(UsenetProfileJson.empty())),
              ],
            ),
          ),
        _UField(controller: _name, label: 'Profile name', hint: 'My profile', maxLength: 80, last: true),
        _UBlock(
          title: 'Preferred languages',
          subtitle: 'In the order picked: releases labelled with these audio languages come first wherever Preferred language is in the sorting. Unlabelled releases stay.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final code in codes)
                _UChip(
                  label: _langs.contains(code) ? '${_langs.indexOf(code) + 1}. ${UsenetProfileJson.languageLabel(code)}' : UsenetProfileJson.languageLabel(code),
                  on: _langs.contains(code),
                  onTap: () => _set(() {
                    if (!_langs.remove(code) && _langs.length < 24) _langs.add(code);
                  }),
                ),
            ],
          ),
        ),
        _UBlock(
          title: 'Preferred size',
          subtitle: 'A preference, not a filter: larger releases stay, below. A season pack counts per episode when that is known; an unknown size stays eligible.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _UPick(
                value: 'Films: ${_usenetGb(_p['preferredMovieSizeGb'] as num)}',
                onTap: () => _pickNum('Preferred film size', 'preferredMovieSizeGb', const [0, 4, 8, 12, 15, 20, 30, 40, 50, 60, 80, 100], _usenetGb),
              ),
              _UPick(
                value: 'Episodes: ${_usenetGb(_p['preferredEpisodeSizeGb'] as num)}',
                onTap: () => _pickNum('Preferred episode size', 'preferredEpisodeSizeGb', const [0, .5, 1, 1.5, 2, 3, 4, 5, 8, 10, 15], _usenetGb),
              ),
            ],
          ),
        ),
        _UBlock(
          title: 'Top results per category',
          subtitle: 'Keeps this many results of each resolution and quality near the top; the rest follow, still there. 0 keeps the strict order.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: _UPick(
              value: top == 0 ? 'Strict order' : '$top',
              onTap: () => _pickNum('Top results per category', 'topPerBucket', [for (var n = 0; n <= 20; n++) n], (v) => v == 0 ? '0 (strict order)' : '${v.toInt()}'),
            ),
          ),
        ),
        _UBlock(
          title: 'Sorting priorities',
          subtitle: 'Applied from the top down. Put Rule score above Quality tier to let strong rules outweigh a tier. Releases known to fail always stay below.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _sort.length; i++)
                () {
                  final e = _sort[i] as Map;
                  final key = '${e['key']}';
                  final desc = e['descending'] != false;
                  return _UListRow(
                    number: i + 1,
                    title: UsenetProfileJson.keyLabels[key] ?? key,
                    actions: [
                      _SmallButton(label: UsenetProfileJson.directionLabel(key, desc), icon: desc ? Icons.south_rounded : Icons.north_rounded, onTap: () => _set(() => e['descending'] = !desc)),
                      _move(_sort, i),
                      _IconAction(icon: Icons.close_rounded, tooltip: 'Remove', danger: true, onTap: _sort.length == 1 ? null : () => _set(() => _sort.removeAt(i))),
                    ],
                  );
                }(),
              if (unused.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _SmallButton(label: 'Add priority', icon: Icons.add_rounded, onTap: () => _set(() => _sort.add({'key': unused.first, 'descending': true}))),
                  ),
                ),
            ],
          ),
        ),
        _UBlock(
          title: 'Quality tiers',
          subtitle: 'The first tier a release matches is its tier. No resolutions or qualities picked matches any. Releases in no tier stay, below the named ones.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _tiers.length; i++)
                _UListRow(
                  number: i + 1,
                  title: '${(_tiers[i] as Map)['name']}',
                  subtitle: _tierText(_tiers[i] as Map),
                  onTap: () async {
                    final t = await _editTier(_tiers[i] as Map);
                    if (t != null) _set(() => _tiers[i] = t);
                  },
                  actions: [
                    _move(_tiers, i),
                    _IconAction(icon: Icons.close_rounded, tooltip: 'Remove', danger: true, onTap: () => _set(() => _tiers.removeAt(i))),
                  ],
                ),
              if (_tiers.length < 24)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _SmallButton(
                      label: 'Add tier',
                      icon: Icons.add_rounded,
                      onTap: () async {
                        final t = await _editTier(UsenetProfileJson.newTier());
                        if (t == null) return;
                        _set(() {
                          _tiers.add(t);
                          if (!_sorts('TIER')) _sort.insert(0, {'key': 'TIER', 'descending': true});
                        });
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        _UBlock(
          title: 'Rules',
          subtitle:
              'Every matching score rule adds its points. Require and Exclude are filters; a minimum remaining count applies one only when enough releases are left. '
              'Rules read release names and what indexers say, not the video itself.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _rules.length; i++)
                _UListRow(
                  number: i + 1,
                  title: _ruleTitle(_rules[i] as Map),
                  subtitle: _ruleText(_rules[i] as Map),
                  onTap: () async {
                    final r = await _editRule(_rules[i] as Map);
                    if (r == null) return;
                    _set(() {
                      _rules[i] = r;
                      _scoreKey(r);
                    });
                  },
                  actions: [
                    _move(_rules, i),
                    _IconAction(icon: Icons.close_rounded, tooltip: 'Remove', danger: true, onTap: () => _set(() => _rules.removeAt(i))),
                  ],
                ),
              if (_rules.length < 80)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _SmallButton(
                      label: 'Add rule',
                      icon: Icons.add_rounded,
                      onTap: () async {
                        final r = await _editRule(UsenetProfileJson.newRule());
                        if (r == null) return;
                        _set(() {
                          _rules.add(r);
                          _scoreKey(r);
                        });
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
        _UBlock(
          title: 'Copy and paste',
          subtitle: tv
              ? 'To bring in a profile copied elsewhere, paste it on your phone: Edit on your phone, then Usenet.'
              : 'Share this profile, or bring in one copied from VyseTV elsewhere. A profile holds no passwords or API keys.',
          child: tv
              ? null
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _SmallButton(label: 'Copy', icon: Icons.copy_rounded, onTap: _copy),
                    _SmallButton(label: 'Paste', icon: Icons.content_paste_rounded, onTap: _paste),
                  ],
                ),
        ),
      ],
      footer: [
        if (_note != null) _UMessage(_note!, bad: _noteBad, good: !_noteBad),
        if (_error != null) _UMessage(_error!, bad: true),
      ],
      actions: [
        _SmallButton(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
        _SmallButton(label: 'Save', icon: Icons.check_rounded, primary: true, onTap: _save),
      ],
    );
  }
}

/// A quality tier: its name, and the resolutions and qualities that belong to it.
class _UTierEditor extends StatefulWidget {
  const _UTierEditor({required this.tier});
  final Map tier;

  @override
  State<_UTierEditor> createState() => _UTierEditorState();
}

class _UTierEditorState extends State<_UTierEditor> {
  late final _name = TextEditingController(text: '${widget.tier['name'] ?? ''}');
  late final _res = <int>{for (final r in widget.tier['resolutions'] as List? ?? const []) (r as num).toInt()};
  late final _q = <String>{for (final q in widget.tier['qualities'] as List? ?? const []) '$q'};
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    final t = <String, dynamic>{
      'name': _name.text.trim(),
      'resolutions': [for (final r in UsenetProfileJson.resolutions) if (_res.contains(r)) r],
      'qualities': [for (final q in UsenetProfileJson.qualities) if (_q.contains(q)) q],
    };
    final bad = UsenetProfileJson.tierProblem(t);
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) => _USheetBody(
    title: 'Quality tier',
    subtitle: 'A release whose resolution and quality are among those picked here is in this tier. Pick none of one kind to match any.',
    fields: [
      _UField(controller: _name, label: 'Tier name', hint: '4K remux', maxLength: 80, last: true),
      _UBlock(
        title: 'Resolutions',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in UsenetProfileJson.resolutions)
              _UChip(label: UsenetProfileJson.resolutionLabel(r), on: _res.contains(r), onTap: () => setState(() => _res.contains(r) ? _res.remove(r) : _res.add(r))),
          ],
        ),
      ),
      _UBlock(
        title: 'Qualities',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final q in UsenetProfileJson.qualities)
              _UChip(label: UsenetProfileJson.qualityLabels[q]!, on: _q.contains(q), onTap: () => setState(() => _q.contains(q) ? _q.remove(q) : _q.add(q))),
          ],
        ),
      ),
    ],
    footer: [if (_error != null) _UMessage(_error!, bad: true)],
    actions: [
      _SmallButton(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
      _SmallButton(label: 'Done', icon: Icons.check_rounded, primary: true, onTap: _done),
    ],
  );
}

/// A condition being edited: what it looks at, how, and the value.
class _UCondition {
  _UCondition(this.field, this.op, String value) : value = TextEditingController(text: value);
  String field;
  String op;
  final TextEditingController value;
}

/// A rule: its name, what it does (adds a score, or keeps out or keeps only what matches), and
/// its conditions.
class _URuleEditor extends StatefulWidget {
  const _URuleEditor({required this.rule});
  final Map rule;

  @override
  State<_URuleEditor> createState() => _URuleEditorState();
}

class _URuleEditorState extends State<_URuleEditor> {
  late final _name = TextEditingController(text: '${widget.rule['name'] ?? ''}');
  late bool _enabled = widget.rule['enabled'] != false;
  late String _action = UsenetProfileJson.actions.contains(widget.rule['action']) ? widget.rule['action'] as String : 'BOOST';
  late final _score = TextEditingController(text: '${(widget.rule['score'] as num? ?? 100).toInt()}');
  late final _minimum = TextEditingController(text: '${(widget.rule['minimumRemaining'] as num? ?? 0).toInt()}');
  late bool _any = widget.rule['matchAny'] == true;
  late final _conditions = <_UCondition>[
    for (final c in widget.rule['conditions'] as List? ?? const [])
      _UCondition('${(c as Map)['field'] ?? 'TITLE'}', '${c['operator'] ?? 'CONTAINS'}', '${c['value'] ?? ''}'),
  ];
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_conditions.isEmpty) _conditions.add(_UCondition('TITLE', 'CONTAINS', ''));
  }

  @override
  void dispose() {
    _name.dispose();
    _score.dispose();
    _minimum.dispose();
    for (final c in _conditions) {
      c.value.dispose();
    }
    super.dispose();
  }

  static String _hint(String field) => switch (field) {
    'TITLE' => 'Part of the name, like REPACK',
    'GROUP' => 'NTb, FLUX',
    'QUALITY' => 'REMUX, BLURAY',
    'RESOLUTION' => '1080',
    'CODEC' => 'HEVC, AV1',
    'VISUAL' => 'HDR, DV',
    'AUDIO' => 'ATMOS, TRUEHD',
    'LANGUAGE' => 'en, ja',
    'INDEXER' => "An indexer's name",
    'SIZE_GB' => '20',
    'AGE_DAYS' => '30',
    'MEDIA_TYPE' => 'movie or series',
    _ => '',
  };

  Future<void> _pickField(_UCondition c) async {
    final r = await _pickOne<String>(context, title: 'Looks at', options: [for (final f in UsenetProfileJson.fields) (f, UsenetProfileJson.fieldLabels[f]!)], current: c.field);
    if (r == null || r.$1 == c.field || !mounted) return;
    // a new field starts over: numbers from at least 0, the rest from "is one of"
    final numeric = UsenetProfileJson.numericFields.contains(r.$1);
    setState(() {
      c.field = r.$1;
      c.op = numeric ? 'AT_LEAST' : 'IS';
      c.value.text = numeric ? '0' : '';
      _error = null;
    });
  }

  Future<void> _pickOperator(_UCondition c) async {
    final r = await _pickOne<String>(
      context,
      title: 'How it compares',
      options: [for (final o in UsenetProfileJson.operatorsFor(c.field)) (o, UsenetProfileJson.operatorLabels[o]!)],
      current: c.op,
    );
    if (r != null && mounted) setState(() => c.op = r.$1);
  }

  void _done() {
    final score = int.tryParse(_score.text.trim());
    final minimum = int.tryParse(_minimum.text.trim());
    if (_action == 'BOOST' && (score == null || score < -10000 || score > 10000)) {
      setState(() => _error = 'The score is a whole number from -10000 to 10000.');
      return;
    }
    if (_action != 'BOOST' && (minimum == null || minimum < 0 || minimum > 200)) {
      setState(() => _error = 'The minimum remaining is a whole number from 0 to 200.');
      return;
    }
    final r = <String, dynamic>{
      'name': _name.text.trim(),
      'enabled': _enabled,
      'action': _action,
      'score': _action == 'BOOST' ? score : (widget.rule['score'] as num? ?? 100).toInt(),
      'matchAny': _any,
      'conditions': [
        for (final c in _conditions) {'field': c.field, 'operator': c.op, 'value': c.op == 'MATCHES' ? c.value.text : c.value.text.trim()},
      ],
      'minimumRemaining': _action == 'BOOST' ? (widget.rule['minimumRemaining'] as num? ?? 0).toInt() : minimum,
    };
    final bad = UsenetProfileJson.ruleProblem(r);
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return _USheetBody(
      title: 'Rule',
      subtitle: 'Releases it matches get its score, are kept out, or are the only ones kept.',
      fields: [
        _UField(controller: _name, label: 'Rule name', hint: 'Prefer my favourite group', maxLength: 80),
        Row(
          children: [
            const Expanded(child: Text('On', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700))),
            _Switch(value: _enabled, onChanged: (v) => setState(() => _enabled = v)),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _UPick(
              value: UsenetProfileJson.actionLabels[_action]!,
              onTap: () async {
                final r = await _pickOne<String>(context, title: 'What it does', options: [for (final a in UsenetProfileJson.actions) (a, UsenetProfileJson.actionLabels[a]!)], current: _action);
                if (r != null && mounted) setState(() => _action = r.$1);
              },
            ),
            _UPick(
              value: _any ? 'Match any condition' : 'Match all conditions',
              onTap: () async {
                final r = await _pickOne<bool>(context, title: 'Conditions', options: const [(false, 'Match all conditions'), (true, 'Match any condition')], current: _any);
                if (r != null && mounted) setState(() => _any = r.$1);
              },
            ),
          ],
        ),
        if (_action == 'BOOST')
          _UField(
            controller: _score,
            label: 'Score',
            hint: '100',
            keyboard: const TextInputType.numberWithOptions(signed: true),
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,5}'))],
          )
        else ...[
          _UField(controller: _minimum, label: 'Minimum remaining results', hint: '0', keyboard: TextInputType.number, formatters: digits, maxLength: 3),
          const Text(
            '0 applies the filter strictly. Higher keeps what there is when filtering would leave fewer releases than this. Releases known to fail never count.',
            style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.35),
          ),
        ],
        for (final (i, c) in _conditions.indexed)
          Container(
            key: ObjectKey(c),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: .03), borderRadius: BorderRadius.circular(12), border: Border.all(color: VyseColors.stroke)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Condition ${i + 1}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: VyseColors.textDim))),
                    if (_conditions.length > 1)
                      _IconAction(
                        icon: Icons.close_rounded,
                        tooltip: 'Remove this condition',
                        danger: true,
                        onTap: () {
                          final gone = _conditions[i];
                          setState(() {
                            _conditions.removeAt(i);
                            _error = null;
                          });
                          // its box lets go of it in the next frame
                          WidgetsBinding.instance.addPostFrameCallback((_) => gone.value.dispose());
                        },
                      )
                    else
                      const SizedBox(height: 34),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _UPick(value: UsenetProfileJson.fieldLabels[c.field] ?? c.field, onTap: () => _pickField(c)),
                    _UPick(value: UsenetProfileJson.operatorLabels[c.op] ?? c.op, onTap: () => _pickOperator(c)),
                  ],
                ),
                const SizedBox(height: 10),
                _UField(
                  controller: c.value,
                  label: 'Value',
                  hint: _hint(c.field),
                  keyboard: c.op == 'AT_LEAST' || c.op == 'AT_MOST' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
                  maxLength: c.op == 'MATCHES' ? 256 : 512,
                ),
              ],
            ),
          ),
        if (_conditions.length < 8)
          Align(
            alignment: Alignment.centerLeft,
            child: _SmallButton(
              label: 'Add condition',
              icon: Icons.add_rounded,
              onTap: () => setState(() {
                final c = UsenetProfileJson.newCondition();
                _conditions.add(_UCondition('${c['field']}', '${c['operator']}', '${c['value']}'));
              }),
            ),
          ),
        const Text(UsenetProfileJson.valuesHint, style: TextStyle(fontSize: 12.5, color: VyseColors.textDim, height: 1.4)),
      ],
      footer: [if (_error != null) _UMessage(_error!, bad: true)],
      actions: [
        _SmallButton(label: 'Cancel', onTap: () => Navigator.of(context).pop()),
        _SmallButton(label: 'Done', icon: Icons.check_rounded, primary: true, onTap: _done),
      ],
    );
  }
}
