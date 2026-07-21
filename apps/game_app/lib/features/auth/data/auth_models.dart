class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.displayName,
    this.email,
    this.rating,
    this.createdAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String? email;
  final int? rating;
  final DateTime? createdAt;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String? ?? 'player';
    return AppUser(
      id: json['userId'] as String? ?? json['id'] as String? ?? username,
      username: username,
      displayName: json['displayName'] as String? ?? username,
      email: json['email'] as String?,
      rating: (json['rating'] as num?)?.round(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': id,
    'username': username,
    'displayName': displayName,
    'email': email,
    'rating': rating,
    'createdAt': createdAt?.toIso8601String(),
  };
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
