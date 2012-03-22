#!/bin/sh

bar () {
  foo "$1"
}

foo () {
  a="$1"
  b="$a"

  eval 'printf "%s\n" "$b"'
}

bar "asd \"
ddd"
