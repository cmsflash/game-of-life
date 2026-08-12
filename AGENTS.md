# Repository instructions

- Keep the repository continuously able to push and deploy to production.
- Any development change presented to the user for review must be committed,
  pushed to `main`, deployed to production, and verified at the live production
  URL unless the user explicitly directs otherwise.
- During this development phase, the user reviews only the production version;
  do not ask the user to review a local or staging build.
- Keep production credentials and other secrets out of the repository.
