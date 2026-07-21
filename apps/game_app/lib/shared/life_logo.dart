import 'package:flutter/material.dart';

import '../core/theme.dart';

class LifeLogo extends StatelessWidget {
  const LifeLogo({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
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
            'LIFE',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
        ],
      ],
    );
  }
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 5;
    final colors = [
      LifeColors.paper,
      LifeColors.sprout,
      LifeColors.paper,
      LifeColors.coral,
    ];
    final positions = [
      const Offset(1, 1),
      const Offset(2, 1),
      const Offset(2, 2),
      const Offset(3, 2),
    ];
    for (var i = 0; i < positions.length; i++) {
      final rect = Rect.fromLTWH(
        positions[i].dx * unit,
        positions[i].dy * unit,
        unit - 1,
        unit - 1,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = colors[i],
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
