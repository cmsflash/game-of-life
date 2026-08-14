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
  Future<void> _operationQueue = Future.value();
  String? _accountId;
  var _generation = 0;
  var _authStateKnown = false;

  Stream<TurnNotificationMessage> get foregroundMessages =>
      _gateway.foregroundMessages;

  Stream<TurnNotificationMessage> get openedMessages => _gateway.openedMessages;

  Future<void> setAccount(String? accountId) async {
    if (_authStateKnown && _accountId == accountId) return;
    _authStateKnown = true;
    _accountId = accountId;
    final generation = ++_generation;
    state = state.copyWith(enabled: false, busy: false, clearError: true);
    if (accountId == null) {
      return _enqueue(() async {
        try {
          await _gateway.deactivate().timeout(_sessionCleanupTimeout);
        } catch (_) {
          // The server no longer has a usable session; local cleanup is best effort.
        }
        state = state.copyWith(enabled: false, busy: false, clearError: true);
      });
    }
    await initialize();
    if (!_isCurrent(generation)) return;
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

  Future<void> refresh() => _enqueue(_refresh);

  Future<void> _refresh() async {
    if (_accountId == null) return;
    final generation = _generation;
    await initialize();
    if (!_isCurrent(generation)) return;
    try {
      final installationId = await _sessionStore.deviceId();
      if (!_isCurrent(generation)) return;
      final capability = await _gateway.capability();
      if (!_isCurrent(generation)) return;
      final subscriptions = await _repository.listSubscriptions();
      if (!_isCurrent(generation)) return;
      final hasServerSubscription = subscriptions.any(
        (subscription) => subscription.installationId == installationId,
      );
      state = state.copyWith(
        loading: false,
        configured: capability.configured,
        supported: capability.supported,
        permission: capability.permission,
        // A server row is not enough to call the device active. Keep the
        // status disconnected until the current endpoint sync succeeds.
        enabled: false,
        clearError: true,
      );

      if (!capability.configured || !capability.supported) {
        state = state.copyWith(enabled: false);
        if (hasServerSubscription) {
          await _repository.deleteSubscription(installationId);
          if (!_isCurrent(generation)) return;
        }
        await _gateway.deactivate();
        return;
      }

      if (capability.permission == TurnNotificationPermission.granted) {
        var endpoint = await _gateway.currentEndpoint();
        if (!_isCurrent(generation)) return;
        // Permission has already been granted, so creating a missing push
        // endpoint here does not display an OS or browser permission prompt.
        endpoint ??= await _gateway.requestEndpoint();
        if (!_isCurrent(generation)) return;
        if (endpoint != null) {
          await _upsert(installationId, endpoint);
          if (!_isCurrent(generation)) return;
          state = state.copyWith(enabled: true, clearError: true);
        } else {
          state = state.copyWith(enabled: false);
          if (hasServerSubscription) {
            await _repository.deleteSubscription(installationId);
            if (!_isCurrent(generation)) return;
          }
          state = state.copyWith(
            enabled: false,
            error:
                'Notifications are allowed, but this device could not connect for alerts.',
          );
        }
      } else {
        state = state.copyWith(enabled: false);
        if (hasServerSubscription) {
          await _repository.deleteSubscription(installationId);
          if (!_isCurrent(generation)) return;
        }
        if (capability.permission == TurnNotificationPermission.denied) {
          await _gateway.deactivate();
          if (!_isCurrent(generation)) return;
        }
        state = state.copyWith(enabled: false);
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  Future<void> allow() {
    if (_accountId == null || state.busy) return Future.value();
    state = state.copyWith(busy: true, clearError: true);
    return _enqueue(_allow);
  }

  Future<void> _allow() async {
    if (_accountId == null) {
      state = state.copyWith(busy: false);
      return;
    }
    final generation = _generation;
    if (state.loading) await initialize();
    if (!_isCurrent(generation)) return;
    if (!state.configured || !state.supported) {
      state = state.copyWith(busy: false);
      return;
    }
    try {
      final endpoint = await _gateway.requestEndpoint();
      if (!_isCurrent(generation)) return;
      final capability = await _gateway.capability();
      if (!_isCurrent(generation)) return;
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
      if (!_isCurrent(generation)) return;
      await _upsert(installationId, endpoint);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        busy: false,
        configured: capability.configured,
        supported: capability.supported,
        permission: capability.permission,
        enabled: true,
        clearError: true,
      );
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(busy: false, error: _message(error));
    }
  }

  Future<void> disconnectAccount() {
    _accountId = null;
    _authStateKnown = true;
    _generation++;
    state = state.copyWith(enabled: false, busy: false, clearError: true);
    return _enqueue(() async {
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
        state = state.copyWith(enabled: false, busy: false, clearError: true);
      }
    });
  }

  void _endpointChanged(TurnNotificationEndpoint endpoint) {
    unawaited(_enqueue(() => _syncEndpoint(endpoint)));
  }

  Future<void> _syncEndpoint(TurnNotificationEndpoint endpoint) async {
    if (_accountId == null) return;
    final generation = _generation;
    try {
      final installationId = await _sessionStore.deviceId();
      if (!_isCurrent(generation)) return;
      await _upsert(installationId, endpoint);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(enabled: true, clearError: true);
    } catch (error) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(error: _message(error));
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _operationQueue.then((_) => operation());
    _operationQueue = result.catchError((_) {});
    return result;
  }

  bool _isCurrent(int generation) =>
      _accountId != null && generation == _generation;

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
