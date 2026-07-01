#!/usr/bin/env bash
# session-sidebar.sh — tmux 세션/창을 항상 보이는 좌측 사이드바 패널로 렌더링.
#
# 기존 키 바인딩은 전혀 건드리지 않고, prefix+S 토글 + 자동 follow 훅으로만 동작한다.
# 패널은 읽기 전용 오버뷰(확인용)이고, 실제 전환은 기존 단축키(prefix BTab / C-f / s)를 그대로 쓴다.
#
# 사용법: session-sidebar.sh {toggle|ensure|ensure-here|kill-all|render}
#   toggle      : @sidebar_on 뒤집고 현재 창에 띄우거나 전체 닫기 (prefix+S 가 호출)
#   ensure      : @sidebar_on=1 이고 follow=on 이면 현재 창에 없을 때만 생성 (창 전환 훅)
#   ensure-here : @sidebar_on=1 이면 현재 창에 보장 (세션 전환 훅)
#   kill-all    : 모든 세션의 사이드바 패널 제거
#   render      : 패널 안에서 도는 렌더 루프 (직접 호출 X)
#
# tmux user option 으로 조절:
#   @sidebar_width      패널 폭(칸)            기본 26
#   @sidebar_min_width  이보다 좁은 창엔 생략  기본 60
#   @sidebar_follow     on|off 따라다니기      기본 on
#   @sidebar_refresh    갱신 주기(초)          기본 2
set -u

SELF="${BASH_SOURCE[0]:-$0}"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac

opt() { tmux show -gv "$1" 2>/dev/null; }

WIDTH="$(opt @sidebar_width)";       : "${WIDTH:=26}"
MINWIN="$(opt @sidebar_min_width)";  : "${MINWIN:=60}"
FOLLOW="$(opt @sidebar_follow)";     : "${FOLLOW:=on}"
REFRESH="$(opt @sidebar_refresh)";   : "${REFRESH:=2}"

is_on() { [ "$(opt @sidebar_on)" = "1" ]; }

# 현재 창에 이미 사이드바 패널이 있으면 그 pane id 출력
sidebar_pane_in_current() {
  tmux list-panes -F '#{@is_sidebar} #{pane_id}' 2>/dev/null \
    | awk '$1=="1"{print $2; exit}'
}

spawn() {
  [ -n "$(sidebar_pane_in_current)" ] && return 0
  local ww
  ww="$(tmux display -p '#{window_width}' 2>/dev/null)"
  [ "${ww:-0}" -lt "$MINWIN" ] && return 0
  local newp
  newp="$(tmux split-window -hb -d -l "$WIDTH" -P -F '#{pane_id}' "exec '$SELF' render" 2>/dev/null)" || return 0
  [ -z "$newp" ] && return 0
  tmux set -p -t "$newp" @is_sidebar 1 2>/dev/null
  tmux select-pane -T 'tmux-sidebar' -t "$newp" 2>/dev/null
}

kill_all() {
  tmux list-panes -a -F '#{@is_sidebar} #{pane_id}' 2>/dev/null \
    | awk '$1=="1"{print $2}' \
    | while read -r p; do tmux kill-pane -t "$p" 2>/dev/null; done
}

render() {
  local ESC; ESC=$'\033'
  local NL; NL=$'\n'
  local RST="${ESC}[0m" B="${ESC}[1m" DIM="${ESC}[2m"
  local CUR="${ESC}[1;33m"     # 현재 세션 (노랑 — status-left 테마와 통일)
  local WIN="${ESC}[1;32m"     # 현재 창 (초록)
  local ACT="${ESC}[31m"       # 활동/벨 (빨강)
  local HDR="${ESC}[1;35m"     # 헤더 (마젠타)

  printf '%s' "${ESC}[?25l"                                   # 커서 숨김
  trap 'printf "%s" "${ESC}[?25h"; exit 0' EXIT INT TERM HUP

  local prev=""
  while :; do
    local w cur curwin sessions windows act_set rule out
    w="$(tmux display -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)";  : "${w:=$WIDTH}"
    cur="$(tmux display -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)"
    curwin="$(tmux display -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)"

    sessions="$(tmux list-sessions -F '#{session_name}	#{session_windows}	#{session_attached}' 2>/dev/null)"
    windows="$(tmux list-windows -a -F '#{session_name}	#{window_index}	#{window_name}	#{window_id}	#{window_active}	#{window_activity_flag}	#{window_bell_flag}' 2>/dev/null)"
    # 활동 플래그가 있는 세션 집합
    act_set="$(printf '%s\n' "$windows" | awk -F'\t' '$6=="1"{print $1}' | sort -u)"

    local maxname=$(( w - 8 )); [ "$maxname" -lt 6 ] && maxname=6
    rule="$(printf '%*s' "$w" '' | tr ' ' '-')"

    out="${HDR} SESSIONS${RST}${NL}${DIM}${rule}${RST}${NL}"

    while IFS=$'\t' read -r name nwin att; do
      [ -z "$name" ] && continue
      local short="$name" sflag=""
      if [ "${#short}" -gt "$maxname" ]; then short="${short:0:maxname-1}…"; fi
      if printf '%s\n' "$act_set" | grep -qxF "$name"; then sflag=" ${ACT}!${RST}"; fi

      if [ "$name" = "$cur" ]; then
        out+="${CUR}▸ ${short}${RST} ${DIM}${nwin}w${RST}${sflag}${NL}"
        # 현재 세션 창 전개
        local wmax=$(( w - 6 )); [ "$wmax" -lt 4 ] && wmax=4
        while IFS=$'\t' read -r sn widx wname wid wactive wact wbell; do
          [ "$sn" = "$name" ] || continue
          local wn="$wname" wm='   ' wcol="$DIM" wflag=""
          if [ "${#wn}" -gt "$wmax" ]; then wn="${wn:0:wmax-1}…"; fi
          if [ "$wid" = "$curwin" ]; then wm=' ▸ '; wcol="$WIN"; fi
          [ "$wact" = "1" ] && wflag=" ${ACT}!${RST}"
          [ "$wbell" = "1" ] && wflag="${wflag} ${ACT}*${RST}"
          out+="${wcol}${wm}${widx}:${wn}${RST}${wflag}${NL}"
        done <<EOF
$windows
EOF
      else
        out+="  ${short} ${DIM}${nwin}w${RST}${sflag}${NL}"
      fi
    done <<EOF
$sessions
EOF

    out+="${DIM}${rule}${RST}${NL}${DIM} prefix+S 닫기${RST}"

    # 내용이 바뀐 경우에만 다시 그려서 깜빡임 최소화
    if [ "$out" != "$prev" ]; then
      printf '%s%s' "${ESC}[H${ESC}[2J" "$out"
      prev="$out"
    fi
    sleep "$REFRESH"
  done
}

case "${1:-}" in
  toggle)
    if is_on; then
      tmux set -g @sidebar_on 0
      kill_all
      tmux display-message "session sidebar: off"
    else
      tmux set -g @sidebar_on 1
      spawn
      tmux display-message "session sidebar: on"
    fi
    ;;
  ensure)
    is_on || exit 0
    [ "$FOLLOW" = "on" ] || exit 0
    spawn
    ;;
  ensure-here)
    is_on || exit 0
    [ "$FOLLOW" = "on" ] || exit 0
    spawn
    ;;
  kill-all) kill_all ;;
  render)   render ;;
  *) echo "usage: ${0##*/} {toggle|ensure|ensure-here|kill-all|render}" >&2; exit 2 ;;
esac
