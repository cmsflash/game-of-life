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
                    onPressed: () => context.go('/settings'),
                    child: const Text('Settings'),
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
            'Sign in, open Settings, choose Delete account, and confirm the '
                'permanent action. On the web, the same steps are available '
                'from this application’s hosted version.',
          ),
        ),
        const SizedBox(height: 14),
        const _LegalSection(
          data: _LegalSectionData(
            'What deletion does',
            'The authentication account and recovery email are deleted. '
                'The public search profile, rating and player stats, friend '
                'relationships, requests, and pending challenges are removed. '
                'Registered notification subscriptions for the account are '
                'removed and this device is deactivated. '
                'Waiting matches are cancelled and active matches are treated '
                'as resignations. Historical match records may be retained '
                'for game integrity, but player labels and move identifiers '
                'are anonymized; anonymized outcomes may remain in aggregate '
                'service records. Operational logs and encrypted backups age '
                'out under the periods described in the Privacy Policy.',
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: () =>
              context.go(signedIn ? '/settings' : '/login?returnTo=/settings'),
          icon: Icon(signedIn ? Icons.person_outline : Icons.login),
          label: Text(signedIn ? 'Open settings' : 'Sign in to delete account'),
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
    'Public profile and Social',
    'Your display name, profile picture, and current Elo rating are searchable '
        'by signed-in players. Search results and Social do not expose your '
        'username or email address. The service stores friend relationships, '
        'incoming and outgoing requests, and pending rated challenges so you '
        'can play directly with friends. Challenges expire after seven days.',
  ),
  _LegalSectionData(
    'Profile picture storage and delivery',
    'Your uploaded profile picture is stored as a private object at rest. The '
        'service shares it through a public, versioned API photo URL. Replacing '
        'or removing a picture makes its old URL immediately fail closed with '
        'a 404 response, although shared caches may retain a prior response for '
        'up to 60 seconds. Failed or superseded upload objects are deleted '
        'immediately on a best-effort basis. Account deletion immediately '
        'prevents public delivery and makes a best-effort attempt to remove its '
        'private objects. A private object left by a racing or failed deletion '
        'remains inaccessible; normal cleanup checks it after about 15 minutes. '
        'Pending or orphan-tagged objects become eligible for storage lifecycle '
        'cleanup after about one day; that timing is not a guaranteed deletion '
        'deadline for every rare race. Durable retries and alarms cover rare '
        'promotion or cleanup races for operator remediation. Cleanup and '
        'dead-letter queue metadata contains only an identity-free owner digest '
        'and object key and may remain up to the configured maximum, currently '
        '14 days.',
  ),
  _LegalSectionData(
    'Game, rating, and service data',
    'The service stores match rules, board states, moves, results, internal '
        'player identifiers, display names, matchmaking records, ratings, and '
        'aggregate player stats so it can run and verify online games. Every '
        'remote game is rated; local games are unrated and excluded from '
        'online stats. Win rate uses all completed remote games, including '
        'draws in its denominator. A kill is every opponent-colored cell that '
        'dies, regardless of which player caused the death. '
        'Security and reliability logs may include time, route, status, '
        'request ID, source IP address, and device or platform category; '
        'request bodies and authentication secrets are not intentionally '
        'logged.',
  ),
  _LegalSectionData(
    'Turn notifications',
    'If you are signed in and have granted notification permission in your '
        'browser or device, the app automatically registers and refreshes a '
        'push endpoint for turn alerts. The service stores an installation '
        'identifier, push provider and endpoint or token, platform, locale, '
        'and time-zone information needed to deliver an immediate alert and '
        'reminders after 8, 24, and 72 hours. The app does not request '
        'permission until you choose Allow notifications. You can revoke '
        'permission in browser or system settings; the app reconciles that '
        'choice when it resumes. One-time reminder jobs carry only match, '
        'revision, turn-start, and reminder timing—not a player identity or '
        'push credentials. The recipient is derived from the authoritative '
        'match, and stale turns are suppressed before delivery. Signing '
        'out or deleting the account removes the server subscription and '
        'deactivates the local endpoint on a best-effort basis.',
  ),
  _LegalSectionData(
    'Use and sharing',
    'Data is used to provide accounts, matchmaking, online play, recovery, '
        'Social, ratings and stats, abuse prevention, security, and service '
        'operations. Display names, profile pictures, and ratings are shared '
        'with signed-in players through public search and with existing '
        'friends and online opponents. Other data '
        'is shared only with '
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
        'days. Push subscriptions remain only while the signed-in installation '
        'is active and permission remains granted; delivery-deduplication '
        'records expire after about seven days. Deleting an account removes '
        'its identity and public search '
        'profile, Social graph, pending requests and challenges, and personal '
        'rating and stats. Retained match history is anonymized; anonymized '
        'outcomes and aggregates may remain for game and rating integrity as '
        'described on the Account deletion page.',
  ),
  _LegalSectionData(
    'Your choices',
    'You can play locally without an account, decline optional Google sign-in, '
        'use browser or system settings to disable notifications, sign out to '
        'remove the local session and notification subscription, or '
        'permanently delete the account from Settings. The service operator is '
        'Shen Zhuoran / CMSFlash. '
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
        'match results or ratings. Your display name, profile picture, and Elo '
        'rating are visible in player search to signed-in players and are also '
        'visible to friends and opponents, so the display name '
        'must not impersonate, threaten, harass, or contain abusive content. '
        'Your username and email address are not presented to opponents.',
  ),
  _LegalSectionData(
    'Profile picture rights and rules',
    'If you upload a profile picture, you confirm that you own it or have '
        'permission to use it. You grant the service a limited, non-exclusive, '
        'worldwide, royalty-free license solely to receive, scan, process, '
        'crop, re-encode, host, reproduce, and publicly display your current '
        'profile picture as needed to operate the service. This license ends '
        'when you remove the picture or delete your account, subject only to '
        'the cache, cleanup, and backup retention disclosed in the Privacy '
        'Policy. Do not upload a picture that is unlawful, abusive, hateful, '
        'threatening, impersonating, privacy-invasive, sexually exploitative, '
        'or that infringes intellectual-property or other rights. The service '
        'may remove or disable a picture and restrict access when reasonably '
        'needed for a violation, security need, or legal requirement.',
  ),
  _LegalSectionData(
    'Service availability',
    'Local play is provided as part of the installed application. Online '
        'features may be interrupted for maintenance, security, network '
        'conditions, regional availability, or discontinued with reasonable '
        'notice where practical. Local games are unrated. Every remote game is '
        'rated, including direct friend challenges. No uninterrupted '
        'matchmaking population is guaranteed. When notification permission '
        'is granted, signing in automatically registers this device for turn '
        'alerts; permission can be revoked in browser or system settings. '
        'Alert delivery and timing are not guaranteed.',
  ),
  _LegalSectionData(
    'Game records',
    'The server is authoritative for online moves and outcomes. Completed '
        'remote games update Elo and aggregate stats. Win rate includes draws '
        'in total completed games. A kill is an opponent-colored cell death, '
        'regardless of which player caused it. Match records may be retained '
        'in anonymized form for replay and rating integrity, security, dispute '
        'investigation, and aggregate operations.',
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
