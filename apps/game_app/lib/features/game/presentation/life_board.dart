import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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
  late final FocusNode _focusNode;
  engine.Coordinate? _hovered;
  var _selected = const engine.Coordinate(0, 0);
  var _hasFocus = false;

  bool get _canActivate => widget.enabled && widget.onCellTap != null;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'Life board');
  }

  @override
  void didUpdateWidget(covariant LifeBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selected.row >= widget.board.rows ||
        _selected.column >= widget.board.columns) {
      _selected = engine.Coordinate(
        _selected.row.clamp(0, widget.board.rows - 1),
        _selected.column.clamp(0, widget.board.columns - 1),
      );
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, constraints.maxHeight);
        final fallbackSide = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : constraints.maxHeight;
        final resolvedSide = side.isFinite ? side : fallbackSide;
        if (!resolvedSide.isFinite || resolvedSide <= 0) {
          return const SizedBox.shrink();
        }
        final size = Size.square(resolvedSide);
        return Center(
          child: Focus(
            focusNode: _focusNode,
            canRequestFocus: _canActivate || _focusNode.hasFocus,
            skipTraversal: !_canActivate && !_focusNode.hasFocus,
            onFocusChange: (hasFocus) {
              if (_hasFocus != hasFocus) {
                setState(() => _hasFocus = hasFocus);
              }
            },
            onKeyEvent: _handleKeyEvent,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: widget.semanticLabel,
              value: _hasFocus ? _cellDescription(_selected) : null,
              hint: _canActivate
                  ? 'Use the arrow keys to select a coordinate, then press '
                        'Enter or Space to activate it.'
                  : null,
              enabled: _canActivate,
              liveRegion: _hasFocus,
              child: MouseRegion(
                cursor: _canActivate
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                onExit: (_) {
                  if (_hovered != null) setState(() => _hovered = null);
                },
                onHover: _canActivate
                    ? (event) =>
                          _updateHovered(_coordinate(event.localPosition, size))
                    : null,
                child: SizedBox.fromSize(
                  size: size,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: LifeBoardPainter(
                          board: widget.board,
                          colorScheme: Theme.of(context).colorScheme,
                          lastMove: widget.lastMove,
                          births: widget.births.toSet(),
                          hovered: _hovered,
                          showHover: _canActivate,
                          focused: _selected,
                          showFocus: _hasFocus,
                        ),
                      ),
                      ..._cellInteractionLayer(size),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _cellInteractionLayer(Size size) {
    final cellWidth = size.width / widget.board.columns;
    final cellHeight = size.height / widget.board.rows;
    return [
      for (var row = 0; row < widget.board.rows; row++)
        for (var column = 0; column < widget.board.columns; column++)
          Positioned(
            left: column * cellWidth,
            top: row * cellHeight,
            width: cellWidth,
            height: cellHeight,
            child: Semantics(
              key: ValueKey('life-cell-$row-$column'),
              sortKey: OrdinalSortKey(
                (row * widget.board.columns + column).toDouble(),
              ),
              label: 'Row ${row + 1}, column ${column + 1}',
              value: _cellStateLabel(widget.board.at(row, column)),
              button: _canActivate,
              enabled: _canActivate,
              selected:
                  _hasFocus && _selected == engine.Coordinate(row, column),
              onTap: _canActivate
                  ? () => _selectAndActivate(engine.Coordinate(row, column))
                  : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: _canActivate
                    ? () => _selectAndActivate(engine.Coordinate(row, column))
                    : null,
                child: const SizedBox.expand(),
              ),
            ),
          ),
    ];
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSelection(rowDelta: -1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _moveSelection(rowDelta: 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _moveSelection(columnDelta: -1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _moveSelection(columnDelta: 1);
    } else if (key == LogicalKeyboardKey.home) {
      _setSelection(engine.Coordinate(_selected.row, 0));
    } else if (key == LogicalKeyboardKey.end) {
      _setSelection(engine.Coordinate(_selected.row, widget.board.columns - 1));
    } else if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.space)) {
      if (_canActivate) {
        widget.onCellTap!(_selected.row, _selected.column);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _moveSelection({int rowDelta = 0, int columnDelta = 0}) {
    _setSelection(
      engine.Coordinate(
        (_selected.row + rowDelta).clamp(0, widget.board.rows - 1),
        (_selected.column + columnDelta).clamp(0, widget.board.columns - 1),
      ),
    );
  }

  void _setSelection(engine.Coordinate coordinate) {
    if (_selected != coordinate) setState(() => _selected = coordinate);
  }

  void _selectAndActivate(engine.Coordinate coordinate) {
    _setSelection(coordinate);
    _focusNode.requestFocus();
    widget.onCellTap!(coordinate.row, coordinate.column);
  }

  void _updateHovered(engine.Coordinate coordinate) {
    if (_hovered != coordinate) setState(() => _hovered = coordinate);
  }

  String _cellDescription(engine.Coordinate coordinate) {
    final state = widget.board.atCoordinate(coordinate);
    return 'Selected row ${coordinate.row + 1}, column '
        '${coordinate.column + 1}, ${_cellStateLabel(state).toLowerCase()}';
  }

  String _cellStateLabel(engine.CellState state) => switch (state) {
    engine.CellState.empty => 'Empty',
    engine.CellState.black => 'Black cell',
    engine.CellState.white => 'White cell',
  };

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
    required this.focused,
    required this.showFocus,
  });

  final engine.Board board;
  final ColorScheme colorScheme;
  final engine.Coordinate? lastMove;
  final Set<engine.Coordinate> births;
  final engine.Coordinate? hovered;
  final bool showHover;
  final engine.Coordinate? focused;
  final bool showFocus;

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

    if (showFocus && focused != null) {
      final rect = Rect.fromLTWH(
        focused!.column * cellWidth + 1.5,
        focused!.row * cellHeight + 1.5,
        cellWidth - 3,
        cellHeight - 3,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius * .75)),
        Paint()..color = colorScheme.primary.withValues(alpha: .24),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius * .75)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colorScheme.primary,
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
      oldDelegate.focused != focused ||
      oldDelegate.showFocus != showFocus ||
      oldDelegate.births != births;
}
