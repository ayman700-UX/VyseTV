import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/platform_detector.dart';
import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/usenet/nntp.dart';
import '../../data/usenet/nntp_tuner.dart';
import '../../data/usenet/usenet_play.dart';
import '../../data/usenet/usenet_sources.dart';
import '../../dpad/dpad_traversal.dart' show DpadStart;

/// Settings > Usenet > a provider > Tune connections: finds how many connections the account
/// accepts from here, which port is fastest and how many connections reach full speed, then
/// offers to apply that. It measures the provider as saved (read again when Start is pressed),
/// with Allow self-hosted servers and the Performance profile as set. Nothing is saved until
/// Apply, which changes only the provider's port, TLS and connection allowance.
///
/// Answers the connection allowance applied, or null when nothing was.
///
/// With a remote: one main button, always in the same place on the right, whose words and job
/// change as the run goes (Start, Stop, Apply or Close), so the ring stays on it; Back while
/// measuring is Stop; Up and Down scroll what is written when there is more than fits.
Future<int?> showConnectionTuner(BuildContext context, UsenetProvider provider) => showDialog<int>(
  context: context,
  useRootNavigator: true,
  barrierColor: Colors.black.withValues(alpha: .6),
  builder: (_) => _TunerDialog(provider: provider),
);

/// Tests: makes the tuner a run uses (left null, the real one).
@visibleForTesting
NntpTuner Function()? debugMakeTuner;

enum _Stage { intro, running, stopped, failed, done }

class _TunerDialog extends StatefulWidget {
  const _TunerDialog({required this.provider});
  final UsenetProvider provider;

  @override
  State<_TunerDialog> createState() => _TunerDialogState();
}

class _TunerDialogState extends State<_TunerDialog> {
  // the run going on, from whichever dialog: one for another provider stops it
  static TuneCancel? _active;

  _Stage _stage = _Stage.intro;
  TuneProgress? _progress;
  TuneOutcome? _outcome;
  TuneCancel? _cancel;
  bool _stopping = false;
  bool _saving = false;
  String? _saveProblem;
  late UsenetProvider _measured = widget.provider;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _active?.cancel();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  UsenetProvider? get _saved => UsenetSourcesStore.current.value.providers.where((p) => p.id == widget.provider.id).firstOrNull;

  void _close([int? applied]) => Navigator.of(context).pop(applied);

  void _start() {
    final fresh = _saved;
    if (fresh == null) return _close(); // deleted meanwhile
    _active?.cancel();
    final cancel = _cancel = _active = TuneCancel();
    setState(() {
      _measured = fresh;
      _stage = _Stage.running;
      _progress = null;
      _outcome = null;
      _stopping = false;
      _saveProblem = null;
    });
    (debugMakeTuner?.call() ?? NntpTuner(userAgent: UsenetPlay.defaultUserAgent))
        .run(
          fresh,
          allowPrivate: AppSettings.usenetAllowPrivate.value,
          depth: AppSettings.usenetProfile.value == 'low-memory' ? 2 : 4,
          cancel: cancel,
          onProgress: (p) {
            if (mounted && identical(_cancel, cancel)) setState(() => _progress = p);
          },
        )
        .then((outcome) {
          if (identical(_active, cancel)) _active = null;
          if (!mounted || !identical(_cancel, cancel)) return;
          setState(() {
            _outcome = outcome;
            _stage = switch (outcome) {
              TuneSucceeded() => _Stage.done,
              TuneFailed() => _Stage.failed,
              TuneStopped() => _Stage.stopped,
            };
          });
        });
  }

  void _stop() {
    if (_stage != _Stage.running || _stopping) return;
    _cancel?.cancel();
    setState(() => _stopping = true);
  }

  Future<void> _apply(TuneSucceeded r) async {
    if (_saving) return;
    final s = UsenetSourcesStore.current.value;
    final at = s.providers.indexWhere((p) => p.id == widget.provider.id);
    if (at < 0) return _close();
    setState(() => _saving = true);
    final list = [...s.providers];
    list[at] = list[at].copyWith(port: r.port, tls: r.tls, connections: r.connections);
    final problem = await UsenetSourcesStore.save(s.copyWith(providers: list));
    if (!mounted) return;
    final now = _saved;
    final applied = now != null && now.port == r.port && now.tls == r.tls && now.connections == r.connections;
    if (applied) return _close(r.connections);
    setState(() {
      _saving = false;
      _saveProblem = problem ?? "The change couldn't be saved.";
    });
  }

  /// Up and Down scroll the text when there is more of it than fits (the buttons share one
  /// line, so the two keys mean nothing else here).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent || (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) || !_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    final to = (p.pixels + p.viewportDimension * .6 * (key == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((to - p.pixels).abs() < 1) return KeyEventResult.ignored;
    _scroll.animateTo(to, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic);
    return KeyEventResult.handled;
  }

  String get _name => widget.provider.name.trim().isEmpty ? widget.provider.host : widget.provider.name.trim();

  List<Widget> _body() {
    const dim = TextStyle(fontSize: 14, color: VyseColors.textDim, height: 1.45);
    final o = _outcome;
    switch (_stage) {
      case _Stage.intro:
        return const [
          Text(
            "Checks how many connections the account accepts, then measures the download speed on the provider's ports and with more and more connections. "
            'It takes about two minutes and downloads a lot of test data: often more than 1 GB, and up to about 4 GB on a fast line. '
            'It counts against a block account. Do not play anything meanwhile. '
            'Other devices using this account at the same time lower the limit found. '
            'Nothing is saved until you apply the result.',
            style: dim,
          ),
        ];
      case _Stage.running:
        return [
          Row(
            children: [
              const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: VyseColors.accent)),
              const SizedBox(width: 12),
              Expanded(child: Text(_stopping ? 'Stopping…' : tuneProgressText(_progress), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4))),
            ],
          ),
          ..._readings(_progress?.readings ?? const []),
        ];
      case _Stage.stopped:
        return [const Text('Stopped. Nothing was changed.', style: dim), ..._readings(o?.readings ?? const [])];
      case _Stage.failed:
        final f = o as TuneFailed;
        return [Text(tuneFailureText(f), style: const TextStyle(fontSize: 14, color: Color(0xFFF87171), height: 1.45)), ..._readings(f.readings)];
      case _Stage.done:
        final r = o as TuneSucceeded;
        return [
          for (final line in tuneSummary(r, _measured))
            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(line, style: const TextStyle(fontSize: 14, height: 1.45))),
          if (_saveProblem != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text(_saveProblem!, style: const TextStyle(fontSize: 13.5, color: Color(0xFFF87171), height: 1.4))),
          ..._readings(r.readings),
        ];
    }
  }

  List<Widget> _readings(List<TuneReading> readings) {
    if (readings.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      LayoutBuilder(
        builder: (context, box) {
          final each = box.maxWidth >= 460 ? (box.maxWidth - 12) / 2 : box.maxWidth;
          return Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final r in readings)
                SizedBox(
                  width: each,
                  child: Text(
                    '$r',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: VyseColors.textDim, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  /// (the secondary button's words and job, the primary's)
  ((String, VoidCallback)?, (String, VoidCallback)) _buttons() {
    final o = _outcome;
    return switch (_stage) {
      _Stage.intro => (('Cancel', _close), ('Start', _start)),
      _Stage.running => (null, ('Stop', _stop)),
      _Stage.stopped || _Stage.failed => (('Run again', _start), ('Close', _close)),
      _Stage.done when o is TuneSucceeded && o.differsFrom(_measured) => (('Cancel', _close), (_saving ? 'Applying…' : 'Apply', () => _apply(o))),
      _Stage.done => (('Run again', _start), ('Close', _close)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final tv = PlatformDetector.isTV();
    final (secondary, primary) = _buttons();
    final body = SingleChildScrollView(
      controller: _scroll,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: _body()),
    );
    return PopScope(
      canPop: _stage != _Stage.running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stop();
      },
      child: Dialog(
        backgroundColor: VyseColors.surface,
        insetPadding: EdgeInsets.symmetric(horizontal: size.width < 520 ? 16 : 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: VyseColors.stroke)),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: VyseColors.accent.withValues(alpha: .14)),
                        child: const Icon(Icons.speed_rounded, color: VyseColors.accent, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Tune $_name',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, height: 1.2),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Flexible(child: tv ? Scrollbar(controller: _scroll, thumbVisibility: true, child: body) : body),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (secondary != null)
                        Flexible(
                          key: ValueKey('secondary-${secondary.$1}'),
                          child: TextButton(
                            onPressed: secondary.$2,
                            child: Text(secondary.$1, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      // one main button in one place: the ring stays on it as its words change
                      Padding(
                        key: const ValueKey('primary'),
                        padding: const EdgeInsets.only(left: 8),
                        child: DpadStart(
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: VyseColors.accent, foregroundColor: Colors.black),
                            onPressed: primary.$2,
                            child: Text(primary.$1, maxLines: 1, style: const TextStyle(fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line saying what a run is doing.
String tuneProgressText(TuneProgress? p) => switch (p?.phase) {
  null => 'Connecting to the provider…',
  TunePhase.limit => 'Checking the connection limit: ${p!.count} accepted so far…',
  TunePhase.port => 'Measuring port ${p!.port} with ${p.count} connections…',
  TunePhase.connections => 'Measuring ${p!.count} connections…',
};

/// Why a run ended without a result.
String tuneFailureText(TuneFailed f) => switch (f.failure) {
  TuneFailure.connect => nntpResultText(f.result == null || f.result == NntpResult.success ? NntpResult.unreachable : f.result!),
  TuneFailure.testData => 'Could not download the test data. Check the internet connection and try again.',
  TuneFailure.missingArticles => 'This provider does not have the test articles, so its speed could not be measured.',
  TuneFailure.tooSlow => 'Too little arrived to measure a speed. Try again later.',
};

/// What a run found, line by line, against [saved] (the provider as it was measured).
List<String> tuneSummary(TuneSucceeded r, UsenetProvider saved) {
  final limit = r.limit;
  return [
    limit != null ? 'Connection limit: $limit. The next connection was refused.' : 'Connection limit: none found up to ${r.tried} connections.',
    if (limit != null && saved.connections > limit)
      'The current allowance of ${saved.connections} is above the limit: playback would get refused connections and stall while the engine retries them.',
    '${r.fastestConnections} connections already reach ${r.fastestMbps.toStringAsFixed(0)} Mbps.',
    r.differsFrom(saved)
        ? 'Recommended: port ${r.port} with a connection allowance of ${r.connections} (now port ${saved.port} with ${saved.connections}). It stays under the limit and is otherwise not lowered.'
        : 'Nothing to apply: the current port and connection allowance are already the best choice.',
    'Test data downloaded: ${shortSize(r.downloadedBytes)}',
  ];
}

/// "1.2 GB", "840 MB": decimal units, as a download's size is usually told.
String shortSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var v = bytes / 1000, u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}
