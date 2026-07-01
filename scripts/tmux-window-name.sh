#!/usr/bin/env bash

set -euo pipefail

mode="${1:-full}"
path="${2:-}"

if [ "$mode" = "full" ] && [ -z "$path" ]; then
  path="${1:-}"
fi

if [ -z "$path" ] || [ ! -d "$path" ]; then
  exit 0
fi

if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$path" rev-parse --short HEAD 2>/dev/null || true)"

if [ -z "$branch" ]; then
  exit 0
fi

print_branch() {
  printf ' %s' "$branch"
}

if [ "$mode" = "branch" ]; then
  print_branch
  exit 0
fi

print_pr() {
  if ! command -v gh >/dev/null 2>&1; then
    return 0
  fi

  repo_root="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$repo_root" ]; then
    return 0
  fi

  cache_root="${TMPDIR:-/tmp}/tmux-window-name-cache"
  mkdir -p "$cache_root"

  cache_key="$(printf '%s|%s\n' "$repo_root" "$branch" | shasum | awk '{print $1}')"
  cache_file="$cache_root/$cache_key"
  ttl=300
  now="$(date +%s)"

  if [ -f "$cache_file" ]; then
    modified="$(stat -f %m "$cache_file" 2>/dev/null || echo 0)"
    age=$((now - modified))
    if [ "$age" -lt "$ttl" ]; then
      pr_number="$(cat "$cache_file" 2>/dev/null || true)"
      if [ -n "$pr_number" ]; then
        printf ' ##%s' "$pr_number"
      fi
      return 0
    fi
  fi

  pr_number="$(
    cd "$repo_root" &&
    gh pr view --head "$branch" --json number --jq '.number' 2>/dev/null || true
  )"

  printf '%s' "$pr_number" > "$cache_file"

  if [ -n "$pr_number" ]; then
    printf ' ##%s' "$pr_number"
  fi
}

case "$mode" in
  pr)
    print_pr
    exit 0
    ;;
  full)
    print_branch
    print_pr
    ;;
  *)
    print_branch
    print_pr
    ;;
esac
