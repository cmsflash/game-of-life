import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/auth/data/auth_models.dart';

void main() {
  const user = AppUser(
    id: 'user-1',
    username: 'alice',
    displayName: 'Alice',
    avatarUrl: 'https://api.example.test/v1/players/user-1/avatar?v=4',
    avatarVersion: 4,
  );

  test('copyWith preserves an avatar when no avatar change is requested', () {
    final updated = user.copyWith(avatarVersion: 5);

    expect(updated.avatarUrl, user.avatarUrl);
    expect(updated.avatarVersion, 5);
  });

  test('copyWith can explicitly clear an avatar', () {
    final updated = user.copyWith(clearAvatarUrl: true, avatarVersion: 5);

    expect(updated.avatarUrl, isNull);
    expect(updated.avatarVersion, 5);
  });
}
