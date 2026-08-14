import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../../auth/data/session_store.dart';
import '../data/turn_notification_repository.dart';
import '../domain/turn_notifications.dart';
import '../platform/turn_notification_gateway.dart';

class TurnNotificationState {
  const TurnNotificationState({
    this.loading = true,
    this.configured = false,
    this.supported = false,
    this.permission = TurnNotificationPermission.unavailable,
    this.enabled = false,
    this.busy = false,
    this.error,
  });

  final bool loading;
  final bool configured;
  final bool supported;
  final TurnNotificationPermission permission;
  final bool enabled;
  final bool busy;
  final String? error;

  bool get canEnable =>
      !loading &&
      !busy &&
      configured &&
      supported &&
      permission != TurnNotificationPermission.denied;

  TurnNotificationState copyWith({
    bool? loading,
    bool? configured,
    bool? supported,
    TurnNotificationPermission? permission,
    bool? enabled,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => TurnNotificationState(
    loading: loading ?? this.loading,
    configured: configured ?? this.configured,
    supported: supported ?? this.supported,
    permission: permission ?? this.permission,
    enabled: enabled ?? this.enabled,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
  );
}

class TurnNotificationController extends StateNotifier<TurnNotificationState> {
  static const _sessionCleanupTimeout = Duration(seconds: 3);

  TurnNotificationController({
    required TurnNotificationRepository repository,
    required TurnNotificationGateway gateway,
    required SessionStore sessionStore,
  }) : this._(repository, gateway, sessionStore);

  TurnNotificationController._(
    this._repository,
    this._gateway,
    this._sessionStore,
  ) : super(const TurnNotificationState()) {
    _endpointSubscription = _gateway.endpointChanges.listen(_endpointChanged);
  }

  final TurnNotificationRepository _repository;
  final TurnNotificationGateway _gateway;
  final SessionStore _sessionStore;
  StreamSubscription<TurnNotificationEndpoint>? _endpointSubscription;
  Future<void>? _initialization;
  var _signedIn = false;
  var _authStateKnown = false;

  Stream<TurnNotificationMessage> get foregroundMessages =>
      _gateway.foregroundMessages;

  Stream<TurnNotificationMessage> get openedMessages => _gateway.openedMessages;

  Future<void> setSignedIn(bool signedIn) async {
    if (_authStateKnown && _signedIn == signedIn) return;
    _authStateKnown = true;
    if (!signedIn) {
      _signedIn = false;
      try {
        await _gateway.deactivate().timeout(_sessionCleanupTimeout);
      } catch (_) {
        // The server no longer has a usable session; local cleanup is best effort.
      }
      state = state.copyWith(enabled: false, busy: false, clearError: true);
      return;
    }
    _signedIn = true;
    await initialize();
    await refresh();
  }

  Future<void> initialize() {
    final current = _initialization;
    if (current != null) return current;
    late final Future<void> attempt;
    attempt = _initialize().whenComplete(() {
      if (state.error != null && identical(_initialization, attempt)) {
        _initialization = null;
      }
    });
    return _initialization = attempt;
  }

  Future<void> _initialize() async {
    Object? configurationError;
    TurnNotificationConfiguration configuration;
    try {
      configuration = await _repository.configuration();
    } catch (error) {
      configurationError = error;
      configuration = const TurnNotificationConfiguration(
        providers: {'webPush', 'firebase'},
      );
    }
    try {
      final capability = await _gateway.initialize(configuration);
      state = state.copyWith(
        loading: false,
        configured: capability.configured,
        supported: capability.supported,
        permission: capability.permission,
        error: configurationError == null ? null : _message(configurationError),
        clearError: configurationError == null,
      );
    } catch (error) {
      state = state.copyWith(
        loading: false,
        configured: true,
        supported: false,
        error: _message(error),
      );
    }
  }

  Future<void> refresh() async {
    if (!_signedIn) return;
    await initialize();
    final installationId = await _sessionStore.deviceId();
    try {
      final capability = await _gateway.capability();
      final subscriptions = await _repository.listSubscriptions();
      final enabled = subscriptions.any(
        (subscription) => subscription.installationId == installationId,
      );
      state = state.copyWith(
        loading: false,
        configured: capability.configured,
        supported: capability.supported,
        permission: capability.permission,
        enabled: enabled,
        clearError: true,
      );

      if (enabled &&
          capability.permission == TurnNotificationPermission.granted) {
        final endpoint = await _gateway.currentEndpoint();
        if (endpoint != null) {
          await _upsert(installationId, endpoint);
        } else {
          await _repository.deleteSubscription(installationId);
          state = state.copyWith(enabled: false);
        }
      } else if (enabled &&
          capability.permission == TurnNotificationPermission.denied) {
        await _repository.deleteSubscription(installationId);
        await _gateway.deactivate();
        state = state.copyWith(enabled: false);
      }
    } catch (error) {
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  Future<void> enable() async {
    if (!_signedIn || state.busy) return;
    if (state.loading) await initialize();
    if (!state.configured || !state.supported) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final endpoint = await _gateway.requestEndpoint();
      final capability = await _gateway.capability();
      if (endpoint == null) {
        state = state.copyWith(
          busy: false,
          permission: capability.permission,
          enabled: false,
          error: capability.permission == TurnNotificationPermission.denied
              ? 'Notifications are blocked in your browser or device settings.'
              : 'Notification permission was not granted.',
        );
        return;
      }
      final installationId = await _sessionStore.deviceId();
      await _upsert(installationId, endpoint);
      state = state.copyWith(
        busy: false,
        configured: capability.configured,
        supported: capability.supported,
        permission: capability.permission,
        enabled: true,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
    }
  }

  Future<void> disable() async {
    if (!_signedIn || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final installationId = await _sessionStore.deviceId();
      await _repository.deleteSubscription(installationId);
      await _gateway.deactivate();
      final capability = await _gateway.capability();
      state = state.copyWith(
        busy: false,
        permission: capability.permission,
        enabled: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(busy: false, error: _message(error));
    }
  }

  Future<void> disconnectAccount() async {
    try {
      final installationId = await _sessionStore.deviceId();
      await _repository
          .deleteSubscription(installationId)
          .timeout(_sessionCleanupTimeout);
    } catch (_) {
      // Signing out must remain possible when the network is unavailable.
    } finally {
      try {
        await _gateway.deactivate().timeout(_sessionCleanupTimeout);
      } catch (_) {
        // Signing out must remain possible when provider cleanup fails.
      }
      _signedIn = false;
      _authStateKnown = true;
      state = state.copyWith(enabled: false, busy: false, clearError: true);
    }
  }

  Future<void> _endpointChanged(TurnNotificationEndpoint endpoint) async {
    if (!_signedIn || !state.enabled) return;
    try {
      final installationId = await _sessionStore.deviceId();
      await _upsert(installationId, endpoint);
    } catch (error) {
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> _upsert(
    String installationId,
    TurnNotificationEndpoint endpoint,
  ) => _repository.upsertSubscription(
    installationId,
    endpoint,
    locale: PlatformDispatcher.instance.locale.toLanguageTag(),
    timeZone: DateTime.now().timeZoneName,
  );

  @override
  void dispose() {
    unawaited(_endpointSubscription?.cancel());
    unawaited(_gateway.dispose());
    super.dispose();
  }
}

String _message(Object error) {
  if (error is ApiException) return error.message;
  return 'Notifications could not be updated. Check your connection and try again.';
}
