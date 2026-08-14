import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:game_of_life/core/theme.dart';
import 'package:game_of_life/features/game/presentation/life_board.dart';

void main() {
  engine.Board testBoard() => engine.Board.empty(rows: 2, columns: 3)
      .withCell(const engine.Coordinate(0, 1), engine.CellState.black)
      .withCell(const engine.Coordinate(1, 2), engine.CellState.white);

  Future<void> pumpBoard(
    WidgetTester tester, {
    required void Function(int row, int column) onCellTap,
    VoidCallback? onMoveConfirm,
    bool enabled = true,
    engine.Board? board,
    engine.Board? previewBoard,
    engine.Coordinate? tentativeMove,
    engine.Coordinate? lastMove,
    List<engine.CellDeath> previewDeaths = const [],
    bool visualizePreviewDeaths = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 300,
              child: LifeBoard(
                board: board ?? testBoard(),
                previewBoard: previewBoard,
                tentativeMove: tentativeMove,
                lastMove: lastMove,
                previewDeaths: previewDeaths,
                visualizePreviewDeaths: visualizePreviewDeaths,
                semanticLabel: 'Test game board',
                enabled: enabled,
                onCellTap: onCellTap,
                onMoveConfirm: onMoveConfirm,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void expectNoLastMoveMarker(LifeBoardPainter painter) {
    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(300));
    }

    expect(
      paintBoard,
      paints..everything((method, arguments) {
        if (method != #drawLine || arguments[2] is! Paint) return true;
        final paint = arguments[2] as Paint;
        return paint.color.toARGB32() != LifeColors.sprout.toARGB32();
      }),
    );
  }

  testWidgets('exposes every coordinate and cell state to semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBoard(tester, onCellTap: (_, _) {});

    expect(find.bySemanticsLabel('Test game board'), findsOneWidget);
    expect(find.bySemanticsLabel('Row 1, column 1'), findsOneWidget);
    expect(find.bySemanticsLabel('Row 1, column 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Row 2, column 3'), findsOneWidget);

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('life-cell-0-0')))
          .getSemanticsData()
          .value,
      'Empty',
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('life-cell-0-1')))
          .getSemanticsData()
          .value,
      'Black cell',
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('life-cell-1-2')))
          .getSemanticsData()
          .value,
      'White cell',
    );
    semantics.dispose();
  });

  testWidgets(
    'a first tap previews, another cell reselects, and a repeated tap confirms',
    (tester) async {
      engine.Coordinate? tentativeMove;
      final previews = <engine.Coordinate>[];
      var confirmations = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.square(
                dimension: 300,
                child: StatefulBuilder(
                  builder: (context, setState) => LifeBoard(
                    board: testBoard(),
                    tentativeMove: tentativeMove,
                    onCellTap: (row, column) {
                      final coordinate = engine.Coordinate(row, column);
                      previews.add(coordinate);
                      setState(() => tentativeMove = coordinate);
                    },
                    onMoveConfirm: () => confirmations += 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('life-cell-1-0')));
      await tester.pump();
      expect(previews, [const engine.Coordinate(1, 0)]);
      expect(confirmations, 0);

      await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
      await tester.pump();
      expect(previews, [
        const engine.Coordinate(1, 0),
        const engine.Coordinate(0, 0),
      ]);
      expect(confirmations, 0);

      await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
      await tester.pump();
      expect(previews, hasLength(2));
      expect(confirmations, 1);
    },
  );

  testWidgets('Enter confirms the currently previewed keyboard coordinate', (
    tester,
  ) async {
    engine.Coordinate? tentativeMove;
    var confirmations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 300,
              child: StatefulBuilder(
                builder: (context, setState) => LifeBoard(
                  board: testBoard(),
                  tentativeMove: tentativeMove,
                  onCellTap: (row, column) => setState(
                    () => tentativeMove = engine.Coordinate(row, column),
                  ),
                  onMoveConfirm: () => confirmations += 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('life-cell-1-0')));
    await tester.pump();
    expect(tentativeMove, const engine.Coordinate(1, 0));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(confirmations, 1);
  });

  testWidgets('selection breathing settles after a bounded cue', (
    tester,
  ) async {
    await pumpBoard(
      tester,
      tentativeMove: const engine.Coordinate(1, 0),
      onCellTap: (_, _) {},
      onMoveConfirm: () {},
    );

    final pumps = await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(pumps, greaterThan(1));
  });

  test('last-move shutter surrounds rather than covers a White cell', () {
    final painter = LifeBoardPainter(
      board: testBoard(),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: const engine.Coordinate(1, 2),
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(300));
    }

    expect(
      paintBoard,
      paints..something(
        (method, arguments) =>
            method == #drawRRect &&
            arguments[1] is Paint &&
            (arguments[1] as Paint).color.toARGB32() ==
                LifeColors.paper.toARGB32() &&
            (arguments[1] as Paint).style == PaintingStyle.fill,
      ),
    );
    expect(
      paintBoard,
      paints..something(
        (method, arguments) =>
            method == #drawLine &&
            arguments[2] is Paint &&
            (arguments[2] as Paint).color.toARGB32() ==
                LifeColors.sprout.toARGB32(),
      ),
    );
  });

  test('board uses a warm wood surface with brown grid and border', () {
    final painter = LifeBoardPainter(
      board: engine.Board.empty(rows: 2, columns: 3),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: null,
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(300));
    }

    expect(
      paintBoard,
      paints
        ..something(
          (method, arguments) =>
              method == #drawRRect &&
              arguments[1] is Paint &&
              (arguments[1] as Paint).shader != null,
        )
        ..something(
          (method, arguments) =>
              method == #drawLine &&
              arguments[2] is Paint &&
              (arguments[2] as Paint).color.toARGB32() ==
                  LifeColors.boardGrid.withValues(alpha: .76).toARGB32(),
        )
        ..something(
          (method, arguments) =>
              method == #drawRRect &&
              arguments[1] is Paint &&
              (arguments[1] as Paint).style == PaintingStyle.stroke &&
              (arguments[1] as Paint).color.toARGB32() ==
                  LifeColors.boardBorder.toARGB32(),
        ),
    );
  });

  test('birth ring and last-move shutter retain dark contrast', () {
    final coordinate = const engine.Coordinate(1, 2);
    final painter = LifeBoardPainter(
      board: testBoard(),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: coordinate,
      births: {coordinate},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(300));
    }

    expect(
      paintBoard,
      paints
        ..something(
          (method, arguments) =>
              method == #drawRRect &&
              arguments[1] is Paint &&
              (arguments[1] as Paint).style == PaintingStyle.stroke &&
              ((arguments[1] as Paint).strokeWidth - 3.6).abs() < .001 &&
              (arguments[1] as Paint).color.toARGB32() ==
                  LifeColors.boardMarkerDark.toARGB32(),
        )
        ..something(
          (method, arguments) =>
              method == #drawLine &&
              arguments[2] is Paint &&
              ((arguments[2] as Paint).strokeWidth - 4.6).abs() < .001 &&
              (arguments[2] as Paint).color.toARGB32() ==
                  LifeColors.boardMarkerDark.toARGB32(),
        ),
    );
  });

  test('tentative selection paints a breathing green border', () {
    const coordinate = engine.Coordinate(1, 0);
    final painter = LifeBoardPainter(
      board: testBoard(),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: null,
      tentativeMove: coordinate,
      selectionPulse: const AlwaysStoppedAnimation(1),
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(300));
    }

    expect(
      paintBoard,
      paints..something(
        (method, arguments) =>
            method == #drawRRect &&
            arguments[1] is Paint &&
            (arguments[1] as Paint).style == PaintingStyle.stroke &&
            ((arguments[1] as Paint).strokeWidth - 2.5).abs() < .001 &&
            (arguments[1] as Paint).color.toARGB32() ==
                LifeColors.sprout.withValues(alpha: .92).toARGB32(),
      ),
    );
  });

  test('last-move shutter remains when the placed cell died', () {
    final painter = LifeBoardPainter(
      board: engine.Board.empty(rows: 2, columns: 3),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: const engine.Coordinate(0, 0),
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(300));
    }

    expect(
      paintBoard,
      paints..something(
        (method, arguments) =>
            method == #drawLine &&
            arguments[2] is Paint &&
            (arguments[2] as Paint).color.toARGB32() ==
                LifeColors.sprout.toARGB32(),
      ),
    );
  });

  test('stale out-of-bounds last move is ignored', () {
    final painter = LifeBoardPainter(
      board: engine.Board.empty(rows: 2, columns: 3),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: const engine.Coordinate(-1, 8),
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    expectNoLastMoveMarker(painter);
  });

  test('preview renders newly living cells as translucent', () {
    final state = const engine.GameEngine().initialState();
    final turn = const engine.GameEngine().applyMove(
      state,
      const engine.GameMove(
        player: engine.Player.black,
        row: 8,
        column: 9,
        expectedRevision: 0,
      ),
    );
    final painter = LifeBoardPainter(
      board: state.board,
      previewBoard: turn.state.board,
      tentativeMove: const engine.Coordinate(8, 9),
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: null,
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(400));
    }

    expect(
      paintBoard,
      paints
        ..something(
          (method, arguments) =>
              method == #drawRRect &&
              arguments[1] is Paint &&
              (arguments[1] as Paint).style == PaintingStyle.fill &&
              (arguments[1] as Paint).shader == null &&
              (arguments[1] as Paint).color.a > 0 &&
              (arguments[1] as Paint).color.a < 1,
        )
        ..something(
          (method, arguments) =>
              method == #drawRRect &&
              arguments[1] is Paint &&
              (arguments[1] as Paint).style == PaintingStyle.fill &&
              (arguments[1] as Paint).shader == null &&
              (arguments[1] as Paint).color.a == 1,
        ),
    );
  });

  test('preview can render deaths as faded stones with a coral cross', () {
    final state = const engine.GameEngine().initialState();
    final turn = const engine.GameEngine().applyMove(
      state,
      const engine.GameMove(
        player: engine.Player.black,
        row: 0,
        column: 0,
        expectedRevision: 0,
      ),
    );
    expect(turn.state.board, state.board);
    final painter = LifeBoardPainter(
      board: state.board,
      previewBoard: turn.state.board,
      tentativeMove: const engine.Coordinate(0, 0),
      previewDeaths: turn.delta.evolution.deaths,
      visualizePreviewDeaths: true,
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: null,
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(400));
    }

    expect(
      paintBoard,
      paints
        ..something(
          (method, arguments) =>
              method == #drawRRect &&
              arguments[1] is Paint &&
              (arguments[1] as Paint).style == PaintingStyle.fill &&
              (arguments[1] as Paint).color.a > 0 &&
              (arguments[1] as Paint).color.a < 1,
        )
        ..something(
          (method, arguments) =>
              method == #drawLine &&
              arguments[2] is Paint &&
              (arguments[2] as Paint).color.toARGB32() ==
                  LifeColors.coral.toARGB32(),
        ),
    );
  });

  test('preview omits death ghosts when visualization is disabled', () {
    final state = const engine.GameEngine().initialState();
    final turn = const engine.GameEngine().applyMove(
      state,
      const engine.GameMove(
        player: engine.Player.black,
        row: 0,
        column: 0,
        expectedRevision: 0,
      ),
    );
    final painter = LifeBoardPainter(
      board: state.board,
      previewBoard: turn.state.board,
      tentativeMove: const engine.Coordinate(0, 0),
      previewDeaths: turn.delta.evolution.deaths,
      visualizePreviewDeaths: false,
      colorScheme: ColorScheme.fromSeed(seedColor: LifeColors.sprout),
      lastMove: null,
      births: const {},
      hovered: null,
      showHover: false,
      focused: null,
      showFocus: false,
    );

    void paintBoard(Canvas canvas) {
      painter.paint(canvas, const Size.square(400));
    }

    expect(
      paintBoard,
      paints..everything((method, arguments) {
        if (method == #drawLine && arguments[2] is Paint) {
          return (arguments[2] as Paint).color.toARGB32() !=
              LifeColors.coral.toARGB32();
        }
        if (method == #drawRRect && arguments[1] is Paint) {
          return (arguments[1] as Paint).color.toARGB32() !=
              LifeColors.coral.toARGB32();
        }
        return true;
      }),
    );
  });

  testWidgets('semantics distinguishes hypothetical cells', (tester) async {
    final semantics = tester.ensureSemantics();
    final board = engine.Board.empty(rows: 2, columns: 3);
    final preview = board.withCell(
      const engine.Coordinate(0, 0),
      engine.CellState.black,
    );
    await pumpBoard(
      tester,
      board: board,
      previewBoard: preview,
      tentativeMove: const engine.Coordinate(0, 0),
      onCellTap: (_, _) {},
    );

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('life-cell-0-0')))
          .getSemanticsData()
          .value,
      'Hypothetical black cell',
    );
    final tentativeSemantics = tester
        .getSemantics(find.byKey(const ValueKey('life-cell-0-0')))
        .getSemanticsData();
    expect(tentativeSemantics.hint, 'Tap again to confirm this move.');
    expect(tentativeSemantics.flagsCollection.isSelected, ui.Tristate.isTrue);
    semantics.dispose();
  });

  testWidgets('semantics announces a tentative placement that will die', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final state = const engine.GameEngine().initialState();
    final turn = const engine.GameEngine().applyMove(
      state,
      const engine.GameMove(
        player: engine.Player.black,
        row: 0,
        column: 0,
        expectedRevision: 0,
      ),
    );
    await pumpBoard(
      tester,
      board: state.board,
      previewBoard: turn.state.board,
      tentativeMove: const engine.Coordinate(0, 0),
      previewDeaths: turn.delta.evolution.deaths,
      onCellTap: (_, _) {},
    );

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('life-cell-0-0')))
          .getSemanticsData()
          .value,
      'Tentative black placement will die next round',
    );
    semantics.dispose();
  });

  testWidgets('arrow keys select coordinates and Enter or Space activates', (
    tester,
  ) async {
    final activations = <engine.Coordinate>[];
    await pumpBoard(
      tester,
      onCellTap: (row, column) {
        activations.add(engine.Coordinate(row, column));
      },
    );

    await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
    await tester.pump();
    activations.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activations, [const engine.Coordinate(1, 1)]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(activations.last, const engine.Coordinate(1, 2));

    final customPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(LifeBoard),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = customPaint.painter! as LifeBoardPainter;
    expect(painter.focused, const engine.Coordinate(1, 2));
    expect(painter.showFocus, isTrue);
  });

  testWidgets('disabled board hides retained keyboard focus', (tester) async {
    await pumpBoard(tester, onCellTap: (_, _) {});
    await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
    await tester.pump();

    final focusFinder = find.descendant(
      of: find.byType(LifeBoard),
      matching: find.byType(Focus),
    );
    expect(focusFinder, findsOneWidget);

    LifeBoardPainter painter() {
      final customPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(LifeBoard),
          matching: find.byType(CustomPaint),
        ),
      );
      return customPaint.painter! as LifeBoardPainter;
    }

    expect(painter().showFocus, isTrue);
    expect(tester.widget<Focus>(focusFinder).focusNode!.hasFocus, isTrue);

    await pumpBoard(tester, enabled: false, onCellTap: (_, _) {});
    await tester.pump();

    expect(painter().showFocus, isFalse);
    expect(tester.widget<Focus>(focusFinder).focusNode!.hasFocus, isFalse);
  });

  testWidgets('keyboard navigation stops at board edges', (tester) async {
    final activations = <engine.Coordinate>[];
    await pumpBoard(
      tester,
      onCellTap: (row, column) {
        activations.add(engine.Coordinate(row, column));
      },
    );

    await tester.tap(find.byKey(const ValueKey('life-cell-0-0')));
    activations.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(activations, [const engine.Coordinate(0, 0)]);
  });
}
