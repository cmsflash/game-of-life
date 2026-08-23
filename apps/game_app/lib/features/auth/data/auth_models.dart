class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.publicUsername,
    this.email,
    this.rating,
    this.createdAt,
    this.avatarUrl,
    this.avatarVersion = 0,
  });

  final String id;
  final String username;
  final String displayName;
  final String? publicUsername;
  final String? email;
  final int? rating;
  final DateTime? createdAt;
  final String? avatarUrl;
  final int avatarVersion;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String? ?? 'player';
    final publicUsername = (json['publicUsername'] as String?)?.trim();
    return AppUser(
      id: json['userId'] as String? ?? json['id'] as String? ?? username,
      username: username,
      displayName: json['displayName'] as String? ?? username,
      publicUsername: publicUsername == null || publicUsername.isEmpty
          ? null
          : publicUsername,
      email: json['email'] as String?,
      rating: (json['rating'] as num?)?.round(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      avatarUrl: json['avatarUrl'] as String?,
      avatarVersion: (json['avatarVersion'] as num?)?.round() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': id,
    'username': username,
    'displayName': displayName,
    'publicUsername': publicUsername,
    'email': email,
    'rating': rating,
    'createdAt': createdAt?.toIso8601String(),
    'avatarUrl': avatarUrl,
    'avatarVersion': avatarVersion,
  };

  AppUser copyWith({
    String? publicUsername,
    bool clearPublicUsername = false,
    String? avatarUrl,
    bool clearAvatarUrl = false,
    int? avatarVersion,
  }) {
    assert(avatarUrl == null || !clearAvatarUrl);
    assert(publicUsername == null || !clearPublicUsername);
    return AppUser(
      id: id,
      username: username,
      displayName: displayName,
      publicUsername: clearPublicUsername
          ? null
          : publicUsername ?? this.publicUsername,
      email: email,
      rating: rating,
      createdAt: createdAt,
      avatarUrl: clearAvatarUrl ? null : avatarUrl ?? this.avatarUrl,
      avatarVersion: avatarVersion ?? this.avatarVersion,
    );
  }
}

class RegistrationResult {
  const RegistrationResult({
    required this.username,
    required this.confirmationRequired,
    this.debugConfirmationCode,
  });

  final String username;
  final bool confirmationRequired;
  final String? debugConfirmationCode;

  factory RegistrationResult.fromJson(Map<String, dynamic> json) =>
      RegistrationResult(
        username: json['username'] as String,
        confirmationRequired: json['confirmationRequired'] as bool? ?? true,
        debugConfirmationCode: json['debugConfirmationCode'] as String?,
      );
}
