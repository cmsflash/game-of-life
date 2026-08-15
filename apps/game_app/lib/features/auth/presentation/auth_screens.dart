import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config.dart';
import '../../../providers.dart';
import '../../../shared/async_message.dart';
import 'auth_widgets.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.returnTo});

  final String? returnTo;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final success = await ref
        .read(authControllerProvider.notifier)
        .login(_username.text, _password.text);
    if (success && mounted) context.go(widget.returnTo ?? '/online');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthPageShell(
      title: 'Welcome back',
      subtitle: 'Sign in to find opponents and continue your matches.',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (AppConfig.googleSignInAvailable) ...[
                GoogleSignInButton(
                  busy: state.busy,
                  onPressed: () => ref
                      .read(authControllerProvider.notifier)
                      .beginGoogleSignIn(),
                ),
                const OrDivider(),
              ],
              TextFormField(
                key: const Key('login-username'),
                controller: _username,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                validator: (value) => value?.trim().isEmpty ?? true
                    ? 'Enter your username.'
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 14),
              PasswordField(
                controller: _password,
                validator: (value) =>
                    value?.isEmpty ?? true ? 'Enter your password.' : null,
                onSubmitted: (_) => _submit(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.go('/forgot-password'),
                  child: const Text('Forgot password?'),
                ),
              ),
              AsyncMessage(error: state.error, notice: state.notice),
              if (state.error != null || state.notice != null)
                const SizedBox(height: 14),
              FilledButton(
                key: const Key('login-submit'),
                onPressed: state.busy ? null : _submit,
                child: state.busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Sign in'),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('New to Life?'),
                  TextButton(
                    onPressed: () => context.go('/register'),
                    child: const Text('Create account'),
                  ),
                ],
              ),
              TextButton(
                onPressed: () => context.go('/local/setup'),
                child: const Text('Play locally without an account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final success = await ref
        .read(authControllerProvider.notifier)
        .register(
          username: _username.text,
          email: _email.text,
          password: _password.text,
          displayName: _displayName.text,
        );
    if (success && mounted) {
      final result = ref.read(authControllerProvider).registration;
      final query = <String, String>{'username': _username.text};
      if (result?.debugConfirmationCode != null) {
        query['code'] = result!.debugConfirmationCode!;
      }
      context.go(Uri(path: '/confirm', queryParameters: query).toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthPageShell(
      title: 'Create your account',
      subtitle:
          'Username and password work anywhere. Email confirms and recovers your account.',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (AppConfig.googleSignInAvailable) ...[
                GoogleSignInButton(
                  busy: state.busy,
                  onPressed: () => ref
                      .read(authControllerProvider.notifier)
                      .beginGoogleSignIn(),
                ),
                const OrDivider(),
              ],
              TextFormField(
                key: const Key('register-username'),
                controller: _username,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.newUsername,
                ],
                textInputAction: TextInputAction.next,
                validator: validateUsername,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  helperText: 'Your private sign-in ID',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _displayName,
                autofillHints: const [AutofillHints.nickname],
                textInputAction: TextInputAction.next,
                validator: (value) => value?.trim().isEmpty ?? true
                    ? 'Enter a display name.'
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  helperText:
                      'Public to signed-in players in search, friends, and matches',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                validator: (value) {
                  final email = value?.trim() ?? '';
                  if (email.isEmpty || !email.contains('@')) {
                    return 'Enter a valid email address.';
                  }
                  return null;
                },
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
              ),
              const SizedBox(height: 14),
              PasswordField(
                controller: _password,
                autofillHints: const [AutofillHints.newPassword],
                validator: validateNewPassword,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 18),
              AsyncMessage(error: state.error, notice: state.notice),
              if (state.error != null || state.notice != null)
                const SizedBox(height: 14),
              FilledButton(
                key: const Key('register-submit'),
                onPressed: state.busy ? null : _submit,
                child: const Text('Create account'),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'By creating an account, you agree to the ',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton(
                    onPressed: () => context.push('/terms'),
                    child: const Text('Terms'),
                  ),
                  Text('and', style: Theme.of(context).textTheme.bodySmall),
                  TextButton(
                    onPressed: () => context.push('/privacy'),
                    child: const Text('Privacy Policy'),
                  ),
                  const Text('.'),
                ],
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => context.go('/login'),
                child: const Text('Already have an account? Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ConfirmAccountScreen extends ConsumerStatefulWidget {
  const ConfirmAccountScreen({
    super.key,
    this.initialUsername,
    this.initialCode,
  });

  final String? initialUsername;
  final String? initialCode;

  @override
  ConsumerState<ConfirmAccountScreen> createState() =>
      _ConfirmAccountScreenState();
}

class _ConfirmAccountScreenState extends ConsumerState<ConfirmAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _username;
  late final TextEditingController _code;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.initialUsername);
    _code = TextEditingController(text: widget.initialCode);
  }

  @override
  void dispose() {
    _username.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthPageShell(
      title: 'Confirm your account',
      subtitle: 'Enter the short code sent to your recovery address.',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _username,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                validator: validateUsername,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                validator: (value) => (value?.trim().length ?? 0) < 4
                    ? 'Enter the confirmation code.'
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Confirmation code',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              const SizedBox(height: 18),
              AsyncMessage(error: state.error, notice: state.notice),
              if (state.error != null || state.notice != null)
                const SizedBox(height: 14),
              FilledButton(
                onPressed: state.busy
                    ? null
                    : () async {
                        if (!_formKey.currentState!.validate()) return;
                        final done = await ref
                            .read(authControllerProvider.notifier)
                            .confirm(_username.text, _code.text);
                        if (done && context.mounted) context.go('/login');
                      },
                child: const Text('Confirm account'),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: state.busy
                    ? null
                    : () async {
                        final usernameError = validateUsername(_username.text);
                        if (usernameError != null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(usernameError)),
                          );
                          return;
                        }
                        final sent = await ref
                            .read(authControllerProvider.notifier)
                            .resendConfirmation(_username.text);
                        final debugCode = ref
                            .read(authControllerProvider)
                            .registration
                            ?.debugConfirmationCode;
                        if (sent && debugCode != null) _code.text = debugCode;
                      },
                child: const Text('Send a new code'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthPageShell(
      title: 'Reset your password',
      subtitle: 'We will send a code if your account has a recovery address.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _username,
              autofillHints: const [AutofillHints.username],
              validator: validateUsername,
              decoration: const InputDecoration(
                labelText: 'Username',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
            const SizedBox(height: 18),
            AsyncMessage(error: state.error, notice: state.notice),
            if (state.error != null || state.notice != null)
              const SizedBox(height: 14),
            FilledButton(
              onPressed: state.busy
                  ? null
                  : () async {
                      if (!_formKey.currentState!.validate()) return;
                      final sent = await ref
                          .read(authControllerProvider.notifier)
                          .forgotPassword(_username.text);
                      if (sent && context.mounted) {
                        final code = ref.read(authControllerProvider).resetCode;
                        final query = {'username': _username.text};
                        if (code != null) query['code'] = code;
                        context.go(
                          Uri(
                            path: '/reset-password',
                            queryParameters: query,
                          ).toString(),
                        );
                      }
                    },
              child: const Text('Send reset code'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Back to sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({
    super.key,
    this.initialUsername,
    this.initialCode,
  });

  final String? initialUsername;
  final String? initialCode;

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _username;
  late final TextEditingController _code;
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.initialUsername);
    _code = TextEditingController(text: widget.initialCode);
  }

  @override
  void dispose() {
    _username.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthPageShell(
      title: 'Choose a new password',
      subtitle: 'Enter the code and a password you do not use elsewhere.',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _username,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                validator: validateUsername,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                textInputAction: TextInputAction.next,
                validator: (value) => (value?.trim().length ?? 0) < 4
                    ? 'Enter the reset code.'
                    : null,
                decoration: const InputDecoration(labelText: 'Reset code'),
              ),
              const SizedBox(height: 14),
              PasswordField(
                controller: _password,
                label: 'New password',
                autofillHints: const [AutofillHints.newPassword],
                validator: validateNewPassword,
              ),
              const SizedBox(height: 18),
              AsyncMessage(error: state.error, notice: state.notice),
              if (state.error != null || state.notice != null)
                const SizedBox(height: 14),
              FilledButton(
                onPressed: state.busy
                    ? null
                    : () async {
                        if (!_formKey.currentState!.validate()) return;
                        final done = await ref
                            .read(authControllerProvider.notifier)
                            .resetPassword(
                              _username.text,
                              _code.text,
                              _password.text,
                            );
                        if (done && context.mounted) context.go('/login');
                      },
                child: const Text('Update password'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GoogleCallbackScreen extends ConsumerStatefulWidget {
  const GoogleCallbackScreen({super.key, required this.code});

  final String? code;

  @override
  ConsumerState<GoogleCallbackScreen> createState() =>
      _GoogleCallbackScreenState();
}

class _GoogleCallbackScreenState extends ConsumerState<GoogleCallbackScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _complete());
  }

  Future<void> _complete() async {
    final code = widget.code;
    if (code == null || code.isEmpty) return;
    final success = await ref
        .read(authControllerProvider.notifier)
        .completeGoogleSignIn(code);
    if (success && mounted) context.go('/online');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    return AuthPageShell(
      title: 'Completing sign-in',
      subtitle: widget.code == null
          ? 'The browser did not return a valid sign-in. You can safely try again.'
          : 'Exchanging the one-time code with the game server…',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.busy)
            const Center(child: CircularProgressIndicator())
          else
            AsyncMessage(error: state.error),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => context.go('/login'),
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}
