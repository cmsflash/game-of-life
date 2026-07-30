import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../providers.dart';
import '../../shared/page_frame.dart';
import '../auth/presentation/auth_controller.dart';
import '../game/presentation/life_board.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return PageFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 800;
              final copy = _HeroCopy(auth: auth);
              final board = const AspectRatio(
                aspectRatio: 1,
                child: _HeroBoard(),
              );
              if (wide) {
                return Row(
                  children: [
                    Expanded(flex: 11, child: copy),
                    const SizedBox(width: 58),
                    Expanded(flex: 9, child: board),
                  ],
                );
              }
              final boardSize = constraints.maxWidth.clamp(0, 520).toDouble();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: constraints.maxWidth, child: copy),
                  const SizedBox(height: 38),
                  SizedBox.square(
                    dimension: boardSize,
                    child: const _HeroBoard(),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 80),
          const SectionHeading(
            eyebrow: 'The rules',
            title: 'Place. Evolve. Outlive.',
            description:
                'Every turn begins with one new cell. Then the whole board evolves under Conway’s rules. Every birth belongs to the player who just moved.',
          ),
          const SizedBox(height: 26),
          const _RuleCards(),
          const SizedBox(height: 70),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final copy = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ready to make the first move?',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Play on one device now, or sign in for an online match.',
                      ),
                    ],
                  );
                  final actions = Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () => context.go('/local/setup'),
                        icon: const Icon(Icons.sports_esports),
                        label: const Text('Local game'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.go(
                          auth.status == AuthStatus.signedIn
                              ? '/online'
                              : '/login?returnTo=/online',
                        ),
                        icon: const Icon(Icons.public),
                        label: const Text('Play online'),
                      ),
                    ],
                  );
                  if (constraints.maxWidth > 680) {
                    return Row(
                      children: [
                        Expanded(child: copy),
                        const SizedBox(width: 24),
                        actions,
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [copy, const SizedBox(height: 22), actions],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(99),
        ),
        child: const Text('CONWAY, WITH COMPETITION'),
      ),
      const SizedBox(height: 24),
      Text(
        'Give life\na side.',
        style: Theme.of(context).textTheme.displayLarge?.copyWith(
          fontSize: MediaQuery.sizeOf(context).width < 500 ? 58 : 80,
        ),
      ),
      const SizedBox(height: 22),
      Text(
        'A two-player strategy game where every stone changes the living world around it.',
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.4,
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(height: 32),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            key: const Key('play-local'),
            onPressed: () => context.go('/local/setup'),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play locally'),
          ),
          OutlinedButton.icon(
            onPressed: () => context.go(
              auth.status == AuthStatus.signedIn
                  ? '/online'
                  : '/login?returnTo=/online',
            ),
            icon: const Icon(Icons.language),
            label: const Text('Find a player'),
          ),
        ],
      ),
      const SizedBox(height: 18),
      Text(
        '20 × 20  •  2 players  •  No pass turns',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class _HeroBoard extends StatelessWidget {
  const _HeroBoard();

  @override
  Widget build(BuildContext context) {
    final cells = List<engine.CellState>.filled(400, engine.CellState.empty);
    const black = [
      (4, 7),
      (5, 7),
      (5, 8),
      (6, 6),
      (6, 8),
      (9, 12),
      (10, 11),
      (10, 12),
      (11, 12),
      (13, 5),
      (14, 5),
      (14, 6),
      (15, 4),
      (15, 6),
    ];
    const white = [
      (3, 13),
      (4, 12),
      (4, 13),
      (5, 13),
      (8, 4),
      (9, 4),
      (9, 5),
      (10, 3),
      (10, 5),
      (13, 13),
      (13, 14),
      (14, 12),
      (14, 14),
      (15, 13),
    ];
    for (final cell in black) {
      cells[cell.$1 * 20 + cell.$2] = engine.CellState.black;
    }
    for (final cell in white) {
      cells[cell.$1 * 20 + cell.$2] = engine.CellState.white;
    }
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF252C37), LifeColors.ink],
        ),
        borderRadius: BorderRadius.circular(34),
        boxShadow: [
          BoxShadow(
            color: LifeColors.sprout.withValues(alpha: .11),
            blurRadius: 50,
            spreadRadius: 5,
          ),
        ],
      ),
      child: LifeBoard(
        board: engine.Board(rows: 20, columns: 20, cells: cells),
        enabled: false,
      ),
    );
  }
}

class _RuleCards extends StatelessWidget {
  const _RuleCards();

  @override
  Widget build(BuildContext context) {
    const rules = [
      (
        Icons.add_circle_outline,
        'Place one cell',
        'Choose any empty square. Your new cell may survive—or die immediately.',
      ),
      (
        Icons.auto_awesome,
        'Evolve together',
        'Every cell updates simultaneously. New life joins the player who made the move.',
      ),
      (
        Icons.emoji_events_outlined,
        'Claim the board',
        'Eliminate the other color, reach the target, or lead when the turn limit ends.',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (var i = 0; i < rules.length; i++)
              SizedBox(
                width: width >= 800 ? (width - 32) / 3 : width,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primaryContainer,
                              child: Icon(rules[i].$1),
                            ),
                            const Spacer(),
                            Text('0${i + 1}'),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(
                          rules[i].$2,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 9),
                        Text(rules[i].$3),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
