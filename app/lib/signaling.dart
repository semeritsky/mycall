import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Одно текстовое сообщение в переписке.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.peer,
    required this.text,
    required this.outgoing,
    required this.ts,
    this.delivered = false,
  });

  final String id;
  final String peer;
  final String text;
  final bool outgoing;
  final DateTime ts;
  bool delivered;
}

/// Состояние соединения с сигнальным сервером.
enum LinkState { offline, connecting, online }

/// Держит постоянное WSS-соединение: по нему приходят и звонки, и сообщения.
///
/// Всё, что касается WebRTC, здесь только пересылается — разбором занимается
/// [CallSession]. Так сигналинг остаётся заменяемым слоем.
class Signaling extends ChangeNotifier {
  Signaling({required this.host, required this.user, required this.token});

  final String host; // например call.example.com
  final String user;
  final String token;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _disposed = false;

  LinkState state = LinkState.offline;
  String? lastError;

  List<String> contacts = [];
  final Set<String> online = {};
  Map<String, dynamic> iceServers = {};
  final Map<String, List<ChatMessage>> conversations = {};
  final Set<String> unread = {};

  /// Сигналы для активного звонка: offer / answer / ice / hangup / decline.
  final _signals = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get signals => _signals.stream;

  /// Буфер сигналов по собеседнику.
  ///
  /// Зачем: [CallSession] подписывается на [signals] только после того, как
  /// получит камеру с микрофоном и создаст peer connection — это сотни
  /// миллисекунд, а на первом звонке ещё и диалог разрешений. Offer от
  /// звонящего успевает прийти раньше, а broadcast-поток события до подписки
  /// не хранит. Без буфера offer теряется, и звонок навсегда зависает
  /// на «Соединяем…».
  final Map<String, List<Map<String, dynamic>>> _buffered = {};

  void _bufferAndEmit(Map<String, dynamic> msg) {
    final from = msg['from'] as String?;
    if (from != null) {
      final list = _buffered.putIfAbsent(from, () => []);
      list.add(msg);
      if (list.length > 200) list.removeAt(0); // защита от переполнения
    }
    _signals.add(msg);
  }

  /// Забрать и очистить накопленные сигналы от собеседника.
  List<Map<String, dynamic>> takeBufferedSignals(String peer) =>
      _buffered.remove(peer) ?? const [];

  /// Входящий звонок: сюда прилетает id звонящего.
  final _incoming = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingCalls => _incoming.stream;

  Future<void> connect() async {
    if (_disposed || state == LinkState.connecting) return;
    _reconnectTimer?.cancel();
    state = LinkState.connecting;
    lastError = null;
    notifyListeners();

    try {
      final socket = await WebSocket.connect('wss://$host/ws')
          .timeout(const Duration(seconds: 12));
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      _send({'type': 'hello', 'user': user, 'token': token});
      socket.listen(
        _onData,
        onDone: () => _onClosed(socket.closeReason),
        onError: (Object e) => _onClosed(e.toString()),
        cancelOnError: true,
      );
    } catch (e) {
      _onClosed(_humanError(e));
    }
  }

  String _humanError(Object e) {
    if (e is SocketException) return 'Сервер не отвечает. Проверьте адрес и сеть.';
    if (e is TimeoutException) return 'Соединение не установилось за 12 секунд.';
    if (e is WebSocketException) return 'Сервер отклонил подключение.';
    return e.toString();
  }

  void _onClosed(Object? reason) {
    _socket = null;
    if (_disposed) return;
    state = LinkState.offline;
    online.clear();
    if (reason != null && reason.toString().isNotEmpty) {
      lastError = reason.toString().contains('unauthorized')
          ? 'Сервер не принял токен. Проверьте имя и токен.'
          : reason.toString();
    }
    notifyListeners();

    // Экспоненциальная пауза, но не дольше 30 секунд:
    // мобильная сеть может отвалиться на десятки минут.
    _attempt = (_attempt + 1).clamp(1, 6);
    final delay = Duration(seconds: [1, 2, 4, 8, 15, 30][_attempt - 1]);
    _reconnectTimer = Timer(delay, connect);
  }

  void _onData(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'welcome':
        _attempt = 0;
        state = LinkState.online;
        contacts = (msg['contacts'] as List).cast<String>();
        online
          ..clear()
          ..addAll((msg['online'] as List).cast<String>());
        iceServers = _buildIceConfig(msg['ice'] as Map<String, dynamic>);
        notifyListeners();
        break;

      case 'ice' when msg.containsKey('ice'):
        iceServers = _buildIceConfig(msg['ice'] as Map<String, dynamic>);
        break;

      case 'presence':
        final peer = msg['user'] as String;
        (msg['online'] as bool) ? online.add(peer) : online.remove(peer);
        notifyListeners();
        break;

      case 'msg':
        final peer = msg['from'] as String;
        _append(
          peer,
          ChatMessage(
            id: msg['id'] as String,
            peer: peer,
            text: msg['text'] as String,
            outgoing: false,
            ts: DateTime.fromMillisecondsSinceEpoch(msg['ts'] as int),
            delivered: true,
          ),
        );
        unread.add(peer);
        notifyListeners();
        break;

      case 'ack':
        for (final list in conversations.values) {
          for (final m in list) {
            if (m.id == msg['id']) m.delivered = true;
          }
        }
        notifyListeners();
        break;

      case 'call':
        // Новый звонок — старые сигналы от этого человека больше не нужны.
        _buffered.remove(msg['from']);
        _incoming.add(msg);
        break;

      case 'offer':
      case 'answer':
      case 'hangup':
      case 'decline':
        _bufferAndEmit(msg);
        break;

      case 'peer-offline':
        lastError = '${msg['user']} не в сети — отправлено уведомление.';
        notifyListeners();
        break;

      case 'error':
        lastError = msg['reason'] as String?;
        notifyListeners();
        break;
    }
    // ice-кандидаты приходят часто; отдаём без лишних notifyListeners
    if (msg['type'] == 'ice' && msg.containsKey('candidate')) _bufferAndEmit(msg);
  }

  Map<String, dynamic> _buildIceConfig(Map<String, dynamic> ice) {
    return {
      'iceServers': [
        {
          'urls': (ice['urls'] as List).cast<String>(),
          'username': ice['username'],
          'credential': ice['credential'],
        }
      ],
      'sdpSemantics': 'unified-plan',
      // relay-only можно включить, если нужно скрыть домашний IP от собеседника:
      // 'iceTransportPolicy': 'relay',
    };
  }

  void _append(String peer, ChatMessage m) {
    (conversations[peer] ??= <ChatMessage>[]).add(m);
  }

  List<ChatMessage> messagesWith(String peer) =>
      conversations[peer] ?? const <ChatMessage>[];

  void markRead(String peer) {
    if (unread.remove(peer)) notifyListeners();
  }

  void sendText(String peer, String text) {
    final id = '${DateTime.now().microsecondsSinceEpoch}-$user';
    _append(
      peer,
      ChatMessage(
        id: id,
        peer: peer,
        text: text,
        outgoing: true,
        ts: DateTime.now(),
      ),
    );
    notifyListeners();
    _send({'type': 'msg', 'id': id, 'to': peer, 'text': text});
  }

  /// Переподключиться немедленно, не дожидаясь очередной паузы.
  ///
  /// Нужно при возврате в приложение: система только что вернула сеть, а наш
  /// отсчёт до следующей попытки может тикать ещё полминуты.
  void reconnectNow() {
    if (_disposed || state != LinkState.offline) return;
    _reconnectTimer?.cancel();
    _attempt = 0;
    connect();
  }

  void ring(String peer, {required bool video}) =>
      _send({'type': 'call', 'to': peer, 'video': video});

  void sendSignal(Map<String, dynamic> payload) => _send(payload);

  void _send(Map<String, dynamic> payload) {
    final socket = _socket;
    if (socket == null) return;
    socket.add(jsonEncode(payload));
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _socket?.close();
    _signals.close();
    _incoming.close();
    super.dispose();
  }
}
