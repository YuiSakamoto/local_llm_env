#!/usr/bin/env bash
# llama-server (OpenAI 互換 API + Web UI) を起動する。
#
# Usage:
#   serve.sh [model.gguf]
#
# 環境変数:
#   LLAMA_CPP_HOME  llama.cpp のインストール先 (default: ~/.local/llama.cpp)
#   PORT            待受ポート (default: 8080)
#   CTX             コンテキスト長 (default: 16384)
#   THREADS         スレッド数 (default: nproc)
set -euo pipefail

LLAMA_CPP_HOME="${LLAMA_CPP_HOME:-$HOME/.local/llama.cpp}"
MODELS_DIR="${LOCAL_LLM_MODELS_DIR:-$HOME/models}"
MODEL="${1:-$MODELS_DIR/Qwen3-4B-Instruct-2507-Q4_K_M.gguf}"
PORT="${PORT:-8080}"
CTX="${CTX:-16384}"
THREADS="${THREADS:-$(nproc)}"

BIN="$LLAMA_CPP_HOME/current/llama-server"
[[ -x "$BIN" ]] || { echo "llama-server not found at $BIN — run setup.sh first" >&2; exit 1; }
[[ -f "$MODEL" ]] || { echo "model not found: $MODEL — run pull-model.sh first" >&2; exit 1; }

echo "starting llama-server: model=$MODEL port=$PORT ctx=$CTX threads=$THREADS"
echo "  OpenAI API: http://127.0.0.1:$PORT/v1  /  Web UI: http://127.0.0.1:$PORT"
# --jinja: モデル同梱の chat template を使い tool calling (function calling) を有効化
exec "$BIN" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -c "$CTX" -t "$THREADS" --jinja
