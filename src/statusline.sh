#!/usr/bin/env bash
# Claude Code statusline
# Displays: directory | git branch + changes | model | context % (icon changes by threshold 🧠→⚠️→🔥) | cost | 5-hour usage
# Dependencies: jq, git. Test: echo '{...}' | ./statusline.sh
set -uo pipefail

# Use a fixed numeric locale; otherwise, under locales that use commas as decimal
# separators, printf may output costs as "1,23" or even fail to parse "1.2345"
# returned by jq. Only LC_NUMERIC is fixed; text processing remains unchanged.
export LC_NUMERIC=C

# ───────── Configurable settings ─────────
CTX_WARN=70
CTX_CRIT=90
RL_WARN=50
RL_CRIT=80
GIT_CACHE_TTL=5
COST_DECIMALS=2

# ───────── Colors ─────────
# Follow the NO_COLOR convention: output plain text when this variable is set.
# Do not perform TTY detection—the statusline stdout is not a terminal, so such
# detection would produce a false negative and suppress colors.
if [ -n "${NO_COLOR:-}" ]; then
  C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_DIM='' C_RESET=''
else
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[91m';  C_DIM=$'\033[2m';    C_RESET=$'\033[0m'
fi

NOW=$(date +%s)   # Reuse the same timestamp throughout to avoid forking date multiple times

# ───────── Utility functions ─────────
# Select a color by threshold: red if value ≥ crit, yellow if ≥ warn, otherwise green.
pick_color() {
  local v=$1 warn=$2 crit=$3
  if   [ "$v" -ge "$crit" ]; then printf '%s' "$C_RED"
  elif [ "$v" -ge "$warn" ]; then printf '%s' "$C_YELLOW"
  else printf '%s' "$C_GREEN"; fi
}
# Get the file mtime. Try GNU (-c %Y) first, then BSD/macOS (-f %m):
# On GNU systems, `stat -f %m` treats %m as a path and writes filesystem
# information to stdout, so it must not be attempted first.
# Then fall back to a numeric-only value; normalize any abnormal output to zero
# to prevent it from contaminating subsequent arithmetic.
file_mtime() {
  local t
  t=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
  case $t in (''|*[!0-9]*) t=0;; esac
  printf '%s' "$t"
}
# Escalate the context icon based on thresholds. Emoji coloring does not work
# in most terminals, so use different icons to communicate warning levels.
ctx_icon() {
  local v=$1
  if   [ "$v" -ge "$CTX_CRIT" ]; then printf '🔥'
  elif [ "$v" -ge "$CTX_WARN" ]; then printf '⚠️'
  else printf '🧠'; fi
}

# ───────── Parse JSON ─────────
input=$(cat)

# Gracefully degrade when jq is unavailable: avoid noisy errors, print one
# minimal message, and exit.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s[statusline]%s 需要 jq\n' "$C_RED" "$C_RESET"
  exit 0
fi

# Separate fields with \x1f (unit separator, a non-whitespace character):
# read does not collapse consecutive separators, so empty fields are preserved.
# With @tsv/tab, tab is IFS whitespace and consecutive separators are collapsed.
# If an intermediate field such as current_dir is empty, all following fields
# would become misaligned.
IFS=$'\x1f' read -r MODEL CWD SESSION_ID COST CTX_PCT RL_PCT RL_RESET <<EOF
$(printf '%s' "$input" | jq -r '
  [ .model.display_name                    // "unknown",
    (.workspace.current_dir // .cwd        // ""),
    (.session_id                           // "default"),
    (.cost.total_cost_usd                  // 0  | tostring),
    (.context_window.used_percentage       // 0  | floor | tostring),
    (.rate_limits.five_hour.used_percentage // "" | tostring),
    (.rate_limits.five_hour.resets_at       // "" | tostring)
  ] | join("")' 2>/dev/null)
EOF

# Fallbacks for jq failures or invalid fields
[ -z "${MODEL:-}" ] && MODEL="unknown"
DIR_NAME="${CWD##*/}"; [ -z "$DIR_NAME" ] && DIR_NAME="~"
case "${CTX_PCT:-}" in (*[!0-9]*|"") CTX_PCT=0;; esac
case "${COST:-}"    in (""|*[!0-9.]*) COST=0;; esac

# ───────── Git segment ─────────
# The cache stores only the last successful result. If git is busy, reuse the
# previous value instead of writing an empty result.
# Tabs are used as field separators in the cache because git branch names
# cannot contain tabs.
build_git_seg() {
  [ -n "$CWD" ] || return 0

  local sid hash cache tmp refresh b s m branch staged modified seg
  sid=${SESSION_ID//[^A-Za-z0-9_-]/_}            # Sanitize to prevent characters such as / from breaking the path
  hash=$(printf '%s' "$CWD" | cksum | cut -d' ' -f1)
  cache="${TMPDIR:-/tmp}/ccstatus-git-${sid}-${hash}"

  refresh=1
  if [ -f "$cache" ] && [ $(( NOW - $(file_mtime "$cache") )) -le "$GIT_CACHE_TTL" ]; then
    refresh=0
  fi

  if [ "$refresh" -eq 1 ]; then
    if git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
      b=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
      if [ -n "$b" ]; then
        s=$(git -C "$CWD" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        m=$(git -C "$CWD" diff         --numstat 2>/dev/null | wc -l | tr -d ' ')
        # Atomic write: write to a temporary file first, then mv it to avoid
        # concurrent readers seeing a partially written file.
        tmp="${cache}.$$"
        if printf '%s\t%s\t%s\n' "$b" "$s" "$m" > "$tmp" 2>/dev/null; then
          mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
        fi
      fi
      # If b is empty because git is busy, preserve the previous cache
    else
      rm -f "$cache"   # Confirmed that this is not a git repository
    fi
  fi

  [ -f "$cache" ] || return 0
  IFS=$'\t' read -r branch staged modified < "$cache" || true
  [ -n "${branch:-}" ] || return 0

  seg=" | ${C_DIM}🌿${C_RESET} ${branch}"
  [ "${staged:-0}"   -gt 0 ] 2>/dev/null && seg="${seg} ${C_GREEN}+${staged}${C_RESET}"
  [ "${modified:-0}" -gt 0 ] 2>/dev/null && seg="${seg} ${C_YELLOW}~${modified}${C_RESET}"
  printf '%s' "$seg"
}

# ───────── 5-hour usage segment ─────────
build_rl_seg() {
  [ -n "${RL_PCT:-}" ] || return 0

  local pct rl_color remain diff
  pct=$(printf '%.0f' "$RL_PCT" 2>/dev/null || echo "")
  [ -n "$pct" ] || return 0

  rl_color=$(pick_color "$pct" "$RL_WARN" "$RL_CRIT")
  remain=""
  case "${RL_RESET:-}" in
    ''|*[!0-9]*) ;;
    *) diff=$(( RL_RESET - NOW ))
       [ "$diff" -gt 0 ] && remain=" ${C_DIM}$(( diff/3600 ))h$(( (diff%3600)/60 ))m${C_RESET}" ;;
  esac
  printf ' | ⏱️ %s%s%%%s%s' "$rl_color" "$pct" "$C_RESET" "$remain"
}

# ───────── Output ─────────
GIT_SEG=$(build_git_seg)
RL_SEG=$(build_rl_seg)
CTX_COLOR=$(pick_color "$CTX_PCT" "$CTX_WARN" "$CTX_CRIT")
CTX_ICON=$(ctx_icon "$CTX_PCT")
COST_FMT=$(printf "%.${COST_DECIMALS}f" "$COST")

printf '%s[%s]%s 📁 %s%s | %s %s%d%%%s | 💰 $%s%s\n' \
  "$C_CYAN" "$MODEL" "$C_RESET" \
  "$DIR_NAME" "$GIT_SEG" \
  "$CTX_ICON" "$CTX_COLOR" "$CTX_PCT" "$C_RESET" \
  "$COST_FMT" "$RL_SEG"
