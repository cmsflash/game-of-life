# Privacy Policy

Effective August 14, 2026.

This policy describes how The Game of Life processes information when a player
uses the local game or the optional online service.

## Local play

Local matches run on the player's device. They do not require an account and
are not sent to the online service. Match positions and the local player names
entered for them are saved on that device so games can be resumed; they can be
removed from the game's menu or by clearing the application's local data. The
current application contains no advertising or third-party analytics.

## Information processed for online play

An online account includes a username, display name, email address,
verification state, internal account identifier, and authentication tokens.
Password handling is delegated to the configured identity provider; the game
service does not store plaintext passwords. Google account data is processed
only when optional Google sign-in is enabled and the player chooses it.

The online service stores match rules, board states, moves, results, internal
player identifiers, public display-name snapshots, and short-lived matchmaking
records. A player's chosen display name is shown to online opponents and
retained with match history; login usernames and email addresses are not
included in match documents.

If a player enables turn notifications, the service stores a random
installation identifier and either a browser push endpoint with its
browser-generated encryption material or a mobile push registration token. It
may also store the device locale, time zone, and platform category. These
values are used only to deliver and troubleshoot requested game notifications;
push credentials are not returned by the account API or shown to opponents.

Security and reliability logs may include request time, route, status, request
identifier, source IP address, response size, and platform category. Request
bodies, access tokens, refresh tokens, passwords, confirmation codes, and OAuth
exchange codes are not intentionally logged.

## Purposes and sharing

Information is used to provide accounts, recovery, matchmaking, online play,
replays, abuse prevention, security, and service operations. Public display
names are disclosed to matched opponents. Other information is disclosed only
to infrastructure and identity providers needed for those functions, or when
legally required. It is not sold and is not used for targeted advertising.

## Retention and deletion

- Account information is kept while the account exists.
- Waiting matchmaking entries expire after about 10 minutes and result entries
  after about one hour. A waiting candidate includes the public display-name
  snapshot used to form a match.
- One-time login exchanges expire after about five minutes; the backing
  records are eligible for automatic removal.
- Command-deduplication records expire after about 24 hours.
- Push subscriptions remain until the installation unregisters, the provider
  reports them expired, or the account is deleted. Delivery-deduplication rows
  expire after about seven days. A credential-free account-deletion guard
  prevents racing devices from restoring a removed subscription and expires
  after about one day.
- Operational logs use a 30-day default retention.
- DynamoDB point-in-time recovery can retain deleted table data for up to 35
  days before it ages out.

A signed-in player can permanently delete an account from **Player → Delete
account**. Deletion removes the identity account and recovery email, cancels
waiting matches, treats active matches as resignations, removes short-lived
player records and push subscriptions, and anonymizes stored display names and
move identifiers in retained match history. Limited operational logs and encrypted
backups age out under the periods above. Encrypted DynamoDB stream copies of
recently changed records expire after about 24 hours; only match changes pass
the notification consumer's invocation filter.

The hosted web application must expose `/account-deletion` as the external
account-deletion information page required by app stores.

## Player choices and contact

Players can use local play without an account, decline optional Google
sign-in, sign out to remove the local session, or delete the account. The
service operator is **Shen Zhuoran / CMSFlash**. For support or privacy
requests that cannot be completed in the app, use the public
[support page](https://cmsflash.github.io/contact/).
