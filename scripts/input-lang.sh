#!/bin/sh
# input-lang.sh — 현재 macOS 입력 소스(입력 언어)를 pane 경계(경로 표시줄)에 표시한다.
#
# 표시 규칙
#   - 활성 pane: 국기 이모지(🇰🇷/🇺🇸/🇯🇵/🇨🇳) + 구분선/경로 색이 "현재 입력 언어" 색을 따른다.
#     (한글=주황, 영어=파랑, 일본어=핑크, 중국어=노랑)
#   - 비활성 pane: 구분선/경로 모두 회색, 국기 없음.
#
# 동작 방식
#   - im-select 로 입력 소스 ID 를 읽어 (색코드, 국기) 로 매핑(lang_info).
#   - watcher 가 변화를 감지하면 아래를 갱신하고 refresh-client 로 즉시 다시 그린다:
#       @input_lang        : 국기(폴백 텍스트 색 포함)  — pane-border-format 에서 사용
#       @input_lang_color  : 언어 색코드              — 활성 pane 경로 색으로 참조
#       pane-active-border-style : 활성 pane 구분선 색 (언어색·굵게)
#   - 전역 status-interval(배터리/uptime 폴링 주기)은 건드리지 않는다(전용 루프).
#   - 메인 .tmux.conf 가 매 로드마다 pane-border-format/스타일을 재설정하므로,
#     watcher 시작 시 짧게 대기 후 재적용(레이스 방지) + 저빈도 안전망으로 유지한다.
#
# 사용
#   input-lang.sh start    # watcher 시작(중복 제거 후 1개만 유지) — tmux 설정에서 호출
#   input-lang.sh watch    # 폴링 루프 본체 (start 가 백그라운드로 띄움)
#   input-lang.sh display  # 현재 국기를 한 번 출력 (디버그용)
#   input-lang.sh stop     # watcher 종료 + 원복

POLL=0.5                    # 입력 소스 폴링 주기(초)
INACTIVE_COLOR=colour242    # 비활성 pane 구분선/경로 색(회색)
DEFAULT_ACTIVE=#00afff      # stop 시 되돌릴 활성 구분선 색(테마 기본)

# pane 경계(경로 표시줄) 앞쪽에 붙일 인디케이터 조각. 뒤에 #{pane_current_path} 가 붙는다.
# 맨 앞 공백 = 왼쪽 여백(모든 pane 공통).
# 활성 pane → [국기 + 경로: 언어색(@input_lang_color)·굵게], 비활성 → [경로: 회색].
# (#[fg=..] 에 콤마를 쓰면 조건부 콤마와 충돌하므로 #[fg=x]#[bold] 처럼 분리.
#  #[fg=#{@input_lang_color}] 는 포맷 확장 시 색코드로 치환된다 — 테마들이 쓰는 패턴.)
BORDER_SEG='  #{?pane_active,#{@input_lang}  #[fg=#{@input_lang_color}]#[bold],#[fg='"$INACTIVE_COLOR"']}'

# -- im-select 바이너리 위치 결정 (tmux 의 제한된 PATH 대비) ---------------------
IM_SELECT=$(command -v im-select 2>/dev/null || true)
[ -z "$IM_SELECT" ] && [ -x /opt/homebrew/bin/im-select ] && IM_SELECT=/opt/homebrew/bin/im-select
[ -z "$IM_SELECT" ] && [ -x /usr/local/bin/im-select ]    && IM_SELECT=/usr/local/bin/im-select

# 입력 소스 ID -> "<색코드> <국기/라벨>". 색은 구분선·경로·국기폴백에 공통으로 쓴다.
# 국기 이모지는 자체 색으로 렌더되고, 색코드는 이모지가 텍스트로 폴백될 때/경로/구분선에 적용.
# (영어는 회색 대신 파랑)
lang_info() {
  case "$1" in
    "")                         printf '' ;;                        # im-select 실패
    *Korean*|*Hangul*|*2Set*)   printf 'colour214 🇰🇷' ;;           # 한국어 → 주황
    *Japanese*|*.Kana*|*Roman*) printf 'colour212 🇯🇵' ;;           # 일본어 → 핑크
    *Chinese*|*Pinyin*|*Zhuyin*|*Cangjie*|*SCIM*|*TCIM*|*Shuangpin*) \
                                printf 'colour220 🇨🇳' ;;           # 중국어 → 노랑
    *keylayout*)                printf 'colour75 🇺🇸' ;;            # ABC/US/Dvorak 등 → 영문(파랑)
    *)                          printf 'colour75 %s' "${1##*.}" ;;
  esac
}

cur_id() { [ -n "$IM_SELECT" ] && "$IM_SELECT" 2>/dev/null; }

# 현재(또는 인자로 받은) 입력 소스를 옵션/스타일에 반영.
apply_lang() {
  info=$(lang_info "$1")
  [ -z "$info" ] && return
  color=${info%% *}   # 첫 토큰 = 색코드
  flag=${info#* }     # 나머지 = 국기/라벨
  tmux set -g @input_lang "#[fg=$color]$flag#[default]" 2>/dev/null
  tmux set -g @input_lang_color "$color" 2>/dev/null
  tmux set -g pane-active-border-style "fg=$color,bold" 2>/dev/null   # 활성 구분선 = 언어색
}

# 붙어있는 모든 client 를 다시 그린다 (watcher 는 client 에 attach 돼 있지 않으므로
# 타겟 없는 refresh-client 대신 client 별로 명시적으로 호출).
redraw() {
  tmux list-clients -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
    tmux refresh-client -t "$c" 2>/dev/null
  done
}

# pane 경계(경로 표시줄) 앞쪽에 인디케이터가 없으면 붙인다 (idempotent).
ensure_border() {
  bf=$(tmux show -gv pane-border-format 2>/dev/null)
  case "$bf" in
    *@input_lang*) : ;;
    *) tmux set -g pane-border-format "$BORDER_SEG$bf" 2>/dev/null; redraw ;;
  esac
}

case "${1:-display}" in
  display)
    if [ -z "$IM_SELECT" ]; then printf 'im-select 없음'; else
      info=$(lang_info "$(cur_id)"); printf '%s' "${info#* }"
    fi
    ;;

  start)
    # 이전 watcher 정리 후 새로 1개만 띄운다 (reload 시 중복 방지).
    pkill -f "$0 watch" 2>/dev/null || true
    if [ -z "$IM_SELECT" ]; then
      tmux set -g @input_lang '#[fg=colour244]?#[default]' 2>/dev/null
      tmux set -g @input_lang_color colour244 2>/dev/null
      exit 0
    fi
    apply_lang "$(cur_id)"          # 초기값 즉시 반영
    nohup "$0" watch >/dev/null 2>&1 &
    ;;

  watch)
    [ -z "$IM_SELECT" ] && exit 0
    # 잠깐 대기해 source-file(동기, pane-border-format/스타일 재설정 포함)이 끝난 뒤에
    # 적용한다 → reload 순서 레이스 없이 항상 반영.
    sleep 0.5
    ensure_border
    prev=""
    n=0
    while tmux has-session 2>/dev/null; do   # 서버가 살아있는 동안만 폴링
      id=$(cur_id)
      if [ "$id" != "$prev" ]; then
        apply_lang "$id"
        redraw   # 전체 redraw: 국기·경로·구분선 즉시 반영
        prev=$id
      fi
      # 안전망: 약 30s 마다 border 토큰 유지 점검 (reload 외의 예외적 초기화 대비)
      n=$((n + 1)); [ "$((n % 60))" -eq 0 ] && ensure_border
      sleep "$POLL"
    done
    ;;

  stop)
    pkill -f "$0 watch" 2>/dev/null || true
    bf=$(tmux show -gv pane-border-format 2>/dev/null)
    bf=${bf#"$BORDER_SEG"}   # 앞에 붙인 인디케이터 조각 제거 (정확 일치)
    [ -n "$bf" ] && tmux set -g pane-border-format "$bf" 2>/dev/null
    tmux set -gu @input_lang 2>/dev/null || true
    tmux set -gu @input_lang_color 2>/dev/null || true
    tmux set -g pane-active-border-style "fg=$DEFAULT_ACTIVE" 2>/dev/null   # 구분선 원복
    redraw
    ;;
esac
