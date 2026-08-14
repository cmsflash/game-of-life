import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers.dart';
import '../../shared/page_frame.dart';
import '../auth/presentation/auth_controller.dart';

enum LegalDocument { about, privacy, terms, accountDeletion }

final _supportUri = Uri.parse('https://cmsflash.github.io/contact/');

class LegalScreen extends ConsumerWidget {
  const LegalScreen({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (document) {
      LegalDocument.about => _AboutContent(
        signedIn:
            ref.watch(authControllerProvider).status == AuthStatus.signedIn,
      ),
      LegalDocument.privacy => const _DocumentContent(
        eyebrow: 'Legal',
        title: 'Privacy Policy',
        introduction:
            'Effective August 14, 2026. This policy explains what The Game of '
            'Life processes when you play locally or use an online account.',
        sections: _privacySections,
      ),
      LegalDocument.terms => const _DocumentContent(
        eyebrow: 'Legal',
        title: 'Terms of Use',
        introduction:
            'Effective August 14, 2026. These terms apply when you create an '
            'account or use the online game service.',
        sections: _termsSections,
      ),
      LegalDocument.accountDeletion => _AccountDeletionContent(
        signedIn:
            ref.watch(authControllerProvider).status == AuthStatus.signedIn,
      ),
    };
  }
}

class _AboutContent extends StatelessWidget {
  const _AboutContent({required this.signedIn});

  final bool signedIn;

  @override
  Widget build(BuildContext context) => PageFrame(
    maxWidth: 860,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          eyebrow: 'About',
          title: 'Life, with an opponent',
          description:
              'A deterministic two-player strategy game built on Conway’s '
              'famous rules. Local games work without an account or network.',
        ),
        const SizedBox(height: 28),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                _AboutLink(
                  icon: Icons.shield_outlined,
                  title: 'Privacy Policy',
                  subtitle: 'What is collected, why, and for how long.',
                  onTap: () => context.push('/privacy'),
                ),
                const Divider(),
                _AboutLink(
                  icon: Icons.description_outlined,
                  title: 'Terms of Use',
                  subtitle: 'The rules for accounts and online play.',
                  onTap: () => context.push('/terms'),
                ),
                const Divider(),
                _AboutLink(
                  icon: Icons.person_remove_outlined,
                  title: 'Account deletion',
                  subtitle: 'Delete an account and understand what remains.',
                  onTap: () => context.push('/account-deletion'),
                ),
                const Divider(),
                _AboutLink(
                  icon: Icons.code,
                  title: 'Open-source licenses',
                  subtitle: 'Licenses for the software used by this app.',
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'The Game of Life',
                    applicationVersion: '1.0.0',
                    applicationLegalese: 'Copyright © 2026 CMSFlash',
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 12,
            ),
            leading: const Icon(Icons.support_agent),
            title: const Text('Support'),
            subtitle: const Text(
              'Contact Shen Zhuoran / CMSFlash through the public support page.',
            ),
            onTap: () =>
                launchUrl(_supportUri, mode: LaunchMode.externalApplication),
            trailing: signedIn
                ? OutlinedButton(
                    onPressed: () => context.go('/player'),
                    child: const Text('Player'),
                  )
                : OutlinedButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Sign in'),
                  ),
          ),
        ),
      ],
    ),
  );
}

class _AboutLink extends StatelessWidget {
  const _AboutLink({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _DocumentContent extends StatelessWidget {
  const _DocumentContent({
    required this.eyebrow,
    required this.title,
    required this.introduction,
    required this.sections,
  });

  final String eyebrow;
  final String title;
  final String introduction;
  final List<_LegalSectionData> sections;

  @override
  Widget build(BuildContext context) => PageFrame(
    maxWidth: 860,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(
          eyebrow: eyebrow,
          title: title,
          description: introduction,
        ),
        const SizedBox(height: 28),
        for (var index = 0; index < sections.length; index++) ...[
          _LegalSection(data: sections[index]),
          if (index != sections.length - 1) const SizedBox(height: 14),
        ],
      ],
    ),
  );
}

class _LegalSection extends StatelessWidget {
  const _LegalSection({required this.data});

  final _LegalSectionData data;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(data.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(data.body, style: const TextStyle(height: 1.55)),
        ],
      ),
    ),
  );
}

class _AccountDeletionContent extends StatelessWidget {
  const _AccountDeletionContent({required this.signedIn});

  final bool signedIn;

  @override
  Widget build(BuildContext context) => PageFrame(
    maxWidth: 780,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          eyebrow: 'Account',
          title: 'Delete your account',
          description:
              'Account deletion is available inside the app and does not '
              'require contacting support.',
        ),
        const SizedBox(height: 28),
        const _LegalSection(
          data: _LegalSectionData(
            'How to delete',
            'Sign in, open Player, choose Delete account, and confirm the '
                'permanent action. On the web, the same steps are available '
                'from this application’s hosted version.',
          ),
        ),
        const SizedBox(height: 14),
        const _LegalSection(
          data: _LegalSectionData(
            'What deletion does',
            'The authentication account and recovery email are deleted. '
                'Waiting matches are cancelled and active matches are treated '
                'as resignations. Historical match records may be retained '
                'for game integrity, but player labels and move identifiers '
                'are anonymized. Operational logs and encrypted backups age '
                'out under the periods described in the Privacy Policy.',
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: () =>
              context.go(signedIn ? '/player' : '/login?returnTo=/player'),
          icon: Icon(signedIn ? Icons.person_outline : Icons.login),
          label: Text(
            signedIn ? 'Open player settings' : 'Sign in to delete account',
          ),
        ),
      ],
    ),
  );
}

class _LegalSectionData {
  const _LegalSectionData(this.title, this.body);

  final String title;
  final String body;
}

const _privacySections = [
  _LegalSectionData(
    'Local play',
    'Local matches run on your device. They do not require an account and are '
        'not sent to the online service. The current release does not include '
        'advertising or third-party analytics.',
  ),
  _LegalSectionData(
    'Account information',
    'If you create an online account, the service processes your username, '
        'display name, email address, account verification state, and '
        'authentication tokens. Password handling is delegated to the '
        'identity provider; the game service does not store plaintext '
        'passwords. A Google account is processed only if optional Google '
        'sign-in is enabled and you choose it.',
  ),
  _LegalSectionData(
    'Game and service data',
    'The service stores match rules, board states, moves, results, internal '
        'player identifiers, display names, and matchmaking records so it can '
        'run and verify online games. Your display name is shown to players '
        'you are matched with; your username and email address are not. '
        'Security and reliability logs may include time, route, status, '
        'request ID, source IP address, and device or platform category; '
        'request bodies and authentication secrets are not intentionally '
        'logged.',
  ),
  _LegalSectionData(
    'Use and sharing',
    'Data is used to provide accounts, matchmaking, online play, recovery, '
        'abuse prevention, security, and service operations. Display names are '
        'shared with matched opponents. Other data is shared only with '
        'infrastructure and identity providers needed to operate those '
        'functions, or when legally required. It is not sold and is not used '
        'for targeted advertising.',
  ),
  _LegalSectionData(
    'Retention and deletion',
    'Account data is kept while the account exists. Matchmaking records expire '
        'within about ten minutes and one-time login exchanges within about '
        'one hour; command-deduplication records expire after about 24 hours. '
        'Operational logs use a 30-day default retention and encrypted '
        'point-in-time backups can retain deleted table data for up to 35 '
        'days. Deleting an account removes its identity data and anonymizes '
        'retained match history as described on the Account deletion page.',
  ),
  _LegalSectionData(
    'Your choices',
    'You can play locally without an account, decline optional Google sign-in, '
        'sign out to remove the local session, or permanently delete the '
        'account from Player. The service operator is Shen Zhuoran / CMSFlash. '
        'For privacy or support questions, use '
        'https://cmsflash.github.io/contact/.',
  ),
];

const _termsSections = [
  _LegalSectionData(
    'Eligibility and accounts',
    'You must be permitted to use online services in your location. Provide '
        'accurate recovery information, protect your credentials, and do not '
        'share access tokens or confirmation codes. One person may not use '
        'accounts to evade service safeguards.',
  ),
  _LegalSectionData(
    'Fair play',
    'Do not automate abusive traffic, exploit defects, interfere with other '
        'players, probe accounts, or attempt to manipulate server-authoritative '
        'match results. Your display name is shown to matched opponents, so it '
        'must not impersonate, threaten, harass, or contain abusive content. '
        'Your username and email address are not presented to opponents.',
  ),
  _LegalSectionData(
    'Service availability',
    'Local play is provided as part of the installed application. Online '
        'features may be interrupted for maintenance, security, network '
        'conditions, regional availability, or discontinued with reasonable '
        'notice where practical. No uninterrupted matchmaking population is '
        'guaranteed.',
  ),
  _LegalSectionData(
    'Game records',
    'The server is authoritative for online moves and outcomes. Completed '
        'match records may be retained in anonymized form for replay integrity, '
        'security, dispute investigation, and aggregate operations.',
  ),
  _LegalSectionData(
    'Changes and termination',
    'Access may be limited for abuse, security risk, or material violation of '
        'these terms. You may stop using the service or delete your account at '
        'any time. Material policy updates will be reflected by a new '
        'effective date in the application.',
  ),
  _LegalSectionData(
    'Contact and applicable terms',
    'The service operator is Shen Zhuoran / CMSFlash. Support is available at '
        'https://cmsflash.github.io/contact/. Mandatory consumer rights in '
        'your jurisdiction are not limited by this document.',
  ),
];
