import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api_client.dart';
import '../data/online_models.dart';
import '../data/online_repository.dart';

class LobbyState {
  const LobbyState({
    this.loading = false,
    this.matches = const [],
    this.ticket,
    this.privateLobby,
    this.matchedId,
    this.error,
  });

  final bool loading;
  final List<OnlineMatchSummary> matches;
  final MatchmakingTicket? ticket;
  final PrivateLobby? privateLobby;
  final String? matchedId;
  final String? error;

  bool get searching =>
      ticket?.status == 'searching' || ticket?.status == 'waiting';
  bool get hosting => privateLobby?.status == 'waiting';

  LobbyState copyWith({
    bool? loading,
    List<OnlineMatchSummary>? matches,
    MatchmakingTicket? ticket,
    PrivateLobby? privateLobby,
    String? matchedId,
    String? error,
    bool clearTicket = false,
    bool clearLobby = false,
    bool clearMatched = false,
    bool clearError = false,
  }) => LobbyState(
    loading: loading ?? this.loading,
    matches: matches ?? this.matches,
    ticket: clearTicket ? null : ticket ?? this.ticket,
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

  Future<void> startQuickMatch() async {
    if (state.searching || state.hosting) return;
    final generation = ++_pollGeneration;
    state = state.copyWith(loading: true, clearError: true, clearMatched: true);
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
        state = state.copyWith(loading: false, error: _message(error));
      }
    }
  }

  Future<void> cancelQuickMatch() async {
    final ticket = state.ticket;
    ++_pollGeneration;
    state = state.copyWith(clearTicket: true);
    if (ticket != null) {
      try {
        await _repository.cancelTicket(ticket.id);
      } on ApiException catch (error) {
        final matchId = error.details?['matchId'];
        if (error.code == 'matchAlreadyFound' && matchId is String) {
          state = state.copyWith(matchedId: matchId);
        } else {
          state = state.copyWith(error: _message(error));
        }
      } catch (error) {
        state = state.copyWith(error: _message(error));
      }
    }
  }

  Future<void> createPrivateLobby() async {
    if (state.searching || state.hosting) return;
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
    state = state.copyWith(clearLobby: true);
    if (lobby != null) {
      try {
        await _repository.closeLobby(lobby.id);
      } catch (error) {
        state = state.copyWith(error: _message(error));
      }
    }
  }

  Future<void> join(String code) async {
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
      clearLobby: true,
    );
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
