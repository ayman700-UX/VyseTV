import 'package:flutter/material.dart';

import '../../core/lean.dart';
import '../../data/app_settings.dart';
import '../../data/subtitles/subtitle_style.dart';

/// Subtitle lines drawn by the app itself, in the look from Settings > Subtitles.
///
/// mpv and Media3 draw their own subtitles. An LG TV's player draws none for a subtitle file:
/// the file is read in the app and its lines come out as text, in time with the film
/// (`Player.subText`), and this puts them on the screen. Everything Settings offers for the
/// look is drawn here, sized as mpv sizes it (for a screen 720 lines tall, scaled to this one),
/// so the same settings look the same on a TV as on the other players.
///
/// It sits where Settings says and stays there: the lines never move for the controls.
class CaptionOverlay extends StatelessWidget {
  const CaptionOverlay({super.key, required this.lines, this.initial = '', this.pictureAspect});

  /// The text to show now ('' for nothing), each time it changes. Several lines come as one
  /// text with line breaks in it.
  final Stream<String> lines;
  final String initial;

  /// The picture's shape (width over height) while it is shown whole, for Settings' "Keep on
  /// the picture": the lines then keep out of its black bars. Null when the picture fills the
  /// screen some other way, or its shape is not known yet.
  final double? pictureAspect;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      // (its own layer: the controls coming and going over it do not paint the line again)
      child: RepaintBoundary(
        child: ListenableBuilder(
          listenable: Listenable.merge(SubtitleStyle.settings),
          builder: (context, _) => StreamBuilder<String>(
            stream: lines,
            initialData: initial,
            builder: (context, snap) => LayoutBuilder(
              builder: (context, box) => captionLines(snap.data ?? '', box.biggest, pictureAspect: pictureAspect),
            ),
          ),
        ),
      ),
    ),
  );

  /// [text] laid out for a screen of [screen]'s size. (Apart from the stream so a test, or a
  /// preview, can draw one text.)
  @visibleForTesting
  static Widget captionLines(String text, Size screen, {double? pictureAspect}) {
    final rows = [
      for (final part in text.split('\n'))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (rows.isEmpty || screen.height <= 0) return const SizedBox.shrink();
    // mpv's own measure: every size is for a screen 720 tall
    final unit = screen.height / 720;
    final size = AppSettings.subtitleSize.value * 1.3 * 720 / 1080 * unit;
    final back = AppSettings.subtitleBackground.value.clamp(0, 100);
    final box = back > 0;
    final outline = box ? 0.0 : AppSettings.subtitleOutline.value / 10 * unit;
    final shadow = box ? 0.0 : AppSettings.subtitleShadow.value / 10 * unit;
    // (the lean interface draws no blurs: a blurred edge is painted again, softened, for every
    // new line, on the chip of a TV)
    final blur = Lean.on ? 0.0 : AppSettings.subtitleBlur.value / 10 * unit;
    final base = TextStyle(
      fontFamily: SubtitleStyle.choiceFor(AppSettings.subtitleFont.value).preview,
      fontFamilyFallback: const [SubtitleStyle.defaultFamily],
      fontSize: size,
      height: 1.25,
      fontWeight: AppSettings.subtitleBold.value ? FontWeight.w700 : FontWeight.w400,
      fontStyle: AppSettings.subtitleItalic.value ? FontStyle.italic : FontStyle.normal,
      letterSpacing: AppSettings.subtitleSpacing.value / 10 * unit,
      decoration: TextDecoration.none,
    );
    Widget line(String said) {
      Widget text = Stack(
        alignment: Alignment.center,
        children: [
          if (outline > 0)
            Text(
              said,
              textAlign: TextAlign.center,
              style: base.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = outline * 2
                  ..strokeJoin = StrokeJoin.round
                  ..color = Color(AppSettings.subtitleOutlineColor.value)
                  ..maskFilter = blur > 0 ? MaskFilter.blur(BlurStyle.normal, blur) : null,
              ),
            ),
          Text(
            said,
            textAlign: TextAlign.center,
            style: base.copyWith(
              color: Color(AppSettings.subtitleColor.value),
              shadows: shadow > 0 ? [Shadow(offset: Offset(shadow, shadow), blurRadius: blur, color: Color(AppSettings.subtitleShadowColor.value))] : null,
            ),
          ),
        ],
      );
      if (box) {
        text = DecoratedBox(
          decoration: BoxDecoration(color: Color(AppSettings.subtitleBackColor.value).withValues(alpha: back / 100)),
          child: Padding(padding: EdgeInsets.symmetric(horizontal: size * .3, vertical: size * .04), child: text),
        );
      }
      return text;
    }

    // Where they rest: mpv's `sub-pos` (how far up from the bottom, or down from the top) and
    // its 22-line margin from the screen's edge; a tenth of the width is kept clear each side.
    final top = AppSettings.subtitleTop.value;
    var edge = (AppSettings.subtitleLift.value.clamp(0, 45) / 100 * screen.height) + 22 * unit;
    // "Keep on the picture": a film wider than the screen has a black bar above and below it,
    // and the lines start from the picture's edge instead of the screen's.
    if (AppSettings.subtitleOnPicture.value && pictureAspect != null && pictureAspect > 0) {
      final pictureH = screen.width / pictureAspect;
      if (pictureH < screen.height) edge += (screen.height - pictureH) / 2;
    }
    return Align(
      alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(top: top ? edge : 0, bottom: top ? 0 : edge, left: screen.width * .1, right: screen.width * .1),
        child: Column(mainAxisSize: MainAxisSize.min, children: [for (final r in rows) line(r)]),
      ),
    );
  }
}
