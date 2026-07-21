# Security policy

Do not open public issues containing credentials, access tokens, private match
data, or account information. Report a suspected vulnerability privately to the
repository owner.

## Deployment requirements

- Store Google OAuth credentials and signing material in AWS Secrets Manager or
  encrypted deployment parameters.
- Never commit `.env` files, Cognito client secrets, AWS credentials, or mobile
  signing material.
- Terminate TLS at API Gateway and reject plaintext production origins.
- Restrict CORS to the deployed web origins.
- Enable DynamoDB point-in-time recovery, CloudWatch retention, API throttling,
  and alarms before opening registration publicly.
- Treat the server-produced match state as authoritative. Clients must never be
  able to write state snapshots directly.
- Rotate compromised OAuth, Cognito, and AWS credentials immediately.

Password processing is delegated to Amazon Cognito. The application backend
must not persist or log plaintext passwords.
