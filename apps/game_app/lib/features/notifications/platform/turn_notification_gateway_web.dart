import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../domain/turn_notifications.dart';
import 'turn_notification_gateway.dart';

TurnNotificationGateway createTurnNotificationGateway() =>
    WebPushTurnNotificationGateway();

class WebPushTurnNotificationGateway implements TurnNotificationGateway {
  web.ServiceWorkerRegistration? _registration;
  TurnNotificationCapability? _capability;
  String? _vapidPublicKey;
  var _initialized = false;

  bool get _supported =>
      web.window.isSecureContext &&
      web.window.navigator.has('serviceWorker') &&
      web.window.has('Notification') &&
      web.window.has('PushManager');

  @override
  Future<TurnNotificationCapability> initialize(
    TurnNotificationConfiguration configuration,
  ) async {
    if (!configuration.supports('webPush')) {
      return _capability = const TurnNotificationCapability.notConfigured();
    }
    _vapidPublicKey = configuration.webPushVapidPublicKey;
    if (_vapidPublicKey == null || _vapidPublicKey!.isEmpty) {
      return _capability = const TurnNotificationCapability.notConfigured();
    }
    if (_initialized) return _refreshCapability();
    if (!_supported) {
      return _capability = const TurnNotificationCapability.unsupported();
    }
    final base = Uri.base;
    final registration = await web.window.navigator.serviceWorker
        .register(
          base.resolve('/push-service-worker.js').toString().toJS,
          web.RegistrationOptions(
            scope: base.resolve('/push/').toString(),
            updateViaCache: 'none',
          ),
        )
        .toDart;
    _registration = registration;
    _initialized = true;
    return _refreshCapability();
  }

  @override
  Future<TurnNotificationCapability> capability() async {
    if (!_initialized) {
      return const TurnNotificationCapability.notConfigured();
    }
    if (_registration == null) {
      return _capability ?? const TurnNotificationCapability.unsupported();
    }
    return _refreshCapability();
  }

  TurnNotificationCapability _refreshCapability() =>
      _capability = TurnNotificationCapability(
        configured: true,
        supported: true,
        permission: switch (web.Notification.permission) {
          'granted' => TurnNotificationPermission.granted,
          'denied' => TurnNotificationPermission.denied,
          _ => TurnNotificationPermission.prompt,
        },
      );

  @override
  Future<TurnNotificationEndpoint?> currentEndpoint() async {
    final currentCapability = await capability();
    if (currentCapability.permission != TurnNotificationPermission.granted) {
      return null;
    }
    final subscription = await _registration!.pushManager
        .getSubscription()
        .toDart;
    return subscription == null ? null : _endpoint(subscription);
  }

  @override
  Future<TurnNotificationEndpoint?> requestEndpoint() async {
    if (!_initialized) return null;
    final registration = _registration;
    if (registration == null) return null;

    var permission = web.Notification.permission;
    if (permission != 'granted') {
      permission = (await web.Notification.requestPermission().toDart).toDart;
    }
    _refreshCapability();
    if (permission != 'granted') return null;

    var subscription = await registration.pushManager.getSubscription().toDart;
    subscription ??= await registration.pushManager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            userVisibleOnly: true,
            applicationServerKey: _decodeVapidKey(_vapidPublicKey!).toJS,
          ),
        )
        .toDart;
    return _endpoint(subscription);
  }

  @override
  Future<void> deactivate() async {
    var registration = _registration;
    if (registration == null && _supported) {
      registration = await web.window.navigator.serviceWorker
          .getRegistration(Uri.base.resolve('/push/').toString())
          .toDart;
    }
    if (registration == null) return;
    final subscription = await registration.pushManager
        .getSubscription()
        .toDart;
    await subscription?.unsubscribe().toDart;
  }

  TurnNotificationEndpoint _endpoint(web.PushSubscription subscription) {
    final p256dh = subscription.getKey('p256dh');
    final auth = subscription.getKey('auth');
    if (p256dh == null || auth == null) {
      throw StateError('The browser returned an incomplete push subscription.');
    }
    return TurnNotificationEndpoint.webPush(
      endpoint: subscription.endpoint,
      p256dh: _encodeKey(p256dh),
      auth: _encodeKey(auth),
    );
  }

  @override
  Stream<TurnNotificationEndpoint> get endpointChanges => const Stream.empty();

  @override
  Stream<TurnNotificationMessage> get foregroundMessages =>
      const Stream.empty();

  @override
  Stream<TurnNotificationMessage> get openedMessages => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

Uint8List _decodeVapidKey(String value) {
  final normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  return base64Decode(padded);
}

String _encodeKey(JSArrayBuffer value) {
  final bytes = JSUint8Array(value).toDart;
  return base64UrlEncode(bytes).replaceAll('=', '');
}
