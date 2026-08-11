import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

/// Системный экран входящего звонка: мелодия, вибрация и показ на
/// заблокированном экране.
///
/// Почему через пакет, а не своими силами. Вывести приложение на экран из фона
/// Android запрещает начиная с десятой версии, и единственный законный обход —
/// уведомление с full-screen intent. С Android 14 на него ещё и нужно отдельное
/// разрешение. Пакет делает это плюс телефонную интеграцию (Telecom), которую
/// иначе пришлось бы писать на Kotlin.
///
/// Наш экран звонка при этом никуда не девается: он открывается как раньше, а
/// системный вызов работает поверх. Если пакет по какой-то причине не сработает,
/// звонок всё равно дойдёт — просто без мелодии и без реакции на locked screen.
class IncomingCall {
  IncomingCall._();

  static const _appName = 'MyCall';
  static bool _listening = false;
  static String? lastError;

  /// Заглушка событий на время нашего собственного закрытия экрана.
  ///
  /// Пакет на endAllCalls() отвечает событием «звонок завершён». Без этого
  /// флага оно приходит нам же, трактуется как отказ абонента и сбрасывает
  /// только что принятый разговор — трубка кладёт себя сама.
  static bool _suppress = false;

  static String _idFor(String peer) => 'mycall-$peer';

  /// Разрешение на full-screen intent. На Android 14+ без него уведомление
  /// не разворачивается на весь экран и вызов на заблокированном телефоне
  /// остаётся незаметным.
  static Future<void> requestPermissions() async {
    try {
      await FlutterCallkitIncoming.requestFullIntentPermission();
    } catch (e) {
      lastError = 'разрешение full-screen: $e';
      debugPrint('IncomingCall.requestPermissions: $e');
    }
  }

  /// Показать входящий вызов. `ringtonePath: 'system_ringtone_default'` —
  /// штатная мелодия телефона, отдельный файл не нужен.
  static Future<void> show({
    required String peer,
    required bool video,
  }) async {
    try {
      await FlutterCallkitIncoming.showCallkitIncoming(
        CallKitParams(
          id: _idFor(peer),
          nameCaller: peer,
          appName: _appName,
          handle: peer,
          type: video ? 1 : 0,
          textAccept: 'Ответить',
          textDecline: 'Отклонить',
          duration: 45000,
          android: const AndroidParams(
            isCustomNotification: true,
            isShowLogo: false,
            ringtonePath: 'system_ringtone_default',
            backgroundColor: '#0E1116',
            actionColor: '#E9B44C',
            incomingCallNotificationChannelName: 'Входящие звонки',
            isShowFullLockedScreen: true,
          ),
        ),
      );
    } catch (e) {
      lastError = 'показ вызова: $e';
      debugPrint('IncomingCall.show: $e');
    }
  }

  /// Убрать системный вызов и остановить мелодию.
  static Future<void> dismiss() async {
    _suppress = true;
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (e) {
      debugPrint('IncomingCall.dismiss: $e');
    }
    // События приходят асинхронно и с задержкой, поэтому глушим с запасом.
    Timer(const Duration(seconds: 2), () => _suppress = false);
  }

  /// Подписаться на кнопки системного экрана. Вызывается один раз при старте.
  static void listen({
    required VoidCallback onAccept,
    required VoidCallback onDecline,
  }) {
    if (_listening) return;
    _listening = true;
    try {
      FlutterCallkitIncoming.onEvent.listen((event) {
        if (event == null || _suppress) return;
        switch (event.event) {
          case Event.actionCallAccept:
            onAccept();
            break;
          // Только явный отказ и истёкший таймаут. actionCallEnded здесь
          // сознательно отсутствует: его присылает и наш собственный
          // dismiss(), и трактовать его как отказ нельзя.
          case Event.actionCallDecline:
          case Event.actionCallTimeout:
            onDecline();
            break;
          default:
            break;
        }
      });
    } catch (e) {
      lastError = 'подписка на события: $e';
      debugPrint('IncomingCall.listen: $e');
    }
  }
}
