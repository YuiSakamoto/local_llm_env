# llm フル活用レシピ集

`llm` コマンドを日常・仕事・自動化に組み込むための実践レシピ。
基本の使い方は `llm cheat`、環境構築は [README](../README.md) を参照。
ここに載っているコマンド例はすべて実機(4 vCPU / 15GB RAM)で動作確認済み。

## 1. 日常のワンライナー

ローカルLLMは「無料・無制限・データが外に出ない」ので、雑に何度でも叩いてよい。

```bash
# コミットメッセージの下書き
git diff --staged | llm ask "この差分のコミットメッセージを Conventional Commits 形式で1行、日本語で。メッセージのみ出力"

# エラーログの一次切り分け
tail -50 error.log | llm ask "エラーの原因として考えられる仮説を3つ、可能性が高い順に"

# コマンドをど忘れした
llm cmd "直近1時間に変更されたファイルだけ tar で固める"

# 英語のドキュメント/メールを読む・書く (日⇔英自動判定)
cat email.txt | llm tr
llm tr "先日の件、社内で確認したところ問題ありませんでした"

# 文章の推敲 (macOS ならクリップボード経由が速い)
pbpaste | llm fix | pbcopy

# ちょっとした質問 (ブラウザを開くまでもないもの)
llm ask "crontab の5フィールドの順番は？"
```

## 2. シェルに組み込む (zsh)

毎回打つものは関数にする。dotfiles2 の `zsh/functions/` に置く場合は
1ファイル1関数で本体だけを書く流儀に合わせる。

```zsh
# zsh/functions/gcai — ステージ済み差分から commit する
# 例: git add -p して gcai → 気に入らなければ git commit --amend
local msg
msg=$(git diff --staged | llm ask 'この差分のコミットメッセージを Conventional Commits 形式で1行、日本語で。メッセージのみ出力') || return
git commit -e -m "$msg"   # -e でエディタ確認を挟む (LLM の出力を無検査で使わない)
```

```zsh
# zsh/functions/explain — 直前に実行したコマンドを解説させる
fc -ln -1 | llm ask "このシェルコマンドを分解して何をするか説明して"
```

`llm cmd` の提案を実行する時は、**必ず目視してから**コピペする
(`llm cmd ... | sh` のような直結はしない)。

## 3. バッチ処理 (課金ゼロの物量作戦)

API 課金がないので「全部に対して回す」が気軽にできる。
既定ではサーバーは同時1リクエスト処理なので、ループは直列でよい。

```bash
# ディレクトリ内の全 Markdown を要約
mkdir -p summaries
for f in *.md; do
  llm sum "$f" > "summaries/${f%.md}.txt"
  echo "done: $f"
done

# CSV の1列を分類する (プロンプトで出力形式を固定するのがコツ)
while IFS= read -r line; do
  label=$(printf '%s' "$line" | llm ask "この問い合わせを [バグ報告/要望/質問/その他] のどれか1語だけで分類して")
  printf '%s\t%s\n' "$label" "$line"
done < inquiries.txt > labeled.tsv
```

構造化出力が欲しい場合は「JSONのみ出力」と指示し、パースできるまでリトライする:

```bash
for i in 1 2 3; do
  out=$(llm ask "次の文から人名と組織名を {\"person\":[],\"org\":[]} の JSON だけで抽出して: $text")
  echo "$out" | python3 -m json.tool >/dev/null 2>&1 && break
done
echo "$out"
```

4B モデルの分類・抽出は 8〜9割の精度と思って設計する。
「LLM で一次処理 → 怪しいものだけ人間 (or Claude) が見る」構成が現実的。

## 4. 定期実行 (cron)

```cron
# 毎朝9時: 昨日のログを要約してファイルに残す
0 9 * * * grep "$(date -d yesterday +\%Y-\%m-\%d)" /var/log/app.log | $HOME/.local/bin/llm sum >> $HOME/daily-log-summary.txt 2>&1
```

cron 環境は PATH が細いのでフルパスで書く。サーバーが落ちていると失敗するため、
`llm up` を先頭に挟むか、`@reboot $HOME/.local/bin/llm up` を足しておく。

## 5. コーディングエージェント (aider)

```bash
uv tool install --python 3.12 aider-chat

export OPENAI_API_BASE=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local
aider --model openai/qwen3-4b --no-show-model-warnings
```

4B モデルでも「小さく明確なタスク」なら完走する
(ファイル作成→編集適用→git コミットまで動作確認済み)。コツ:

- 1回の指示は1ファイル・1機能に絞る。大きな指示は迷走する
- `/add` で対象ファイルを明示的に絞る (コンテキストを食わせすぎない)
- 生成物は必ず diff で確認する。テストがあるなら回す

## 6. Tool calling (function calling)

`--jinja` 付きで serve しているので OpenAI 互換の tools が使える。
自作スクリプトから「LLM に関数を選ばせて自分で実行する」エージェントの土台にできる。

```bash
curl -sS http://127.0.0.1:8080/v1/chat/completions -H "Content-Type: application/json" -d '{
  "messages": [{"role": "user", "content": "東京の天気を調べて"}],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "指定した都市の現在の天気を取得する",
      "parameters": {
        "type": "object",
        "properties": {"city": {"type": "string", "description": "都市名"}},
        "required": ["city"]
      }
    }
  }]
}'
# → finish_reason: "tool_calls",
#   tool_calls: [{"function": {"name": "get_weather", "arguments": "{\"city\": \"東京\"}"}}]
```

返ってきた `tool_calls` を自分のコードで実行し、結果を `role: "tool"` の
メッセージとして追記して再度投げれば1周回る。OpenAI SDK もそのまま使える
(`base_url="http://127.0.0.1:8080/v1", api_key="local"`)。

## 7. Web UI

ブラウザで <http://127.0.0.1:8080> を開くとチャット UI がある。
リモートマシンで serve している場合は SSH ポートフォワードで手元から使う:

```bash
ssh -L 8080:127.0.0.1:8080 <remote-host>
```

API は 127.0.0.1 バインドなのでこの方法以外で外部からは届かない (意図的)。

## 8. チューニングと使い分け

`serve.sh` は環境変数で調整できる:

```bash
CTX=32768 ./serve.sh              # 長文を食わせたい (RAM消費増)
PORT=9000 ./serve.sh              # ポート変更 (llm 側は LLM_URL=http://127.0.0.1:9000)
./serve.sh ~/models/別モデル.gguf  # モデル差し替え
```

| 用途 | モデル | 取得コマンド |
|---|---|---|
| デフォルト (バランス) | Qwen3-4B | `./setup.sh` で導入済み |
| 大量バッチを高速に | SmolLM2-1.7B | `./pull-model.sh ai/smollm2 1.7b-q4_K_M` |
| 品質重視 (遅い) | Qwen3-8B | `./pull-model.sh ai/qwen3 8b-q4_K_M` |

速度の目安 (4 vCPU): 4B で生成 約9 tok/s。数百字の応答に1分程度かかるため、
対話的な用途は短い出力を指示し、長い出力はバッチに回すと快適。

## 9. 得意・不得意 (4B ローカルモデルの現実)

**得意**: 要約・翻訳・分類・抽出・定型文生成・コマンド想起。
入力に答えが含まれている変換系タスクは安定して強い。

**不得意**: 多段の推論、最新情報 (学習時点で止まっている)、長大な出力、
厳密な事実性。**知識を問う質問は平気で間違える**ので、
検証可能な用途 (実行して確かめられるコマンド、原文と突き合わせられる要約) に使う。

使い分けの指針: 機密データ・物量・定型 → ローカル llm / 設計・複雑な実装・正確性が要る調査 → Claude。
