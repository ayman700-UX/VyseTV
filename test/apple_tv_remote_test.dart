// The Siri Remote's touch surface and Play/Pause on an Apple TV (lib/core/platform/
// apple_tv_remote.dart), with this test playing the engine's messages.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/core/platform/apple_tv_remote.dart';

void main() {
  late List<LogicalKeyboardKey> pressed;
  late AppleTvRemote remote;

  setUp(() {
    pressed = [];
    remote = AppleTvRemote(step: 100, press: pressed.add);
  });

  void swipe(List<(double, double)> points) {
    remote.handle({'type': 'started', 'x': points.first.$1, 'y': points.first.$2});
    for (final (x, y) in points.skip(1)) {
      remote.handle({'type': 'move', 'x': x, 'y': y});
    }
    remote.handle({'type': 'ended', 'x': points.last.$1, 'y': points.last.$2});
  }

  test('Play/Pause becomes the media key every player answers', () {
    remote.handle({'type': 'play_pause', 'source': 'presses'});
    expect(pressed, [LogicalKeyboardKey.mediaPlayPause]);
  });

  test('a swipe moves one step per step of travel, in its direction', () {
    swipe([(0, 0), (60, 4), (130, 8)]);
    expect(pressed, [LogicalKeyboardKey.arrowRight]);
    pressed.clear();
    swipe([(500, 500), (500, 380), (500, 260)]);
    expect(pressed, [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowUp]);
    pressed.clear();
    swipe([(0, 0), (-350, 10)]);
    expect(pressed, [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowLeft]);
  });

  test('a touch that does not travel a step, a click on the surface, moves nothing', () {
    swipe([(10, 10), (40, 30), (12, 70)]);
    expect(pressed, isEmpty);
  });

  test('the swipe keeps its axis through a little drift, and changes it on a clear turn', () {
    swipe([(0, 0), (90, 60), (110, 80)]);
    expect(pressed, [LogicalKeyboardKey.arrowRight], reason: 'mostly sideways');
    pressed.clear();
    swipe([(0, 0), (40, 0), (40, 300)]);
    expect(pressed, [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowDown]);
  });

  test('nothing coasts after the finger lifts, and a move without a touch is ignored', () {
    swipe([(0, 0), (150, 0)]);
    remote.handle({'type': 'move', 'x': 600, 'y': 0});
    expect(pressed, [LogicalKeyboardKey.arrowRight]);
  });

  test('what the engine sends that is not for this is ignored', () {
    remote.handle('play_pause');
    remote.handle({'type': 'loc', 'x': 1, 'y': 2});
    remote.handle({'type': 'move'});
    expect(pressed, isEmpty);
  });
}
