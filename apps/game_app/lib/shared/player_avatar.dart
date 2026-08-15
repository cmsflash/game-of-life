import 'package:flutter/material.dart';

class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({
    super.key,
    required this.displayName,
    this.avatarUrl,
    this.avatarVersion = 0,
    this.radius = 20,
  });

  final String displayName;
  final String? avatarUrl;
  final int avatarVersion;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final url = _safeAvatarUrl(avatarUrl);
    final fallback = _AvatarFallback(displayName: displayName, radius: radius);
    return Semantics(
      image: true,
      label: 'Profile picture for $displayName',
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: radius * 2,
          child: ClipOval(
            child: url == null
                ? fallback
                : Image.network(
                    url,
                    key: ValueKey('$url#$avatarVersion'),
                    width: radius * 2,
                    height: radius * 2,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => fallback,
                    loadingBuilder: (context, child, progress) {
                      if (progress == null) return child;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          fallback,
                          Center(
                            child: SizedBox.square(
                              dimension: radius * .7,
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.displayName, required this.radius});

  final String displayName;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final normalized = displayName.trim();
    final initial = normalized.isEmpty ? 'P' : normalized.characters.first;
    return ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Center(
        child: Text(
          initial.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
            fontSize: radius * .8,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

String? _safeAvatarUrl(String? value) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.toString();
}
