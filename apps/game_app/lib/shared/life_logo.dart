import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Canonical 2x2 starting position in row-major order: TL, TR, BL, BR.
const lifeLogoCellColors = <Color>[
  LifeColors.sprout,
  LifeColors.paper,
  LifeColors.paper,
  LifeColors.sprout,
];

class LifeLogo extends StatelessWidget {
  const LifeLogo({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mark = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: LifeColors.ink,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: CustomPaint(painter: _LogoPainter()),
        ),
        if (!compact) ...[
          const SizedBox(width: 11),
          Text(
            'Game of Life',
            maxLines: 1,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: .5,
            ),
          ),
        ],
      ],
    );
    return Semantics(
      image: true,
      label: 'Game of Life logo, diagonal two-player starting position',
      child: ExcludeSemantics(
        child: compact
            ? mark
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: mark,
                ),
              ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide * .22;
    final gap = size.shortestSide * .075;
    final block = cell * 2 + gap;
    final origin = Offset((size.width - block) / 2, (size.height - block) / 2);
    final positions = [
      Offset.zero,
      Offset(cell + gap, 0),
      Offset(0, cell + gap),
      Offset(cell + gap, cell + gap),
    ];
    for (var i = 0; i < positions.length; i++) {
      final rect = Rect.fromLTWH(
        origin.dx + positions[i].dx,
        origin.dy + positions[i].dy,
        cell,
        cell,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = lifeLogoCellColors[i],
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
