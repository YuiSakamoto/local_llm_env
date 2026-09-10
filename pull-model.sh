#!/usr/bin/env bash
# Docker Hub の ai/ 名前空間 (Docker Model Runner) から GGUF モデルを取得する。
# HuggingFace / Ollama registry が egress policy で塞がれている環境でも、
# mirror.gcr.io (blob は storage.googleapis.com 配信) 経由なら取得できる。
#
# Usage:
#   pull-model.sh <repo> <tag> [outdir]
#   pull-model.sh ai/qwen3 4b-instruct-2507-q4_K_M
#
# タグ一覧の確認:
#   pull-model.sh --tags ai/qwen3
set -euo pipefail

MODELS_DIR_DEFAULT="${LOCAL_LLM_MODELS_DIR:-$HOME/models}"
# 試行順: mirror.gcr.io → registry-1.docker.io (後者は blob CDN が通る環境向け)
REGISTRIES=("mirror.gcr.io" "registry-1.docker.io")

get_token() {
  local registry=$1 repo=$2
  case "$registry" in
    mirror.gcr.io)
      curl -fsS "https://mirror.gcr.io/v2/token?scope=repository:${repo}:pull&service=mirror.gcr.io" ;;
    registry-1.docker.io)
      curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" ;;
    *) echo "unknown registry: $registry" >&2; return 1 ;;
  esac | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])'
}

fetch_manifest() {
  local registry=$1 repo=$2 ref=$3 token=$4
  curl -fsS -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://${registry}/v2/${repo}/manifests/${ref}"
}

if [[ "${1:-}" == "--tags" ]]; then
  repo=${2:?usage: pull-model.sh --tags <repo>}
  token=$(get_token "registry-1.docker.io" "$repo")
  curl -fsS -H "Authorization: Bearer $token" \
    "https://registry-1.docker.io/v2/${repo}/tags/list" | python3 -m json.tool
  exit 0
fi

repo=${1:?usage: pull-model.sh <repo e.g. ai/qwen3> <tag> [outdir]}
tag=${2:?usage: pull-model.sh <repo> <tag> [outdir]}
outdir=${3:-$MODELS_DIR_DEFAULT}
mkdir -p "$outdir"

for registry in "${REGISTRIES[@]}"; do
  echo "==> trying registry: $registry"
  token=$(get_token "$registry" "$repo") || { echo "  token failed"; continue; }
  manifest=$(fetch_manifest "$registry" "$repo" "$tag" "$token") || { echo "  manifest failed"; continue; }

  # manifest index の場合は最初の manifest を辿る
  child=$(printf '%s' "$manifest" | python3 -c '
import sys, json
m = json.load(sys.stdin)
print(m["manifests"][0]["digest"] if "manifests" in m else "")')
  if [[ -n "$child" ]]; then
    manifest=$(fetch_manifest "$registry" "$repo" "$child" "$token") || { echo "  child manifest failed"; continue; }
  fi

  # GGUF weight レイヤーの digest / ファイル名 / サイズを抽出
  layers=$(printf '%s' "$manifest" | python3 -c '
import sys, json
m = json.load(sys.stdin)
for l in m.get("layers", []):
    path = l.get("annotations", {}).get("org.cncf.model.filepath", "")
    if "model.weight" in l.get("mediaType", "") and path.endswith(".gguf"):
        print(l["digest"], path, l["size"])')
  if [[ -z "$layers" ]]; then
    echo "  no GGUF weight layer found in manifest" >&2
    continue
  fi

  ok=1
  while read -r digest filepath size; do
    dest="$outdir/$filepath"
    if [[ -f "$dest" ]] && [[ "$(stat -c%s "$dest")" == "$size" ]]; then
      echo "  already downloaded: $dest"
      continue
    fi
    echo "  downloading $filepath ($((size / 1024 / 1024)) MB) from $registry ..."
    # mirror.gcr.io はキャッシュミス時に上流から取り込むため初回は応答まで数分かかる
    if ! curl -fSL --connect-timeout 30 --max-time 7200 --retry 3 --retry-delay 15 -C - \
        -H "Authorization: Bearer $token" \
        -o "$dest" "https://${registry}/v2/${repo}/blobs/${digest}"; then
      ok=0; break
    fi
    echo "  verifying sha256 ..."
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [[ "sha256:$actual" != "$digest" ]]; then
      echo "  checksum mismatch: $dest" >&2
      rm -f "$dest"; ok=0; break
    fi
    echo "  OK: $dest"
  done <<< "$layers"

  [[ $ok -eq 1 ]] && exit 0
done

echo "failed to pull $repo:$tag from all registries" >&2
exit 1
