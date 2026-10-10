# AGENTS.md — sethucms-sdk-dart

Dart and Flutter client SDK.

This repository is one part of SethuCMS. **Read `../sethucms/AGENTS.md` first** for the whole picture, the security rules that must not be broken, and the working agreements.

## Build and test

```sh
dart pub get && dart analyze && dart test
```

## Notes

UNVERIFIED so far: it was written but never run. Run the three commands first and fix what they report.

## Always

- Run the tests for what you changed and say what you ran and what you could not run.
- Do not `git commit` or `git push` unless the owner asks.
- Never print or store a secret, token or password.
