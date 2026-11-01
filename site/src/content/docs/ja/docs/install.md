---
title: インストール
description: 必要なもの、インストールの手順、アンインストールの方法。
sidebar:
  order: 2
---

## 必要なもの

- macOS 26 以降、Apple Silicon
- Git
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) か [Codex](https://github.com/openai/codex)、または両方。Weir はお使いのものを、そのアカウントのまま動かします。

サイドバーに PR の状態を出したい場合は、`gh` か `glab` を入れてサインインしてください。なくても Weir は動きます。

## インストールする

1. [最新のリリース](https://github.com/nek0der/weir/releases/latest)から DMG をダウンロードします。
2. DMG を開いて、`Weir.app` を `/Applications` にドラッグします。
3. Weir を開きます。

リリース版は署名と公証を受けているので、開発元が不明なアプリとして macOS に止められることはありません。初回は、ダウンロードしたアプリを開くかどうかの確認が出ます。

Weir は承認のための小さなバックグラウンドサービスを登録します。**システム設定 → 一般 → ログイン項目と機能拡張** に表示されます。オフにすると、承認にはすべて各エージェントのプロンプトで答えます。

次は[最初のエージェントを動かしましょう](/ja/docs/quick-start/)。

## アップデートする

Weir は 1 日に 1 回アップデートを確認します。インストールは、選んだときにだけ行います。すぐに確認するには、**Weir** メニューの **アップデートを確認…** を選びます。

## アンインストールする

1. Weir を終了して、`Weir.app` をゴミ箱に入れます。
2. `~/Library/Application Support/Weir/` と `~/Library/Preferences/com.nekoder.Weir.plist` を削除します。
3. **ログイン項目と機能拡張** に Weir が残っていたら、オフにします。

各リポジトリには、ターンのスナップショットも残っています。消すには、リポジトリで次を実行します。

```bash
git for-each-ref --format='%(refname)' refs/weir/ | xargs -n1 git update-ref -d
```

続けて、`git rev-parse --git-common-dir` が表示するディレクトリと、その `worktrees/` の下の各フォルダにある `weir` フォルダを削除します。

Weir で作ったワークツリーは普通の Git のワークツリーです。不要なものは `git worktree remove` で削除してください。
