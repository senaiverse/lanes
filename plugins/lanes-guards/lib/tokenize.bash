# Shell tokenizer for lanes-guard, sourced by bin/lanes-guard (a library: no shebang, no set -e of its own).
# tokenize <text> appends one SEP-joined string per simple command to CMDS, recursing into $( ) and backticks. Quotes
# ($'...' decoded), backslashes and line continuations are removed as the shell removes them. Beside CMDS it fills
# CMD_STDIN[i] (the heredoc body or here-string word fed to command i), CMD_SUB[i] (the serial of the innermost
# substitution command i runs in, or empty) and CMD_OUT[i] (set when command i's output may reach another command or a
# file, see tokenize). A substitution leaves SUBMARK serial SUBMARK in its word. `()` after a word sets FUNC_DEF:
# `name ()`, also behind a reserved word (`{ name () ...`), and otherwise only a syntax error. Text it
# cannot parse (an unterminated quote, too much nesting) sets LOOSE.
# Limit: words are joined with SEP (0x1f) and split on it again, so a literal 0x1f byte in a command forges a word
# boundary. The guard only exempts from a parse, so a forged boundary can cause a refusal, not a bypass.

SEP=$'\x1f'
SUBMARK=$'\x1e'
MAX_TOKENIZE_CALLS=200

# read_close <text> <index after the opener> <close char, ")" or a backtick>: sets REPLY_END to the matching closer.
# Inside $( ) quotes hide a ")" and "(" nests; inside backticks only a backslash escapes.
read_close() {
  local s="$1" i="$2" close="$3" n="${#1}" d=1 c rest
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    if [ "$c" = "\\" ]; then i=$((i + 2)); continue; fi
    if [ "$c" = "$close" ]; then
      d=$((d - 1))
      if [ "$d" -eq 0 ]; then REPLY_END=$i; return 0; fi
    elif [ "$close" = ")" ]; then
      case "$c" in
        "'")
          rest="${s:i+1}"
          if [[ "$rest" == *"'"* ]]; then rest="${rest%%"'"*}"; i=$((i + ${#rest} + 1)); else i=$((n - 1)); fi ;;
        '"')
          i=$((i + 1))
          while [ "$i" -lt "$n" ] && [ "${s:i:1}" != '"' ]; do
            if [ "${s:i:1}" = "\\" ]; then i=$((i + 1)); fi
            i=$((i + 1))
          done ;;
        "(") d=$((d + 1)) ;;
      esac
    fi
    i=$((i + 1))
  done
  LOOSE=1; REPLY_END=$n
}

# sub_in <text> <index of "$" or backtick>: tokenizes the substitution that starts there under a new serial; sets
# SUB_NEXT past it and SUB_MARK to the mark its word carries.
sub_in() {
  local s="$1" i="$2" e open=1 close='`' CUR_SUB
  if [ "${s:i:1}" = '$' ]; then open=2; close=")"; fi
  SUB_SERIAL=$((SUB_SERIAL + 1)); CUR_SUB=$SUB_SERIAL
  read_close "$s" $((i + open)) "$close"; e=$REPLY_END
  tokenize "${s:i+open:e-i-open}"
  SUB_NEXT=$((e + 1)); SUB_MARK="\$$SUBMARK$CUR_SUB$SUBMARK"
}

# _flush, _endcmd and the heredoc helpers work on tokenize's locals through bash's dynamic scope.
_flush() {
  if [ "$have" -eq 1 ]; then
    if [ "$redir" -eq 1 ]; then
      redir=0
      if [ "$herestr" -eq 1 ]; then here_word="$w"; herestr=0; fi
    else
      words+=("$w")
    fi
  fi
  w=""; have=0
}

_endcmd() {
  local IFS="$SEP" idx k
  _flush
  redir=0; herestr=0
  if [ "${#words[@]}" -gt 0 ]; then
    idx=${#CMDS[@]}
    CMD_STDIN[idx]="$here_word"; CMD_SUB[idx]="${CUR_SUB:-}"
    for k in "${!hd_delim[@]}"; do [ -n "${hd_cmd[k]:-}" ] || hd_cmd[k]=$idx; done
    CMDS+=("${words[*]}"); level+=("$idx")
  fi
  here_word=""; words=()
}

# _ansi_c reads the $'...' word at index i and appends its decoded text to w. The scan stops only at an unescaped quote,
# so the body cannot close the quote inside eval, and $'...' expands nothing: bash decodes it as it will at run time.
_ansi_c() {
  local j=$((i + 2)) body
  while [ "$j" -lt "$n" ] && [ "${s:j:1}" != "'" ]; do
    if [ "${s:j:1}" = "\\" ]; then j=$((j + 1)); fi
    j=$((j + 1))
  done
  if [ "$j" -ge "$n" ]; then LOOSE=1; w+="${s:i+2}"; i=$n; return 0; fi
  body="${s:i+2:j-i-2}"
  eval "body=\$'$body'"
  w+="$body"; i=$((j + 1))
}

# _heredoc_bodies reads the pending heredoc bodies that start at index i (just after a newline).
_heredoc_bodies() {
  local k rest line cmp body
  for k in "${!hd_delim[@]}"; do
    body=""
    while [ "$i" -lt "$n" ]; do
      rest="${s:i}"
      line="${rest%%$'\n'*}"
      if [[ "$rest" == *$'\n'* ]]; then i=$((i + ${#line} + 1)); else i=$n; fi
      cmp="$line"
      if [ "${hd_strip[k]}" = 1 ]; then cmp="${line#"${line%%[!$'\t']*}"}"; fi
      if [ "$cmp" = "${hd_delim[k]}" ]; then break; fi
      body+="$line"$'\n'
    done
    if [ -n "${hd_cmd[k]:-}" ]; then CMD_STDIN[hd_cmd[k]]="$body"; fi
  done
  hd_delim=(); hd_strip=(); hd_cmd=()
}

# _heredoc_operator reads "<<[-] DELIM" at index i and queues the heredoc; it leaves i after the delimiter.
_heredoc_operator() {
  local j=$((i + 2)) strip=0 d="" ch rest
  if [ "${s:j:1}" = "-" ]; then strip=1; j=$((j + 1)); fi
  while [ "${s:j:1}" = " " ] || [ "${s:j:1}" = $'\t' ]; do j=$((j + 1)); done
  while [ "$j" -lt "$n" ]; do
    ch="${s:j:1}"
    case "$ch" in
      " "|$'\t'|$'\n'|";"|"|"|"&"|"("|")"|"<"|">") break ;;
      "'") rest="${s:j+1}"; rest="${rest%%"'"*}"; d+="$rest"; j=$((j + ${#rest} + 2)); continue ;;
      '"') rest="${s:j+1}"; rest="${rest%%'"'*}"; d+="$rest"; j=$((j + ${#rest} + 2)); continue ;;
      "\\") d+="${s:j+1:1}"; j=$((j + 2)); continue ;;
      *) d+="$ch" ;;
    esac
    j=$((j + 1))
  done
  hd_delim+=("$d"); hd_strip+=("$strip")
  i=$j
}

# tokenize also sets CMD_OUT for the commands of this text level (not of its substitutions) that a pipe follows, and
# for all of them when the level holds an output redirection or a process substitution: a group (`{ a; b; } | sh`) or
# `exec >f` reaches commands the operator is not next to. Operators inside quotes or heredoc bodies do not count.
tokenize() {
  TOKENIZE_CALLS=$((TOKENIZE_CALLS + 1))
  if [ "$TOKENIZE_CALLS" -gt "$MAX_TOKENIZE_CALLS" ]; then LOOSE=1; return 0; fi
  local s="$1" n="${#1}" i=0 c nx ch w="" have=0 redir=0 herestr=0 here_word="" rest q j k buf piped=0 out_all=0
  local -a words=() hd_delim=() hd_strip=() hd_cmd=() level=()
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    case "$c" in
      "\\")
        nx="${s:i+1:1}"
        if [ "$nx" != $'\n' ]; then w+="$nx"; have=1; fi
        i=$((i + 2)) ;;
      "'")
        rest="${s:i+1}"
        if [[ "$rest" == *"'"* ]]; then
          q="${rest%%"'"*}"; w+="$q"; have=1; i=$((i + ${#q} + 2))
        else
          LOOSE=1; w+="$rest"; have=1; i=$n
        fi ;;
      '"')
        j=$((i + 1)); buf=""
        while [ "$j" -lt "$n" ]; do
          ch="${s:j:1}"
          if [ "$ch" = '"' ]; then
            break
          elif [ "$ch" = "\\" ]; then
            nx="${s:j+1:1}"
            case "$nx" in
              '"'|"\\"|'$'|'`') buf+="$nx" ;;
              $'\n') ;;
              *) buf+="\\$nx" ;;
            esac
            j=$((j + 2))
          elif [ "$ch" = '`' ] || { [ "$ch" = '$' ] && [ "${s:j+1:1}" = '(' ]; }; then
            sub_in "$s" "$j"; buf+="$SUB_MARK"; j=$SUB_NEXT
          else
            buf+="$ch"; j=$((j + 1))
          fi
        done
        if [ "$j" -ge "$n" ]; then LOOSE=1; fi
        w+="$buf"; have=1; i=$((j + 1)) ;;
      '$')
        case "${s:i+1:1}" in
          '(') sub_in "$s" "$i"; i=$SUB_NEXT; w+="$SUB_MARK" ;;
          "'") _ansi_c ;;
          '"') i=$((i + 1)) ;;
          *) i=$((i + 1)); w+='$' ;;
        esac
        have=1 ;;
      '`') sub_in "$s" "$i"; i=$SUB_NEXT; w+="$SUB_MARK"; have=1 ;;
      " "|$'\t') _flush; i=$((i + 1)) ;;
      $'\n') _endcmd; i=$((i + 1)); _heredoc_bodies ;;
      "|")
        _endcmd; i=$((i + 1))
        if [ "${s:i:1}" = "|" ]; then
          i=$((i + 1))
        else
          piped=${#level[@]}
          if [ "${s:i:1}" = "&" ]; then i=$((i + 1)); fi
        fi ;;
      "(")
        _flush
        if [ "${#words[@]}" -ge 1 ] && [[ "${s:i+1}" =~ ^[[:space:]]*\) ]]; then FUNC_DEF=1; fi
        _endcmd; i=$((i + 1)) ;;
      ";"|"&"|")") _endcmd; i=$((i + 1)) ;;
      "#")
        if [ "$have" -eq 0 ]; then
          rest="${s:i}"; rest="${rest%%$'\n'*}"; i=$((i + ${#rest}))
        else
          w+="#"; i=$((i + 1))
        fi ;;
      "<"|">")
        if [ "${s:i+1:1}" = '(' ]; then out_all=1; _endcmd; i=$((i + 1)); continue; fi
        if [ "$have" -eq 1 ] && [[ "$w" =~ ^[0-9]+$ ]]; then w=""; have=0; else _flush; fi
        if [ "${s:i:3}" = '<<<' ]; then
          redir=1; herestr=1; i=$((i + 3))
        elif [ "${s:i:2}" = '<<' ]; then
          _heredoc_operator
        else
          j=$i
          while [ "${s:j:1}" = "<" ] || [ "${s:j:1}" = ">" ]; do j=$((j + 1)); done
          if [ "${s:j:1}" = "&" ] || [ "${s:j:1}" = "|" ]; then j=$((j + 1)); fi
          if [[ "${s:i:j-i}" == *'>'* ]]; then out_all=1; fi
          redir=1; i=$j
        fi ;;
      *) w+="$c"; have=1; i=$((i + 1)) ;;
    esac
  done
  _endcmd
  for ((k = 0; k < ${#level[@]}; k++)); do
    if [ "$out_all" -eq 1 ] || [ "$k" -lt "$piped" ]; then CMD_OUT[level[k]]=1; fi
  done
}
