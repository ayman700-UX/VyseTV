import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../dpad/dpad_traversal.dart';
import '../../dpad/input_mode_tracker.dart';

/// The Siri Remote, beyond what the engine already turns into keys.
///
/// The tvOS engine turns a click on the remote's ring (or a press of the older remote's touch
/// surface at its edge) into an arrow key, a click in the middle into Select, and Menu/Back into
/// Escape: the D-pad kit takes those like any remote's. Two things it leaves to the app, both
/// sent on the channel the engine uses for the remote's touch surface:
///
///  * Play/Pause, which tvos/Runner/AppDelegate.swift takes and sends as `play_pause`. It
///    becomes the media play/pause key every player already answers.
///  * Swipes on the touch surface (`started`, `move`, `ended`, `cancelled`, in the surface's
///    points). The first Siri Remote has no ring, only that surface: without this an Apple TV HD
///    could not be driven at all. A swipe moves the focus one step per [step] points of travel
///    along its main axis, as many steps as the finger travels, never coasting after it lifts.
///
/// The keys go to the focused control and up through its parents, the way a key from the
/// keyboard does (a [Shortcuts] or a [Focus] with `onKeyEvent` sees them alike), as upstream's
/// Apple TV remote does it. Such a key never passes [HardwareKeyboard], so the D-pad kit is told
/// of it by hand: the app is in remote mode, and a key was pressed.
class AppleTvRemote {
  AppleTvRemote({this.step = 280, @visibleForTesting void Function(LogicalKeyboardKey key)? press})
    : _press = press ?? _pressOnFocus;

  static final instance = AppleTvRemote();

  static const _channel = BasicMessageChannel<Object?>('flutter/gamepadtouchevent', JSONMessageCodec());

  /// Points of travel on the touch surface for one step of focus.
  final double step;

  final void Function(LogicalKeyboardKey key) _press;

  bool _listening = false;
  Offset? _anchor;
  Axis? _axis;

  void start() {
    if (_listening) return;
    _listening = true;
    _channel.setMessageHandler((message) async {
      handle(message);
      return null;
    });
  }

  /// One message of the engine (or of AppDelegate.swift). Public for the tests.
  @visibleForTesting
  void handle(Object? message) {
    if (message is! Map) return;
    switch (message['type']) {
      case 'play_pause':
        _press(LogicalKeyboardKey.mediaPlayPause);
      case 'started':
        _anchor = _point(message);
        _axis = null;
      case 'move':
        _move(_point(message));
      case 'ended' || 'cancelled':
        _anchor = null;
        _axis = null;
    }
  }

  static Offset? _point(Map<Object?, Object?> m) {
    final x = m['x'], y = m['y'];
    return x is num && y is num ? Offset(x.toDouble(), y.toDouble()) : null;
  }

  void _move(Offset? at) {
    final anchor = _anchor;
    if (at == null || anchor == null) return;
    final d = at - anchor;
    // The axis is the one the finger set off along, held for the rest of the swipe unless it
    // clearly turns (half again as far along the other).
    final along = d.dx.abs() >= d.dy.abs() ? Axis.horizontal : Axis.vertical;
    if (_axis == null || (along != _axis && _mainOf(d, along) > _mainOf(d, _axis!) * 1.5)) _axis = along;
    final axis = _axis!;
    final travel = _mainOf(d, axis);
    if (travel < step) return;
    final forward = (axis == Axis.horizontal ? d.dx : d.dy) > 0;
    final key = axis == Axis.horizontal
        ? (forward ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft)
        : (forward ? LogicalKeyboardKey.arrowDown : LogicalKeyboardKey.arrowUp);
    final steps = (travel / step).floor();
    for (var i = 0; i < steps; i++) {
      _press(key);
    }
    // (what was travelled for these steps is spent; the rest counts toward the next)
    final spent = steps * step * (forward ? 1 : -1);
    _anchor = axis == Axis.horizontal ? Offset(anchor.dx + spent, at.dy) : Offset(at.dx, anchor.dy + spent);
  }

  static double _mainOf(Offset d, Axis axis) => axis == Axis.horizontal ? d.dx.abs() : d.dy.abs();

  static final _physical = <LogicalKeyboardKey, PhysicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.mediaPlayPause: PhysicalKeyboardKey.mediaPlayPause,
  };

  /// A key down and up on the focused control, then each parent until one takes it.
  static void _pressOnFocus(LogicalKeyboardKey key) {
    InputModeTracker.reportNonPointerInput();
    Dpad.keyPressed();
    final physical = _physical[key] ?? PhysicalKeyboardKey.arrowUp;
    final now = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    for (final event in <KeyEvent>[
      KeyDownEvent(physicalKey: physical, logicalKey: key, timeStamp: now, deviceType: ui.KeyEventDeviceType.directionalPad),
      KeyUpEvent(physicalKey: physical, logicalKey: key, timeStamp: now, deviceType: ui.KeyEventDeviceType.directionalPad),
    ]) {
      FocusNode? node = FocusManager.instance.primaryFocus;
      while (node != null) {
        final handler = node.onKeyEvent;
        if (handler != null && handler(node, event) != KeyEventResult.ignored) break;
        node = node.parent;
      }
    }
    SchedulerBinding.instance.scheduleFrame();
  }
}
