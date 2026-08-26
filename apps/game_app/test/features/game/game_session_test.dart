import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/features/game/data/local_game_store.dart';
import 'package:game_of_life/features/game/domain/game_session.dart';
import 'package:game_of_life/features/game/presentation/local_games_controller.dart';

void main() {
  group('LocalGamesController', () {
    test('creates multiple stable, resumable games', () async {
      final store = MemoryLocalGameStore();
      final ids = ['local-1', 'local-2'].iterator;
      var now = DateTime.utc(2026, 8, 14, 1);
      final controller = LocalGamesController(
        store,
        idFactory: () {
          ids.moveNext();
          return ids.current;
        },
        clock: () => now,
      );
      await controller.load();

      final first = await controller.create(
        const LocalGameConfig(blackName: 'Ari', whiteName: 'Bo'),
        title: 'Kitchen table',
      );
      now = now.add(const Duration(minutes: 1));
      final second = await controller.create(
        const LocalGameConfig(
          mode: LocalGameMode.turnLimit,
          turnLimit: 20,
          blackName: 'Cy',
          whiteName: 'Dee',
        ),
      );

      expect(first.id, 'local-1');
      expect(first.title, 'Kitchen table');
      expect(first.opponentLabel, 'Bo');
      expect(second.id, 'local-2');
      expect(second.title, 'Cy vs Dee');
      expect(controller.state.games.map((game) => game.id), [
        'local-2',
        'local-1',
      ]);
      expect(controller.state.selectedGame?.id, 'local-2');
      expect(store.games, hasLength(2));

      final restored = LocalGamesController(store);
      await restored.load();
      expect(restored.state.status, LocalGamesLoadStatus.ready);
      expect(restored.state.gameById('local-1')?.title, 'Kitchen table');
      expect(restored.state.gameById('local-2')?.config.turnLimit, 20);
    });

    test('starts from the centered stable position with Black first', () async {
      final fixture = await _Fixture.create();

      final game = fixture.game.game;
      expect(game.blackPopulation, 2);
      expect(game.whitePopulation, 2);
      expect(game.toMove, engine.Player.black);
      expect(game.board.at(9, 9), engine.CellState.black);
      expect(game.board.at(9, 10), engine.CellState.white);
    });

    test('AI vs AI advances exactly one turn per explicit step', () async {
      final fixture = await _Fixture.create(
        config: const LocalGameConfig(
          blackName: 'Black AI',
          whiteName: 'White AI',
          blackParticipant: LocalParticipantType.aiLevel1,
          whiteParticipant: LocalParticipantType.aiLevel2,
        ),
      );

      expect(fixture.current.game.ply, 0);
      expect(fixture.controller.consider(fixture.id, 0, 0), isFalse);
      expect(fixture.current.game.ply, 0);

      expect(await fixture.controller.advanceAi(fixture.id), isTrue);
      expect(fixture.current.game.ply, 1);
      expect(fixture.current.game.toMove, engine.Player.white);

      expect(await fixture.controller.advanceAi(fixture.id), isTrue);
      expect(fixture.current.game.ply, 2);
      expect(fixture.current.game.toMove, engine.Player.black);
    });

    test('player vs AI automatically answers a committed human move', () async {
      final fixture = await _Fixture.create(
        config: const LocalGameConfig(
          blackName: 'You',
          whiteName: 'AI level 1',
          whiteParticipant: LocalParticipantType.aiLevel1,
        ),
      );

      expect(fixture.current.game.ply, 0);
      expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);
      expect(await fixture.controller.commit(fixture.id), isTrue);

      expect(fixture.current.game.ply, 2);
      expect(fixture.current.game.toMove, engine.Player.black);
      expect(fixture.current.preview, isNull);
      expect(fixture.current.lastMove, isNotNull);
      expect(fixture.store.games.single.game.ply, 2);
    });

    test('a Black AI opens once when the human chooses White', () async {
      final fixture = await _Fixture.create(
        config: const LocalGameConfig(
          blackName: 'AI level 2',
          whiteName: 'You',
          blackParticipant: LocalParticipantType.aiLevel2,
        ),
      );

      expect(fixture.current.game.ply, 1);
      expect(fixture.current.game.toMove, engine.Player.white);

      expect(await fixture.controller.restart(fixture.id), isTrue);
      expect(fixture.current.game.ply, 1);
      expect(fixture.current.game.toMove, engine.Player.white);
    });

    test(
      'previews without persisting or advancing authoritative state',
      () async {
        final fixture = await _Fixture.create();
        final before = fixture.game.game;
        final writesBefore = fixture.store.writeCount;

        expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);

        final session = fixture.current;
        expect(session.game, same(before));
        expect(session.game.revision, 0);
        expect(session.lastMove, isNull);
        expect(session.preview?.coordinate, const engine.Coordinate(0, 0));
        expect(session.preview?.turn.state.revision, 1);
        expect(session.preview?.turn.state.toMove, engine.Player.white);
        expect(
          session.preview?.deaths,
          contains(const engine.Coordinate(0, 0)),
        );
        expect(fixture.store.writeCount, writesBefore);
      },
    );

    test('changing selection recomputes from authoritative board', () async {
      final fixture = await _Fixture.create();
      final initial = fixture.game.game;

      expect(fixture.controller.consider(fixture.id, 8, 9), isTrue);
      final firstBoard = fixture.current.preview!.board;
      expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);

      final expected = const engine.GameEngine().applyMove(
        initial,
        const engine.GameMove(
          player: engine.Player.black,
          row: 0,
          column: 0,
          expectedRevision: 0,
        ),
      );
      expect(fixture.current.game, same(initial));
      expect(
        fixture.current.preview!.coordinate,
        const engine.Coordinate(0, 0),
      );
      expect(fixture.current.preview!.board, expected.state.board);
      expect(fixture.current.preview!.board, isNot(firstBoard));
    });

    test(
      'commit persists only the addressed game and its latest preview',
      () async {
        final fixture = await _Fixture.create();
        final other = await fixture.controller.create(
          const LocalGameConfig(blackName: 'Other black'),
          title: 'Other game',
        );
        final otherState = other.game;
        fixture.clock = fixture.clock.add(const Duration(minutes: 2));
        expect(fixture.controller.consider(fixture.id, 8, 9), isTrue);
        expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);
        final expected = fixture.current.preview!;

        expect(await fixture.controller.commit(fixture.id), isTrue);

        final session = fixture.current;
        expect(session.game, same(expected.turn.state));
        expect(session.game.revision, 1);
        expect(session.lastMove, const engine.Coordinate(0, 0));
        expect(session.lastBirths, expected.births);
        expect(session.lastDeaths, expected.deaths);
        expect(session.preview, isNull);
        expect(
          fixture.controller.state.gameById(other.id)?.game,
          same(otherState),
        );
        expect(await fixture.controller.commit(fixture.id), isFalse);

        final restored = LocalGamesController(fixture.store);
        await restored.load();
        final reopened = restored.state.gameById(fixture.id)!;
        expect(reopened.game.stateHash, session.game.stateHash);
        expect(reopened.lastMove, session.lastMove);
        expect(reopened.preview, isNull);
        expect(reopened.updatedAt, fixture.clock);
      },
    );

    test('a White-majority birth persists as White', () async {
      final fixture = await _Fixture.create();
      expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);
      expect(await fixture.controller.commit(fixture.id), isTrue);

      expect(fixture.controller.consider(fixture.id, 8, 9), isTrue);
      expect(await fixture.controller.commit(fixture.id), isTrue);

      final session = fixture.current;
      expect(session.game.revision, 2);
      expect(session.game.toMove, engine.Player.black);
      expect(session.lastMove, const engine.Coordinate(8, 9));
      expect(session.game.board.at(8, 9), engine.CellState.white);
      expect(session.lastBirths, contains(const engine.Coordinate(8, 10)));
      expect(session.game.board.at(8, 10), engine.CellState.white);
    });

    test(
      'rejects an occupied cell without replacing a valid preview',
      () async {
        final fixture = await _Fixture.create();
        expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);

        expect(fixture.controller.consider(fixture.id, 9, 9), isFalse);
        expect(fixture.current.game.revision, 0);
        expect(fixture.current.error, isNotEmpty);
        expect(
          fixture.current.preview?.coordinate,
          const engine.Coordinate(0, 0),
        );
      },
    );

    test('cancel and restart affect only the requested saved game', () async {
      final fixture = await _Fixture.create();
      expect(fixture.controller.consider(fixture.id, 0, 0), isTrue);
      await fixture.controller.commit(fixture.id);
      expect(fixture.controller.consider(fixture.id, 8, 9), isTrue);

      fixture.controller.cancelPreview(fixture.id);
      expect(fixture.current.game.revision, 1);
      expect(fixture.current.preview, isNull);
      expect(fixture.current.lastMove, const engine.Coordinate(0, 0));

      await fixture.controller.restart(fixture.id);
      expect(fixture.current.game.revision, 0);
      expect(fixture.current.lastMove, isNull);
      expect(fixture.current.lastBirths, isEmpty);
      expect(fixture.current.lastDeaths, isEmpty);
    });

    test('summaries expose list-ready turn and result metadata', () async {
      final fixture = await _Fixture.create(
        config: const LocalGameConfig(blackName: 'Ada', whiteName: 'Grace'),
      );

      final summary = fixture.controller.state.summaries.single;
      expect(summary.id, fixture.id);
      expect(summary.blackName, 'Ada');
      expect(summary.whiteName, 'Grace');
      expect(summary.modeLabel, 'Elimination');
      expect(summary.isActive, isTrue);
      expect(summary.toMove, engine.Player.black);
      expect(summary.toMoveLabel, 'Ada');
      expect(summary.ply, 0);
      expect(summary.winner, isNull);
      expect(summary.winnerLabel, isNull);
      expect(summary.isDraw, isFalse);
      expect(summary.blackPopulation, 2);
      expect(summary.whitePopulation, 2);
    });

    test('delete removes only one saved game', () async {
      final fixture = await _Fixture.create();
      await fixture.controller.create(const LocalGameConfig(), title: 'Second');

      expect(await fixture.controller.delete(fixture.id), isTrue);
      expect(fixture.controller.state.gameById(fixture.id), isNull);
      expect(fixture.controller.state.games, hasLength(1));
      expect(fixture.store.games, hasLength(1));
      expect(await fixture.controller.delete('missing'), isFalse);
    });

    test(
      'commit captures and locks its preview before waiting behind another write',
      () async {
        final setup = await _twoGameBlockingSetup();
        expect(setup.controller.consider(setup.secondId, 0, 0), isTrue);
        setup.store.blockNextWrite();
        final blockedCommit = setup.controller.commit(setup.secondId);
        await setup.store.writeStarted;

        expect(setup.controller.consider(setup.firstId, 0, 0), isTrue);
        final queuedCommit = setup.controller.commit(setup.firstId);

        expect(setup.controller.consider(setup.firstId, 8, 9), isFalse);
        expect(
          setup.controller.state.gameById(setup.firstId)?.preview?.coordinate,
          const engine.Coordinate(0, 0),
        );
        expect(await setup.controller.commit(setup.firstId), isFalse);
        expect(await setup.controller.restart(setup.firstId), isFalse);
        expect(await setup.controller.delete(setup.firstId), isFalse);

        setup.store.releaseBlockedWrite();
        expect(await blockedCommit, isTrue);
        expect(await queuedCommit, isTrue);
        final committed = setup.controller.state.gameById(setup.firstId)!;
        expect(committed.lastMove, const engine.Coordinate(0, 0));
        expect(committed.game.revision, 1);
        expect(
          setup.store.games
              .singleWhere((game) => game.id == setup.firstId)
              .lastMove,
          const engine.Coordinate(0, 0),
        );
      },
    );

    test(
      'restart locks its captured game before entering the write queue',
      () async {
        final setup = await _twoGameBlockingSetup();
        setup.controller.consider(setup.firstId, 0, 0);
        await setup.controller.commit(setup.firstId);
        expect(
          setup.controller.state.gameById(setup.firstId)?.game.revision,
          1,
        );

        setup.controller.consider(setup.secondId, 0, 0);
        setup.store.blockNextWrite();
        final blockedCommit = setup.controller.commit(setup.secondId);
        await setup.store.writeStarted;

        final queuedRestart = setup.controller.restart(setup.firstId);
        expect(setup.controller.consider(setup.firstId, 8, 9), isFalse);
        expect(await setup.controller.restart(setup.firstId), isFalse);
        expect(await setup.controller.delete(setup.firstId), isFalse);

        setup.store.releaseBlockedWrite();
        expect(await blockedCommit, isTrue);
        expect(await queuedRestart, isTrue);
        final restarted = setup.controller.state.gameById(setup.firstId)!;
        expect(restarted.game.revision, 0);
        expect(restarted.lastMove, isNull);
        expect(
          setup.store.games
              .singleWhere((game) => game.id == setup.firstId)
              .game
              .revision,
          0,
        );
      },
    );

    test('delete locks its target before entering the write queue', () async {
      final setup = await _twoGameBlockingSetup();
      setup.controller.consider(setup.secondId, 0, 0);
      setup.store.blockNextWrite();
      final blockedCommit = setup.controller.commit(setup.secondId);
      await setup.store.writeStarted;

      final queuedDelete = setup.controller.delete(setup.firstId);
      expect(setup.controller.consider(setup.firstId, 0, 0), isFalse);
      expect(await setup.controller.delete(setup.firstId), isFalse);
      expect(await setup.controller.restart(setup.firstId), isFalse);

      setup.store.releaseBlockedWrite();
      expect(await blockedCommit, isTrue);
      expect(await queuedDelete, isTrue);
      expect(setup.controller.state.gameById(setup.firstId), isNull);
      expect(
        setup.store.games.where((game) => game.id == setup.firstId),
        isEmpty,
      );
    });

    test('failed create leaves no in-memory game or retry duplicate', () async {
      final store = MemoryLocalGameStore()..writeError = StateError('disk');
      var sequence = 0;
      final controller = LocalGamesController(
        store,
        idFactory: () => 'local-${sequence++}',
        clock: () => DateTime.utc(2026, 8, 14),
      );
      await controller.load();

      await expectLater(
        controller.create(const LocalGameConfig()),
        throwsA(isA<StateError>()),
      );
      expect(controller.state.games, isEmpty);
      expect(store.games, isEmpty);

      store.writeError = null;
      await controller.create(const LocalGameConfig());
      expect(controller.state.games, hasLength(1));
      expect(store.games, hasLength(1));
    });

    test('failed read cannot be overwritten by creating a new game', () async {
      final existing = LocalGameSession(
        id: 'existing',
        title: 'Existing game',
        opponentLabel: 'White',
        createdAt: DateTime.utc(2026, 8, 13),
        updatedAt: DateTime.utc(2026, 8, 13),
        config: const LocalGameConfig(),
        game: const engine.GameEngine().initialState(),
      );
      final store = MemoryLocalGameStore(games: [existing])
        ..readError = StateError('temporarily unavailable');
      final controller = LocalGamesController(
        store,
        idFactory: () => 'new',
        clock: () => DateTime.utc(2026, 8, 14),
      );
      await controller.load();
      expect(controller.state.status, LocalGamesLoadStatus.failed);

      store.readError = null;
      await expectLater(
        controller.create(const LocalGameConfig()),
        throwsA(isA<StateError>()),
      );
      expect(store.games.single.id, 'existing');
      expect(store.writeCount, 0);

      await controller.retryLoad();
      expect(controller.state.gameById('existing'), isNotNull);
      await controller.create(const LocalGameConfig());
      expect(
        store.games.map((game) => game.id),
        containsAll(['existing', 'new']),
      );
    });

    test(
      'failed commit preserves the authoritative state and preview',
      () async {
        final fixture = await _Fixture.create();
        fixture.controller.consider(fixture.id, 0, 0);
        final preview = fixture.current.preview;
        fixture.store.writeError = StateError('disk');

        await expectLater(
          fixture.controller.commit(fixture.id),
          throwsA(isA<StateError>()),
        );

        expect(fixture.current.game.revision, 0);
        expect(fixture.current.lastMove, isNull);
        expect(fixture.current.preview, same(preview));
        expect(fixture.store.games.single.game.revision, 0);

        fixture.store.writeError = null;
        expect(await fixture.controller.commit(fixture.id), isTrue);
        expect(fixture.current.game.revision, 1);
        expect(fixture.store.games.single.game.revision, 1);
      },
    );

    test('failed restart keeps the committed position and markers', () async {
      final fixture = await _Fixture.create();
      fixture.controller.consider(fixture.id, 0, 0);
      await fixture.controller.commit(fixture.id);
      final before = fixture.current;
      fixture.store.writeError = StateError('disk');

      await expectLater(
        fixture.controller.restart(fixture.id),
        throwsA(isA<StateError>()),
      );

      expect(fixture.current.game, same(before.game));
      expect(fixture.current.lastMove, before.lastMove);
      expect(fixture.store.games.single.game.revision, 1);
    });

    test('failed delete keeps the game in memory and storage', () async {
      final fixture = await _Fixture.create();
      fixture.store.writeError = StateError('disk');

      await expectLater(
        fixture.controller.delete(fixture.id),
        throwsA(isA<StateError>()),
      );

      expect(fixture.controller.state.gameById(fixture.id), isNotNull);
      expect(fixture.store.games.single.id, fixture.id);
    });
  });

  group('LocalGameSession serialization', () {
    test('round trips verified game state and committed markers', () async {
      final fixture = await _Fixture.create();
      fixture.controller.consider(fixture.id, 0, 0);
      await fixture.controller.commit(fixture.id);

      final restored = LocalGameSession.fromJson(fixture.current.toJson());
      expect(restored.id, fixture.id);
      expect(restored.game.stateHash, fixture.current.game.stateHash);
      expect(restored.config.mode, fixture.current.config.mode);
      expect(restored.lastMove, fixture.current.lastMove);
      expect(restored.lastBirths, fixture.current.lastBirths);
      expect(restored.lastDeaths, fixture.current.lastDeaths);
      expect(restored.preview, isNull);
    });

    test('round trips independent AI levels', () {
      const config = LocalGameConfig(
        blackName: 'Alpha',
        whiteName: 'Beta',
        blackParticipant: LocalParticipantType.aiLevel1,
        whiteParticipant: LocalParticipantType.aiLevel2,
      );

      final restored = LocalGameConfig.fromJson(config.toJson());

      expect(restored.blackParticipant, LocalParticipantType.aiLevel1);
      expect(restored.whiteParticipant, LocalParticipantType.aiLevel2);
    });

    test('old saved configs default both participants to human', () {
      final legacy = const LocalGameConfig().toJson()
        ..remove('blackParticipant')
        ..remove('whiteParticipant');

      final restored = LocalGameConfig.fromJson(legacy);

      expect(restored.isHumanVsHuman, isTrue);
    });

    test('legacy AI and mixture settings migrate to AI level 1', () {
      final legacy = const LocalGameConfig().toJson()
        ..['blackParticipant'] = 'ai'
        ..['whiteParticipant'] = 'ai'
        ..['aiStrategyPercentages'] = const {
          'maxSelfCells': 20,
          'minOpponentCells': 30,
          'maxCellAdvantage': 50,
        };

      final restored = LocalGameConfig.fromJson(legacy);

      expect(restored.blackParticipant, LocalParticipantType.aiLevel1);
      expect(restored.whiteParticipant, LocalParticipantType.aiLevel1);
      expect(restored.toJson(), isNot(contains('aiStrategyPercentages')));
    });

    test('rejects a config that disagrees with persisted engine rules', () {
      final now = DateTime.utc(2026, 8, 14);
      final session = LocalGameSession(
        id: 'game-1',
        title: 'Mismatch',
        opponentLabel: 'White',
        createdAt: now,
        updatedAt: now,
        config: const LocalGameConfig(),
        game: const engine.GameEngine().initialState(),
      ).toJson();
      session['config'] = const LocalGameConfig(
        mode: LocalGameMode.turnLimit,
        turnLimit: 20,
      ).toJson();

      expect(() => LocalGameSession.fromJson(session), throwsFormatException);
    });
  });
}

class _Fixture {
  _Fixture(this.store, this.id, this.clock) {
    controller = LocalGamesController(
      store,
      idFactory: () {
        final suffix = _idCounter++;
        return suffix == 0 ? id : '$id-$suffix';
      },
      clock: () => clock,
    );
  }

  static Future<_Fixture> create({
    LocalGameConfig config = const LocalGameConfig(),
  }) async {
    final store = MemoryLocalGameStore();
    final fixture = _Fixture(store, 'local-test', DateTime.utc(2026, 8, 14));
    await fixture.controller.load();
    await fixture.controller.create(config);
    return fixture;
  }

  late final LocalGamesController controller;
  final MemoryLocalGameStore store;
  final String id;
  DateTime clock;
  var _idCounter = 0;

  LocalGameSession get game => controller.state.gameById(id)!;
  LocalGameSession get current => game;
}

class _BlockingSetup {
  const _BlockingSetup({
    required this.controller,
    required this.store,
    required this.firstId,
    required this.secondId,
  });

  final LocalGamesController controller;
  final _BlockingLocalGameStore store;
  final String firstId;
  final String secondId;
}

Future<_BlockingSetup> _twoGameBlockingSetup() async {
  final store = _BlockingLocalGameStore();
  final ids = ['first', 'second'].iterator;
  final controller = LocalGamesController(
    store,
    idFactory: () {
      ids.moveNext();
      return ids.current;
    },
    clock: () => DateTime.utc(2026, 8, 14),
  );
  await controller.load();
  final first = await controller.create(const LocalGameConfig());
  final second = await controller.create(const LocalGameConfig());
  return _BlockingSetup(
    controller: controller,
    store: store,
    firstId: first.id,
    secondId: second.id,
  );
}

class _BlockingLocalGameStore extends MemoryLocalGameStore {
  Completer<void>? _writeStarted;
  Completer<void>? _releaseWrite;

  Future<void> get writeStarted => _writeStarted!.future;

  void blockNextWrite() {
    if (_writeStarted != null) {
      throw StateError('A write is already blocked');
    }
    _writeStarted = Completer<void>();
    _releaseWrite = Completer<void>();
  }

  void releaseBlockedWrite() {
    final release = _releaseWrite;
    if (release == null || release.isCompleted) {
      throw StateError('No write is blocked');
    }
    release.complete();
  }

  @override
  Future<void> writeGames(List<LocalGameSession> games) async {
    final started = _writeStarted;
    final release = _releaseWrite;
    if (started != null && !started.isCompleted) {
      started.complete();
      await release!.future;
      _writeStarted = null;
      _releaseWrite = null;
    }
    await super.writeGames(games);
  }
}
