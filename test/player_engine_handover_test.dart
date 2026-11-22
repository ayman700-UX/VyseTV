import 'package:flutter_test/flutter_test.dart';
import 'package:vyse_tv/data/app_settings.dart';
import 'package:vyse_tv/data/playback/player_engine.dart';

void main() {
  tearDown(() {
    AppSettings.mpvHandOver.value = '';
    PlayerEngine.debugOffered = null;
  });

  test('hand-over to mpv: off by default on an Android TV, on elsewhere', () {
    PlayerEngine.debugOffered = true; // a TV
    expect(PlayerEngine.allowHandOver, isFalse);
    PlayerEngine.debugOffered = false; // a phone, a PC
    expect(PlayerEngine.allowHandOver, isTrue);
  });

  test('a choice wins over the default, both ways', () {
    PlayerEngine.debugOffered = true;
    PlayerEngine.chooseHandOver(true);
    expect(PlayerEngine.allowHandOver, isTrue);
    PlayerEngine.debugOffered = false;
    PlayerEngine.chooseHandOver(false);
    expect(PlayerEngine.allowHandOver, isFalse);
  });
}
