import 'package:flutter_test/flutter_test.dart';
import 'package:game_of_life/features/auth/data/auth_models.dart';

void main() {
  const user = AppUser(
    id: 'user-1',
    username: 'alice',
    displayName: 'Alice',
    publicUsername: 'alice',
    avatarUrl: 'https://api.example.test/v1/players/user-1/avatar?v=4',
    avatarVersion: 4,
  );

  test('copyWith preserves an avatar when no avatar change is requested', () {
    final updated = user.copyWith(avatarVersion: 5);

    expect(updated.avatarUrl, user.avatarUrl);
    expect(updated.avatarVersion, 5);
    expect(updated.publicUsername, 'alice');
  });

  test('copyWith can explicitly clear an avatar', () {
    final updated = user.copyWith(clearAvatarUrl: true, avatarVersion: 5);

    expect(updated.avatarUrl, isNull);
    expect(updated.avatarVersion, 5);
  });

  test('public username is parsed, serialized, changed, and cleared', () {
    final parsed = AppUser.fromJson({
      'id': 'user-2',
      'username': 'provider-internal-id',
      'displayName': 'Briar',
      'publicUsername': '  briar_player  ',
    });

    expect(parsed.publicUsername, 'briar_player');
    expect(parsed.toJson()['publicUsername'], 'briar_player');
    expect(
      parsed.copyWith(publicUsername: 'briar_new').publicUsername,
      'briar_new',
    );
    expect(parsed.copyWith(clearPublicUsername: true).publicUsername, isNull);
  });

  test('blank or missing public usernames remain private', () {
    final blank = AppUser.fromJson({
      'id': 'google-1',
      'username': 'provider-generated-id',
      'displayName': 'Google Player',
      'publicUsername': '   ',
    });
    final missing = AppUser.fromJson({
      'id': 'google-2',
      'username': 'another-provider-id',
      'displayName': 'Another Google Player',
    });

    expect(blank.publicUsername, isNull);
    expect(missing.publicUsername, isNull);
  });
}
