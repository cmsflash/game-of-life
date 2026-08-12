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
    this.previewBoard,
    this.tentativeMove,
    this.previewDeaths = const [],
    this.visualizePreviewDeaths = false,
    this.births = const [],
    this.semanticLabel = '20 by 20 game board',
  });

  final engine.Board board;
  final void Function(int row, int column)? onCellTap;
  final bool enabled;
  final engine.Coordinate? lastMove;
  final engine.Board? previewBoard;
  final engine.Coordinate? tentativeMove;
  final List<engine.CellDeath> previewDeaths;
  final bool visualizePreviewDeaths;
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
    final wasActivatable = oldWidget.enabled && oldWidget.onCellTap != null;
    if (wasActivatable && !_canActivate && _focusNode.hasFocus) {
      _focusNode.unfocus();
    }
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
            canRequestFocus: _canActivate,
            skipTraversal: !_canActivate,
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
              value: _hasFocus && _canActivate
                  ? _cellDescription(_selected)
                  : null,
              hint: _canActivate
                  ? 'Use the arrow keys to select a coordinate, then press '
                        'Enter or Space to preview it.'
                  : null,
              enabled: _canActivate,
              liveRegion: _hasFocus && _canActivate,
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
                          previewBoard: widget.previewBoard,
                          tentativeMove: widget.tentativeMove,
                          previewDeaths: widget.previewDeaths,
                          visualizePreviewDeaths: widget.visualizePreviewDeaths,
                          births: widget.births.toSet(),
                          hovered: _hovered,
                          showHover: _canActivate,
                          focused: _selected,
                          showFocus: _hasFocus && _canActivate,
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
              value: _cellStateLabel(engine.Coordinate(row, column)),
              button: _canActivate,
              enabled: _canActivate,
              selected:
                  _hasFocus &&
                  _canActivate &&
                  _selected == engine.Coordinate(row, column),
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
    if (!_canActivate) return KeyEventResult.ignored;
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
    return 'Selected row ${coordinate.row + 1}, column '
        '${coordinate.column + 1}, '
        '${_cellStateLabel(coordinate).toLowerCase()}';
  }

  String _cellStateLabel(engine.Coordinate coordinate) {
    final current = widget.board.atCoordinate(coordinate);
    final preview = widget.previewBoard?.atCoordinate(coordinate);
    final death = _previewDeathAt(coordinate);
    if (death != null) {
      final color = death.player == engine.Player.black ? 'Black' : 'White';
      if (current == engine.CellState.empty &&
          coordinate == widget.tentativeMove) {
        return 'Tentative ${color.toLowerCase()} placement will die next round';
      }
      return '$color cell will die next round';
    }
    if (preview == null || preview == current) {
      return switch (current) {
        engine.CellState.empty => 'Empty',
        engine.CellState.black => 'Black cell',
        engine.CellState.white => 'White cell',
      };
    }
    if (preview == engine.CellState.empty) {
      return 'Empty next round; currently ${current.name}';
    }
    return 'Hypothetical ${preview.name} cell';
  }

  engine.CellDeath? _previewDeathAt(engine.Coordinate coordinate) {
    for (final death in widget.previewDeaths) {
      if (death.coordinate == coordinate) return death;
    }
    return null;
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
    this.previewBoard,
    this.tentativeMove,
    this.previewDeaths = const [],
    this.visualizePreviewDeaths = false,
    required this.births,
    required this.hovered,
    required this.showHover,
    required this.focused,
    required this.showFocus,
  });

  final engine.Board board;
  final ColorScheme colorScheme;
  final engine.Coordinate? lastMove;
  final engine.Board? previewBoard;
  final engine.Coordinate? tentativeMove;
  final List<engine.CellDeath> previewDeaths;
  final bool visualizePreviewDeaths;
  final Set<engine.Coordinate> births;
  final engine.Coordinate? hovered;
  final bool showHover;
  final engine.Coordinate? focused;
  final bool showFocus;

  @override
  void paint(Canvas canvas, Size size) {
    final displayBoard = previewBoard ?? board;
    final cellWidth = size.width / board.columns;
    final cellHeight = size.height / board.rows;
    final radius = math.min(cellWidth, cellHeight) * .22;
    final boardRect = Offset.zero & size;
    final boardShape = RRect.fromRectAndRadius(
      boardRect,
      Radius.circular(radius * 2),
    );

    canvas.drawRRect(
      boardShape,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [LifeColors.boardWoodLight, LifeColors.boardWoodDark],
        ).createShader(boardRect),
    );
    canvas.save();
    canvas.clipRRect(boardShape);

    final gridPaint = Paint()
      ..color = LifeColors.boardGrid.withValues(alpha: .76)
      ..strokeWidth = .8;
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
        final cell = displayBoard.at(row, column);
        if (cell == engine.CellState.empty) continue;
        final coordinate = engine.Coordinate(row, column);
        final rect = Rect.fromLTWH(
          column * cellWidth + cellWidth * .13,
          row * cellHeight + cellHeight * .13,
          cellWidth * .74,
          cellHeight * .74,
        );
        final isBlack = cell == engine.CellState.black;
        final isHypothetical =
            previewBoard != null && board.atCoordinate(coordinate) != cell;
        final isBirth = previewBoard == null && births.contains(coordinate);
        final stoneShape = RRect.fromRectAndRadius(
          rect,
          Radius.circular(radius),
        );
        final stoneColor = isBlack ? const Color(0xFF080A0D) : LifeColors.paper;
        final paint = Paint()
          ..color = isHypothetical
              ? stoneColor.withValues(alpha: .56)
              : stoneColor;
        canvas.drawRRect(stoneShape, paint);
        if (isBirth) {
          canvas.drawRRect(
            stoneShape,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3.6
              ..color = LifeColors.boardMarkerDark,
          );
          canvas.drawRRect(
            stoneShape,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = LifeColors.sprout,
          );
        } else {
          canvas.drawRRect(
            stoneShape,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color =
                  (isBlack
                          ? Colors.white.withValues(alpha: .42)
                          : LifeColors.boardBorder.withValues(alpha: .82))
                      .withValues(alpha: isHypothetical ? .46 : 1),
          );
        }
      }
    }

    if (previewBoard != null && visualizePreviewDeaths) {
      for (final death in previewDeaths) {
        if (!board.contains(death.coordinate) ||
            previewBoard!.atCoordinate(death.coordinate) !=
                engine.CellState.empty) {
          continue;
        }
        _drawDeathGhost(
          canvas,
          death: death,
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          radius: radius,
        );
      }
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
          ..strokeWidth = 3.8
          ..color = LifeColors.boardMarkerDark,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius * .75)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colorScheme.primary,
      );
    }
    final shutter = tentativeMove ?? lastMove;
    if (shutter != null && board.contains(shutter)) {
      _drawShutter(
        canvas,
        coordinate: shutter,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
      );
    }
    canvas.restore();
    canvas.drawRRect(
      boardShape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..color = LifeColors.boardBorder,
    );
  }

  void _drawDeathGhost(
    Canvas canvas, {
    required engine.CellDeath death,
    required double cellWidth,
    required double cellHeight,
    required double radius,
  }) {
    final coordinate = death.coordinate;
    final rect = Rect.fromLTWH(
      coordinate.column * cellWidth + cellWidth * .13,
      coordinate.row * cellHeight + cellHeight * .13,
      cellWidth * .74,
      cellHeight * .74,
    );
    final stoneShape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final isBlack = death.player == engine.Player.black;
    final stoneColor = isBlack ? const Color(0xFF080A0D) : LifeColors.paper;
    canvas.drawRRect(
      stoneShape,
      Paint()..color = stoneColor.withValues(alpha: isBlack ? .28 : .46),
    );
    canvas.drawRRect(
      stoneShape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.8
        ..color = LifeColors.boardMarkerDark.withValues(alpha: .9),
    );
    canvas.drawRRect(
      stoneShape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = LifeColors.coral,
    );

    final inset = math.min(cellWidth, cellHeight) * .24;
    final firstStart = Offset(rect.left + inset, rect.top + inset);
    final firstEnd = Offset(rect.right - inset, rect.bottom - inset);
    final secondStart = Offset(rect.right - inset, rect.top + inset);
    final secondEnd = Offset(rect.left + inset, rect.bottom - inset);
    final darkPaint = Paint()
      ..color = LifeColors.boardMarkerDark
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final coralPaint = Paint()
      ..color = LifeColors.coral
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawLine(firstStart, firstEnd, darkPaint)
      ..drawLine(secondStart, secondEnd, darkPaint)
      ..drawLine(firstStart, firstEnd, coralPaint)
      ..drawLine(secondStart, secondEnd, coralPaint);
  }

  void _drawShutter(
    Canvas canvas, {
    required engine.Coordinate coordinate,
    required double cellWidth,
    required double cellHeight,
  }) {
    final left = coordinate.column * cellWidth + cellWidth * .08;
    final top = coordinate.row * cellHeight + cellHeight * .08;
    final right = (coordinate.column + 1) * cellWidth - cellWidth * .08;
    final bottom = (coordinate.row + 1) * cellHeight - cellHeight * .08;
    final horizontal = cellWidth * .24;
    final vertical = cellHeight * .24;
    final segments = <(Offset, Offset)>[
      (Offset(left, top), Offset(left + horizontal, top)),
      (Offset(left, top), Offset(left, top + vertical)),
      (Offset(right, top), Offset(right - horizontal, top)),
      (Offset(right, top), Offset(right, top + vertical)),
      (Offset(left, bottom), Offset(left + horizontal, bottom)),
      (Offset(left, bottom), Offset(left, bottom - vertical)),
      (Offset(right, bottom), Offset(right - horizontal, bottom)),
      (Offset(right, bottom), Offset(right, bottom - vertical)),
    ];
    final darkPaint = Paint()
      ..color = LifeColors.boardMarkerDark
      ..strokeWidth = 4.6
      ..strokeCap = StrokeCap.square;
    final greenPaint = Paint()
      ..color = LifeColors.sprout
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.square;
    for (final segment in segments) {
      canvas.drawLine(segment.$1, segment.$2, darkPaint);
    }
    for (final segment in segments) {
      canvas.drawLine(segment.$1, segment.$2, greenPaint);
    }
  }

  @override
  bool shouldRepaint(covariant LifeBoardPainter oldDelegate) =>
      oldDelegate.board != board ||
      oldDelegate.colorScheme != colorScheme ||
      oldDelegate.lastMove != lastMove ||
      oldDelegate.previewBoard != previewBoard ||
      oldDelegate.tentativeMove != tentativeMove ||
      oldDelegate.previewDeaths != previewDeaths ||
      oldDelegate.visualizePreviewDeaths != visualizePreviewDeaths ||
      oldDelegate.hovered != hovered ||
      oldDelegate.showHover != showHover ||
      oldDelegate.focused != focused ||
      oldDelegate.showFocus != showFocus ||
      oldDelegate.births != births;
}
