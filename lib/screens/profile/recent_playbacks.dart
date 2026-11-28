import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/playback/playback_report.dart';
import '../../widgets/common.dart' show Pressable;

/// Settings → Playback → Recent playbacks: the last [PlaybackReport.keepCount] videos opened,
/// newest first, each with how it ended. Picking one opens its report card. Laid out for the
/// width it has: on a narrow phone the time moves under the title, and every line is one line.
class RecentPlaybackList extends StatelessWidget {
  const RecentPlaybackList({super.key, required this.reports, required this.onOpen, this.now});
  final List<PlaybackReport> reports;
  final void Function(PlaybackReport report) onOpen;

  /// The time "5 min ago" counts from (tests set it).
  final DateTime? now;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final narrow = box.maxWidth < 420;
      final at = now ?? DateTime.now();
      return Column(
        children: [
          for (var i = 0; i < reports.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _Entry(report: reports[i], narrow: narrow, now: at, onTap: () => onOpen(reports[i])),
          ],
        ],
      );
    },
  );
}

class _Entry extends StatelessWidget {
  const _Entry({required this.report, required this.narrow, required this.now, required this.onTap});
  final PlaybackReport report;
  final bool narrow;
  final DateTime now;
  final VoidCallback onTap;

  static const _red = Color(0xFFF26B6B);
  static const _green = Color(0xFF4CD28B);

  /// How it ended, as a colour: red for one that failed, amber for one that needed the other
  /// player or never got going, green for one that played.
  Color get _tone {
    if (report.failed) return _red;
    if (report.handedOver) return VyseColors.accent;
    if (report.started) return _green;
    return report.outcome == 'starting' ? VyseColors.textFaint : VyseColors.accent;
  }

  @override
  Widget build(BuildContext context) {
    final ago = agoText(report.when, now);
    final outcome = report.outcome.isEmpty ? '' : report.outcome[0].toUpperCase() + report.outcome.substring(1);
    final second = [outcome, if (report.source.isNotEmpty) report.source].join(' · ');
    return Pressable(
      onTap: onTap,
      tooltip: 'Open its report card',
      focusRadius: 10,
      builder: (context, hovered, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white.withValues(alpha: pressed ? .12 : (hovered ? .09 : .04)),
        ),
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: _tone, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    report.title.isEmpty ? 'A video' : report.title,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    second,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: report.failed ? _red : VyseColors.textDim),
                  ),
                  // (on a narrow phone the time has a line of its own, under the rest)
                  if (narrow && ago.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(ago, maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 12, color: VyseColors.textFaint)),
                  ],
                ],
              ),
            ),
            if (!narrow && ago.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(ago, maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 12.5, color: VyseColors.textFaint)),
            ],
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded, size: 20, color: VyseColors.textFaint),
          ],
        ),
      ),
    );
  }
}

/// "Just now", "5 min ago", "3 h ago", "Yesterday", "4 days ago"; empty for a time not known.
String agoText(DateTime when, DateTime now) {
  if (when.year < 2000) return '';
  final d = now.difference(when);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'Yesterday';
  return '${d.inDays} days ago';
}
