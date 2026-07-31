import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Responsive shell shared by local and online game screens.
///
/// Portrait and compact windows keep the board at a useful touch size by
/// deriving its square from the viewport width and scrolling the whole page.
/// Landscape windows switch to a side-by-side layout only when the board and
/// panel both fit without shrinking the board below [_minimumWideBoardSide].
class GamePlayLayout extends StatelessWidget {
  const GamePlayLayout({super.key, required this.board, required this.panel});

  final Widget board;
  final Widget panel;

  static bool isCompact(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_GamePlayLayoutMode>()
          ?.isCompact ??
      false;

  static const _compactPadding = EdgeInsets.fromLTRB(12, 12, 12, 24);
  static const _widePadding = EdgeInsets.all(24);
  static const _gap = 16.0;
  static const _wideGap = 24.0;
  static const _panelWidth = 360.0;
  static const _maximumCompactBoardSide = 1120.0;
  static const _maximumWideBoardSide = 760.0;
  static const _maximumCompactPanelWidth = 760.0;
  static const _minimumWideBoardSide = 560.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wideBoardSide = math.min(
        _maximumWideBoardSide,
        math.min(
          constraints.maxWidth -
              _widePadding.horizontal -
              _wideGap -
              _panelWidth,
          constraints.maxHeight - _widePadding.vertical,
        ),
      );
      final isLandscape = constraints.maxWidth > constraints.maxHeight;
      final useWideLayout =
          isLandscape && wideBoardSide >= _minimumWideBoardSide;

      if (useWideLayout) {
        return Padding(
          padding: _widePadding,
          child: Center(
            child: Row(
              key: const Key('game-layout-wide-row'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox.square(
                  key: const Key('game-board-frame'),
                  dimension: wideBoardSide,
                  child: board,
                ),
                const SizedBox(width: _wideGap),
                SizedBox(
                  key: const Key('game-panel-frame'),
                  width: _panelWidth,
                  child: SingleChildScrollView(
                    child: _GamePlayLayoutMode(isCompact: false, child: panel),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final boardSide = math.max(
        0.0,
        math.min(
          _maximumCompactBoardSide,
          math.min(
            constraints.maxWidth - _compactPadding.horizontal,
            constraints.maxHeight - _compactPadding.vertical,
          ),
        ),
      );
      final panelWidth = math.min(boardSide, _maximumCompactPanelWidth);
      return SingleChildScrollView(
        key: const Key('game-layout-compact-scroll'),
        padding: _compactPadding,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                key: const Key('game-board-frame'),
                dimension: boardSide,
                child: board,
              ),
              const SizedBox(height: _gap),
              SizedBox(
                key: const Key('game-panel-frame'),
                width: panelWidth,
                child: _GamePlayLayoutMode(isCompact: true, child: panel),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _GamePlayLayoutMode extends InheritedWidget {
  const _GamePlayLayoutMode({required this.isCompact, required super.child});

  final bool isCompact;

  @override
  bool updateShouldNotify(_GamePlayLayoutMode oldWidget) =>
      isCompact != oldWidget.isCompact;
}
