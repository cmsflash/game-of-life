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
    bool enabled = true,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 300,
              child: LifeBoard(
                board: testBoard(),
                semanticLabel: 'Test game board',
                enabled: enabled,
                onCellTap: onCellTap,
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
        if (method != #drawRRect || arguments[1] is! Paint) return true;
        final paint = arguments[1] as Paint;
        return paint.style != PaintingStyle.stroke ||
            paint.color.toARGB32() != LifeColors.coral.toARGB32();
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

  test('last-move marker outlines rather than covers a White cell', () {
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
            method == #drawRRect &&
            arguments[1] is Paint &&
            (arguments[1] as Paint).color.toARGB32() ==
                LifeColors.coral.toARGB32() &&
            (arguments[1] as Paint).style == PaintingStyle.stroke,
      ),
    );
  });

  test('last-move marker is omitted when the placed cell died', () {
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

    expectNoLastMoveMarker(painter);
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
