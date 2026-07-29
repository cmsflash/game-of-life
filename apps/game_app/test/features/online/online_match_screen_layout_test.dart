import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/online/data/online_models.dart';
import 'package:game_of_life/features/online/data/online_repository.dart';
import 'package:game_of_life/features/online/presentation/online_match_screen.dart';
import 'package:game_of_life/providers.dart';

void main() {
  testWidgets('online match fits its board and scrolls status vertically', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          onlineRepositoryProvider.overrideWithValue(
            _MatchRepository(_activeMatch()),
          ),
        ],
        child: const MaterialApp(home: OnlineMatchScreen(matchId: 'match-1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('online-life-board')), findsOneWidget);
    expect(tester.takeException(), isNull);
    final scrollViews = tester.widgetList<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scrollViews, isNotEmpty);
    expect(
      scrollViews.every((view) => view.scrollDirection == Axis.vertical),
      isTrue,
    );

    final statusCard = find.ancestor(
      of: find.text('MOVE 1'),
      matching: find.byType(Card),
    );
    expect(statusCard, findsOneWidget);
    expect(tester.getSize(statusCard).width, lessThanOrEqualTo(320));
  });
}

OnlineMatch _activeMatch() {
  const players = [
    OnlinePlayer(
      id: 'black',
      username: 'black',
      displayName: 'Black player',
      color: engine.Player.black,
    ),
    OnlinePlayer(
      id: 'white',
      username: 'white',
      displayName: 'White player',
      color: engine.Player.white,
    ),
  ];
  final state = const engine.GameEngine().initialState();
  return OnlineMatch(
    id: 'match-1',
    status: 'active',
    revision: 0,
    board: state.board,
    players: players,
    blackPopulation: state.board.population(engine.CellState.black),
    whitePopulation: state.board.population(engine.CellState.white),
    yourColor: engine.Player.black,
    nextPlayer: engine.Player.black,
  );
}

class _MatchRepository implements OnlineRepository {
  _MatchRepository(this.match);

  final OnlineMatch match;

  @override
  Future<OnlineMatch?> getMatch(String id, {String? etag}) async => match;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
