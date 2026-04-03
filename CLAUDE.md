# CLAUDE.md

## Zenn CLIコマンド

```bash
npx zenn new:article                          # 記事作成（ランダムslug）
npx zenn new:article --slug my-article --title "タイトル" --type tech --emoji "🔥"
npx zenn preview                              # プレビュー（localhost:8000）
npx zenn list:articles                        # 記事一覧
```

slug要件: `a-z0-9`、ハイフン、アンダースコアで12〜50字

## 記事フロントマター

```yaml
---
title: "記事タイトル"
emoji: "⚡"
type: "tech"                   # tech / idea
topics: ["react", "typescript"]
published: true                # true: 公開 / false: 下書き
published_at: 2026-04-01 09:00 # 公開予約（JST、省略可）
publication_name: "three_dots_inc"  # 必須
---
```

## Zenn独自Markdown記法

- `:::message` / `:::message alert` / `:::details タイトル` で囲む
- コードブロックのファイル名: `` ```ts:src/index.ts ``
- diff表示: `` ```diff ts ``（行頭に `+` `-` ` ` が必須）
- 外部埋め込み: URL単独行でカード化
- 画像幅指定: `![alt](URL =250x)` / 数式: KaTeX対応

## 公開フロー

1. `npx zenn new:article` → `articles/` 配下を編集 → `npx zenn preview` で確認
2. `published: true` にしてmainへpush → 自動デプロイ
- `published: false` のままpushしても公開されない
- slugを変更すると別記事扱い

---

# 記事作成プロジェクト

## 概要

Reviewer（レビュー・品質評価・スタイルガイド管理）とWriter（記事執筆）の2エージェントで、10回のイテレーションを通じて記事品質を向上させる。

## プロセスフロー

### Phase 1: 初期セットアップ
1. `npx zenn new:article` で新規ファイル作成（`publication_name: "three_dots_inc"` 必須）
2. Reviewerが情報収集（公式ドキュメント・GitHub・関連記事）
3. Reviewerがスタイルガイド作成

### Phase 2: イテレーティブ改善（10回）
各回: Writer が記事執筆 → Reviewer がレビュー（10点満点）・フィードバック・スタイルガイド更新

### Phase 3: AI開示
記事末尾にAIでの記事作成を試している旨を記載

### 本文先頭メッセージ
フロントマター直後に挿入:
```markdown
:::message
この記事は [Claude Code](https://claude.ai/code) を使用して記述しています。
:::
```

### Phase 4: 公開
`published: true` に変更

## レビュー基準（各2点満点、計10点）

参考: [AI が技術記事を書く時代のレビューについて](https://zenn.dev/uhyo/articles/ai-writes-tech-articles-202510)

1. **技術的正確性** — 実装例・説明の正確さ
2. **自然な文章フロー** — 読みやすさ・論理的な流れ
3. **記事構成・ナラティブ** — 分かりやすい構成・物語性
4. **実践的価値** — 読者が活用できる具体的情報
5. **人間らしさ・個性** — 個人的経験・見解、人間らしい「不完全さ」

**目標**: 8.5点以上（合格）/ 9.0点以上（優秀）

## 注意事項

- Reviewerは厳格で建設的なフィードバックを提供
- 実装例はすべて検証済みのものを使用
- 最終成果物: 高品質な技術記事 + スタイルガイド + イテレーションログ
