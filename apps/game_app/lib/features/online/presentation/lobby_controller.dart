import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../data/online_models.dart';
import '../data/online_repository.dart';

enum MatchmakingIntent { findOpponent, publicRoom }

class LobbyState {
  const LobbyState({
    this.loading = false,
    this.matches = const [],
    this.ticket,
    this.matchmakingIntent,
    this.privateLobby,
    this.matchedId,
    this.error,
  });

  final bool loading;
  final List<OnlineMatchSummary> matches;
  final MatchmakingTicket? ticket;
  final MatchmakingIntent? matchmakingIntent;
  final PrivateLobby? privateLobby;
  final String? matchedId;
  final String? error;

  bool get searching =>
      ticket?.status == 'searching' || ticket?.status == 'waiting';
  bool get hosting => privateLobby?.status == 'waiting';
  bool get hasOwnedWaitingRoom => matches.any(
    (match) => match.status == 'waiting' && match.joinCode != null,
  );

  LobbyState copyWith({
    bool? loading,
    List<OnlineMatchSummary>? matches,
    MatchmakingTicket? ticket,
    MatchmakingIntent? matchmakingIntent,
    PrivateLobby? privateLobby,
    String? matchedId,
    String? error,
    bool clearTicket = false,
    bool clearMatchmakingIntent = false,
    bool clearLobby = false,
    bool clearMatched = false,
    bool clearError = false,
  }) => LobbyState(
    loading: loading ?? this.loading,
    matches: matches ?? this.matches,
    ticket: clearTicket ? null : ticket ?? this.ticket,
    matchmakingIntent: clearMatchmakingIntent
        ? null
        : matchmakingIntent ?? this.matchmakingIntent,
    privateLobby: clearLobby ? null : privateLobby ?? this.privateLobby,
    matchedId: clearMatched ? null : matchedId ?? this.matchedId,
    error: clearError ? null : error ?? this.error,
  );
}

class LobbyController extends StateNotifier<LobbyState> {
  LobbyController(this._repository) : super(const LobbyState());

  final OnlineRepository _repository;
  var _pollGeneration = 0;

  Future<void> loadMatches() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final page = await _repository.listMatches();
      state = state.copyWith(loading: false, matches: page.items);
    } catch (error) {
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  Future<void> startQuickMatch({
    MatchmakingIntent intent = MatchmakingIntent.findOpponent,
  }) async {
    if (state.searching || state.hosting || state.hasOwnedWaitingRoom) return;
    final generation = ++_pollGeneration;
    state = state.copyWith(
      loading: true,
      matchmakingIntent: intent,
      clearError: true,
      clearMatched: true,
    );
    try {
      var ticket = await _repository.startQuickMatch();
      if (!mounted || generation != _pollGeneration) return;
      state = state.copyWith(loading: false, ticket: ticket);
      while (mounted &&
          generation == _pollGeneration &&
          (ticket.status == 'searching' || ticket.status == 'waiting')) {
        await Future<void>.delayed(ticket.pollAfter);
        if (!mounted || generation != _pollGeneration) return;
        ticket = await _repository.getTicket(ticket.id);
        if (!mounted || generation != _pollGeneration) return;
        state = state.copyWith(ticket: ticket);
      }
      if (ticket.matchId != null && mounted && generation == _pollGeneration) {
        state = state.copyWith(matchedId: ticket.matchId);
      }
    } catch (error) {
      if (mounted && generation == _pollGeneration) {
        state = state.copyWith(
          loading: false,
          error: _message(error),
          clearTicket: true,
          clearMatchmakingIntent: true,
        );
      }
    }
  }

  Future<void> cancelQuickMatch() async {
    final ticket = state.ticket;
    ++_pollGeneration;
    state = state.copyWith(loading: ticket != null, clearError: true);
    if (ticket != null) {
      try {
        await _repository.cancelTicket(ticket.id);
        state = state.copyWith(
          loading: false,
          clearTicket: true,
          clearMatchmakingIntent: true,
        );
      } on ApiException catch (error) {
        final matchId = error.details?['matchId'];
        if (error.code == 'matchAlreadyFound' && matchId is String) {
          state = state.copyWith(
            loading: false,
            matchedId: matchId,
            clearTicket: true,
            clearMatchmakingIntent: true,
          );
        } else {
          state = state.copyWith(loading: false, error: _message(error));
        }
      } catch (error) {
        state = state.copyWith(loading: false, error: _message(error));
      }
    }
  }

  Future<void> createPrivateLobby() async {
    if (state.searching || state.hosting || state.hasOwnedWaitingRoom) return;
    final generation = ++_pollGeneration;
    state = state.copyWith(loading: true, clearError: true, clearMatched: true);
    try {
      var lobby = await _repository.createPrivateLobby();
      if (!mounted || generation != _pollGeneration) return;
      state = state.copyWith(loading: false, privateLobby: lobby);
      while (mounted &&
          generation == _pollGeneration &&
          lobby.status == 'waiting') {
        await Future<void>.delayed(lobby.pollAfter);
        if (!mounted || generation != _pollGeneration) return;
        lobby = await _repository.getLobby(lobby.id);
        if (!mounted || generation != _pollGeneration) return;
        state = state.copyWith(privateLobby: lobby);
      }
      if (lobby.matchId != null && mounted && generation == _pollGeneration) {
        state = state.copyWith(matchedId: lobby.matchId);
      }
    } catch (error) {
      if (mounted && generation == _pollGeneration) {
        state = state.copyWith(loading: false, error: _message(error));
      }
    }
  }

  Future<void> closePrivateLobby() async {
    final lobby = state.privateLobby;
    ++_pollGeneration;
    state = state.copyWith(loading: lobby != null, clearError: true);
    if (lobby != null) {
      try {
        await _repository.closeLobby(lobby.id);
        state = state.copyWith(loading: false, clearLobby: true);
      } on ApiException catch (error) {
        if (!await _resolveRoomCloseRace(lobby.id, error)) {
          state = state.copyWith(loading: false, error: _message(error));
        }
      } catch (error) {
        state = state.copyWith(loading: false, error: _message(error));
      }
    }
  }

  Future<void> closeWaitingRoom(String id) async {
    if (state.privateLobby?.id == id) ++_pollGeneration;
    state = state.copyWith(loading: true, clearError: true);
    try {
      await _repository.closeLobby(id);
      state = state.copyWith(
        loading: false,
        matches: [
          for (final match in state.matches)
            if (match.id != id) match,
        ],
        clearLobby: state.privateLobby?.id == id,
      );
    } on ApiException catch (error) {
      if (!await _resolveRoomCloseRace(id, error)) {
        state = state.copyWith(loading: false, error: _message(error));
      }
    } catch (error) {
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  Future<bool> _resolveRoomCloseRace(String id, ApiException error) async {
    if (error.code != 'matchUnavailable') return false;
    try {
      final lobby = await _repository.getLobby(id);
      if (lobby.matchId == null) return false;
      state = state.copyWith(
        loading: false,
        matchedId: lobby.matchId,
        matches: [
          for (final match in state.matches)
            if (match.id != id) match,
        ],
        clearLobby: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> join(String code) async {
    if (state.searching || state.hosting || state.hasOwnedWaitingRoom) return;
    state = state.copyWith(loading: true, clearError: true, clearMatched: true);
    try {
      final lobby = await _repository.joinLobby(code);
      state = state.copyWith(
        loading: false,
        privateLobby: lobby,
        matchedId: lobby.matchId,
      );
    } catch (error) {
      state = state.copyWith(loading: false, error: _message(error));
    }
  }

  void acknowledgeMatch() {
    ++_pollGeneration;
    state = state.copyWith(
      clearMatched: true,
      clearTicket: true,
      clearMatchmakingIntent: true,
      clearLobby: true,
    );
  }

  void sessionEnded() {
    ++_pollGeneration;
    state = const LobbyState();
  }

  Future<void> disconnectAccount() async {
    final ticket = state.ticket;
    final lobby = state.privateLobby;
    final waitingRoomIds = <String>{
      if (lobby?.status == 'waiting') lobby!.id,
      for (final match in state.matches)
        if (match.status == 'waiting' && match.joinCode != null) match.id,
    };
    sessionEnded();
    if (ticket != null &&
        (ticket.status == 'searching' || ticket.status == 'waiting')) {
      try {
        await _repository.cancelTicket(ticket.id);
      } catch (_) {
        // Session shutdown must continue when cancellation loses a race.
      }
    }
    for (final id in waitingRoomIds) {
      try {
        await _repository.closeLobby(id);
      } catch (_) {
        // Session shutdown must continue when closure loses a race.
      }
    }
  }

  @override
  void dispose() {
    ++_pollGeneration;
    super.dispose();
  }
}

String _message(Object error) => error is ApiException
    ? error.message
    : 'Could not reach the game server. Please try again.';
