library torrserver_flutter;

import 'dart:io';
import 'src/torrserver_controller.dart';
import 'src/torrserver_controller_ffi.dart';
import 'src/torrserver_controller_ios.dart';
import 'src/torrserver_controller_subprocess.dart';

export 'src/binary_locator.dart';
export 'src/exceptions.dart';
export 'src/models/torrent_info.dart';
export 'src/models/torrserver_settings.dart';
export 'src/port_finder.dart';
export 'src/rest_client.dart';
export 'src/torrserver_controller.dart';
export 'src/torrserver_controller_subprocess.dart' show TorrServerControllerSubprocess;

/// Factory creating a platform-appropriate [TorrServerController] instance.
///
/// On iOS, returns an in-process controller ([TorrServerControllerIos]).
/// With [inProcessLibrary] (the path of libtorrserver.so, tool/go-shim/build-tizen-so.sh), the
/// engine runs inside the app from that library, listening on this device only.
/// On Windows, Linux, macOS, and Android, returns a subprocess controller ([TorrServerControllerSubprocess]).
TorrServerController createTorrServerController({String? inProcessLibrary}) {
  if (inProcessLibrary != null) {
    return torrServerControllerFfi(inProcessLibrary);
  }
  if (Platform.isIOS) {
    return TorrServerControllerIos();
  }
  return TorrServerControllerSubprocess();
}
