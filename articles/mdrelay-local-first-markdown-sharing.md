---
title: "ローカルファーストなMarkdown共有ツール「mdrelay」を作っている"
emoji: "📡"
type: "tech"
topics: ["markdown", "typescript", "cloudflare", "cli"]
published: true
---

:::message
この記事は [Claude Code](https://claude.ai/code) を使用して記述しています。
:::

## Markdownが手元から離れていくストレス

設計メモをMarkdownで書いて、チームに共有するためにドキュメント共有サービスにコピペする。レビューコメントがWeb上に付く。それをローカルに反映して……結局ローカルのファイルは放置してWebでしか編集しなくなる。ターミナルとエディタで生きている人間としては、これが地味にずっとストレスだった。

**mdrelay** は、この「共有するとローカルから離れていく」問題への自分なりの解だ。まだMVP段階の開発中プロダクトだが、設計思想と技術的な意思決定について書いてみる。

## コンセプト: 共有は副作用であるべき

mdrelayの設計思想はシンプルだ。

> **ローカルのMarkdownファイルをそのまま共有する。ソースはローカルに残り、共有は副作用。**

既存のドキュメント共有ツールは「Webが主、ローカルが従」の構造だ。mdrelayはこれを逆転させる。

- **ソースはローカル**: `.md` ファイルは手元のエディタで書く。これまで通り
- **共有はCLIで**: ターミナルから `mdrelay publish` するだけ
- **Webはビューアー**: ブラウザは閲覧とコメントのためだけ

Gitがソースコードの共有を「pushという副作用」にしたように、mdrelayはドキュメント共有を「publishという副作用」にする。

目指しているワークフローはこうだ。

```bash
# 手元のエディタで設計書を書く（いつも通り）
$ vim design.md

# 1コマンドで共有URLを取得
$ mdrelay publish design.md
→ https://mdrelay.app/d/abc123

# URLをチームに渡す。相手はログイン不要で閲覧・コメントできる
# コメントが付いたらCLIで確認
$ mdrelay comments abc123

# ローカルで修正して再publish。ソースは常に手元にある
$ vim design.md
$ mdrelay publish design.md --update abc123
```

ファイルを書く→publishする→URLを渡す→コメントをもらう→手元で直す。このサイクルがターミナルで完結する。正直に言うと、このフローはまだ完成していない。CLIは開発中で、現時点ではWeb UIからの公開のみ動いている。ただ、この体験を実現するために技術選定から作り込んでいる。

## 技術スタックの全体像

まず全体の構成を示す。Turborepoのモノレポで、全パッケージをTypeScriptに統一した。

```
packages/
  api/      # Cloudflare Workers + Hono + ORPC
  web/      # React + Vite + shadcn/ui
  cli/      # CLIツール（開発中）
  shared/   # Zodスキーマ・共通型定義
```

`shared/` パッケージがこの構成の要だ。ここにZodスキーマを置くことで、`api/` のORPCプロシージャのinputバリデーションと `web/` のフォームバリデーションが同じスキーマを参照する。バックエンドで「必須項目を追加」した瞬間にフロントのフォームでも型エラーが出るので、APIとUIの齟齬が構造的に起きない。

以下、各要素の選定理由と実際にハマったポイントを書いていく。

## なぜORPCを選んだか

一番語りたいのはAPI層の設計だ。

### tRPCとの比較

フロントエンドとバックエンドの間の型安全性をどう担保するか。最初はtRPCを検討した。実績があるし、エコシステムも大きい。ただ、調べていくうちに[ORPC](https://orpc.unnoq.com/)の存在を知った。

tRPCにもfetchアダプターやCloudflare Workers向けのドキュメントはある。動かないわけではない。ただ、自分が評価した時点では、ORPCの方がfetch APIファーストで設計されている印象を受けた。tRPCはもともとNode.jsのHTTPサーバー上で進化してきた経緯があり、Workersアダプターは後付け感があった。ORPCは最初からfetch APIベースで、Workersに載せるときの不安が少なかった。

### 新しいOSSに賭けるリスク

正直なところ、ORPCはtRPCに比べてスター数もドキュメントも少なく、プロダクションでの事例も限られている。実際、開発中にAPIの破壊的変更に遭遇した。今まで動いていたコードがビルドエラーになり、ドキュメントにも移行ガイドがなく、深夜にORPCのソースコードを読み漁って原因を突き止めた。一瞬「やっぱりtRPCに戻そうか」と思ったが、変更内容を理解してみるとAPIが整理されて良くなっていた。結果的には乗り越えたが、個人プロダクトだから許容できるリスクだ。チーム開発なら慎重になるべきポイントだと思う。

### ORPCの書き味

ORPCのサーバーインスタンス（`os`）を起点に、ミドルウェア→バリデーション→ハンドラをチェーンする書き味はこんな感じだ（※APIは執筆時点のもの。ORPCは活発に開発されており、最新のAPIは[公式ドキュメント](https://orpc.unnoq.com/)を参照してほしい）。

```typescript
import { os } from "@orpc/server";
import { z } from "zod";

// ミドルウェアでユーザー認証を挟み、
// Zodでinputをバリデーションし、
// handlerでビジネスロジックを書く
const publishDocument = os
  .use(authMiddleware) // 認証ミドルウェア
  .input(
    z.object({
      content: z.string().min(1),
      visibility: z.enum(["public", "private"]),
    })
  )
  .handler(async ({ input, context }) => {
    const doc = await db
      .insert(documents)
      .values({
        content: input.content,
        visibility: input.visibility,
        ownerId: context.user.id,
      })
      .returning();
    return { id: doc.id, url: `https://mdrelay.app/d/${doc.id}` };
  });

// ルーターにまとめる
const router = os.router({
  document: os.router({
    publish: publishDocument,
    // list, delete, ...
  }),
});
```

フロントエンド側では、このルーターの型をインポートするだけで、inputもoutputもすべて型推論が効く。OpenAPIスキーマの生成やクライアント用型定義の手動同期が不要になる。個人開発ではこういう「手間を省ける」選定が効いてくる。

## Cloudflare Workersの制約と向き合う

サーバーレス実行環境にはCloudflare Workersを選んだ。個人プロジェクトとしてコストを抑えつつ、エッジデプロイでパフォーマンスも確保できるのが理由だ。

ただし、Workersには独特の制約がある。ランタイムがV8 isolateベースでNode.jsとは異なるため、ライブラリ選定で「Workers対応しているか」が最初のフィルタになった。

### Better Authの統合でハマったこと

認証基盤は正直一番迷った。最初はClerkで始めたが、セルフホストできない点が気になり始めて途中で乗り換えた。マネージドで楽なのは確かだったが、個人プロダクトの認証基盤を外部SaaSに完全に依存するのは、料金体系の変更リスクも含めて怖かった。Auth.jsも試したがWorkers対応が安定しなかった（調べた時点の話）。最終的にBetter AuthというOSSの認証ライブラリに落ち着いた。セルフホスト可能で、Workers対応を謳っていたのが決め手だ。

ただ、実際に統合すると初期化パターンでハマった。

Node.js環境では、アプリ起動時にグローバルでAuthインスタンスを初期化するのが一般的だ。

```typescript
// ❌ Node.jsの一般的なパターン — Workersでは使えない
// アプリ起動時に一度だけ実行される
const db = drizzle(process.env.DATABASE_URL);
const auth = createAuth({ database: db });

export default app; // 以降のリクエストでauth, dbを使い回す
```

Workersではこれが動かない。`process.env` が存在しないのはもちろん、グローバルスコープでの初期化自体が非推奨だ。環境変数は `env` パラメータとしてリクエストごとに渡される。

```typescript
// ✅ Workers環境: リクエストごとに初期化する
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // env はリクエストハンドラの引数として受け取る
    const db = drizzle(neon(env.DATABASE_URL));
    const auth = createAuth({ database: db });

    return router.handle(request, { db, auth });
  },
};
```

「リクエストごとにDBコネクションとAuthインスタンスを作るのか？」という疑問は当然出てくる。NeonのようなHTTPベースのサーバーレスDBでは、従来のTCPコネクションプーリングとは異なり、各リクエストが独立したHTTPリクエストとしてDBにアクセスする。コネクション状態を保持しないステートレスな接続なので、リクエストごとのインスタンス生成は実用上問題にならなかった。

もう一つ、Better Auth固有のハマりポイントとして `trustedOrigins` の設定がある。Workers環境ではリクエストのオリジン検証が厳密で、`createAuth` に `trustedOrigins` を明示的に渡さないとOAuthのコールバックが弾かれた。ローカル開発環境と本番環境でオリジンが異なるため、`env` から動的に設定する必要があり、地味に時間を取られた。

### Drizzle ORMを選んだ理由

ORMはDrizzle ORMを選んだ。比較対象はPrismaだったが、PrismaはWorkers対応にData Proxyが必要で構成が複雑になる。Drizzleは軽量で、HTTP経由のサーバーレスDB接続（Neon等）がネイティブにサポートされている。

マイグレーション管理もシンプルだ。`drizzle-kit` でスキーマからSQLを生成して適用するだけ。Prismaのように独自のマイグレーションエンジンを持たず、生成されたSQLが見えるので安心感がある。

## 現在の状態とこれから

**今動いているもの**: Web UIでのMarkdown公開共有、閲覧権限管理、ネスト対応コメント、ダッシュボード、メール/パスワード認証。

**これから作るもの**: 一番重要なのはCLIだ。前述のワークフローで示した `publish` や `comments` の実装が最優先。`gh` CLIのデバイスフローを参考に、ブラウザでOAuth認証→CLIにトークンが返る流れを設計している。将来的には `--watch` でファイル変更の自動同期も実現したい。

その先には、変更ログ・承認ワークフロー（設計書レビュー向け）、プロジェクト機能（複数ドキュメントの一括管理）、TUI対応を考えている。料金モデルはCLIとコメントをFreeとし、プライベート共有や承認ワークフローをPro機能とする予定だ。

## おわりに

mdrelayは「ローカルのMarkdownを、ローカルのまま共有する」という、ニッチな課題に取り組んでいる。コンセプトの核であるCLIがまだ動いていない時点で「作っている」としか言えないし、ORPCのような新しめの技術に賭けていることへの不安もある。

ただ、「共有するたびにローカルから離れていく」ストレスは、CLIで生活している開発者なら共感してもらえるんじゃないかと思う。まずはCLIを仕上げて、自分が毎日使えるものにするのが直近のゴールだ。

技術スタックの深掘り——ORPC導入の詳細やCloudflare Workers上でのBetter Auth統合——は個別記事で書いていきたい。「こういうユースケースならこの構成はどう？」「自分も似たことやってる」等のフィードバックがあればコメントで教えてほしい。
