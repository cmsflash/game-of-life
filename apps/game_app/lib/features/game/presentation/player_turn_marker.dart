import 'package:flutter/material.dart';
import 'package:game_engine/game_engine.dart' as engine;

import '../../../core/theme.dart';

/// The player-color turn dot becomes an explicit commit control once a move
/// has been previewed.
class PlayerTurnMarker extends StatelessWidget {
  const PlayerTurnMarker({
    super.key,
    required this.player,
    required this.active,
    this.onCommit,
    this.busy = false,
    this.markerSize = 28,
  });

  final engine.Player player;
  final bool active;
  final VoidCallback? onCommit;
  final bool busy;
  final double markerSize;

  Color get _background =>
      player == engine.Player.black ? LifeColors.ink : LifeColors.paper;

  Color get _foreground =>
      player == engine.Player.black ? LifeColors.paper : LifeColors.ink;

  @override
  Widget build(BuildContext context) {
    if (onCommit == null && !busy) {
      return SizedBox.square(
        dimension: 48,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: markerSize,
            height: markerSize,
            decoration: BoxDecoration(
              color: _background,
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
                width: active ? 2 : 1,
              ),
            ),
          ),
        ),
      );
    }

    return IconButton.filled(
      key: const Key('commit-move'),
      tooltip: busy ? 'Committing move' : 'Commit move',
      onPressed: busy ? null : onCommit,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(48),
        fixedSize: const Size.square(48),
        backgroundColor: _background,
        disabledBackgroundColor: _background.withValues(alpha: .7),
        foregroundColor: _foreground,
        disabledForegroundColor: _foreground,
        side: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2.5,
        ),
      ),
      icon: busy
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: _foreground,
              ),
            )
          : const Icon(Icons.check_rounded, size: 28),
    );
  }
}
