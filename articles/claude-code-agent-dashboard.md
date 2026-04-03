---
title: "Claude Codeマルチエージェントのリアルタイム監視ダッシュボードを作った"
emoji: "📊"
type: "tech"
topics: ["claudecode", "ai", "bash", "tmux", "ターミナル"]
published: true
publication_name: "three_dots_inc"
---

:::message
この記事は [Claude Code](https://claude.ai/code) を使用して記述しています。
:::

## はじめに

[前回の記事](https://zenn.dev/three_dots_inc/articles/claude-code-multi-agent-team)で、Claude Codeをtmuxベースのマルチエージェント開発チーム（11人編成）として運用する話を書いた。

構築してすぐ直面した問題がある。**「今、誰が何をしているか分からない」**。

tmuxのウィンドウを順番に覗いていくのは、11人×複数プロジェクトだと現実的ではない。ある日、あるプロジェクトのEngineerが許可待ちで30分止まっていたことに気づかず、その間TLもBLも「Engineer待ち」でIDLEだった。人間がボトルネックになっていたのに、それに気づく手段がなかった。

この経験から、173行のBashスクリプトでターミナルTUIのダッシュボードを作った。この記事では、設計判断と実装の詳細を書く。

## なぜターミナルTUIか

最初はObsidianベースのダッシュボードを考えた。ファイルに状態を書き出して、ObsidianのDataviewで表示する案だ。

やめた理由は単純で、**ファイルベースだと本質的にリアルタイムにならない**から。スクリプト実行時点のスナップショットでしかなく、「今まさに止まっている」ことに気づけない。

ターミナルTUIにした理由：

- **1秒間隔の自動更新**で、許可待ちのエージェントをすぐ発見できる
- **tmuxの別ペインに常時表示**できるので、作業中にチラ見できる
- **外部依存なし**。bash + tmux標準コマンドだけで完結する

## 完成形

先に完成形を見せる。

```
Agent Status Dashboard

━━━ project-a (19m) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ● pm           Screen and document output tests
 ○ 10 idle

━━━ project-b (10h 40m) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ◆ pm           [許可待ち] Project retrospective
 ● tl           Set up Biome linting with Husky pre-c...
 ● bl           Review demo HTML specifications
 ● engineer     Implement auth screen redesign...
 ○ 7 idle

2 sessions | 22 agents | 1 perm | 2 working | 9 done | 14 idle
```

各エージェントの状態を色分きアイコンで表示し、最下部にサマリーを出す。IDLEのエージェントは件数だけまとめて1行で表示する。数十体のエージェントを全部列挙するとターミナルに収まらないからだ。

## ステータス判定：Claude Codeの状態をどう外から知るか

一番苦労したのがここ。Claude Codeには稼働状態を取得する公式APIがない。かなり泥臭いハックになった。

### pane_titleとスピナー文字

Claude Codeは、tmuxの`pane_title`にスピナー文字＋タスク名をセットする。

- `⠐ Implement F1 foundation DB` — ブレイユ文字が回転 → **処理中**
- `✳ Set up Biome linting` — ✳で安定 → **完了**
- `✳ Claude Code` — タスク名が "Claude Code" → **タスク未割当**

この3パターンを判定すればいい。問題は「ブレイユ文字かどうか」をどう判定するか。

### UTF-8バイトパターンで判定する

ブレイユ文字（U+2800〜U+28FF）のUTF-8エンコーディングは、先頭バイトが `e2`、2バイト目が `a0`〜`a3` の範囲になる。これを `xxd -p` でhex変換して比較する。

```bash
parse_title() {
  local title="$1"
  local task
  task=$(echo "$title" | sed 's/^[^a-zA-Z0-9]*//;s/^[[:space:]]*//')

  # タスク名が "Claude Code" or 空 → IDLE
  if [ "$task" = "Claude Code" ] || [ -z "$task" ]; then
    echo "IDLE|—"
    return
  fi

  # 先頭3バイトをhexに変換
  local hex
  hex=$(printf '%s' "$title" | head -c 3 | xxd -p)
  local byte2="${hex:2:2}"

  # ブレイユ文字範囲(e2 a0-a3 xx)なら処理中
  if [ "${hex:0:2}" = "e2" ] && [ "$byte2" \> "9f" ] && [ "$byte2" \< "a4" ]; then
    echo "WORK|${task}"
  else
    echo "DONE|${task}"
  fi
}
```

macOSの`grep`はPerl正規表現（`\x{2800}`等）に対応していないので、正規表現で直接Unicodeコードポイントを指定する方法は使えない。hexバイト比較が確実だった。

正直、Claude Codeのバージョンアップでスピナー表示が変わったら壊れる。脆い実装だとは分かっているが、他に方法がなかった。

### 許可待ち（PERM）の検出

ここが一番実用上重要な部分。

`--dangerously-skip-permissions`を使わない運用だと、ツール実行時にユーザーの許可を求めるプロンプトが表示される。このとき、Claude Codeはスピナーを止めるため、状態としては `DONE`（✳）になる。

つまり、**スピナーだけでは許可待ちかタスク完了か区別できない**。

解決策として、`tmux capture-pane`でペインの末尾10行を取得し、許可プロンプトのキーワードを探す。

```bash
# WORK/DONEの場合、capture-paneで許可待ちを判定
if [ "$status" = "WORK" ] || [ "$status" = "DONE" ]; then
  local tail
  tail=$(tmux capture-pane -t "$target" -p 2>/dev/null | tail -10 || true)
  if echo "$tail" | grep -qiE \
    'Do you want to proceed|Allow|Deny|Yes$|No$|approve|Permission.*requires'; then
    status="PERM"
  fi
fi
```

実際の許可プロンプトはこんな表示になる：

```
 Permission rule Bash(rm *) requires confirmation for this command.
 Do you want to proceed?
 ❯ 1. Yes
   2. No
```

当初、`capture-pane`のチェックはWORK状態のエージェントにしか行っていなかった。しかし許可プロンプト表示中はスピナーが止まるためDONEと判定される。これに気づくまで、許可待ちのエージェントが「完了」として表示されていた。地味だが痛いバグだった。

### 4つのステータスまとめ

| 表示 | ステータス | 意味 | 判定方法 |
|------|-----------|------|---------|
| 緑● | WORK | 処理中 | ブレイユスピナー検出 |
| 黄● | DONE | 完了・入力待ち | ✳スピナー + タスク名あり |
| 灰○ | IDLE | タスク未割当 | pane_title = "Claude Code" |
| 赤◆ | PERM | 許可待ち（要操作） | capture-paneでプロンプト検出 |

## ちらつき問題と解決

### 素朴な実装の問題

最初は素朴に「画面クリア → 描画」でループしていた。

```bash
while true; do
  clear
  # 各エージェントの状態を出力...
  sleep 1
done
```

`clear`（`\033[2J`）を実行すると、一瞬画面が真っ白になってから描画される。1秒ごとにチカチカして目が疲れる。

### tmpファイルバッファ + カーソル上書き

解決策は、出力を一度tmpファイルに書き込み、カーソルを左上に戻してから一括出力すること。

```bash
BUF=$(mktemp)
trap 'printf "\033[?25h"; rm -f "$BUF"; exit 0' INT TERM EXIT

render() {
  {
    # 全出力をファイルに書く
    printf "${BOLD}Agent Status Dashboard${RESET}\n"
    echo ""
    # ... 各セッション・エージェントの状態を出力 ...
  } > "$BUF"

  # カーソル左上 + 残余クリア → 一括出力
  printf '\033[H\033[J'
  /bin/cat "$BUF"
}
```

ポイント：

- **`\033[H`**（カーソルを左上に戻す）と **`\033[J`**（カーソル以降をクリア）の組み合わせ。全画面クリアではなく、前フレームの残余だけ消す
- **tmpファイル経由**で出力を溜めてから一括表示。変数バッファ（`buf+=$(printf "...\n")`）だとbashの`$()`が末尾改行を食うため使えない
- **`\033[?25l`** でカーソルを非表示にし、終了時に **`\033[?25h`** で戻す

### セッション削除時の表示崩れ

もう1つの問題。`stop-team.sh`でセッションを削除すると、表示対象が減って出力行数が短くなる。すると前フレームの下部が残像として残る。

`\033[J`が「カーソル位置以降をクリア」するので、カーソルを先頭に戻してからクリアすれば前フレームの残像も消える。これで解決した。

## エージェントIDのマッピング

tmuxのペインは `window_name.pane_index`（例: `dev.0`）で識別されるが、ダッシュボードには人間が読みやすい名前で表示したい。

```bash
agent_id() {
  local win="$1" pane="$2"
  case "${win}.${pane}" in
    pm.0)    echo "pm";;
    lead.0)  echo "tl";;
    lead.1)  echo "bl";;
    lead.2)  echo "ui_lead";;
    ui.0)    echo "ui_designer";;
    ui.1)    echo "ux_architect";;
    dev.0)   echo "engineer";;
    dev.1)   echo "engineer2";;
    dev.2)   echo "engineer3";;
    dev.3)   echo "tester";;
    dev.4)   echo "qa";;
    *)       echo "${win}.${pane}";;
  esac
}
```

`team.yaml`のロール定義と合わせている。未知のペインはそのまま`window.pane`で表示するフォールバック付き。

## 実装全体の構造

173行のスクリプトの全体構造はシンプルで、以下の4ステップのループだ。

```
1. tmux list-sessions でセッション一覧取得（managerは除外）
2. 各セッションの tmux list-panes でペイン一覧取得
3. 各ペインの pane_title → parse_title() → ステータス判定
   → WORK/DONE なら capture-pane で PERM チェック
4. tmpファイルに書き込み → カーソル上書きで一括描画
5. sleep 1 → 1へ戻る
```

起動は `bash agent-status.sh` だけ。tmuxの別ウィンドウかペインで常時走らせておく。

## 運用してみて

### 許可待ち検出が一番効いた

以前は「なんか進捗ないな」→ 各ペインを巡回 →「あ、3人許可待ちだった」と気づくまでに15分かかっていた。今はダッシュボードの赤◆を見れば1秒で分かる。

11人が毎回許可を求めてくるので、ダッシュボードがなかったら人間がボタンを押す作業だけで午前中が終わる。冗談でなく。

### アップタイム表示が地味に便利

各セッションの起動時刻から経過時間を計算して表示している。「10時間走りっぱなしだからそろそろコンテキストが埋まってるかも」という判断材料になる。

```bash
format_uptime() {
  local created="$1"
  local now
  now=$(date +%s)
  local diff=$((now - created))
  local hours=$((diff / 3600))
  local mins=$(( (diff % 3600) / 60 ))
  if [ "$hours" -gt 0 ]; then
    echo "${hours}h ${mins}m"
  else
    echo "${mins}m"
  fi
}
```

### 残っている課題

- **Claude Codeの内部仕様依存**。スピナー文字が変わったら壊れる。公式のステータスAPIが欲しい
- **capture-paneの誤検出**。ペインの末尾に"Allow"を含むログが残っていると誤ってPERM判定されることがある。出現頻度は低いが、ゼロではない
- **macOSの`tmux capture-pane`に`-l`フラグがない**。行数を指定して取得できないため、全行取得してから`tail`で切っている。大きなペインだと若干遅い

## まとめ

173行のBashスクリプトで、数十体のAIエージェントのリアルタイム監視ができるようになった。

技術的に面白かったのは、Claude Codeの状態判定にUTF-8のバイトパターンを使ったところ。「公式APIがない」制約の中で、pane_titleとcapture-paneという2つの情報源をかけ合わせて4状態を判別する。泥臭いが実用的なアプローチだと思う。

一番の収穫は「可視化すると運用の質が変わる」という当たり前の事実を再確認したこと。見えないものは管理できない。エージェントが何体いても、全体像が見えれば人間は適切に介入できる。

## AIでの記事作成について

この記事はClaude Codeで記述しています。ダッシュボードの実装コードはすべて実稼働中のスクリプトからの引用で、記事用に作ったモックではありません。
