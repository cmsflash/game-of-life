import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:game_engine/game_engine.dart' as engine;

import '../../../core/theme.dart';

class LifeBoard extends StatefulWidget {
  const LifeBoard({
    super.key,
    required this.board,
    this.onCellTap,
    this.enabled = true,
    this.lastMove,
    this.births = const [],
    this.semanticLabel = '20 by 20 game board',
  });

  final engine.Board board;
  final void Function(int row, int column)? onCellTap;
  final bool enabled;
  final engine.Coordinate? lastMove;
  final List<engine.Coordinate> births;
  final String semanticLabel;

  @override
  State<LifeBoard> createState() => _LifeBoardState();
}

class _LifeBoardState extends State<LifeBoard> {
  engine.Coordinate? _hovered;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        final size = Size.square(side.isFinite ? side : constraints.maxWidth);
        return Center(
          child: Semantics(
            label: widget.semanticLabel,
            button: widget.enabled,
            child: MouseRegion(
              cursor: widget.enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onExit: (_) => setState(() => _hovered = null),
              onHover: widget.enabled
                  ? (event) => setState(
                      () => _hovered = _coordinate(event.localPosition, size),
                    )
                  : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: widget.enabled && widget.onCellTap != null
                    ? (details) {
                        final coordinate = _coordinate(
                          details.localPosition,
                          size,
                        );
                        widget.onCellTap!(coordinate.row, coordinate.column);
                      }
                    : null,
                child: SizedBox.fromSize(
                  size: size,
                  child: CustomPaint(
                    painter: LifeBoardPainter(
                      board: widget.board,
                      colorScheme: Theme.of(context).colorScheme,
                      lastMove: widget.lastMove,
                      births: widget.births.toSet(),
                      hovered: _hovered,
                      showHover: widget.enabled,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  engine.Coordinate _coordinate(Offset position, Size size) {
    final cellWidth = size.width / widget.board.columns;
    final cellHeight = size.height / widget.board.rows;
    return engine.Coordinate(
      (position.dy / cellHeight).floor().clamp(0, widget.board.rows - 1),
      (position.dx / cellWidth).floor().clamp(0, widget.board.columns - 1),
    );
  }
}

class LifeBoardPainter extends CustomPainter {
  LifeBoardPainter({
    required this.board,
    required this.colorScheme,
    required this.lastMove,
    required this.births,
    required this.hovered,
    required this.showHover,
  });

  final engine.Board board;
  final ColorScheme colorScheme;
  final engine.Coordinate? lastMove;
  final Set<engine.Coordinate> births;
  final engine.Coordinate? hovered;
  final bool showHover;

  @override
  void paint(Canvas canvas, Size size) {
    final cellWidth = size.width / board.columns;
    final cellHeight = size.height / board.rows;
    final radius = math.min(cellWidth, cellHeight) * .22;
    final boardRect = Offset.zero & size;

    canvas.drawRRect(
      RRect.fromRectAndRadius(boardRect, Radius.circular(radius * 2)),
      Paint()..color = const Color(0xFF1B2028),
    );
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(boardRect, Radius.circular(radius * 2)),
    );

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: .095)
      ..strokeWidth = .7;
    for (var row = 1; row < board.rows; row++) {
      final y = row * cellHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    for (var column = 1; column < board.columns; column++) {
      final x = column * cellWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    for (var row = 0; row < board.rows; row++) {
      for (var column = 0; column < board.columns; column++) {
        final cell = board.at(row, column);
        if (cell == engine.CellState.empty) continue;
        final coordinate = engine.Coordinate(row, column);
        final rect = Rect.fromLTWH(
          column * cellWidth + cellWidth * .13,
          row * cellHeight + cellHeight * .13,
          cellWidth * .74,
          cellHeight * .74,
        );
        final isBlack = cell == engine.CellState.black;
        final paint = Paint()
          ..color = isBlack ? const Color(0xFF080A0D) : LifeColors.paper;
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(radius)),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(radius)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = births.contains(coordinate) ? 2.1 : 1
            ..color = births.contains(coordinate)
                ? LifeColors.sprout
                : isBlack
                ? Colors.white.withValues(alpha: .42)
                : Colors.black.withValues(alpha: .22),
        );
      }
    }

    if (lastMove != null) {
      final center = Offset(
        (lastMove!.column + .5) * cellWidth,
        (lastMove!.row + .5) * cellHeight,
      );
      canvas.drawCircle(
        center,
        math.min(cellWidth, cellHeight) * .13,
        Paint()..color = LifeColors.coral,
      );
    }

    if (showHover && hovered != null) {
      final rect = Rect.fromLTWH(
        hovered!.column * cellWidth + 1,
        hovered!.row * cellHeight + 1,
        cellWidth - 2,
        cellHeight - 2,
      );
      canvas.drawRect(
        rect,
        Paint()..color = colorScheme.primary.withValues(alpha: .19),
      );
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(boardRect, Radius.circular(radius * 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = colorScheme.outlineVariant,
    );
  }

  @override
  bool shouldRepaint(covariant LifeBoardPainter oldDelegate) =>
      oldDelegate.board != board ||
      oldDelegate.colorScheme != colorScheme ||
      oldDelegate.lastMove != lastMove ||
      oldDelegate.hovered != hovered ||
      oldDelegate.showHover != showHover ||
      oldDelegate.births != births;
}
