# Privacy Policy

Effective July 28, 2026.

This policy describes how The Game of Life processes information when a player
uses the local game or the optional online service.

## Local play

Local matches run on the player's device. They do not require an account and
are not sent to the online service. The current application contains no
advertising or third-party analytics.

## Information processed for online play

An online account includes a username, display name, email address,
verification state, internal account identifier, and authentication tokens.
Password handling is delegated to the configured identity provider; the game
service does not store plaintext passwords. Google account data is processed
only when optional Google sign-in is enabled and the player chooses it.

The online service stores match rules, board states, moves, results, internal
player identifiers, and short-lived matchmaking records. User-entered names
are not shown to opponents.

Security and reliability logs may include request time, route, status, request
identifier, source IP address, response size, and platform category. Request
bodies, access tokens, refresh tokens, passwords, confirmation codes, and OAuth
exchange codes are not intentionally logged.

## Purposes and sharing

Information is used to provide accounts, recovery, matchmaking, online play,
replays, abuse prevention, security, and service operations. It is disclosed
only to infrastructure and identity providers needed for those functions, or
when legally required. It is not sold and is not used for targeted advertising.

## Retention and deletion

- Account information is kept while the account exists.
- Waiting matchmaking entries expire after about 10 minutes and result entries
  after about one hour.
- One-time login exchanges expire after about five minutes; the backing
  records are eligible for automatic removal.
- Command-deduplication records expire after about 24 hours.
- Operational logs use a 30-day default retention.
- DynamoDB point-in-time recovery can retain deleted table data for up to 35
  days before it ages out.

A signed-in player can permanently delete an account from **Profile → Delete
account**. Deletion removes the identity account and recovery email, cancels
waiting matches, treats active matches as resignations, removes short-lived
player records, and anonymizes player labels and move identifiers in retained
match history. Limited operational logs and encrypted backups age out under
the periods above.

The hosted web application must expose `/account-deletion` as the external
account-deletion information page required by app stores.

## Player choices and contact

Players can use local play without an account, decline optional Google
sign-in, sign out to remove the local session, or delete the account. The
service operator is **Shen Zhuoran / CMSFlash**. For support or privacy
requests that cannot be completed in the app, use the public
[support page](https://cmsflash.github.io/contact/).
