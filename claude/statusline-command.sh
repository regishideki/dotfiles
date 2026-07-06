#!/bin/bash
# Claude Code statusLine script
# Line 1: model · effort · thinking · vim · session · dir · git · worktree · PR · agent · version
# Line 2: context bar · tokens · cache · rate limits

input=$(cat)

# ANSI color codes (interpreted via printf %b)
B='\033[1m'   # bold
D='\033[2m'   # dim
R='\033[0m'   # reset
CY='\033[36m' # cyan
YL='\033[33m' # yellow
GR='\033[32m' # green
RE='\033[31m' # red
MG='\033[35m' # magenta

# Extract fields
model=$(echo "$input"        | jq -r '.model.display_name // "Unknown"')
effort=$(echo "$input"       | jq -r '.effort.level // empty')
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
thinking=$(echo "$input"     | jq -r '.thinking.enabled // false')
vim_mode=$(echo "$input"     | jq -r '.vim.mode // empty')
session_name=$(echo "$input" | jq -r '.session_name // empty')
cwd=$(echo "$input"          | jq -r '.workspace.current_dir // .cwd // ""')
worktree_name=$(echo "$input"| jq -r '.worktree.name // empty')
pr_num=$(echo "$input"       | jq -r '.pr.number // empty')
pr_state=$(echo "$input"     | jq -r '.pr.review_state // empty')
agent_name=$(echo "$input"   | jq -r '.agent.name // empty')
version=$(echo "$input"      | jq -r '.version // empty')
used_pct=$(echo "$input"     | jq -r '.context_window.used_percentage // empty')
total_in=$(echo "$input"     | jq -r '.context_window.total_input_tokens // empty')
total_out=$(echo "$input"    | jq -r '.context_window.total_output_tokens // empty')
cache_write=$(echo "$input"  | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input"   | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
five_h_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_d_pct=$(echo "$input"  | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_d_reset=$(echo "$input"| jq -r '.rate_limits.seven_day.resets_at // empty')

# Format seconds-until-reset into "Xh Ym" or "Ym"
fmt_reset() {
  local ts="$1" now diff h m
  [ -z "$ts" ] || [ "$ts" = "null" ] && return
  now=$(date +%s); diff=$(( ts - now ))
  [ $diff -le 0 ] && return
  h=$(( diff / 3600 )); m=$(( (diff % 3600) / 60 ))
  [ $h -gt 0 ] && printf "%dh%dm" $h $m || printf "%dm" $m
}

# Format raw token count as "X.Xk"
fmt_k() {
  local n="$1"
  [ -z "$n" ] || [ "$n" = "null" ] && printf "?" && return
  awk "BEGIN {printf \"%.1fk\", $n/1000}"
}

# ── LINE 1 ──────────────────────────────────────────────────────────

out1=""
sep1=""
app1() { out1="${out1}${sep1}${1}"; sep1=" "; }

# Model (bold)
app1 "${B}${model}${R}"

# Effort label
case "$effort" in
  low)    app1 "${D}low${R}" ;;
  medium) app1 "${YL}medium${R}" ;;
  high)   app1 "${YL}high${R}" ;;
  xhigh)  app1 "${RE}xhigh${R}" ;;
  max)    app1 "${RE}max${R}" ;;
esac

# Thinking indicator
[ "$thinking" = "true" ] && app1 "${CY}💭${R}"

# Vim mode
[ -n "$vim_mode" ] && app1 "${MG}[${vim_mode}]${R}"

# Session name
[ -n "$session_name" ] && app1 "${D}\"${session_name}\"${R}"

# Current directory (basename only)
dir_name="${cwd##*/}"
app1 "${CY}${dir_name}${R}"

# Git branch + staged/modified/untracked counters
if [ -n "$cwd" ] && git --no-optional-locks -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)
  if [ -n "$branch" ]; then
    staged=$(git --no-optional-locks -C "$cwd" diff --cached --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
    modified=$(git --no-optional-locks -C "$cwd" diff --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
    untracked=$(git --no-optional-locks -C "$cwd" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d '[:space:]')
    git_part="${YL}(${branch}"
    [ "${staged:-0}" -gt 0 ]   2>/dev/null && git_part="${git_part} +${staged}"
    [ "${modified:-0}" -gt 0 ] 2>/dev/null && git_part="${git_part} ~${modified}"
    [ "${untracked:-0}" -gt 0 ]2>/dev/null && git_part="${git_part} ?${untracked}"
    git_part="${git_part})${R}"
    app1 "$git_part"
  fi
fi

# Worktree name
[ -n "$worktree_name" ] && app1 "${D}[wt:${worktree_name}]${R}"

# PR number + review state icon
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved)           pr_icon="${GR}✓${R}" ;;
    changes_requested)  pr_icon="${RE}✗${R}" ;;
    draft)              pr_icon="${D}d${R}" ;;
    *)                  pr_icon="?" ;;
  esac
  app1 "PR#${pr_num}(${pr_icon})"
fi

# Agent name
[ -n "$agent_name" ] && app1 "${MG}[${agent_name}]${R}"

# Claude Code version
[ -n "$version" ] && app1 "${D}v${version}${R}"

printf "%b\n" "$out1"

# ── LINE 2 ──────────────────────────────────────────────────────────

out2=""
sep2=""
app2() { out2="${out2}${sep2}${1}"; sep2=" | "; }

# Context window progress bar + percentage
if [ -n "$used_pct" ]; then
  used_int=$(printf "%.0f" "$used_pct")
  filled=$(( used_int / 10 ))
  [ $filled -gt 10 ] && filled=10
  empty=$(( 10 - filled ))
  bar=""
  i=0; while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  i=0; while [ $i -lt $empty ];  do bar="${bar}░"; i=$(( i + 1 )); done
  if   [ "$used_int" -ge 80 ]; then bar_col="${RE}"
  elif [ "$used_int" -ge 50 ]; then bar_col="${YL}"
  else                               bar_col="${GR}"; fi
  app2 "${bar_col}${bar}${R} ${used_int}%"
fi

# Total tokens in / out
if [ -n "$total_in" ] && [ -n "$total_out" ]; then
  app2 "in:$(fmt_k "$total_in") out:$(fmt_k "$total_out")"
fi

# Session cost vs limit
if [ -n "$session_cost" ] && awk "BEGIN { exit !($session_cost > 0) }" 2>/dev/null; then
  cost_fmt=$(awk "BEGIN { printf \"\$%.3f\", $session_cost }")
  LIMIT_FILE="$HOME/.claude/cost-limit"
  if [ -f "$LIMIT_FILE" ]; then
    cost_limit=$(tr -d '[:space:]$' < "$LIMIT_FILE")
  else
    cost_limit=""
  fi
  if [ -n "$cost_limit" ] && awk "BEGIN { exit !($cost_limit > 0) }" 2>/dev/null; then
    limit_pct=$(awk "BEGIN { printf \"%.0f\", ($session_cost / $cost_limit) * 100 }")
    if   [ "$limit_pct" -ge 85 ]; then limit_col="${RE}"
    elif [ "$limit_pct" -ge 60 ]; then limit_col='\033[38;5;208m'
    elif [ "$limit_pct" -ge 35 ]; then limit_col="${YL}"
    else                                limit_col="${GR}"; fi
    app2 "${YL}${cost_fmt}${R}${D}/\$${cost_limit}${R} ${limit_col}(${limit_pct}%)${R}"
  else
    app2 "${YL}${cost_fmt}${R}"
  fi
fi

# Cache creation / read (only when non-zero)
cache_part=""
[ "${cache_write:-0}" -gt 0 ] 2>/dev/null && cache_part="cw:$(fmt_k "$cache_write")"
[ "${cache_read:-0}"  -gt 0 ] 2>/dev/null && cache_part="${cache_part:+${cache_part} }cr:$(fmt_k "$cache_read")"
[ -n "$cache_part" ] && app2 "$cache_part"

# Rate limits (5-hour and 7-day) with time-until-reset
rate_part=""
if [ -n "$five_h_pct" ]; then
  five_int=$(printf "%.0f" "$five_h_pct")
  r=$(fmt_reset "$five_h_reset")
  rate_part="5h:${five_int}%${r:+(↺${r})}"
fi
if [ -n "$seven_d_pct" ]; then
  seven_int=$(printf "%.0f" "$seven_d_pct")
  r=$(fmt_reset "$seven_d_reset")
  rate_part="${rate_part:+${rate_part} }7d:${seven_int}%${r:+(↺${r})}"
fi
[ -n "$rate_part" ] && app2 "$rate_part"

[ -n "$out2" ] && printf "%b\n" "$out2"
