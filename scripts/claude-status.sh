#!/bin/sh
# claude-status.sh — 각 tmux 윈도우 탭에 그 창에서 돌고 있는 Claude Code 세션의 상태를 표시한다.
#
# 표시 규칙 (탭에서 윈도우 이름 오른쪽에 배지 1글자 — "#I #W ●")
#   ● 주황  busy     : 응답/툴 실행 중
#   ▲ 빨강  waiting  : 나를 기다림 (권한 프롬프트 등)
#   $ 파랑  shell    : 셸 명령 수행 중
#   · 회색  idle     : 살아있고 한가함
#   (배지 없음)      : 그 창엔 Claude 세션이 없음
#
# 동작 방식
#   - Claude Code(2.1.x)는 실행 중인 세션마다 ~/.claude/sessions/<pid>.json 에
#     {"pid":…,"status":"busy|shell|idle|waiting",…} 를 전이 시점마다 갱신한다.
#     (같은 데이터의 공식 조회 명령은 `claude agents --json` 이지만, 폴링에는
#      바이너리 기동 비용이 있어 파일을 직접 읽는다.)
#   - Claude pid → tmux 윈도우 매핑: pid 의 조상을 따라 올라가며 pane_pid 와 일치하는
#     pane 을 찾는다(보통 1홉: claude 의 부모가 곧 pane 의 셸).
#   - 찾은 윈도우에 @cc_status 옵션을 쓰고, window-status-format 안의 조건식이 이를
#     배지로 렌더한다. 값이 없는 윈도우는 배지가 아예 안 붙는다.
#   - 죽은 세션의 stale json 은 ps 테이블에 pid 가 없으므로 자동으로 걸러진다.
#   - 메인 .tmux.conf 가 매 로드마다 window-status-format 을 재생성하므로,
#     watcher 시작 시 짧게 대기 후 주입 + 저빈도 안전망으로 유지한다(input-lang.sh 와 동일).
#   - 전역 status-interval 은 건드리지 않는다. 변경이 있을 때만 refresh-client 로 다시 그린다.
#
# 사용
#   claude-status.sh start   # watcher 시작(중복 제거 후 1개만 유지) — tmux 설정에서 호출
#   claude-status.sh watch   # 폴링 루프 본체 (start 가 백그라운드로 띄움)
#   claude-status.sh once    # 한 번만 반영 (디버그용)
#   claude-status.sh dump    # 계산된 "윈도우 상태" 매핑만 출력 (디버그용)
#   claude-status.sh stop    # watcher 종료 + 배지/옵션 원복

POLL=1                                  # 폴링 주기(초)
SESS_DIR=$HOME/.claude/sessions         # Claude Code 세션 레지스트리
OPT=@cc_status                          # 윈도우별 상태를 담는 user option
MAX_HOPS=6                              # pid → pane 조상 탐색 최대 홉수

# 라벨("#I #W") 뒤에 붙일 배지 조각. 상태가 없으면 앞 공백까지 통째로 사라지도록
# 공백을 조건식 안에 둔다. 글리프 뒤의 #[default] 는 "그 창 상태의 기본 스타일"
# (window-status-style / -current-style / -last-style …)로 되돌리는 것이므로,
# 배지 색이 뒤따르는 여백·구분자까지 물들지 않는다.
BADGE='#{?#{@cc_status}, #{?#{==:#{@cc_status},busy},#[fg=colour214]●,#{?#{==:#{@cc_status},waiting},#[fg=colour203]▲,#{?#{==:#{@cc_status},shell},#[fg=colour75]$,#[fg=colour242]·}}}#[default],}'
BADGE_HEAD='#{?#{@cc_status},'   # strip 이 배지 시작점을 찾는 앵커
BADGE_TAIL=',}'                  # 배지 몸통의 끝 (배지 안에는 이 조합이 여기 말고 없다)

NL='
'

# 붙어있는 모든 client 를 다시 그린다 (watcher 는 client 에 attach 돼 있지 않으므로
# 타겟 없는 refresh-client 대신 client 별로 명시적으로 호출).
redraw() {
  tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
    tmux refresh-client -S -t "$c" 2>/dev/null
  done
}

# 포맷 문자열의 라벨("#I #W") 바로 뒤에 배지를 끼워넣는다 (idempotent).
inject() {
  fmt=$(tmux show -gwv "$1" 2>/dev/null)
  [ -n "$fmt" ] || return 0
  case "$fmt" in *"$OPT"*) return 0 ;; esac      # 이미 주입돼 있음
  case "$fmt" in
    *"#I #W"*) tmux setw -g "$1" "${fmt%%"#I #W"*}#I #W$BADGE${fmt#*"#I #W"}" 2>/dev/null ;;
    *)         tmux setw -g "$1" "$fmt$BADGE" 2>/dev/null ;;   # 라벨 형태가 다르면 끝에 붙인다
  esac
}

# 배지를 제거한다. BADGE 문자열 전체가 아니라 앵커(시작)~첫 ",}"(끝) 구간을 지우므로,
# 배지 모양을 바꾼 뒤에도 예전 버전이 남아있으면 함께 정리된다.
strip() {
  fmt=$(tmux show -gwv "$1" 2>/dev/null)
  case "$fmt" in *"$BADGE_HEAD"*) ;; *) return 0 ;; esac
  rest=${fmt#*"$BADGE_HEAD"}
  tmux setw -g "$1" "${fmt%%"$BADGE_HEAD"*}${rest#*"$BADGE_TAIL"}" 2>/dev/null
}

ensure_badge() {
  inject window-status-format
  inject window-status-current-format
}

remove_badge() {
  strip window-status-format
  strip window-status-current-format
}

# 한 tick 분량의 입력을 모아 awk 로 넘긴다.
#   P <window_id> <pane_pid>   : tmux pane 목록
#   T <pid> <ppid>             : 프로세스 부모 테이블 (한 번의 ps 호출)
#   S <json>                   : 세션 레지스트리 한 줄 (파일당 1줄 JSON)
collect() {
  tmux list-panes -a -F 'P #{window_id} #{pane_pid}' 2>/dev/null
  ps -ax -o pid=,ppid= 2>/dev/null | awk '{print "T", $1, $2}'
  for f in "$SESS_DIR"/*.json; do
    [ -f "$f" ] || continue
    printf 'S '
    cat "$f" 2>/dev/null
    printf '\n'
  done
}

# "<window_id> <status>" 목록. 한 윈도우에 여러 세션이 있으면 우선순위가 높은 쪽을 쓴다.
compute() {
  collect | awk '
    BEGIN { rank["idle"] = 1; rank["shell"] = 2; rank["waiting"] = 3; rank["busy"] = 4 }
    $1 == "P" { win[$3] = $2; next }
    $1 == "T" { par[$2] = $3; next }
    $1 == "S" {
      pid = ""; st = ""
      if (match($0, /"pid":[0-9]+/)) {
        t = substr($0, RSTART, RLENGTH); sub(/^"pid":/, "", t); pid = t
      }
      if (match($0, /"status":"[a-z]+"/)) {
        t = substr($0, RSTART, RLENGTH); sub(/^"status":"/, "", t); sub(/"$/, "", t); st = t
      } else if (match($0, /"state":"[a-z_]+"/)) {
        t = substr($0, RSTART, RLENGTH); sub(/^"state":"/, "", t); sub(/"$/, "", t); st = t
      }
      if (pid == "" || st == "") next
      cur = pid + 0
      for (i = 0; i < '"$MAX_HOPS"'; i++) {
        if (cur in win) {
          w = win[cur]
          if (!(w in best) || rank[st] > rank[best[w]]) best[w] = st
          break
        }
        if (!(cur in par)) break        # 죽은 pid(stale json) 이거나 이 tmux 서버 밖
        cur = par[cur] + 0
        if (cur <= 1) break
      }
    }
    END { for (w in best) print w, best[w] }
  '
}

# 이전 tick 과 달라진 윈도우만 갱신한다.
PREV=
apply() {
  new=$(compute)
  changed=0
  ids=

  old_ifs=$IFS
  IFS=$NL
  for line in $new; do
    w=${line%% *}
    s=${line#* }
    case "$NL$PREV$NL" in
      *"$NL$w $s$NL"*) ;;                                     # 변화 없음
      *) tmux setw -t "$w" "$OPT" "$s" 2>/dev/null; changed=1 ;;
    esac
    ids="$ids$w$NL"
  done
  for line in $PREV; do                                       # 사라진 세션의 배지 제거
    w=${line%% *}
    case "$NL$ids" in
      *"$NL$w$NL"*) ;;
      *) tmux setw -u -t "$w" "$OPT" 2>/dev/null; changed=1 ;;
    esac
  done
  IFS=$old_ifs

  [ "$changed" -eq 1 ] && redraw
  PREV=$new
}

case "${1:-once}" in
  start)
    # 이전 watcher 정리 후 새로 1개만 띄운다 (reload 시 중복 방지).
    pkill -f "$0 watch" 2>/dev/null || true
    # 남아있는(예전 모양의) 배지를 먼저 걷어낸다 → watch 가 현재 BADGE 로 다시 주입.
    remove_badge
    nohup "$0" watch >/dev/null 2>&1 &
    ;;

  watch)
    # source-file(동기, window-status-format 재생성 포함)이 끝난 뒤 주입 → reload 레이스 방지.
    sleep 0.5
    ensure_badge
    n=0
    while tmux has-session 2>/dev/null; do   # 서버가 살아있는 동안만 폴링
      apply
      # 안전망: 약 30s 마다 주입 유지 점검 (reload 외의 예외적 초기화 대비)
      n=$((n + 1)); [ "$((n % 30))" -eq 0 ] && ensure_badge
      sleep "$POLL"
    done
    ;;

  once)
    ensure_badge
    apply
    ;;

  dump)
    compute
    ;;

  stop)
    pkill -f "$0 watch" 2>/dev/null || true
    remove_badge
    tmux list-windows -a -F '#{window_id}' 2>/dev/null | while IFS= read -r w; do
      tmux setw -u -t "$w" "$OPT" 2>/dev/null
    done
    redraw
    ;;
esac
