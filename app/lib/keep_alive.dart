import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Удерживает процесс приложения живым, пока вы «на связи».
///
/// Класс называется LinkKeeper, а не KeepAlive: во Flutter уже есть виджет
/// KeepAlive, и одноимённый класс ломает компиляцию коллизией имён.
///
/// Зачем это нужно. Постоянное WSS-соединение живёт в основном изолате, а
/// Android через несколько минут после сворачивания выгружает процесс целиком —
/// сокет рвётся, и звонок до вас не доходит. Единственный законный способ
/// запретить системе это делать — foreground service с постоянным уведомлением.
///
/// Сервис здесь пустой: никакой логики внутри него нет, его единственная задача
/// — существовать. Соединение остаётся там же, где было.
///
/// Все вызовы плагина обёрнуты в try/catch: если сервис не запустится, лучше
/// работать без него, чем уронить приложение на старте.
class LinkKeeper {
  LinkKeeper._();

  static const _channelId = 'mycall_link';
  static bool _initialized = false;
  static bool _running = false;

  static bool get isRunning => _running;

  /// Текст последней ошибки. Показывается в интерфейсе: без отладчика это
  /// единственный способ узнать, почему сервис не поднялся.
  static String? lastError;

  /// Снято ли ограничение батареи.
  ///
  /// Это не косметика. Через несколько минут неподвижности с погашенным
  /// экраном Android уходит в Doze и отключает приложениям сеть — foreground
  /// service тут не помогает, он защищает процесс, а не доступ к сети.
  /// Единственное штатное исключение из Doze — белый список батареи.
  static bool batteryUnrestricted = true;

  /// Перечитать фактическое состояние у системы.
  static Future<void> refresh() async {
    try {
      _running = await FlutterForegroundTask.isRunningService;
      batteryUnrestricted =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (e) {
      debugPrint('LinkKeeper.refresh: $e');
    }
  }

  /// Открыть системные настройки батареи. Прямой запрос диалогом часть
  /// прошивок отклоняет молча, поэтому нужен и этот путь.
  static Future<void> openBatterySettings() async {
    try {
      await FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();
    } catch (e) {
      debugPrint('LinkKeeper.openBatterySettings: $e');
    }
  }

  /// Запросить разрешения и поднять сервис. Возвращает true, если получилось.
  ///
  /// Порядок важен: на Android 13+ foreground service не запускается без
  /// разрешения на уведомления, поэтому сначала разрешения, потом старт.
  static Future<bool> ensureRunning(String user) async {
    await requestPermissions();
    await refresh();
    if (_running) return true;

    // Android отказывает в запуске foreground service, если приложение ещё не
    // считается активным на экране. При повторном входе разрешения уже выданы,
    // диалогов нет, и запуск случается слишком рано — отсюда пауза.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // Три попытки: остановленный сервис освобождается не мгновенно, и первый
    // запуск сразу после выхода из аккаунта нередко не проходит.
    for (var attempt = 1; attempt <= 3 && !_running; attempt++) {
      await start(user);
      if (!_running) {
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        await refresh();
      }
    }
    return _running;
  }

  /// Разрешения, без которых сервис не запустится: уведомления и снятие
  /// ограничений батареи. Второе особенно важно — с включённой оптимизацией
  /// производитель телефона всё равно прибьёт процесс, невзирая на сервис.
  static Future<void> requestPermissions() async {
    try {
      final notifications = await FlutterForegroundTask.checkNotificationPermission();
      if (notifications != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      lastError = 'разрешения: $e';
      debugPrint('LinkKeeper.requestPermissions: $e');
    }
  }

  static void _init() {
    if (_initialized) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _channelId,
          channelName: 'Связь',
          channelDescription: 'Соединение с сервером, чтобы доходили звонки',
          // HIGH нужен, чтобы уведомление о входящем звонке всплывало
          // поверх экрана, а не пряталось в шторку.
          channelImportance: NotificationChannelImportance.HIGH,
          priority: NotificationPriority.HIGH,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      _initialized = true;
    } catch (e) {
      lastError = 'инициализация: $e';
      debugPrint('LinkKeeper._init: $e');
    }
  }

  /// Запустить сервис. Вызывается, когда установлено соединение с сервером.
  static Future<void> start(String user) async {
    _init();
    if (!_initialized) {
      lastError ??= 'плагин не инициализирован';
      return;
    }
    if (_running) return;
    try {
      await FlutterForegroundTask.startService(
        notificationTitle: 'MyCall на связи',
        notificationText: 'Вы вошли как $user',
      );
      _running = await FlutterForegroundTask.isRunningService;
      if (!_running) {
        lastError = 'сервис не поднялся, причина не сообщена системой';
      } else {
        lastError = null;
      }
    } catch (e) {
      lastError = 'запуск: $e';
      debugPrint('LinkKeeper.start: $e');
    }
  }

  /// Показать входящий звонок в уведомлении. Пока приложение свёрнуто, это
  /// единственный способ узнать о звонке: нажатие на уведомление открывает
  /// приложение, где экран звонка уже ждёт.
  static Future<void> ringing(String peer) async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Входящий звонок',
        notificationText: 'Звонит $peer — нажмите, чтобы ответить',
      );
    } catch (e) {
      debugPrint('LinkKeeper.ringing: $e');
    }
  }

  /// Вернуть обычный текст уведомления после завершения звонка.
  static Future<void> idle(String user) async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'MyCall на связи',
        notificationText: 'Вы вошли как $user',
      );
    } catch (e) {
      debugPrint('LinkKeeper.idle: $e');
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('LinkKeeper.stop: $e');
    }
    _running = false;
    // Сбрасываем инициализацию: после остановки плагин мог остаться в
    // несогласованном состоянии, и следующий запуск должен начать заново.
    _initialized = false;
    lastError = null;
  }
}
