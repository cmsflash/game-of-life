import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/shared/player_avatar.dart';

void main() {
  testWidgets('avatar has an accessible initial fallback', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PlayerAvatar(displayName: 'Alice')),
      ),
    );

    expect(find.text('A'), findsOneWidget);
    expect(find.bySemanticsLabel('Profile picture for Alice'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    semantics.dispose();
  });

  testWidgets('avatar rejects non-web URLs and keeps initials', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayerAvatar(
            displayName: 'Briar',
            avatarUrl: 'file:///private/avatar.webp',
            avatarVersion: 3,
          ),
        ),
      ),
    );

    expect(find.text('B'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('avatar consumes the trusted versioned server URL', (
    tester,
  ) async {
    const url = 'https://api.example.test/v1/players/briar/avatar?v=4';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayerAvatar(
            displayName: 'Briar',
            avatarUrl: url,
            avatarVersion: 4,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as NetworkImage).url, url);
    expect(image.key, const ValueKey('$url#4'));
  });
}
