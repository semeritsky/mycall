import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_screen.dart';
import 'chat_screen.dart';
import 'family.dart';
import 'incoming_call.dart';
import 'keep_alive.dart';
import 'signaling.dart';
import 'theme.dart';


/// Адрес сервера. Поле остаётся редактируемым, чтобы при переезде сервера не
/// требовалась пересборка приложения.
const kDefaultHost = 'call.ritsky.com';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(MyCallApp(prefs: prefs));
}

class MyCallApp extends StatefulWidget {
  const MyCallApp({super.key, required this.prefs});
  final SharedPreferences prefs;

  @override
  State<MyCallApp> createState() => _MyCallAppState();
}

class _MyCallAppState extends State<MyCallApp> {
  Signaling? _signaling;

  @override
  void initState() {
    super.initState();
    final host = widget.prefs.getString('host');
    final user = widget.prefs.getString('user');
    final token = widget.prefs.getString('token');
    // Сохранённого человека может уже не быть в составе семьи — например, его
    // переименовали. Тогда не пытаемся войти под ним, а показываем выбор.
    if (host != null && user != null && token != null && kFamily.containsKey(user)) {
      _openLink(host, user, token);
    }
  }

  void _openLink(String host, String user, String token) {
    final link = Signaling(host: host, user: user, token: token);
    setState(() => _signaling = link);
    link.connect();
    // Сервис поднимается не здесь, а после запроса разрешений — см.
    // _ContactsScreenState._setupBackground. На Android 13+ без разрешения
    // на уведомления foreground service не стартует.
  }

  Future<void> _saveAndConnect(String host, String user, String token) async {
    await widget.prefs.setString('host', host);
    await widget.prefs.setString('user', user);
    await widget.prefs.setString('token', token);
    _openLink(host, user, token);
  }

  void _signOut() {
    widget.prefs.remove('token');
    LinkKeeper.stop();
    _signaling?.dispose();
    setState(() => _signaling = null);
  }

  @override
  Widget build(BuildContext context) {
    final link = _signaling;
    return MaterialApp(
      title: 'MyCall',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: ink,
        colorScheme: const ColorScheme.dark(
          surface: ink,
          primary: amber,
          onPrimary: Color(0xFF15181D),
          secondary: live,
          onSurface: textColor,
        ),
        textTheme: const TextTheme(
          headlineSmall: TextStyle(
              fontSize: 24, fontWeight: FontWeight.w600, letterSpacing: -0.4),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(fontSize: 15, height: 1.35),
          labelSmall: TextStyle(
              fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w600),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          hintStyle: const TextStyle(color: muted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: link == null
          ? SetupScreen(
              // Кто входил на этом телефоне в прошлый раз — тот и выбран.
              initialHost: widget.prefs.getString('host') ?? kDefaultHost,
              initialUser: widget.prefs.getString('user') ?? kDefaultUser,
              onSubmit: _saveAndConnect,
            )
          : ContactsScreen(link: link, onSignOut: _signOut),
    );
  }
}

// ---------------------------------------------------------------- настройка

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.onSubmit,
    this.initialHost = kDefaultHost,
    this.initialUser = kDefaultUser,
  });

  final void Function(String host, String user, String token) onSubmit;
  final String initialHost;
  final String initialUser;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _host;
  late String _selected;
  bool _editHost = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.initialHost);
    // Если сохранённого имени в списке семьи нет (например, состав поменялся),
    // не падаем, а берём первого.
    _selected = kFamily.containsKey(widget.initialUser)
        ? widget.initialUser
        : kFamily.keys.first;
  }

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim().replaceAll(RegExp(r'^https?://|/$'), '');
    final token = kFamily[_selected];
    if (host.isEmpty || token == null) {
      setState(() => _error = 'Проверьте адрес сервера и выбор человека.');
      return;
    }
    widget.onSubmit(host, _selected, token);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                      color: amber, shape: BoxShape.circle),
                ),
                const SizedBox(height: 20),
                Text('Кто ты?',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  'Выбери себя и нажми «Подключиться».',
                  style: TextStyle(color: muted, height: 1.4),
                ),
                const SizedBox(height: 28),

                // Список семьи. Токен подставляется сам, вводить нечего.
                Container(
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selected,
                      isExpanded: true,
                      dropdownColor: surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                      icon: const Icon(Icons.expand_more, color: muted),
                      style: const TextStyle(color: textColor, fontSize: 17),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      items: [
                        for (final id in kFamily.keys)
                          DropdownMenuItem(
                            value: id,
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: surfaceHigh,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    displayName(id).substring(0, 1),
                                    style: const TextStyle(
                                        color: amber,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Text(displayName(id)),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _selected = value);
                      },
                    ),
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: danger)),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Подключиться'),
                  ),
                ),
                const SizedBox(height: 20),

                // Адрес сервера убран с глаз: нужен раз в жизни, при переезде.
                if (_editHost)
                  TextField(
                    controller: _host,
                    decoration: const InputDecoration(
                        labelText: 'Адрес сервера'),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  )
                else
                  Center(
                    child: TextButton(
                      onPressed: () => setState(() => _editHost = true),
                      child: Text(
                        'Сервер: ${_host.text}',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- контакты

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, required this.link, required this.onSignOut});
  final Signaling link;
  final VoidCallback onSignOut;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen>
    with WidgetsBindingObserver {
  bool _callInProgress = false;
  StreamSubscription<Map<String, dynamic>>? _endWatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.link.incomingCalls.listen(_onIncoming);

    // Отбой нельзя доверять только экрану звонка: на стороне вызываемого он
    // может ещё не открыться или уже закрыться, а системный вызов с мелодией
    // существует отдельно от нашего дерева виджетов — и тогда гасить его
    // оказывается некому. Этот слушатель живёт всё время, пока вы в сети.
    _endWatch = widget.link.signals.listen((msg) {
      final type = msg['type'];
      if (type == 'hangup' || type == 'decline') {
        IncomingCall.dismiss();
      }
    });

    _setupBackground();
  }

  @override
  void dispose() {
    _endWatch?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Возврат из системных настроек: перечитываем состояние, чтобы
    // предупреждение исчезло само, без перезапуска приложения.
    if (state == AppLifecycleState.resumed) {
      _healBackground();
    }
  }

  /// Каждый раз, когда приложение снова на экране, проверяем сервис и, если он
  /// упал или не поднялся после повторного входа, пробуем ещё раз. Это тот
  /// момент, когда система разрешает запуск охотнее всего.
  Future<void> _healBackground() async {
    // После сна сеть только что вернулась — не ждём очередной паузы отсчёта.
    widget.link.reconnectNow();
    await LinkKeeper.refresh();
    if (!LinkKeeper.isRunning) {
      await LinkKeeper.ensureRunning(widget.link.user);
    }
    if (mounted) setState(() {});
  }

  /// Разрешения, затем foreground service. Именно в этом порядке: без
  /// разрешения на уведомления сервис на Android 13+ не запускается.
  Future<void> _setupBackground() async {
    await [Permission.camera, Permission.microphone, Permission.notification]
        .request();
    await LinkKeeper.ensureRunning(widget.link.user);
    await IncomingCall.requestPermissions();
    // Кнопки системного экрана вызова живут вне дерева виджетов, поэтому
    // адресуем их к активной сессии напрямую.
    IncomingCall.listen(
      onAccept: () => CallScreenAccess.accept(),
      onDecline: () => CallScreenAccess.decline(),
    );
    if (mounted) setState(() {});
  }

  Future<void> _askPermissions() async {
    await [Permission.camera, Permission.microphone].request();
  }

  Future<void> _onIncoming(Map<String, dynamic> msg) async {
    if (_callInProgress) return; // занято — второй звонок игнорируем
    _callInProgress = true;
    final from = msg['from'] as String;
    final withVideo = (msg['video'] as bool?) ?? true;
    // Системный экран вызова: мелодия, вибрация, показ на заблокированном
    // экране. Наш экран открывается тут же — он и обслуживает сам звонок.
    await IncomingCall.show(peer: displayName(from), video: withVideo);
    await LinkKeeper.ringing(displayName(from));

    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      // Открыть экран звонка не получилось — значит обслуживать вызов нечем,
      // и оставлять звонящую мелодию нельзя.
      await IncomingCall.dismiss();
      _callInProgress = false;
      return;
    }

    await navigator.push(MaterialPageRoute(
      builder: (_) => CallScreen(
        link: widget.link,
        peer: from,
        video: withVideo,
        isCaller: false,
      ),
      fullscreenDialog: true,
    ));
    _callInProgress = false;
    await IncomingCall.dismiss();
    await LinkKeeper.idle(widget.link.user);
  }

  Future<void> _placeCall(String peer, {required bool video}) async {
    if (_callInProgress) return;
    final granted = await Permission.microphone.isGranted &&
        (!video || await Permission.camera.isGranted);
    if (!granted) {
      await _askPermissions();
      return;
    }
    _callInProgress = true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CallScreen(
        link: widget.link,
        peer: peer,
        video: video,
        isCaller: true,
      ),
      fullscreenDialog: true,
    ));
    _callInProgress = false;
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: ink,
            titleSpacing: 20,
            title: Row(
              children: [
                _LinkIndicator(state: link.state),
                const SizedBox(width: 10),
                Text(displayName(link.user),
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            actions: [
              IconButton(
                onPressed: widget.onSignOut,
                icon: const Icon(Icons.logout, size: 20, color: muted),
                tooltip: 'Выйти',
              ),
            ],
          ),
          body: Column(
            children: [
              if (link.state != LinkState.online)
                _Banner(
                  text: link.state == LinkState.connecting
                      ? 'Подключаемся к серверу…'
                      : link.lastError ?? 'Нет связи с сервером',
                ),
              Expanded(
                child: link.contacts.isEmpty
                    ? const _Empty()
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: link.contacts.length,
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, color: Color(0xFF1E242E), indent: 76),
                        itemBuilder: (context, i) {
                          final peer = link.contacts[i];
                          return _ContactRow(
                            peer: peer,
                            online: link.online.contains(peer),
                            unread: link.unread.contains(peer),
                            lastMessage: link.messagesWith(peer).isEmpty
                                ? null
                                : link.messagesWith(peer).last.text,
                            onOpen: () {
                              link.markRead(peer);
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    ChatScreen(link: link, peer: peer),
                              ));
                            },
                            onVideo: () => _placeCall(peer, video: true),
                            onVoice: () => _placeCall(peer, video: false),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.peer,
    required this.online,
    required this.unread,
    required this.lastMessage,
    required this.onOpen,
    required this.onVideo,
    required this.onVoice,
  });

  final String peer;
  final bool online;
  final bool unread;
  final String? lastMessage;
  final VoidCallback onOpen;
  final VoidCallback onVideo;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onOpen,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      leading: Stack(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: surfaceHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Text(
              displayName(peer).substring(0, 1).toUpperCase(),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600, color: textColor),
            ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: live,
                  shape: BoxShape.circle,
                  border: Border.all(color: ink, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Text(displayName(peer),
          style: TextStyle(
              color: textColor,
              fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
      subtitle: Text(
        lastMessage ?? (online ? 'в сети' : 'не в сети'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: unread ? amber : muted, fontSize: 13),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onVoice,
            icon: const Icon(Icons.call, color: muted, size: 22),
            tooltip: 'Позвонить',
          ),
          IconButton(
            onPressed: onVideo,
            icon: const Icon(Icons.videocam, color: amber, size: 24),
            tooltip: 'Видеозвонок',
          ),
        ],
      ),
    );
  }
}

class _LinkIndicator extends StatelessWidget {
  const _LinkIndicator({required this.state});
  final LinkState state;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      LinkState.online => live,
      LinkState.connecting => amber,
      LinkState.offline => const Color(0xFF4A525F),
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Text(text, style: const TextStyle(color: muted, fontSize: 13)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Контактов пока нет. Добавьте себя и знакомых в переменную USERS '
          'на сервере и перезапустите сигналку.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, height: 1.5),
        ),
      ),
    );
  }
}
