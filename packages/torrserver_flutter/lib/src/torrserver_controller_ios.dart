import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'exceptions.dart';
import 'models/torrent_info.dart';
import 'models/torrserver_settings.dart';
import 'port_finder.dart';
import 'rest_client.dart';
import 'torrserver_controller.dart';

/// In-process implementation of [TorrServerController]: the engine runs inside the app.
///
/// On iOS and Apple TV it is started over the plugin's MethodChannel. A system that loads it
/// as a shared library instead (a Samsung TV: torrserver_controller_ffi.dart) passes its own
/// [startNative] and [stopNative].
class TorrServerControllerIos implements TorrServerController {
  static const MethodChannel _channel = MethodChannel('torrserver_flutter');
  int? _port;
  Uri? _baseUrl;
  TorrServerRestClient? _restClient;
  bool _isRunning = false;
  final Future<void> Function(int port, String dataDir)? _startNative;
  final Future<void> Function()? _stopNative;

  TorrServerControllerIos({Future<void> Function(int port, String dataDir)? startNative, Future<void> Function()? stopNative})
      : _startNative = startNative,
        _stopNative = stopNative;

  @override
  bool get isRunning => _isRunning;

  @override
  Uri? get baseUrl => _baseUrl;

  @override
  int? get port => _port;

  @override
  Future<void> start({
    int? port,
    TorrServerSettings? settings,
    Directory? dataDir,
    List<String>? extraArgs,
    String? customBinaryPath,
  }) async {
    if (_isRunning) {
      throw const TorrServerStartException(
        'TorrServer is already running on iOS',
      );
    }

    // 1. Select free port
    final selectedPort = port ?? await PortFinder.findFreePort();

    // 2. Resolve database / config directory
    final resolvedDataDir = dataDir ?? await _getDefaultDataDir();
    if (!await resolvedDataDir.exists()) {
      await resolvedDataDir.create(recursive: true);
    }

    // 3. Start the engine: the native plugin over the MethodChannel, or the caller's own way
    try {
      final startNative = _startNative;
      if (startNative != null) {
        await startNative(selectedPort, resolvedDataDir.path);
      } else {
        await _channel.invokeMethod('startServer', {
          'port': selectedPort,
          'dataDir': resolvedDataDir.path,
        });
      }
    } on PlatformException catch (e) {
      throw TorrServerStartException(
        'Failed to start TorrServer on iOS: ${e.message}',
        e,
      );
    } catch (e) {
      throw TorrServerStartException(
        'Failed to start TorrServer on iOS: $e',
        e,
      );
    }

    _port = selectedPort;
    _baseUrl = Uri.parse('http://127.0.0.1:$selectedPort');
    _restClient = TorrServerRestClient(_baseUrl!);

    // 4. Poll healthcheck (/echo)
    try {
      await _waitForServerReady(const Duration(seconds: 12));
      _isRunning = true;

      // 5. Apply initial settings if provided
      if (settings != null) {
        try {
          await _restClient!.setSettings(settings);
        } catch (_) {}
      }
    } catch (e) {
      await stop();
      if (e is TorrServerException) {
        rethrow;
      }
      throw TorrServerStartException(
        'TorrServer iOS in-process failed healthcheck: $e',
        e,
      );
    }
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _baseUrl = null;
    _restClient?.close();
    _restClient = null;

    try {
      final stopNative = _stopNative;
      if (stopNative != null) {
        await stopNative();
      } else {
        await _channel.invokeMethod('stopServer');
      }
    } catch (_) {}

    _port = null;
  }

  @override
  Future<TorrentInfo> addTorrent({
    String? magnet,
    Uint8List? torrentFile,
    String? title,
    String? category,
    String? poster,
    String? data,
    bool saveToDb = false,
  }) async {
    _ensureRunning();
    if (magnet != null && magnet.isNotEmpty) {
      return _restClient!.addTorrent(
        link: magnet,
        title: title,
        category: category,
        poster: poster,
        data: data,
        saveToDb: saveToDb,
      );
    } else if (torrentFile != null && torrentFile.isNotEmpty) {
      return _restClient!.uploadTorrentFile(
        torrentBytes: torrentFile,
        title: title,
        category: category,
        poster: poster,
        data: data,
        saveToDb: saveToDb,
      );
    }
    throw const TorrServerInvalidTorrentException(
      'Either magnet URI or torrentFile bytes must be provided',
    );
  }

  @override
  Future<List<TorrentInfo>> listTorrents() {
    _ensureRunning();
    return _restClient!.listTorrents();
  }

  @override
  Future<TorrentInfo> getTorrent(String hash) {
    _ensureRunning();
    return _restClient!.getTorrent(hash);
  }

  @override
  Future<void> removeTorrent(String hash) {
    _ensureRunning();
    return _restClient!.removeTorrent(hash);
  }

  @override
  Future<void> dropTorrent(String hash) {
    _ensureRunning();
    return _restClient!.dropTorrent(hash);
  }

  @override
  Future<void> setTorrent(
    String hash, {
    String? title,
    String? poster,
    String? category,
    String? data,
  }) {
    _ensureRunning();
    return _restClient!.setTorrent(
      hash,
      title: title,
      poster: poster,
      category: category,
      data: data,
    );
  }

  @override
  Uri streamUrl(String hash, {int fileIndex = 0}) {
    _ensureRunning();
    return _restClient!.streamUrl(hash, fileIndex: fileIndex);
  }

  @override
  Future<TorrServerSettings> getSettings() {
    _ensureRunning();
    return _restClient!.getSettings();
  }

  @override
  Future<void> setSettings(TorrServerSettings settings) {
    _ensureRunning();
    return _restClient!.setSettings(settings);
  }

  @override
  Future<void> setDefaultSettings() {
    _ensureRunning();
    return _restClient!.setDefaultSettings();
  }

  @override
  Future<String> echo() {
    _ensureRunning();
    return _restClient!.echo();
  }

  void _ensureRunning() {
    if (!_isRunning || _restClient == null) {
      throw const TorrServerProcessException(
          'TorrServer is not running on iOS');
    }
  }

  Future<void> _waitForServerReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        await _restClient!.echo(timeout: const Duration(milliseconds: 500));
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw TorrServerStartException(
      'TorrServer iOS in-process engine failed to respond within ${timeout.inSeconds} seconds',
    );
  }

  Future<Directory> _getDefaultDataDir() async {
    try {
      final appSupport = await getApplicationSupportDirectory();
      return Directory('${appSupport.path}/torrserver_data');
    } catch (_) {
      return Directory('${Directory.current.path}/torrserver_data');
    }
  }
}
