# GitHub Actions runtime evidence（実行環境証跡）

2026-08-25に公式`actions/checkout` repositoryを基準としてreviewしました。

```text
previous = actions/checkout v4.2.2
previous SHA = 11bd71901bbe5b1630ceea73d27597364c9af683
selected = actions/checkout v7.0.1
selected SHA = 3d3c42e5aac5ba805825da76410c181273ba90b1
selected action runtime = node24
immutable full SHA pin = YES
persist-credentials = false
```

公式latest-release APIは、2026-07-20公開のv7.0.1を返しました。review時点で`refs/tags/v7`と`refs/tags/v7.0.1`はいずれも選択した40-hex commitへresolveされ、exact-tagの`action.yml`には`runs.using: node24`と宣言されていました。

workflowはmutable tagではなくcommitへpinしています。安全性を下げるNode fallback environment variableは使用しません。

一次情報:

- [actions/checkout v7.0.1 release](https://github.com/actions/checkout/releases/tag/v7.0.1)
- [actions/checkout repository](https://github.com/actions/checkout)

