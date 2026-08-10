import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_screen.dart';
import 'chat_screen.dart';
import 'keep_alive.dart';
import 'signaling.dart';
import 'theme.dart';


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
    // Сервис поднимаем сразу: он должен переживать сворачивание приложения
    // независимо от того, установлено ли соединение в эту секунду.
    KeepAlive.start(user);
  }

  Future<void> _saveAndConnect(String host, String user, String token) async {
    await widget.prefs.setString('host', host);
    await widget.prefs.setString('user', user);
    await widget.prefs.setString('token', token);
    _openLink(host, user, token);
  }

  void _signOut() {
    widget.prefs.remove('token');
    KeepAlive.stop();
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
          ? SetupScreen(onSubmit: _saveAndConnect)
          : ContactsScreen(link: link, onSignOut: _signOut),
    );
  }
}

// ---------------------------------------------------------------- настройка

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onSubmit});
  final void Function(String host, String user, String token) onSubmit;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _token = TextEditingController();
  String? _error;

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

class _ContactsScreenState extends State<ContactsScreen> {
  bool _callInProgress = false;

  @override
  void initState() {
    super.initState();
    widget.link.incomingCalls.listen(_onIncoming);
    _askPermissions();
  }

  Future<void> _askPermissions() async {
    await [Permission.camera, Permission.microphone, Permission.notification]
        .request();
    // Отдельно: снятие ограничений батареи. Без этого производитель телефона
    // прибьёт процесс даже при работающем foreground service.
    await KeepAlive.requestPermissions();
  }

  Future<void> _onIncoming(Map<String, dynamic> msg) async {
    if (_callInProgress) return; // занято — второй звонок игнорируем
    _callInProgress = true;
    // Если приложение свёрнуто, увидеть звонок можно только в уведомлении.
    await KeepAlive.ringing(msg['from'] as String);
    await navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => CallScreen(
        link: widget.link,
        peer: msg['from'] as String,
        video: (msg['video'] as bool?) ?? true,
        isCaller: false,
      ),
      fullscreenDialog: true,
    ));
    _callInProgress = false;
    await KeepAlive.idle(widget.link.user);
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
