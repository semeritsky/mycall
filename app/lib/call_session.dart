import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling.dart';

enum CallStage { dialing, ringing, connecting, active, ended }

/// Одна попытка звонка: peer connection, локальный и удалённый потоки,
/// обмен SDP и ICE через [Signaling].
///
/// Медиа шифруется DTLS-SRTP и идёт напрямую между устройствами; сервер
/// участвует только в обмене сигналами (или как слепой TURN-релей).
class CallSession extends ChangeNotifier {
  CallSession({
    required this.signaling,
    required this.peer,
    required this.video,
    required this.isCaller,
  });

  final Signaling signaling;
  final String peer;
  final bool video;
  final bool isCaller;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final List<RTCIceCandidate> _pendingCandidates = [];
  RTCSessionDescription? _heldOffer;

  CallStage stage = CallStage.dialing;
  String? statusText;
  bool micEnabled = true;
  bool cameraEnabled = true;
  bool speakerOn = true;
  bool frontCamera = true;
  DateTime? connectedAt;

  /// Общая подготовка: рендереры, локальное медиа, peer connection.
  Future<void> prepare() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _sub = signaling.signals.listen(_onSignal);

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': video
          ? {
              'facingMode': 'user',
              // Компромисс качество/трафик для мобильного интернета.
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 24},
            }
          : false,
    });
    localRenderer.srcObject = _localStream;
    cameraEnabled = video;

    _pc = await createPeerConnection(signaling.iceServers);
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      signaling.sendSignal({
        'type': 'ice',
        'to': peer,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        notifyListeners();
      }
    };

    _pc!.onConnectionState = (s) {
      switch (s) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          stage = CallStage.active;
          connectedAt ??= DateTime.now();
          statusText = null;
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          statusText = 'Связь нестабильна';
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          statusText = 'Не удалось установить соединение';
          stage = CallStage.ended;
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          stage = CallStage.ended;
          break;
        default:
          break;
      }
      notifyListeners();
    };

    await Helper.setSpeakerphoneOn(true);
  }

  /// Исходящий звонок: звоним и сразу отправляем offer.
  Future<void> start() async {
    stage = CallStage.dialing;
    notifyListeners();
    signaling.ring(peer, video: video);

    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': video,
    });
    await _pc!.setLocalDescription(offer);
    signaling.sendSignal({
      'type': 'offer',
      'to': peer,
      'sdp': offer.sdp,
      'video': video,
    });
  }

  /// Входящий звонок: принимаем — отвечаем на уже полученный offer.
  Future<void> accept() async {
    stage = CallStage.connecting;
    notifyListeners();
    final offer = _heldOffer;
    if (offer != null) {
      _heldOffer = null;
      await _applyRemoteOffer(offer);
    }
  }

  void decline() {
    signaling.sendSignal({'type': 'decline', 'to': peer});
    stage = CallStage.ended;
    notifyListeners();
  }

  Future<void> _applyRemoteOffer(RTCSessionDescription offer) async {
    await _pc!.setRemoteDescription(offer);
    await _drainCandidates();
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    signaling.sendSignal({'type': 'answer', 'to': peer, 'sdp': answer.sdp});
  }

  Future<void> _onSignal(Map<String, dynamic> msg) async {
    if (msg['from'] != peer) return;
    switch (msg['type']) {
      case 'offer':
        final offer = RTCSessionDescription(msg['sdp'] as String, 'offer');
        // Если пользователь ещё не нажал «Ответить», держим offer у себя.
        if (stage == CallStage.ringing) {
          _heldOffer = offer;
        } else {
          await _applyRemoteOffer(offer);
        }
        break;

      case 'answer':
        stage = CallStage.connecting;
        notifyListeners();
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'answer'),
        );
        await _drainCandidates();
        break;

      case 'ice':
        final candidate = RTCIceCandidate(
          msg['candidate'] as String?,
          msg['sdpMid'] as String?,
          msg['sdpMLineIndex'] as int?,
        );
        final remote = await _pc?.getRemoteDescription();
        if (remote == null) {
          _pendingCandidates.add(candidate); // trickle ICE опережает SDP
        } else {
          await _pc!.addCandidate(candidate);
        }
        break;

      case 'hangup':
      case 'decline':
        statusText = msg['type'] == 'decline' ? 'Отклонён' : 'Звонок завершён';
        stage = CallStage.ended;
        notifyListeners();
        break;
    }
  }

  Future<void> _drainCandidates() async {
    for (final c in _pendingCandidates) {
      await _pc?.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  // ------------------------------------------------------------ управление

  void toggleMic() {
    micEnabled = !micEnabled;
    for (final t in _localStream?.getAudioTracks() ?? []) {
      t.enabled = micEnabled;
    }
    notifyListeners();
  }

  void toggleCamera() {
    cameraEnabled = !cameraEnabled;
    for (final t in _localStream?.getVideoTracks() ?? []) {
      t.enabled = cameraEnabled;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    final track = tracks.first;
    await Helper.switchCamera(track);
    frontCamera = !frontCamera;
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speakerOn = !speakerOn;
    await Helper.setSpeakerphoneOn(speakerOn);
    notifyListeners();
  }

  Future<void> hangUp({bool notifyPeer = true}) async {
    if (notifyPeer && stage != CallStage.ended) {
      signaling.sendSignal({'type': 'hangup', 'to': peer});
    }
    stage = CallStage.ended;
    notifyListeners();
    await _teardown();
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    for (final t in _localStream?.getTracks() ?? []) {
      await t.stop();
    }
    await _localStream?.dispose();
    await _pc?.close();
    _pc = null;
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
