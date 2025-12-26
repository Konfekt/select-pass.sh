#!/usr/bin/env bash

# select-pass.sh
# Rofi/dmenu/wofi frontend for password-store with typing or clipboard copy:
# Fuzzy search, select and type/paste passwords managed by password-store. Based on https://github.com/petrmanek/passmenu-otp, which is
# based on https://git.zx2c4.com/password-store/tree/contrib/dmenu/passmenu

# trace exit on error of program or pipe (or use of undeclared variable)
set -o errtrace -o errexit -o pipefail # -o nounset
# optionally debug output by supplying TRACE=1
[[ "${TRACE:-0}" == "1" ]] && set -o xtrace
if [[ "${BASH_VERSINFO:-0}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 ) ]]; then
  shopt -s inherit_errexit
fi

PS4='+\t '
[[ ! -t 0 ]] && [[ -n "${DISPLAY:-}" ]] && command -v notify-send > /dev/null 2>&1 && notify=1
error_handler() {
  summary="Error: In ${BASH_SOURCE[0]}, Lines $1 and $2, Command $3 exited with Status $4"
  body=$(pr -tn "${BASH_SOURCE[0]}" | tail -n+$(($1 - 3)) | head -n7 | sed '4s/^\s*/>> /')
  echo >&2 -en "$summary\n$body"
  [ -z "${notify:+x}" ] || notify-send --urgency=critical "$summary" "$body"
  exit "$4"
}
trap 'error_handler $LINENO "$BASH_LINENO" "$BASH_COMMAND" $?' ERR

if [[ "${1-}" =~ ^-*h(elp)?$ ]]; then
  cat <<'EOF'
Usage: passy.sh [--type|--clip]

Select an entry from password-store.
Enter types the secret.
Use --type/--clip to select the default action.
When using rofi, Ctrl+Y copies to clipboard.

Options:
  --type     Force typing (default on non-rofi menus).
  --clip     Force clipboard copy.
EOF
  exit 0
fi

PROMPT='❯ '

action_default="type"
case "${1-}" in
  --type) action_default="type"; shift ;;
  --clip|--clipboard) action_default="clip"; shift ;;
esac

menu_tool=""
menu_args=()

type_tool=""
type_args=()

if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  if command -v rofi >/dev/null 2>&1; then
    menu_tool="rofi"
    menu_args=(-dmenu -i -sort -p "$PROMPT" -kb-accept-entry "Return,KP_Enter" -kb-custom-1 "Control+y")
  elif command -v wofi >/dev/null 2>&1; then
    menu_tool="wofi"
    menu_args=(--dmenu --prompt "$PROMPT")
  else
    echo "Error: No suitable menu engine found (rofi or wofi)" >&2
    exit 1
  fi

  if command -v ydotool >/dev/null 2>&1; then
    type_tool="ydotool"
    type_args=(type --file -)
  else
    echo "Error: No suitable typing tool found on Wayland (ydotool)" >&2
    exit 1
  fi
elif [[ -n "${DISPLAY:-}" ]]; then
  if command -v rofi >/dev/null 2>&1; then
    menu_tool="rofi"
    menu_args=(-dmenu -i -sort -p "$PROMPT" -kb-accept-entry "Return,KP_Enter" -kb-custom-1 "Control+y")
  elif command -v dmenu >/dev/null 2>&1; then
    menu_tool="dmenu"
    menu_args=(-p "$PROMPT")
  else
    echo "Error: No suitable menu engine found (rofi or dmenu)" >&2
    exit 1
  fi

  if command -v xdotool >/dev/null 2>&1; then
    type_tool="xdotool"
    type_args=(type --clearmodifiers --delay 50 --file -)
  else
    echo "Error: No suitable typing tool found on X11 (xdotool)" >&2
    exit 1
  fi
else
  echo "Error: No Wayland or X11 display detected" >&2
  exit 1
fi

dir="${PASSWORD_STORE_DIR:-"$HOME/.password-store"}"

shopt -s nullglob globstar
password_files=( "$dir"/**/*.gpg )
password_files=( "${password_files[@]#"$dir"/}" )
password_files=( "${password_files[@]%.gpg}" )

if [[ "${#password_files[@]}" -eq 0 ]]; then
  echo "Error: No .gpg entries found under: $dir" >&2
  exit 1
fi

# Disable errexit and errtrace for menu selection
[[ "$-" == *E* ]] && errtrace_was_set=1 && set +E
[[ "$-" == *e* ]] && errexit_was_set=1 && set +e
old_err_trap="$(trap -p ERR)"
trap ':' ERR
# entry selection
password="$(printf '%s\n' "${password_files[@]}" | "${menu_tool}"  "${menu_args[@]}")"
rc=$?
# Restore errexit and errtrace
(( errtrace_was_set )) && set -E
(( errexit_was_set )) && set -e
eval "$old_err_trap"

[[ -n "${password:-}" ]] || exit 0

action="$action_default"
if [[ "$menu_tool" == "rofi" ]]; then
  case "$rc" in
    0) action="type" ;;   # Enter.
    10) action="clip" ;;  # Ctrl+Y (custom-1).
    *) exit 0 ;;
  esac
fi

pass_args="show"
if pass otp "$password" >/dev/null 2>&1; then
  pass_args="otp"
fi

if [[ "$action" == "clip" ]]; then
  pass "$pass_args" -c "$password" 2>/dev/null
  exit $?
fi

pass "$pass_args" "$password" | {
  IFS= read -r secret
  printf '%s' "$secret"
} | "$type_tool" "${type_args[@]}"

# Release modifier keys to avoid them getting stuck
# See https://github.com/jordansissel/xdotool/issues/43
if [[ "$type_tool" == "xdotool" ]]; then
  xdotool sleep 0.4 keyup Meta_L Meta_R Alt_L Alt_R Super_L Super_R Control_L Control_R Shift_L Shift_R
fi
