# Shell tokenizer for lanes-guard, sourced by bin/lanes-guard (a library: no shebang, no set -e of its own).
# tokenize <text> appends one SEP-joined string per simple command to CMDS, recursing into $( ), backticks and heredoc
# bodies. Quotes, backslashes and line continuations are removed as the shell removes them. Beside CMDS it fills
# CMD_STDIN[i] (the heredoc body or here-string word fed to command i) and CMD_PIPE[i] (the index of the command piped
# into command i, or -1). Text it cannot parse (an unterminated quote, too much nesting) sets LOOSE and is kept in
# LOOSE_TEXT for a loose pattern match.
# Limit: words are joined with SEP (0x1f) and split on it again, so a literal 0x1f byte in a command forges a word
# boundary. The guard is a mistake guard, so the case is accepted.

SEP=$'\x1f'
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
  LOOSE=1; LOOSE_TEXT+="${s:$2}"$'\n'; REPLY_END=$n
}

# sub_in <text> <index of "$" or backtick>: tokenizes the substitution that starts there; sets SUB_NEXT past it.
sub_in() {
  local s="$1" i="$2" e open=1 close='`'
  if [ "${s:i:1}" = '$' ]; then open=2; close=")"; fi
  read_close "$s" $((i + open)) "$close"; e=$REPLY_END
  tokenize "${s:i+open:e-i-open}"
  SUB_NEXT=$((e + 1))
}

# subst_only <text>: tokenizes only the substitutions inside text (an unquoted heredoc body runs them).
subst_only() {
  local s="$1" i=0 n="${#1}" c
  # shellcheck disable=SC2016 # the patterns are literal text
  [[ "$s" == *'$('* || "$s" == *'`'* ]] || return 0
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    if [ "$c" = "\\" ]; then
      i=$((i + 2))
    elif [ "$c" = '`' ] || { [ "$c" = '$' ] && [ "${s:i+1:1}" = '(' ]; }; then
      sub_in "$s" "$i"; i=$SUB_NEXT
    else
      i=$((i + 1))
    fi
  done
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
    CMD_STDIN[idx]="$here_word"; CMD_PIPE[idx]="$pipe_from"
    for k in "${!hd_delim[@]}"; do [ -n "${hd_cmd[k]:-}" ] || hd_cmd[k]=$idx; done
    CMDS+=("${words[*]}")
    pipe_from=-1
  fi
  here_word=""; words=()
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
    if [ "${hd_quoted[k]}" = 0 ]; then subst_only "$body"; fi
  done
  hd_delim=(); hd_quoted=(); hd_strip=(); hd_cmd=()
}

# _heredoc_operator reads "<<[-] DELIM" at index i and queues the heredoc; it leaves i after the delimiter.
_heredoc_operator() {
  local j=$((i + 2)) strip=0 quoted=0 d="" ch rest
  if [ "${s:j:1}" = "-" ]; then strip=1; j=$((j + 1)); fi
  while [ "${s:j:1}" = " " ] || [ "${s:j:1}" = $'\t' ]; do j=$((j + 1)); done
  while [ "$j" -lt "$n" ]; do
    ch="${s:j:1}"
    case "$ch" in
      " "|$'\t'|$'\n'|";"|"|"|"&"|"("|")"|"<"|">") break ;;
      "'") quoted=1; rest="${s:j+1}"; rest="${rest%%"'"*}"; d+="$rest"; j=$((j + ${#rest} + 2)); continue ;;
      '"') quoted=1; rest="${s:j+1}"; rest="${rest%%'"'*}"; d+="$rest"; j=$((j + ${#rest} + 2)); continue ;;
      "\\") quoted=1; d+="${s:j+1:1}"; j=$((j + 2)); continue ;;
      *) d+="$ch" ;;
    esac
    j=$((j + 1))
  done
  hd_delim+=("$d"); hd_quoted+=("$quoted"); hd_strip+=("$strip")
  i=$j
}

tokenize() {
  TOKENIZE_CALLS=$((TOKENIZE_CALLS + 1))
  if [ "$TOKENIZE_CALLS" -gt "$MAX_TOKENIZE_CALLS" ]; then LOOSE=1; LOOSE_TEXT+="$1"$'\n'; return 0; fi
  local s="$1" n="${#1}" i=0 c nx ch w="" have=0 redir=0 herestr=0 here_word="" pipe_from=-1 rest q j buf
  local -a words=() hd_delim=() hd_quoted=() hd_strip=() hd_cmd=()
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
          LOOSE=1; LOOSE_TEXT+="$rest"$'\n'; w+="$rest"; have=1; i=$n
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
            sub_in "$s" "$j"; buf+='$'; j=$SUB_NEXT
          else
            buf+="$ch"; j=$((j + 1))
          fi
        done
        if [ "$j" -ge "$n" ]; then LOOSE=1; LOOSE_TEXT+="${s:i}"$'\n'; fi
        w+="$buf"; have=1; i=$((j + 1)) ;;
      '$')
        if [ "${s:i+1:1}" = '(' ]; then sub_in "$s" "$i"; i=$SUB_NEXT; else i=$((i + 1)); fi
        w+='$'; have=1 ;;
      '`') sub_in "$s" "$i"; i=$SUB_NEXT; w+='$'; have=1 ;;
      " "|$'\t') _flush; i=$((i + 1)) ;;
      $'\n') _endcmd; i=$((i + 1)); _heredoc_bodies ;;
      "|")
        _endcmd
        if [ "${s:i+1:1}" = "|" ]; then pipe_from=-1; i=$((i + 2)); continue; fi
        pipe_from=$((${#CMDS[@]} - 1)); i=$((i + 1))
        if [ "${s:i:1}" = "&" ]; then i=$((i + 1)); fi ;;
      ";"|"&"|"("|")") _endcmd; pipe_from=-1; i=$((i + 1)) ;;
      "#")
        if [ "$have" -eq 0 ]; then
          rest="${s:i}"; rest="${rest%%$'\n'*}"; i=$((i + ${#rest}))
        else
          w+="#"; i=$((i + 1))
        fi ;;
      "<"|">")
        if [ "${s:i+1:1}" = '(' ]; then _endcmd; i=$((i + 1)); continue; fi
        if [ "$have" -eq 1 ] && [[ "$w" =~ ^[0-9]+$ ]]; then w=""; have=0; else _flush; fi
        if [ "${s:i:3}" = '<<<' ]; then
          redir=1; herestr=1; i=$((i + 3))
        elif [ "${s:i:2}" = '<<' ]; then
          _heredoc_operator
        else
          j=$i
          while [ "${s:j:1}" = "<" ] || [ "${s:j:1}" = ">" ]; do j=$((j + 1)); done
          if [ "${s:j:1}" = "&" ] || [ "${s:j:1}" = "|" ]; then j=$((j + 1)); fi
          redir=1; i=$j
        fi ;;
      *) w+="$c"; have=1; i=$((i + 1)) ;;
    esac
  done
  _endcmd
}
