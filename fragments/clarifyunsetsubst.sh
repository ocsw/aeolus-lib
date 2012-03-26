#!/bin/sh

clarifyargs () {
  printf "%s:" "$#"
  for arg in ${1+"$@"}; do
    printf " '%s'" "$arg"
  done
  printf "\n"
}

a="c d"

[ "$(clarifyargs ${a:+a b})"     != "2: 'a' 'b'" ] && echo "fail"
[ "$(clarifyargs ${a:+"a b"})"   != "1: 'a b'" ]   && echo "fail"
[ "$(clarifyargs "${a:+a b}")"   != "1: 'a b'" ]   && echo "fail"
[ "$(clarifyargs "${a:+"a b"}")" != "1: 'a b'" ]   && echo "fail"

[ "$(clarifyargs ${a:+$a})"     != "2: 'c' 'd'" ] && echo "fail"
[ "$(clarifyargs ${a:+"$a"})"   != "1: 'c d'" ]   && echo "fail"
[ "$(clarifyargs "${a:+$a}")"   != "1: 'c d'" ]   && echo "fail"
[ "$(clarifyargs "${a:+"$a"}")" != "1: 'c d'" ]   && echo "fail"
