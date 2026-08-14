enum TurnNotificationPermission { unavailable, prompt, denied, granted }

class TurnNotificationConfiguration {
  const TurnNotificationConfiguration({
    required this.providers,
    this.webPushVapidPublicKey,
  });

  factory TurnNotificationConfiguration.fromJson(Map<String, dynamic> json) =>
      TurnNotificationConfiguration(
        providers: {
          for (final provider in json['providers'] as List? ?? const [])
            if (provider is String) provider,
        },
        webPushVapidPublicKey: json['webPushVapidPublicKey'] as String?,
      );

  final Set<String> providers;
  final String? webPushVapidPublicKey;

  bool supports(String provider) => providers.contains(provider);
}

class TurnNotificationCapability {
  const TurnNotificationCapability({
    required this.configured,
    required this.supported,
    required this.permission,
  });

  const TurnNotificationCapability.notConfigured()
    : configured = false,
      supported = true,
      permission = TurnNotificationPermission.unavailable;

  const TurnNotificationCapability.unsupported()
    : configured = true,
      supported = false,
      permission = TurnNotificationPermission.unavailable;

  final bool configured;
  final bool supported;
  final TurnNotificationPermission permission;

  bool get canEnable => configured && supported;
}

class TurnNotificationEndpoint {
  const TurnNotificationEndpoint.firebase({
    required this.platform,
    required this.token,
  }) : provider = 'firebase',
       endpoint = null,
       p256dh = null,
       auth = null,
       assert(token != null);

  const TurnNotificationEndpoint.webPush({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  }) : provider = 'webPush',
       platform = 'web',
       token = null,
       assert(endpoint != null),
       assert(p256dh != null),
       assert(auth != null);

  final String provider;
  final String platform;
  final String? token;
  final String? endpoint;
  final String? p256dh;
  final String? auth;

  Map<String, Object> toJson({
    required String installationId,
    String? locale,
    String? timeZone,
  }) => {
    'installationId': installationId,
    'platform': platform,
    'provider': provider,
    'token': ?token,
    'endpoint': ?endpoint,
    'p256dh': ?p256dh,
    'auth': ?auth,
    if (locale != null && locale.isNotEmpty) 'locale': locale,
    if (timeZone != null && timeZone.isNotEmpty) 'timeZone': timeZone,
  };
}

class TurnNotificationMessage {
  const TurnNotificationMessage({
    this.matchId,
    this.path,
    this.title,
    this.body,
  });

  final String? matchId;
  final String? path;
  final String? title;
  final String? body;

  String? get matchPath {
    final candidate = path;
    if (candidate != null && candidate.startsWith('/online/match/')) {
      return candidate;
    }
    final id = matchId;
    if (id == null || id.isEmpty) return null;
    return '/online/match/${Uri.encodeComponent(id)}';
  }
}

class TurnNotificationSubscription {
  const TurnNotificationSubscription({
    required this.installationId,
    required this.platform,
    required this.provider,
    this.locale,
    this.timeZone,
  });

  factory TurnNotificationSubscription.fromJson(Map<String, dynamic> json) =>
      TurnNotificationSubscription(
        installationId: json['installationId'] as String,
        platform: json['platform'] as String,
        provider: json['provider'] as String,
        locale: json['locale'] as String?,
        timeZone: json['timeZone'] as String?,
      );

  final String installationId;
  final String platform;
  final String provider;
  final String? locale;
  final String? timeZone;
}
