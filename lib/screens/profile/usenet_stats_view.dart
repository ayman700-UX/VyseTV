import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/usenet/usenet_sources.dart';
import '../../data/usenet/usenet_stats.dart';
import '../../dpad/focusable_wrapper.dart';
import '../../widgets/common.dart' show Pressable;

const _card = Color(0xFF0D0F18);
const _danger = Color(0xFFF26B6B);
const _gap = 14.0;

/// Settings > Usenet > Diagnostics, under the startup cards: which days and content the counts
/// cover, a comparison of the sources, a card per indexer and per provider (in your list's
/// order), and Reset statistics. Shown once at least one provider or indexer is set up; it
/// follows the counts live. Each card is a stop for a remote, so it can be brought into view
/// and read; on a wide window the cards go two to a row.
class UsenetStatisticsSection extends StatefulWidget {
  const UsenetStatisticsSection({super.key});

  @override
  State<UsenetStatisticsSection> createState() => _UsenetStatisticsSectionState();
}

class _UsenetStatisticsSectionState extends State<UsenetStatisticsSection> {
  @override
  void initState() {
    super.initState();
    // reading the counts writes what was held, so what is shown is what is kept
    UsenetStats.instance.flush();
  }

  Future<void> _reset() async {
    final yes = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: VyseColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Reset statistics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        content: const Text('Clear all provider and indexer statistics? This cannot be undone.', style: TextStyle(color: VyseColors.textDim)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: _danger, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (yes == true) await UsenetStats.instance.reset();
  }

  @override
  Widget build(BuildContext context) {
    final stats = UsenetStats.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([stats.revision, stats.period, stats.content, UsenetSourcesStore.current]),
      builder: (context, _) {
        final sources = UsenetSourcesStore.current.value;
        if (sources.providers.isEmpty && sources.indexers.isEmpty) return const SizedBox.shrink();
        final period = stats.period.value;
        String name(String n) => n.trim().isEmpty ? 'Unnamed' : n.trim();

        final indexers = [for (final i in sources.indexers) (i, stats.indexer(i.id), stats.indexerToday(i.id))];
        final providers = [for (final p in sources.providers) (p, stats.provider(p.id))];
        final cards = <Widget>[
          if (indexers.length >= 2) ...[
            _BarCard(title: 'Releases played', bars: [for (final (i, c, _) in indexers) (name(i.name), c.played)]),
            _BarCard(title: 'NZB downloads', bars: [for (final (i, c, _) in indexers) (name(i.name), c.grabs)]),
          ],
          if (providers.length >= 2) _BarCard(title: 'Articles served', bars: [for (final (p, c) in providers) (name(p.name), c.articles)]),
          for (final (i, c, today) in indexers) _StatCard(title: name(i.name), rows: UsenetStatRows.indexer(c, today, period, stats.since(i.id))),
          for (final (p, c) in providers) _StatCard(title: name(p.name), rows: UsenetStatRows.provider(c, period, stats.since(p.id))),
        ].where((w) => w is! _BarCard || w.shown).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PickerRow<StatsPeriod>(
              icon: Icons.calendar_month_outlined,
              title: 'Statistics period',
              subtitle: 'The days the source statistics below count',
              value: period,
              options: StatsPeriod.values,
              label: (p) => p.label,
              onChanged: stats.setPeriod,
            ),
            const SizedBox(height: _gap),
            _PickerRow<StatsContent>(
              icon: Icons.movie_outlined,
              title: 'Statistics content',
              subtitle: 'The searches and playback the source statistics below count',
              value: stats.content.value,
              options: StatsContent.values,
              label: (c) => c.label,
              onChanged: stats.setContent,
            ),
            if (cards.isNotEmpty) ...[const SizedBox(height: _gap), _CardGrid(children: cards)],
            const SizedBox(height: _gap),
            _ResetRow(onReset: _reset),
          ],
        );
      },
    );
  }
}

/// Settings > Usenet > Diagnostics: how long the last Usenet stream took to start, step by
/// step (a summary, the engine, the NZB's stages, the caches). Before any, only the summary,
/// saying how to get one. Each card is a stop for a remote; on a wide window two to a row.
class UsenetDiagnosticsCard extends StatelessWidget {
  const UsenetDiagnosticsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final diagnostics = UsenetDiagnostics.instance;
    diagnostics.ensureLoaded();
    return ValueListenableBuilder<UsenetStartupReport?>(
      valueListenable: diagnostics.last,
      builder: (context, report, _) => _CardGrid(
        children: [
          for (final c in UsenetDiagnostics.cards(report))
            _ReadCard(
              label: c.title,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Header(c.title),
                  for (final r in c.rows) _InfoRow(r.label, r.value, highlight: r.highlight),
                  if (c.note != null) ...[
                    SizedBox(height: c.rows.isEmpty ? 2 : 10),
                    Text(c.note!, style: TextStyle(fontSize: c.rows.isEmpty ? 13 : 11.5, color: c.rows.isEmpty ? VyseColors.textDim : VyseColors.textFaint, height: 1.4)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Cards one under another, or two to a row where there is room for both.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children});
  final List<Widget> children;

  static const twoFrom = 760.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final two = box.maxWidth >= twoFrom;
      if (!two) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: _gap), children[i]],
          ],
        );
      }
      final each = (box.maxWidth - _gap) / 2;
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [for (final c in children) SizedBox(width: each, child: c)],
      );
    },
  );
}

/// A card of facts with nothing to press: a stop for a remote all the same, so it is brought
/// into view and read like the rest of the page.
class _ReadCard extends StatelessWidget {
  const _ReadCard({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => FocusableWrapper(
    semanticLabel: label,
    excludeChildSemantics: false,
    borderRadius: 14,
    disableScale: true,
    useFocusGlow: true,
    child: Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: VyseColors.stroke)),
      child: child,
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: VyseColors.accent),
    ),
  );
}

/// "Label …… value" on one line; the label gives way first.
class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.highlight = false});
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3.5),
    child: Row(
      children: [
        Expanded(
          flex: 5,
          child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
        ),
        const SizedBox(width: 12),
        Flexible(
          flex: 4,
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: highlight ? FontWeight.w800 : FontWeight.w600,
              color: highlight ? VyseColors.accent : VyseColors.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );
}

/// An indexer's or a provider's counts; "No data yet" when the period and content chosen
/// have none.
class _StatCard extends StatelessWidget {
  const _StatCard({required this.title, required this.rows});
  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => _ReadCard(
    label: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(title),
        if (rows.isEmpty)
          const Text('No data yet', style: TextStyle(fontSize: 13, color: VyseColors.textFaint))
        else
          for (final (label, value) in rows) _InfoRow(label, value),
      ],
    ),
  );
}

/// The sources side by side on one count: the largest first, each bar its share of the largest.
class _BarCard extends StatelessWidget {
  _BarCard({required this.title, required List<(String, int)> bars})
    : bars = [...bars]..sort((a, b) {
        final c = b.$2.compareTo(a.$2);
        return c != 0 ? c : a.$1.toLowerCase().compareTo(b.$1.toLowerCase());
      });
  final String title;
  final List<(String, int)> bars;

  /// Only with two sources or more, and something counted.
  bool get shown => bars.length >= 2 && bars.first.$2 > 0;

  @override
  Widget build(BuildContext context) {
    final top = bars.isEmpty ? 0 : bars.first.$2;
    return _ReadCard(
      label: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(title),
          for (final (name, value) in bars)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: VyseColors.textDim)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 4,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .06), borderRadius: BorderRadius.circular(4)),
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: top <= 0 ? 0 : (value / top).clamp(0.0, 1.0),
                        child: Container(decoration: BoxDecoration(color: VyseColors.accent, borderRadius: BorderRadius.circular(4))),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('$value', maxLines: 1, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A title and what it does, with the choices beside it, or under it where the row is narrow.
class _PickerRow<T> extends StatelessWidget {
  const _PickerRow({required this.icon, required this.title, required this.subtitle, required this.value, required this.options, required this.label, required this.onChanged});
  final IconData icon;
  final String title;
  final String subtitle;
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
    decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: VyseColors.stroke)),
    child: LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 600;
        final text = _TitleText(icon: icon, title: title, subtitle: subtitle, lines: wide ? 1 : 2);
        final choices = _Segments<T>(value: value, options: options, label: label, onChanged: onChanged, fill: !wide);
        return wide
            ? Row(children: [Expanded(child: text), const SizedBox(width: 16), choices])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [text, const SizedBox(height: 12), choices]);
      },
    ),
  );
}

class _TitleText extends StatelessWidget {
  const _TitleText({required this.icon, required this.title, required this.subtitle, this.lines = 1});
  final IconData icon;
  final String title;
  final String subtitle;

  /// One beside a control; two when the control is under it.
  final int lines;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: VyseColors.textDim),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(subtitle, maxLines: lines, softWrap: lines > 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: VyseColors.textDim, height: 1.3)),
          ],
        ),
      ),
    ],
  );
}

/// Choices in a dark tray, the one in use lifted. [fill]: they share the whole width.
class _Segments<T> extends StatelessWidget {
  const _Segments({required this.value, required this.options, required this.label, required this.onChanged, required this.fill});
  final T value;
  final List<T> options;
  final String Function(T) label;
  final ValueChanged<T> onChanged;
  final bool fill;

  @override
  Widget build(BuildContext context) {
    Widget option(T o) => Pressable(
      onTap: () => onChanged(o),
      builder: (context, hovered, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: EdgeInsets.symmetric(horizontal: fill ? 8 : 16, vertical: 9),
        alignment: fill ? Alignment.center : null,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          color: o == value ? Colors.white.withValues(alpha: .16) : Colors.white.withValues(alpha: hovered ? .06 : 0),
        ),
        child: Text(
          label(o),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: o == value ? VyseColors.text : VyseColors.textDim),
        ),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: .05), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [for (final o in options) fill ? Expanded(child: option(o)) : option(o)],
      ),
    );
  }
}

class _ResetRow extends StatelessWidget {
  const _ResetRow({required this.onReset});
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
    decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14), border: Border.all(color: VyseColors.stroke)),
    child: LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 480;
        final text = _TitleText(icon: Icons.cleaning_services_outlined, title: 'Reset statistics', subtitle: 'Clear the counts of every provider and indexer', lines: wide ? 1 : 2);
        final button = _DangerButton(label: 'Reset', onTap: onReset);
        return wide
            ? Row(children: [Expanded(child: text), const SizedBox(width: 16), button])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, const SizedBox(height: 12), button]);
      },
    ),
  );
}

/// Settings' small red button.
class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    builder: (context, hovered, pressed) => AnimatedScale(
      scale: pressed ? .95 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(18, 11, 18, 11),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: _danger.withValues(alpha: hovered ? .2 : .1)),
        child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _danger)),
      ),
    ),
  );
}
