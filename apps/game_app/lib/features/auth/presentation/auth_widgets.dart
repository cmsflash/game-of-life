import 'package:flutter/material.dart';
import 'package:game_engine/game_engine.dart' as engine;
import 'package:go_router/go_router.dart';

import '../../../core/theme.dart';
import '../../../shared/life_logo.dart';
import '../../game/presentation/life_board.dart';

class AuthPageShell extends StatelessWidget {
  const AuthPageShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final form = Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? 64 : 24,
                  vertical: 28,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => context.go('/'),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LifeLogo(),
                        ),
                      ),
                      const SizedBox(height: 48),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 30),
                      child,
                    ],
                  ),
                ),
              ),
            );
            if (!wide) return form;
            return Row(
              children: [
                Expanded(child: form),
                Expanded(child: _AuthArtwork()),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AuthArtwork extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final board = const engine.GameEngine().initialState().board;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Container(
        decoration: BoxDecoration(
          color: LifeColors.ink,
          borderRadius: BorderRadius.circular(36),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: .72,
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: LifeBoard(board: board, enabled: false),
                ),
              ),
            ),
            Positioned(
              left: 48,
              right: 48,
              bottom: 46,
              child: Text(
                'One move.\nA world of consequences.',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: LifeColors.paper,
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.validator,
    this.autofillHints = const [AutofillHints.password],
    this.textInputAction = TextInputAction.done,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final Iterable<String>? autofillHints;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  var _obscure = true;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: widget.controller,
    obscureText: _obscure,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: widget.autofillHints,
    textInputAction: widget.textInputAction,
    validator: widget.validator,
    onFieldSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      prefixIcon: const Icon(Icons.lock_outline),
      suffixIcon: IconButton(
        tooltip: _obscure ? 'Show password' : 'Hide password',
        onPressed: () => setState(() => _obscure = !_obscure),
        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
      ),
    ),
  );
}

class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    required this.busy,
  });

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('google-sign-in'),
    onPressed: busy ? null : onPressed,
    icon: busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'G',
              style: TextStyle(
                color: Color(0xFF4285F4),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
    label: const Text('Continue with Google'),
  );
}

class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: Divider()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 22),
        child: Text(
          'OR',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            letterSpacing: 1.3,
          ),
        ),
      ),
      const Expanded(child: Divider()),
    ],
  );
}

String? validateUsername(String? value) {
  final username = value?.trim() ?? '';
  if (!RegExp(r'^[A-Za-z0-9_.-]{3,32}$').hasMatch(username)) {
    return 'Use 3–32 letters, numbers, dots, dashes, or underscores.';
  }
  return null;
}

String? validateNewPassword(String? value) {
  final password = value ?? '';
  if (password.length < 10) return 'Use at least 10 characters.';
  if (!RegExp(r'[A-Za-z]').hasMatch(password) ||
      !RegExp(r'[0-9]').hasMatch(password)) {
    return 'Include at least one letter and one number.';
  }
  return null;
}
