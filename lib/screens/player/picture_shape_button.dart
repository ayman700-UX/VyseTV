// VyseTV addition (not in upstream).
//
// The picture's shape (PictureShape) for the players that have no menus of their own: the Live
// TV channel player and the portal browser's player. One button: each press, or OK with a
// remote, moves to the next shape (Fit, Fill, Stretch, 16:9, 4:3, 21:9), and it says which one
// is on. The engines are told as the film player tells them (player_page.dart, _applyShape).

import 'package:flutter/material.dart';

import '../../data/app_settings.dart';
import '../../mpv/mpv.dart';
import '../../widgets/common.dart';
import 'picture_shape.dart';

/// Tells [player] [shape] for a picture drawn in [box] (the box matters for Stretch only): the
/// picture frame (Media3, an LG's and a Samsung's player), then mpv's own two properties (which
/// Media3's plugin also reads, and keeps for the mpv it may hand a video to).
Future<void> applyPictureShape(Player player, PictureShape shape, Size? box) async {
  try {
    await player.setBoxFitMode(shape.boxFit);
  } catch (_) {}
  try {
    await player.setProperty('video-aspect-override', shape.aspectOverride(box));
  } catch (_) {}
  try {
    await player.setProperty('panscan', shape.panscan);
  } catch (_) {}
}

/// The next shape the button moves to: every one in turn, then Fit again.
PictureShape nextPictureShape(PictureShape s) => PictureShape.values[(s.index + 1) % PictureShape.values.length];

/// The shape a player opens with: Fit, Fill or Stretch as last picked on this device (a fixed
/// shape is about one video, and is not kept).
PictureShape rememberedPictureShape() => PictureShape.remembered(AppSettings.pictureShape.value);

/// Keeps [s] for the next player if it is one that is kept.
void keepPictureShape(PictureShape s) {
  if (s.kept) AppSettings.pictureShape.set(s.id);
}

/// The button: an icon with the shape in use beside it.
class PictureShapeButton extends StatelessWidget {
  const PictureShapeButton({super.key, required this.shape, required this.onTap});
  final PictureShape shape;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    tooltip: 'Aspect ratio: ${shape.label}',
    focusRadius: 20,
    builder: (context, hovered, pressed) => AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.white.withValues(alpha: pressed ? .22 : (hovered ? .16 : .1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.aspect_ratio_rounded, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Text(shape.label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.white)),
        ],
      ),
    ),
  );
}
