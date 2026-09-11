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
# nproc は GNU coreutils。macOS では sysctl で代替する
THREADS="${THREADS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

# setup.sh が置いたバイナリを優先し、無ければ PATH のもの
# (macOS: brew install llama.cpp) にフォールバックする
BIN="$LLAMA_CPP_HOME/current/llama-server"
if [[ ! -x "$BIN" ]]; then
  BIN="$(command -v llama-server || true)"
fi
[[ -n "$BIN" && -x "$BIN" ]] || {
  echo "llama-server not found — Linux: setup.sh を実行 / macOS: brew install llama.cpp" >&2
  exit 1
}
[[ -f "$MODEL" ]] || { echo "model not found: $MODEL — run pull-model.sh first" >&2; exit 1; }

echo "starting llama-server: model=$MODEL port=$PORT ctx=$CTX threads=$THREADS"
echo "  OpenAI API: http://127.0.0.1:$PORT/v1  /  Web UI: http://127.0.0.1:$PORT"
# --jinja: モデル同梱の chat template を使い tool calling (function calling) を有効化
exec "$BIN" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -c "$CTX" -t "$THREADS" --jinja
