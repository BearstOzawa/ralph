#!/usr/bin/env bash

normalize_lang() {
  local raw="${1:-zh-CN}"
  raw=$(printf '%s' "$raw" | tr '_' '-' | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    zh|zh-cn|zh-hans) echo "zh-CN" ;;
    en|en-us) echo "en-US" ;;
    *) echo "zh-CN" ;;
  esac
}

locale_file() {
  local lang
  lang=$(normalize_lang "${1:-$LANG}")
  local base_dir
  base_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  echo "${base_dir}/../../locales/core/${lang}.json"
}

i18n_text() {
  local key="$1"
  shift || true
  local file fallback format
  file=$(locale_file "${LANG:-zh-CN}")
  fallback="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../locales/core/zh-CN.json"
  format=$(jq -r --arg key "$key" '.[$key] // empty' "$file" 2>/dev/null)
  if [ -z "$format" ] || [ "$format" = "null" ]; then
    format=$(jq -r --arg key "$key" '.[$key] // empty' "$fallback" 2>/dev/null)
  fi
  if [ -z "$format" ] || [ "$format" = "null" ]; then
    printf '%s' "$key"
    return 0
  fi
  printf "$format" "$@"
}
