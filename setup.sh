#!/usr/bin/env bash
# Claude Code リモート実行環境 (egress 制限あり) でローカル LLM 環境を構築する。
#
# やること:
#   1. llama.cpp のビルド済みバイナリを GitHub Releases から取得
#      (最新タグは git ls-remote で解決。アセット未反映のタグはスキップ)
#   2. デフォルトモデル (Qwen3-4B-Instruct-2507 Q4_K_M, 約2.5GB) を
#      mirror.gcr.io 経由で取得
#
# Usage:
#   setup.sh              # ランタイム + デフォルトモデル
#   setup.sh --no-model   # ランタイムのみ
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_HOME="${LLAMA_CPP_HOME:-$HOME/.local/llama.cpp}"
DEFAULT_MODEL_REPO="${LOCAL_LLM_MODEL_REPO:-ai/qwen3}"
DEFAULT_MODEL_TAG="${LOCAL_LLM_MODEL_TAG:-4b-instruct-2507-q4_K_M}"

# GitHub Releases のビルド済みバイナリは ubuntu-x64 のみなので、
# macOS では Homebrew の llama.cpp を使う (serve.sh が PATH から拾う)
if [[ "$(uname -s)" == "Darwin" ]]; then
  if command -v llama-server >/dev/null 2>&1; then
    echo "==> llama-server found: $(command -v llama-server)"
  elif command -v brew >/dev/null 2>&1; then
    echo "==> installing llama.cpp via Homebrew"
    brew install llama.cpp
  else
    echo "macOS では brew install llama.cpp でランタイムを導入してください" >&2
    exit 1
  fi
  if [[ "${1:-}" != "--no-model" ]]; then
    echo "==> pulling default model $DEFAULT_MODEL_REPO:$DEFAULT_MODEL_TAG"
    "$SCRIPT_DIR/pull-model.sh" "$DEFAULT_MODEL_REPO" "$DEFAULT_MODEL_TAG"
  fi
  mkdir -p "$HOME/.local/bin"
  if [[ ! -e "$HOME/.local/bin/llm" && ! -L "$HOME/.local/bin/llm" ]]; then
    ln -s "$SCRIPT_DIR/llm" "$HOME/.local/bin/llm"
  fi
  echo
  echo "done. 起動: llm up  /  使い方: llm cheat"
  exit 0
fi

echo "==> resolving latest llama.cpp release tag"
tags=$(git ls-remote --tags https://github.com/ggml-org/llama.cpp \
  | awk -F/ '{print $3}' | grep -E '^b[0-9]+$' | sort -V | tail -10 | tac)

mkdir -p "$LLAMA_CPP_HOME"
installed=""
for tag in $tags; do
  if [[ -x "$LLAMA_CPP_HOME/llama-$tag/llama-server" ]]; then
    installed=$tag; echo "==> llama.cpp $tag already installed"; break
  fi
  url="https://github.com/ggml-org/llama.cpp/releases/download/$tag/llama-$tag-bin-ubuntu-x64.tar.gz"
  echo "==> trying $url"
  # タグ作成直後は release アセットが未アップロードのことがあるので順に落ちる
  if curl -fSL --connect-timeout 20 --max-time 600 -o "$LLAMA_CPP_HOME/llama-bin.tar.gz" "$url"; then
    tar xzf "$LLAMA_CPP_HOME/llama-bin.tar.gz" -C "$LLAMA_CPP_HOME"
    rm -f "$LLAMA_CPP_HOME/llama-bin.tar.gz"
    installed=$tag
    break
  fi
done
[[ -n "$installed" ]] || { echo "failed to download llama.cpp binaries" >&2; exit 1; }

ln -sfn "$LLAMA_CPP_HOME/llama-$installed" "$LLAMA_CPP_HOME/current"
"$LLAMA_CPP_HOME/current/llama-server" --version
echo "==> llama.cpp $installed installed at $LLAMA_CPP_HOME/current"

if [[ "${1:-}" != "--no-model" ]]; then
  echo "==> pulling default model $DEFAULT_MODEL_REPO:$DEFAULT_MODEL_TAG"
  "$SCRIPT_DIR/pull-model.sh" "$DEFAULT_MODEL_REPO" "$DEFAULT_MODEL_TAG"
fi

# llm CLI を PATH に登録。dotfiles2 が bin/llm ランチャーを ~/.local/bin に
# 張っている環境ではそちらを正とするため、既存のものは上書きしない
mkdir -p "$HOME/.local/bin"
if [[ ! -e "$HOME/.local/bin/llm" && ! -L "$HOME/.local/bin/llm" ]]; then
  ln -s "$SCRIPT_DIR/llm" "$HOME/.local/bin/llm"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "NOTE: ~/.local/bin が PATH にありません。export PATH=\"\$HOME/.local/bin:\$PATH\" を追加してください" ;;
esac

echo
echo "done. 起動: llm up  /  使い方: llm cheat"
