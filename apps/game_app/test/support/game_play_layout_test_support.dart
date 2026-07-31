import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

enum ExpectedGameLayout { compact, wide }

class GameLayoutViewport {
  const GameLayoutViewport(this.name, this.size, this.layout, this.boardSide);

  final String name;
  final Size size;
  final ExpectedGameLayout layout;
  final double boardSide;
}

const gameLayoutViewports = [
  GameLayoutViewport(
    'small phone portrait',
    Size(320, 568),
    ExpectedGameLayout.compact,
    296,
  ),
  GameLayoutViewport(
    'phone portrait',
    Size(390, 844),
    ExpectedGameLayout.compact,
    366,
  ),
  GameLayoutViewport(
    'tablet portrait',
    Size(820, 1180),
    ExpectedGameLayout.compact,
    796,
  ),
  GameLayoutViewport(
    'constrained landscape',
    Size(900, 700),
    ExpectedGameLayout.compact,
    608,
  ),
  GameLayoutViewport(
    'tablet landscape',
    Size(1180, 820),
    ExpectedGameLayout.wide,
    716,
  ),
  GameLayoutViewport('desktop', Size(1440, 1000), ExpectedGameLayout.wide, 760),
];

void configureGameViewport(WidgetTester tester, GameLayoutViewport viewport) {
  tester.view.physicalSize = viewport.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void expectGameLayoutGeometry(
  WidgetTester tester,
  GameLayoutViewport viewport, {
  required Key boardKey,
}) {
  final boardFrame = find.byKey(const Key('game-board-frame'));
  final panelFrame = find.byKey(const Key('game-panel-frame'));
  final board = find.byKey(boardKey);
  expect(boardFrame, findsOneWidget);
  expect(panelFrame, findsOneWidget);
  expect(board, findsOneWidget);

  final boardRect = tester.getRect(boardFrame);
  final renderedBoardRect = tester.getRect(board);
  final panelRect = tester.getRect(panelFrame);
  expect(boardRect.width, closeTo(viewport.boardSide, .01));
  expect(boardRect.height, closeTo(viewport.boardSide, .01));
  expect(renderedBoardRect.size, boardRect.size);

  switch (viewport.layout) {
    case ExpectedGameLayout.compact:
      expect(
        find.byKey(const Key('game-layout-compact-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('game-layout-wide-row')), findsNothing);
      expect(panelRect.top, closeTo(boardRect.bottom + 16, .01));
      expect(panelRect.width, closeTo(viewport.boardSide.clamp(0, 760), .01));
      expect(boardRect.center.dx, closeTo(viewport.size.width / 2, .01));
      expect(panelRect.center.dx, closeTo(viewport.size.width / 2, .01));
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('game-layout-compact-scroll')),
      );
      expect(scrollView.scrollDirection, Axis.vertical);
    case ExpectedGameLayout.wide:
      expect(find.byKey(const Key('game-layout-wide-row')), findsOneWidget);
      expect(find.byKey(const Key('game-layout-compact-scroll')), findsNothing);
      expect(panelRect.left, closeTo(boardRect.right + 24, .01));
      expect(panelRect.width, closeTo(360, .01));
      expect(panelRect.center.dy, closeTo(boardRect.center.dy, .01));
  }
}
