import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_screen.dart';
import 'chat_screen.dart';
import 'incoming_call.dart';
import 'keep_alive.dart';
import 'signaling.dart';
import 'theme.dart';


/// Значения по умолчанию в полях входа. Это только подстановка — поля остаются
/// редактируемыми, чтобы при переезде сервера или входе под другим именем не
/// требовалась пересборка приложения.
const kDefaultHost = 'call.ritsky.com';
const kDefaultUser = 'mama';

/// ВНИМАНИЕ: токен — это пароль, и здесь он лежит внутри APK в открытом виде.
/// Любой, у кого есть файл приложения, может его прочитать и войти как
/// kDefaultUser. Держите такую сборку только у тех, кому она предназначена.
const kDefaultToken = 'f9c5015ec67c070a06d70152d163a6fab97e6171443e4809';

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
    if (host != null && user != null && token != null) {
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
              // Сохранённые значения имеют приоритет над встроенными:
              // если человек уже входил под своим именем, оно и подставится.
              initialHost: widget.prefs.getString('host') ?? kDefaultHost,
              initialUser: widget.prefs.getString('user') ?? kDefaultUser,
              initialToken: widget.prefs.getString('token') ?? kDefaultToken,
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
    this.initialToken = kDefaultToken,
  });

  final void Function(String host, String user, String token) onSubmit;
  final String initialHost;
  final String initialUser;
  final String initialToken;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _host;
  late final TextEditingController _user;
  late final TextEditingController _token;
  String? _error;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.initialHost);
    _user = TextEditingController(text: widget.initialUser);
    _token = TextEditingController(text: widget.initialToken);
  }

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _token.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _host.text.trim().replaceAll(RegExp(r'^https?://|/$'), '');
    if (host.isEmpty || _user.text.trim().isEmpty || _token.text.isEmpty) {
      setState(() => _error = 'Заполните все три поля.');
      return;
    }
    widget.onSubmit(host, _user.text.trim(), _token.text.trim());
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
                Text('Свой канал связи',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  'Укажите сервер, который вы развернули, и свои данные из '
                  'списка USERS.',
                  style: TextStyle(color: muted, height: 1.4),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                      labelText: 'Домен сервера',
                      hintText: 'call.example.com'),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(
                      labelText: 'Ваш id', hintText: 'alex'),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  decoration: const InputDecoration(labelText: 'Токен'),
                  obscureText: true,
                  autocorrect: false,
                  // Клавиатуру поднимаем только если вводить действительно
                  // нужно: при заполненных полях она лишь мешает.
                  autofocus: widget.initialToken.isEmpty,
                  onSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!, style: const TextStyle(color: Color(0xFFE07A5F))),
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.link.incomingCalls.listen(_onIncoming);
    _setupBackground();
  }

  @override
  void dispose() {
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
    await IncomingCall.show(peer: from, video: withVideo);
    await LinkKeeper.ringing(from);
    await navigatorKey.currentState?.push(MaterialPageRoute(
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
                Text(link.user,
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
              // Без фонового режима звонки не доходят при свёрнутом
              // приложении, поэтому о его отсутствии надо говорить явно.
              if (!LinkKeeper.isRunning)
                _BackgroundWarning(
                  title: 'Фоновый режим выключен',
                  text: LinkKeeper.lastError ??
                      'Звонки не будут доходить, пока приложение свёрнуто.',
                  actionLabel: 'Включить',
                  onAction: _setupBackground,
                ),
              // Отдельная беда: сервис работает, но Android через несколько
              // минут сна отключает приложению сеть. Спасает только белый
              // список батареи.
              if (LinkKeeper.isRunning && !LinkKeeper.batteryUnrestricted)
                _BackgroundWarning(
                  title: 'Телефон усыпляет приложение',
                  text: 'Через несколько минут в спящем режиме связь рвётся и '
                      'звонок не дойдёт. Снимите ограничения батареи.',
                  actionLabel: 'Настройки',
                  onAction: LinkKeeper.openBatterySettings,
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
              peer.substring(0, 1).toUpperCase(),
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
      title: Text(peer,
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

class _BackgroundWarning extends StatelessWidget {
  const _BackgroundWarning({
    required this.title,
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF2A2118),
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      color: amber, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: const TextStyle(color: muted, fontSize: 12, height: 1.3),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
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
