# Public CI smoke test

この一時的な文書変更は、公開repositoryの`pull_request` CI trust boundaryを確認するためのsame-repository smoke testです。mainへmergeしません。

```text
PRODUCT_SOURCE_CHANGES = 0
DEPENDENCY_CHANGES = 0
WORKFLOW_CHANGES = 0
SIGNING = NO
DEPLOY = NO
```

このtestはtrue fork PRの代替ではありません。authorized secondary fork targetを利用できるようになった時点で、別途true fork smoke testが必要です。
