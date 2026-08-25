# GitHub Actions runtime evidence

Reviewed on 2026-08-25 against the official `actions/checkout` repository.

```text
previous = actions/checkout v4.2.2
previous SHA = 11bd71901bbe5b1630ceea73d27597364c9af683
selected = actions/checkout v7.0.1
selected SHA = 3d3c42e5aac5ba805825da76410c181273ba90b1
selected action runtime = node24
immutable full SHA pin = YES
persist-credentials = false
```

The official latest-release API returned v7.0.1, published 2026-07-20. Both `refs/tags/v7` and `refs/tags/v7.0.1` resolved to the selected 40-hex commit at review time, and exact-tag `action.yml` declared `runs.using: node24`.

The workflow pins the commit, not the mutable tag. No insecure Node fallback environment variable is used.

Primary sources:

- [actions/checkout v7.0.1 release](https://github.com/actions/checkout/releases/tag/v7.0.1)
- [actions/checkout repository](https://github.com/actions/checkout)

