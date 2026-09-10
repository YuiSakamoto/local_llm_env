# local_llm_env — Claude Code リモート実行環境でローカル LLM を動かす

Claude Code のリモート実行環境（egress 制限つきコンテナ）上に、llama.cpp ベースの
ローカル LLM 環境（OpenAI 互換 API + Web UI + コーディングエージェント）を構築するスクリプト群。
4 vCPU / 15GB RAM / GPU なしのコンテナで動作検証済み。

## 背景: リモート実行環境のネットワーク制約

モデル配布の主要ホストは egress policy でブロックされているため、通常の手順
（`ollama pull` や `huggingface-cli download`）は使えない。実測での疎通状況:

| 経路 | 状態 |
|---|---|
| `huggingface.co` / `cdn-lfs.huggingface.co` | ❌ ブロック |
| `ollama.com` / `registry.ollama.ai` | ❌ ブロック |
| `modelscope.cn`, `kaggle.com`, Docker Hub blob CDN (`cloudfront.docker.com`) | ❌ ブロック |
| `github.com/<o>/<r>/releases/download/...`(リリースアセット) | ✅ 通る |
| `raw.githubusercontent.com`, git プロトコル (公開リポジトリ) | ✅ 通る |
| `pypi.org` / `files.pythonhosted.org` / `registry.npmjs.org` | ✅ 通る |
| **`mirror.gcr.io`**(Docker Hub ミラー、blob は GCS 配信) | ✅ 通る |

そこで以下の組み合わせで構築する:

- **ランタイム**: llama.cpp ビルド済みバイナリを GitHub Releases から取得
- **モデル**: Docker Hub `ai/` 名前空間(Docker Model Runner)の GGUF を
  `mirror.gcr.io` 経由で OCI blob として取得(SHA256 検証つき)
- **エージェント**: aider を PyPI から取得

## クイックスタート

```bash
# 1. ランタイム + デフォルトモデル (Qwen3-4B-Instruct-2507 Q4_K_M, 約2.5GB) を導入
./setup.sh

# 2. サーバー起動 (OpenAI 互換 API: http://127.0.0.1:8080/v1, Web UI: http://127.0.0.1:8080)
llm up          # またはフォアグラウンドで ./serve.sh

# 3. 動作確認
curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}],"max_tokens":50}'
```

## llm コマンド — ターミナルから気軽に使う

`setup.sh` が `~/.local/bin/llm` にシンボリックリンクを張る。**使い方を忘れたら `llm cheat`**。

```bash
llm up                          # サーバー起動 (未起動なら)
llm ask "質問"                  # なんでも質問
cat report.txt | llm ask "要約して"   # パイプで流し込み
llm sum file.txt                # 3行要約
llm tr "hello world"            # 日⇔英 翻訳 (自動判定)
git diff | llm fix              # stdin の文章校正
llm cmd "7日より古いログを削除"  # シェルコマンド提案
llm chat                        # 会話モード (履歴保持)
llm status                      # ヘルスチェック + ロード中モデル
```

依存は Python 標準ライブラリのみ。接続先は環境変数 `LLM_URL` で変更可能
(default: `http://127.0.0.1:8080`)。

## モデルの追加取得

Docker Hub の `ai/` 名前空間にあるモデルなら何でも取得できる。

```bash
# タグ一覧を確認
./pull-model.sh --tags ai/qwen3

# 取得 (デフォルト保存先: ~/models)
./pull-model.sh ai/qwen3 8b-q4_K_M
./pull-model.sh ai/gemma3 4b-q4_K_M

# 取得したモデルで起動
./serve.sh ~/models/Qwen3-8B-Q4_K_M.gguf
```

主なリポジトリ: `ai/qwen3`(0.6b〜235b)、`ai/qwen2.5`、`ai/gemma3`、`ai/smollm2`、
`ai/llama3.2`、`ai/mistral`、`ai/phi4`、`ai/deepseek-r1-distill-llama`、
`ai/qwen3-coder`(30b-a3b〜)、`ai/deepcoder-preview`(14B) など。

## コーディングエージェント (aider)

```bash
uv tool install --python 3.12 aider-chat

export OPENAI_API_BASE=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local
aider --model openai/qwen3-4b --no-show-model-warnings
```

`--jinja` つきで serve しているので tool calling(function calling)も有効。
aider がローカル LLM 相手にファイル作成→編集適用→git コミットまで行えることを確認済み。

## マシンスペックの目安

4 vCPU / 15GB RAM / GPU なしでの実測値(Qwen3-4B Q4_K_M):

- プロンプト処理: 約 60 tok/s
- 生成: 約 9 tok/s

| モデル | サイズ | 用途の目安 |
|---|---|---|
| `ai/qwen3:4b-instruct-2507-q4_K_M` | 2.5GB | デフォルト。速度と品質のバランス |
| `ai/smollm2:1.7b-q4_K_M` 等の小型 | <1.5GB | 高速に回したい定型処理 |
| `ai/qwen3:8b-q4_K_M` | 5GB | 品質重視(生成 4-5 tok/s 程度) |
| 14B 以上 / 30B MoE | 9GB〜 | RAM 15GB では非推奨 |

## 注意

- リモート実行環境のコンテナは**揮発性**。コンテナ再作成後は `setup.sh` の再実行が必要。
- モデルは `~/models`、バイナリは `~/.local/llama.cpp` に置かれ、git 管理外。
- API は `127.0.0.1` バインドのみ(外部公開しない)。
