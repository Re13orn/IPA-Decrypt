# Contributing

[English](CONTRIBUTING.md) · [简体中文](CONTRIBUTING.zh-CN.md)

Read the [project overview](README.md), [build guide](docs/en/BUILDING.md), and [known issues](docs/en/KNOWN_ISSUES.md). Contributions to this public repository are welcome through issues, discussions, and pull requests.

## Development

- Use synthetic accounts, `example.invalid` domains, and synthetic credentials in automated tests.
- Validate existing records when changing data models or paths.
- Keep account labels separate from credential bytes; deduplicate by actual content.
- Test account authentication, session creation, and downloads separately when changing authentication.
- Preserve provenance, fixed versions, copyright, and license notices for third-party inputs.
- Commit source, documentation, and necessary test fixtures. Keep signing material, user data, generated libraries, caches, and install packages out of source commits.

## Checks

```sh
python3 scripts/verify-dependencies.py
bash scripts/test.sh
```

Run platform builds and package checks appropriate to the change. Record the environment, results, and unverified scope. Documentation-only edits need link/content checks rather than an app rebuild.

## Pull requests

Describe the concrete trigger, changed behavior, compatibility impact, and validation. Add regression coverage for data migrations and file-processing changes.

## Reports

Use [Discussions](https://github.com/Re13orn/IPA-Decrypt/discussions) for questions and ideas. [Report a bug](https://github.com/Re13orn/IPA-Decrypt/issues/new/choose) with app and OS versions, the workflow, diagnostic stage code, and reproduction steps. English and 简体中文 are both welcome. See [SECURITY.md](SECURITY.md) for sensitive reports.

## Releases

- Documentation, screenshots, and repository settings do not require an app version bump.
- Group related compatible fixes into a release with a clear purpose.
- Installation, login, and file-processing blockers may need a separate hotfix.
- Version the two platforms independently; link to a validated existing asset when that platform has not changed.
- Release notes describe behavior changes, validation evidence, and remaining limits.
