# AWS deployment

The production stack is defined by [`infra/template.yaml`](../infra/template.yaml).
It deploys one regional HTTPS API, a container Lambda containing both the
FastAPI service and compiled Dart engine, a retained DynamoDB table, a retained
Cognito user pool, and the logs and alarms described in
[`operations.md`](operations.md).

## Prerequisites

- An AWS account and AWS CLI credentials authorized to create the resources in
  the template, including IAM roles, ECR repositories, Lambda, API Gateway,
  DynamoDB, Cognito, Secrets Manager, CloudWatch, SNS, and optional Route 53.
- Docker running locally. The Lambda image compiles the canonical Dart engine
  inside Docker, so the host does not need Dart for a deployment build.
- AWS SAM CLI 1.100 or newer.
- A globally unique, lowercase Cognito domain prefix.
- For a custom API hostname, a public ACM certificate in the deployment region.

Choose the region after testing the actual target networks. Hong Kong
(`ap-east-1`), Tokyo (`ap-northeast-1`), and Singapore (`ap-southeast-1`) are
reasonable canary candidates, but no AWS region is guaranteed reachable from
every mainland network. Follow [`mainland-validation.md`](mainland-validation.md)
before committing production DNS.

## First deployment

From the repository root:

```bash
cp infra/samconfig.example.toml samconfig.toml
```

Edit the copied file. At minimum, select a region and replace the placeholder
`CognitoDomainPrefix`. `samconfig.toml` is gitignored and must not contain a
Google client secret. Then validate, build, and deploy:

```bash
infra/validate.sh
sam build --config-env production
sam deploy --guided --config-env production
```

Accept `CAPABILITY_IAM` when prompted. Keep change-set confirmation enabled.
SAM creates or selects an ECR repository for the image when
`resolve_image_repos` is enabled.

The default stack intentionally has deletion protection enabled and retains the
user pool, table, generated application secrets, and log groups if the stack is
deleted. For an ephemeral non-production stack, explicitly pass
`EnableDeletionProtection=false`; retention policies still apply.

Retrieve the values needed by the client:

```bash
aws cloudformation describe-stacks \
  --stack-name the-game-of-life-production \
  --region ap-east-1 \
  --query 'Stacks[0].Outputs' \
  --output table
```

Point Flutter at the `ApiBaseUrl` output:

```bash
flutter run \
  --dart-define=API_BASE_URL=https://REPLACE-WITH-API-BASE-URL
```

Do not add a trailing slash to `API_BASE_URL`.

## Google login

Username/password registration, verification, recovery, and login do not
depend on Google. They remain the primary fallback where Google is unavailable.
Google login is enabled only when both `GoogleClientId` and
`GoogleClientSecretArn` are set.

1. Decide the AWS region and Cognito domain prefix.
2. In Google Cloud, create an OAuth 2.0 Web application client.
3. Add this exact authorized redirect URI in Google Cloud:

   ```text
   https://COGNITO-PREFIX.auth.AWS-REGION.amazoncognito.com/oauth2/idpresponse
   ```

4. Store the Google client secret as the entire `SecretString` of an AWS
   Secrets Manager secret in the same region. Pass only that secret's ARN as
   `GoogleClientSecretArn`; never put the secret in `samconfig.toml`.
5. Pass the non-secret Google client ID as `GoogleClientId` and deploy the
   change set.

There are two distinct callbacks:

- Google redirects to Cognito's `/oauth2/idpresponse` URL above.
- Cognito redirects to the game API's
  `/v1/auth/google/callback`, which the template derives automatically.

The application then redirects to an exact URL in `AllowedReturnUrls` with a
short-lived, one-time exchange code. Add each real web callback and the native
`com.cmsflash.gameoflife://auth` callback to that allowlist. Do not use wildcard
return URLs.
The web host must rewrite application paths such as `/auth/callback` to
`index.html`; the Flutter client uses path-based routing.

## Production email

Cognito's default sender is useful for initial testing but has restrictive
delivery limits. For production verification and password-reset mail:

1. Verify a domain or email identity in the SES region supported by the user
   pool region, and request SES production access in that SES region.
2. Authorize the Cognito regional service principal to send from the identity,
   restricted to the AWS account and user-pool ARN.
3. Deploy with both `CognitoSesSourceArn` and `CognitoFromEmail`.

SES is not available in Hong Kong (`ap-east-1`). A Hong Kong user pool using
`EmailSendingAccount: DEVELOPER` must therefore use its first supported
alternate SES region, Singapore (`ap-southeast-1`). The source ARN passed to
the Hong Kong stack has this form:

```text
arn:aws:ses:ap-southeast-1:ACCOUNT-ID:identity/EMAIL-OR-DOMAIN
```

The SES identity must be in the same AWS account. Attach its sending
authorization policy in Singapore after the initial user-pool deployment; the
policy principal is `cognito-idp.ap-east-1.amazonaws.com`, and its conditions
must restrict `AWS:SourceAccount` to the account and `AWS:SourceArn` to that
specific Hong Kong user-pool ARN. Cross-region CloudFormation exports are not
available, so pass the SES ARN to this stack as a parameter. The initial stack
can use `COGNITO_DEFAULT` email until the SES identity is verified and approved.

The template switches Cognito to its `DEVELOPER` email mode only when both
values are present. A typical From value is
`The Game of Life <noreply@example.com>`.

## Custom API domain

Supply `ApiCustomDomainName` and a same-region `ApiCertificateArn` together.
If the DNS zone is in the same AWS account, also set
`CreateRoute53Records=true` and `Route53HostedZoneId`; the stack creates A and
AAAA aliases. For external DNS, use the `ApiCustomDomainTarget` stack output.

The custom domain maps to the root of the API stage, so the client base is
simply `https://api.example.com`. The regional execute-api URL remains enabled
and is emitted as `ApiExecuteUrl` for emergency diagnostics.

Set `CorsAllowedOrigins` to exact HTTPS origins for browser builds. Native
application callback schemes belong in `AllowedReturnUrls`, not CORS. The API
uses bearer tokens rather than browser cookies, so credentialed CORS is disabled;
production should still use exact origins rather than wildcards.

## Updates and rollback

For every release:

```bash
infra/validate.sh
sam build --config-env production
sam deploy --config-env production
```

Review the generated CloudFormation change set before execution. Lambda image
updates are atomic: existing environments keep the prior image while the new
environment initializes. If a release is unhealthy, redeploy the prior source
revision; do not mutate match records to compensate for application bugs.

Changing a Secrets Manager value alone does not necessarily cause
CloudFormation to refresh a dynamic reference. After rotating the Google
secret, update the Cognito identity provider in a controlled maintenance
window and deploy a stack change so CloudFormation again owns the final
configuration. Validate both Google and username/password login afterward.

## Template validation

Fast validation runs CloudFormation/SAM linting:

```bash
infra/validate.sh
```

To validate and perform the full container build:

```bash
infra/validate.sh --build
```

The latter requires Docker and compiles the Dart engine into the Lambda image.
