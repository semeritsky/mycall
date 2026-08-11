import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'call_session.dart';
import 'incoming_call.dart';
import 'signaling.dart';
import 'theme.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.link,
    required this.peer,
    required this.video,
    required this.isCaller,
  });

  final Signaling link;
  final String peer;
  final bool video;
  final bool isCaller;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  /// Активная сессия. Нужна, чтобы кнопки системного экрана входящего звонка
  /// (он живёт вне дерева виджетов) могли ответить или отклонить.
  static CallSession? activeSession;

  late final CallSession _session;
  Timer? _ticker;
  Timer? _timeout;
  Timer? _hideTimer;
  Duration _elapsed = Duration.zero;
  bool _controlsVisible = true;
  bool _ready = false;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    _session = CallSession(
      signaling: widget.link,
      peer: widget.peer,
      video: widget.video,
      isCaller: widget.isCaller,
    );
    _session.addListener(_onSessionChange);
    activeSession = _session;
    _boot();
  }

  Future<void> _boot() async {
    WakelockPlus.enable();
    try {
      await _session.prepare();
      if (widget.isCaller) {
        await _session.start();
      } else {
        _session.stage = CallStage.ringing;
      }
      if (mounted) setState(() => _ready = true);

      // Без этого зависший звонок висит «Соединяем…» бесконечно и непонятно,
      // ждать ли дальше. 45 секунд — заведомо больше, чем нужно ICE.
      _timeout = Timer(const Duration(seconds: 45), () {
        if (!mounted || _session.stage == CallStage.active) return;
        setState(() => _fatal =
            'Соединение не установилось за 45 секунд.\n'
            'Состояние ICE: ${_session.iceState ?? "неизвестно"}\n\n'
            'Если здесь «failed» — не работает TURN-релей: '
            'проверьте порты 3478 и 5349 и диапазон 49160–49300/udp, '
            'в том числе в панели хостера.');
      });
    } catch (e) {
      if (mounted) setState(() => _fatal = 'Не удалось включить камеру или микрофон: $e');
    }
  }

  void _onSessionChange() {
    if (!mounted) return;
    if (_session.stage == CallStage.active) {
      IncomingCall.dismiss();
      _timeout?.cancel();
      _timeout = null;
      // Первый раз прячем через 4 секунды после соединения, а также
      // перезапускаем отсчёт после нажатий на кнопки — они идут сюда же.
      if (_controlsVisible) _scheduleHide();
    }
    if (_session.stage == CallStage.active && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final since = _session.connectedAt;
        if (since != null) setState(() => _elapsed = DateTime.now().difference(since));
      });
    }
    if (_session.stage == CallStage.ended) {
      _leave();
      return;
    }
    setState(() {});
  }

  Future<void> _leave() async {
    await IncomingCall.dismiss(); // остановить мелодию
    _ticker?.cancel();
    _ticker = null;
    _timeout?.cancel();
    _timeout = null;
    _hideTimer?.cancel();
    await WakelockPlus.disable();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    if (activeSession == _session) activeSession = null;
    _ticker?.cancel();
    _timeout?.cancel();
    _hideTimer?.cancel();
    _session.removeListener(_onSessionChange);
    _session.hangUp(notifyPeer: _session.stage != CallStage.ended);
    WakelockPlus.disable();
    super.dispose();
  }

  /// Кнопки прячем только когда есть на что смотреть: при активном
  /// видеозвонке. На входящем вызове и в аудиозвонке они нужны постоянно.
  bool get _canAutoHide =>
      widget.video && _session.stage == CallStage.active;

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_canAutoHide) return;
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (!_canAutoHide) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  String get _statusLine {
    if (_session.statusText != null) return _session.statusText!;
    return switch (_session.stage) {
      CallStage.dialing => 'Вызываем…',
      CallStage.ringing => widget.video ? 'Входящий видеозвонок' : 'Входящий звонок',
      CallStage.connecting => 'Соединяем…',
      CallStage.active => _format(_elapsed),
      CallStage.ended => 'Завершён',
    };
  }

  static String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_fatal != null) {
      return Scaffold(
        backgroundColor: ink,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_fatal!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: textColor, height: 1.4)),
                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Закрыть'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final incoming = _session.stage == CallStage.ringing;
    final hasRemoteVideo =
        _session.remoteRenderer.srcObject != null && _session.stage == CallStage.active;

    return Scaffold(
      backgroundColor: const Color(0xFF090B0F),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (hasRemoteVideo)
            RTCVideoView(
              _session.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            _Placeholder(peer: widget.peer),

          // Прозрачный слой для нажатий: лежит поверх видео, но НИЖЕ кнопок,
          // поэтому пока они видны, нажатия достаются им. Когда скрыты —
          // IgnorePointer их пропускает, и нажатие приходит сюда.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: const SizedBox.expand(),
            ),
          ),

          // Верхняя плашка: кто и в каком состоянии.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _Fading(
              visible: _controlsVisible,
              child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).viewPadding.top + 16,
                left: 24,
                right: 24,
                bottom: 20,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Colors.transparent],
                ),
              ),
              child: Column(
                children: [
                  Text(
                    widget.peer,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statusLine,
                    style: TextStyle(
                      color: _session.stage == CallStage.active ? live : muted,
                      fontSize: 14,
                      letterSpacing: 0.4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  // Пока соединение не установлено, показываем состояние ICE —
                  // это единственный способ понять причину без отладчика.
                  if (_session.stage != CallStage.active &&
                      _session.iceState != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'ICE: ${_session.iceState}',
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ),
                ],
              ),
              ),
            ),
          ),

          // Своё превью — небольшое окно в углу.
          if (_ready && widget.video && _session.cameraEnabled)
            Positioned(
              right: 16,
              top: MediaQuery.of(context).viewPadding.top + 96,
              width: 108,
              height: 156,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  color: surfaceHigh,
                  child: RTCVideoView(
                    _session.localRenderer,
                    mirror: _session.frontCamera,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),

          // Управление.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _Fading(
              visible: _controlsVisible,
              child: Container(
              padding: EdgeInsets.only(
                top: 28,
                bottom: MediaQuery.of(context).viewPadding.bottom + 28,
              ),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xE6000000), Colors.transparent],
                ),
              ),
              child: incoming ? _incomingControls() : _activeControls(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _incomingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(
          icon: Icons.call_end,
          label: 'Отклонить',
          background: danger,
          size: 68,
          onTap: () {
            _session.decline();
            _leave();
          },
        ),
        _RoundButton(
          icon: widget.video ? Icons.videocam : Icons.call,
          label: 'Ответить',
          background: live,
          size: 68,
          onTap: _session.accept,
        ),
      ],
    );
  }

  Widget _activeControls() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              icon: _session.micEnabled ? Icons.mic : Icons.mic_off,
              label: _session.micEnabled ? 'Микрофон' : 'Выключен',
              background: _session.micEnabled ? surfaceHigh : Colors.white,
              foreground: _session.micEnabled ? Colors.white : Colors.black,
              onTap: _session.toggleMic,
            ),
            if (widget.video)
              _RoundButton(
                icon: _session.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                label: _session.cameraEnabled ? 'Камера' : 'Выключена',
                background: _session.cameraEnabled ? surfaceHigh : Colors.white,
                foreground: _session.cameraEnabled ? Colors.white : Colors.black,
                onTap: _session.toggleCamera,
              ),
            if (widget.video)
              _RoundButton(
                icon: Icons.cameraswitch,
                label: 'Развернуть',
                background: surfaceHigh,
                onTap: _session.switchCamera,
              ),
            _RoundButton(
              icon: _session.speakerOn ? Icons.volume_up : Icons.hearing,
              label: _session.speakerOn ? 'Динамик' : 'Трубка',
              background: surfaceHigh,
              onTap: _session.toggleSpeaker,
            ),
          ],
        ),
        const SizedBox(height: 22),
        _RoundButton(
          icon: Icons.call_end,
          label: 'Завершить',
          background: danger,
          size: 64,
          onTap: () async {
            await _session.hangUp();
            await _leave();
          },
        ),
      ],
    );
  }
}

/// Плавно убирает панель и перестаёт принимать нажатия, когда она скрыта —
/// иначе невидимые кнопки продолжали бы перехватывать касания.
class _Fading extends StatelessWidget {
  const _Fading({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: child,
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.onTap,
    this.foreground = Colors.white,
    this.size = 52,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        children: [
          Material(
            color: background,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(icon, color: foreground, size: size * 0.44),
              ),
            ),
          ),
          const SizedBox(height: 7),
          Text(label,
              style: const TextStyle(color: muted, fontSize: 11, letterSpacing: 0.2)),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.peer});
  final String peer;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF090B0F),
      alignment: Alignment.center,
      child: Container(
        width: 116,
        height: 116,
        decoration: BoxDecoration(
          color: surfaceHigh,
          borderRadius: BorderRadius.circular(34),
        ),
        alignment: Alignment.center,
        child: Text(
          peer.substring(0, 1).toUpperCase(),
          style: const TextStyle(
              fontSize: 44, fontWeight: FontWeight.w600, color: textColor),
        ),
      ),
    );
  }
}

/// Мостик для системного экрана входящего звонка: он находится вне дерева
/// виджетов и не может дотянуться до состояния экрана обычным путём.
class CallScreenAccess {
  CallScreenAccess._();

  static void accept() => _CallScreenState.activeSession?.accept();
  static void decline() => _CallScreenState.activeSession?.decline();
}
