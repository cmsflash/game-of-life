import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../domain/turn_notifications.dart';
import 'turn_notification_gateway.dart';

TurnNotificationGateway createTurnNotificationGateway() =>
    FirebaseTurnNotificationGateway();

class FirebaseTurnNotificationGateway implements TurnNotificationGateway {
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _sharedApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _sharedAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _androidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );
  static const _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const _iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _iosBundleId = String.fromEnvironment(
    'FIREBASE_IOS_BUNDLE_ID',
    defaultValue: 'com.cmsflash.gameoflife',
  );

  final _endpointChanges =
      StreamController<TurnNotificationEndpoint>.broadcast();
  final _foregroundMessages =
      StreamController<TurnNotificationMessage>.broadcast();
  final _openedMessages = StreamController<TurnNotificationMessage>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];

  FirebaseMessaging? _messaging;
  TurnNotificationCapability? _capability;
  var _initialized = false;

  String get _platform => Platform.isIOS ? 'ios' : 'android';

  String get _apiKey {
    final platformValue = Platform.isIOS ? _iosApiKey : _androidApiKey;
    return platformValue.isNotEmpty ? platformValue : _sharedApiKey;
  }

  String get _appId {
    final platformValue = Platform.isIOS ? _iosAppId : _androidAppId;
    return platformValue.isNotEmpty ? platformValue : _sharedAppId;
  }

  bool get _configured =>
      _projectId.isNotEmpty &&
      _senderId.isNotEmpty &&
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty;

  @override
  Future<TurnNotificationCapability> initialize(
    TurnNotificationConfiguration configuration,
  ) async {
    if (!configuration.supports('firebase')) {
      return _capability = const TurnNotificationCapability.notConfigured();
    }
    if (_initialized) return capability();
    if (!Platform.isAndroid && !Platform.isIOS) {
      return _capability = const TurnNotificationCapability.unsupported();
    }
    if (!_configured) {
      return _capability = const TurnNotificationCapability.notConfigured();
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          iosBundleId: Platform.isIOS ? _iosBundleId : null,
        ),
      );
    }
    final messaging = FirebaseMessaging.instance;
    if (!await messaging.isSupported()) {
      _messaging = messaging;
      _initialized = true;
      return _capability = const TurnNotificationCapability.unsupported();
    }

    final initialMessage = await messaging.getInitialMessage();
    _messaging = messaging;

    _subscriptions
      ..add(
        messaging.onTokenRefresh.listen((token) {
          _endpointChanges.add(
            TurnNotificationEndpoint.firebase(
              platform: _platform,
              token: token,
            ),
          );
        }),
      )
      ..add(
        FirebaseMessaging.onMessage.listen(
          (message) => _foregroundMessages.add(_fromRemoteMessage(message)),
        ),
      )
      ..add(
        FirebaseMessaging.onMessageOpenedApp.listen(
          (message) => _openedMessages.add(_fromRemoteMessage(message)),
        ),
      );

    _initialized = true;
    if (initialMessage != null) {
      scheduleMicrotask(
        () => _openedMessages.add(_fromRemoteMessage(initialMessage)),
      );
    }
    return _refreshCapability();
  }

  @override
  Future<TurnNotificationCapability> capability() async {
    if (!_initialized) {
      return const TurnNotificationCapability.notConfigured();
    }
    if (_messaging == null) {
      return _capability ?? const TurnNotificationCapability.unsupported();
    }
    return _refreshCapability();
  }

  Future<TurnNotificationCapability> _refreshCapability() async {
    final settings = await _messaging!.getNotificationSettings();
    return _capability = TurnNotificationCapability(
      configured: true,
      supported: true,
      permission: _permission(settings.authorizationStatus),
    );
  }

  @override
  Future<TurnNotificationEndpoint?> currentEndpoint() async {
    final currentCapability = await capability();
    if (currentCapability.permission != TurnNotificationPermission.granted) {
      return null;
    }
    final token = await _messaging!.getToken();
    if (token == null || token.isEmpty) return null;
    return TurnNotificationEndpoint.firebase(platform: _platform, token: token);
  }

  @override
  Future<TurnNotificationEndpoint?> requestEndpoint() async {
    if (!_initialized) return null;
    final messaging = _messaging;
    if (messaging == null) return null;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    _capability = TurnNotificationCapability(
      configured: true,
      supported: true,
      permission: _permission(settings.authorizationStatus),
    );
    if (_capability!.permission != TurnNotificationPermission.granted) {
      return null;
    }
    final token = await messaging.getToken();
    if (token == null || token.isEmpty) return null;
    return TurnNotificationEndpoint.firebase(platform: _platform, token: token);
  }

  @override
  Future<void> deactivate() async {
    final messaging = _messaging;
    if (messaging != null) await messaging.deleteToken();
  }

  @override
  Stream<TurnNotificationEndpoint> get endpointChanges =>
      _endpointChanges.stream;

  @override
  Stream<TurnNotificationMessage> get foregroundMessages =>
      _foregroundMessages.stream;

  @override
  Stream<TurnNotificationMessage> get openedMessages => _openedMessages.stream;

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _endpointChanges.close();
    await _foregroundMessages.close();
    await _openedMessages.close();
  }
}

TurnNotificationPermission _permission(AuthorizationStatus status) =>
    switch (status) {
      AuthorizationStatus.authorized ||
      AuthorizationStatus.provisional => TurnNotificationPermission.granted,
      AuthorizationStatus.denied => TurnNotificationPermission.denied,
      AuthorizationStatus.notDetermined => TurnNotificationPermission.prompt,
    };

TurnNotificationMessage _fromRemoteMessage(RemoteMessage message) {
  final rawPath =
      message.data['path']?.toString() ?? message.data['url']?.toString();
  final parsed = rawPath == null ? null : Uri.tryParse(rawPath);
  return TurnNotificationMessage(
    matchId: message.data['matchId']?.toString(),
    path: parsed?.path,
    title: message.notification?.title ?? message.data['title']?.toString(),
    body: message.notification?.body ?? message.data['body']?.toString(),
  );
}
