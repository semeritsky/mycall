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
  Signaling({required this.host, required this.user, required this.token}) {
    // Наблюдатель работает всё время жизни соединения и вытаскивает его из
    // любого залипания: подвисшая попытка, мёртвый сокет, пропущенный таймер.
    _watchdog = Timer.periodic(const Duration(seconds: 8), (_) => _check());
  }

  void _check() {
    if (_disposed) return;
    switch (state) {
      case LinkState.online:
        // Сервер отвечает на наш ping; тишина дольше минуты означает, что
        // соединение уже не работает, чем бы оно себя ни считало.
        if (_silence > const Duration(seconds: 70)) _forceReconnect();
        break;
      case LinkState.connecting:
        final since = _connectingSince;
        if (since != null &&
            DateTime.now().difference(since) > const Duration(seconds: 25)) {
          _forceReconnect();
        }
        break;
      case LinkState.offline:
        // Отсчёт до следующей попытки потерялся (например, система убила
        // таймер во сне) — восстанавливаем его.
        if (_reconnectTimer == null || !_reconnectTimer!.isActive) connect();
        break;
    }
  }

  /// Разорвать текущее соединение и подключиться заново, не спрашивая
  /// состояния. Единственный способ выйти из залипшего подключения.
  void _forceReconnect() {
    // Сразу помечаем всё предыдущее устаревшим: закрытие сокета асинхронно, и
    // его onDone не должен сойти за обрыв нового соединения.
    _generation++;
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    final dying = _socket;
    _socket = null;
    dying?.close().catchError((_) {});
    state = LinkState.offline;
    _attempt = 0;
    notifyListeners();
    connect();
  }

  final String host; // например call.example.com
  final String user;
  final String token;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  Timer? _watchdog;
  Timer? _heartbeat;
  int _attempt = 0;
  bool _disposed = false;

  /// Номер текущей попытки подключения.
  ///
  /// Попытка может идти секунды, и за это время появиться новая. Без номера
  /// устаревшая попытка доводила дело до конца и открывала второй сокет, а
  /// сервер держит одно соединение на человека — телефон выбивал сам себя
  /// сообщением «вошли с другого телефона». Обработчики брошенного сокета при
  /// этом продолжали портить состояние живого.
  int _generation = 0;

  /// Когда последний раз что-то пришло от сервера.
  ///
  /// Нужно, чтобы отличить живое соединение от мёртвого. При потере сети без
  /// разрыва TCP — телефон вышел из зоны, ушёл в сон — сокет остаётся «открытым»
  /// с точки зрения приложения, и без этой проверки оно так и считает себя
  /// подключённым, ничего не получая.
  DateTime _lastSeen = DateTime.now();
  DateTime? _connectingSince;

  Duration get _silence => DateTime.now().difference(_lastSeen);

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
    if (_disposed) return;
    // Раньше здесь стоял выход, если состояние уже «подключаемся». Из-за этого
    // подвисшая попытка блокировала все следующие навсегда. Теперь за подвисшие
    // попытки отвечает наблюдатель, а сюда можно входить свободно.
    if (state == LinkState.connecting &&
        _connectingSince != null &&
        DateTime.now().difference(_connectingSince!) <
            const Duration(seconds: 25)) {
      return;
    }
    _reconnectTimer?.cancel();
    _heartbeat?.cancel();
    final generation = ++_generation;
    state = LinkState.connecting;
    _connectingSince = DateTime.now();
    lastError = null;
    notifyListeners();

    try {
      final socket = await WebSocket.connect('wss://$host/ws')
          .timeout(const Duration(seconds: 12));

      // Пока мы ждали, появилась более свежая попытка — эта уже не нужна.
      // Закрываем молча: hello отправить не успели, сервер её и не заметит.
      if (_disposed || generation != _generation) {
        socket.close().catchError((_) {});
        return;
      }

      _socket = socket;
      _lastSeen = DateTime.now();
      socket.pingInterval = const Duration(seconds: 20);
      _send({'type': 'hello', 'user': user, 'token': token});
      socket.listen(
        (data) {
          if (generation == _generation) _onData(data);
        },
        onDone: () {
          if (generation == _generation) _onClosed(socket.closeReason);
        },
        onError: (Object e) {
          if (generation == _generation) _onClosed(e.toString());
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (generation == _generation) _onClosed(_humanError(e));
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
    _heartbeat?.cancel();
    _connectingSince = null;
    if (_disposed) return;
    state = LinkState.offline;
    online.clear();
    final text = reason?.toString() ?? '';
    if (text.isNotEmpty) {
      if (text.contains('unauthorized')) {
        lastError = 'Сервер не принял токен. Проверьте имя и токен.';
      } else if (text.contains('replaced by new session')) {
        // Сервер держит одно соединение на человека: второй вход тем же именем
        // выкидывает первый, и два телефона начинают выбивать друг друга.
        lastError = 'Этим же именем вошли с другого телефона.';
      } else {
        lastError = text;
      }
    }
    notifyListeners();

    // Экспоненциальная пауза, но не дольше 30 секунд:
    // мобильная сеть может отвалиться на десятки минут.
    _attempt = (_attempt + 1).clamp(1, 5);
    final delay = Duration(seconds: [1, 2, 4, 8, 15][_attempt - 1]);
    _reconnectTimer = Timer(delay, connect);
  }

  void _onData(dynamic raw) {
    _lastSeen = DateTime.now();
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'welcome':
        _attempt = 0;
        state = LinkState.online;
        _connectingSince = null;
        // Собственный пульс: сервер отвечает pong, и по нему видно, что канал
        // действительно живой, а не просто «не закрыт».
        _heartbeat?.cancel();
        _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
          _send({'type': 'ping'});
        });
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
    if (_disposed) return;
    // Здоровое соединение не трогаем.
    if (state == LinkState.online && _silence < const Duration(seconds: 40)) {
      return;
    }
    // И не мешаем начатой недавно попытке: событие «приложение на экране»
    // приходит сразу после запуска, когда первое подключение уже идёт.
    final since = _connectingSince;
    if (state == LinkState.connecting &&
        since != null &&
        DateTime.now().difference(since) < const Duration(seconds: 10)) {
      return;
    }
    _forceReconnect();
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
    _watchdog?.cancel();
    _heartbeat?.cancel();
    _reconnectTimer?.cancel();
    _socket?.close();
    _signals.close();
    _incoming.close();
    super.dispose();
  }
}
