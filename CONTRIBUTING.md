# Contributing Guidelines

Thank you for your interest in contributing to this sample. Whether it's a bug
report, new feature, correction, or additional documentation, we greatly value
feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests
to ensure we have all the necessary information to effectively respond to your
bug report or contribution.

## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest
features. When filing an issue, please check existing open, or recently closed,
issues to make sure somebody else hasn't already reported the issue. Please try
to include as much information as you can, e.g. reproducible steps, versions of
the tooling (`kubectl`, `helm`, `eksctl`, `cdk`, Node), and anything unusual
about your environment.

## Contributing via Pull Requests

Contributions via pull requests are much appreciated. Before sending us a pull
request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure
   someone else hasn't addressed the problem already.
3. `make test` passes locally (the unit/render/e2e suites). CI additionally runs
   `make lint` (actionlint + `helm lint`) — run it too if you touched workflows or the chart.
4. You open an issue to discuss any significant work — we would hate for your
   time to be wasted.

## Code of Conduct

This project has adopted the
[Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).

## Security issue notifications

If you discover a potential security issue in this project we ask that you
notify AWS/Amazon Security via our
[vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/).
Please do **not** create a public GitHub issue.

## Cutting a release

The reusable workflows are consumed by app repos via
`uses: <org>/<repo>/.github/workflows/preview.yml@<ref>`, so a **published tag**
must exist for callers to pin. On release:

1. Stamp the version + date in [CHANGELOG.md](CHANGELOG.md) (move `[Unreleased]`
   to a dated version) and bump `charts/preview-env/Chart.yaml` `version`/`appVersion`.
2. Tag it: `git tag v1.0.0 && git tag -f v1 && git push --tags` — keep a moving
   major tag (`v1`) so the documented `@v1` caller reference resolves.

## Licensing

See the [LICENSE](LICENSE) file for our project's licensing (MIT-0). We will ask
you to confirm the licensing of your contribution.
