import 'package:socket_io_client/socket_io_client.dart' as IO;

typedef BumpHandler = void Function(String? versionHint);

class WsService {
  final String wsUrl;     // مثال: http://192.168.1.5:8081
  final String apiToken;  // من التسجيل
  IO.Socket? _s;

  WsService({required this.wsUrl, required this.apiToken});

  void connect({required BumpHandler onBump}) {
    final opts = IO.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .setQuery({'token': apiToken})
        .build();

    _s = IO.io(wsUrl, opts);

    _s!
      ..onConnect((_) => print('[WS] connected'))
      ..onDisconnect((why) => print('[WS] disconnected: $why'))
      ..onError((e) => print('[WS] error: $e'))
      ..on('playlist.bump', (data) {
        final version = (data is Map && data['version'] != null)
            ? data['version'].toString()
            : null;
        print('[WS] playlist.bump received: $version');
        onBump(version);
      })
      ..connect();
  }

  void dispose() => _s?.dispose();
}
