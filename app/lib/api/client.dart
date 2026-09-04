import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

/// WebSocket client for korgd.
///
/// Handles RPC correlation, event fan-out, and reconnection with backoff. The phone
/// will drop this socket every time it backgrounds, so reconnect is a first-class
/// path, not an error case: on reconnect the app re-subscribes and refetches, and the
/// UI shows connection state rather than silently going stale.
enum KorgConnectionState { disconnected, connecting, connected }

class ServerEventMsg {
  final String kind;
  final Map<String, dynamic> data;
  const ServerEventMsg(this.kind, this.data);
}

class KorgClient {
  KorgClient({this.host = '127.0.0.1', this.port = 7171});

  final String host;
  final int port;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<ServerEventMsg>.broadcast();
  final _connection = StreamController<KorgConnectionState>.broadcast();
  final _subscribed = <String>{};

  var _state = KorgConnectionState.disconnected;
  var _attempt = 0;
  var _disposed = false;
  Timer? _retryTimer;
  AccountInfo? account;

  Stream<ServerEventMsg> get events => _events.stream;
  Stream<KorgConnectionState> get connection => _connection.stream;
  KorgConnectionState get state => _state;

  void _setState(KorgConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_connection.isClosed) _connection.add(s);
  }

  Future<void> connect() async {
    if (_disposed || _state == KorgConnectionState.connecting) return;
    _retryTimer?.cancel();
    _setState(KorgConnectionState.connecting);

    try {
      final ch = WebSocketChannel.connect(Uri.parse('ws://$host:$port'));
      await ch.ready;
      _channel = ch;
      _sub = ch.stream.listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed());

      _send({
        't': 'hello',
        'protocolVersion': kProtocolVersion,
        'clientName': 'Korg',
        'platform': _platform(),
      });
    } catch (_) {
      _onClosed();
    }
  }

  static String _platform() {
    // Kept deliberately coarse; the daemon only uses it for logging.
    return const bool.fromEnvironment('dart.library.io') ? 'macos' : 'ios';
  }

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['t'] as String?) {
      case 'hello_ok':
        _attempt = 0;
        account = AccountInfo.fromJson(msg['account'] as Map<String, dynamic>);
        final serverVersion = msg['protocolVersion'] as int?;
        if (serverVersion != kProtocolVersion) {
          // Surface loudly instead of failing later with confusing nulls.
          _events.add(ServerEventMsg('error', {
            'code': 'protocol_mismatch',
            'message': 'Daemon speaks protocol v$serverVersion, this app speaks v$kProtocolVersion.',
          }));
        }
        _setState(KorgConnectionState.connected);
        // Re-subscribe to whatever we were watching before the drop.
        for (final id in _subscribed) {
          _send({'t': 'subscribe', 'conversationId': id});
        }
      case 'rpc_ok':
        _pending.remove(msg['id'])?.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? {});
      case 'rpc_err':
        final err = msg['error'] as Map<String, dynamic>;
        _pending.remove(msg['id'])?.completeError(KorgRpcException(err['code'] as String, err['message'] as String));
      case 'event':
        final ev = msg['event'] as Map<String, dynamic>;
        _events.add(ServerEventMsg(ev['e'] as String, ev));
    }
  }

  void _onClosed() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _setState(KorgConnectionState.disconnected);

    for (final c in _pending.values) {
      c.completeError(const KorgRpcException('disconnected', 'Lost connection to korgd.'));
    }
    _pending.clear();

    if (_disposed) return;
    // Exponential backoff, capped, with jitter so several clients don't stampede.
    _attempt = min(_attempt + 1, 6);
    final base = 500 * (1 << (_attempt - 1));
    final delay = Duration(milliseconds: min(base, 15000) + Random().nextInt(400));
    _retryTimer = Timer(delay, connect);
  }

  void _send(Map<String, dynamic> m) => _channel?.sink.add(jsonEncode(m));

  Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic> params = const {}]) {
    if (_state != KorgConnectionState.connected) {
      return Future.error(const KorgRpcException('disconnected', 'Not connected to korgd.'));
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _send({'t': 'rpc', 'id': id, 'method': method, 'params': params});
    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pending.remove(id);
        throw const KorgRpcException('timeout', 'The daemon did not respond.');
      },
    );
  }

  void subscribe(String conversationId) {
    _subscribed.add(conversationId);
    _send({'t': 'subscribe', 'conversationId': conversationId});
  }

  void unsubscribe(String conversationId) {
    _subscribed.remove(conversationId);
    _send({'t': 'unsubscribe', 'conversationId': conversationId});
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _events.close();
    _connection.close();
  }
}

class KorgRpcException implements Exception {
  final String code;
  final String message;
  const KorgRpcException(this.code, this.message);
  @override
  String toString() => message;
}
