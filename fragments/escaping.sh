#!/bin/sh

foo ()  {
  /usr/bin/printf "%s\n" "$1"
}
bar () {
  foo "`/usr/bin/printf "%s\n" "$1" | sed 's/\?/\\?/g'`"
  foo "$(/usr/bin/printf "%s\n" "$1" | sed 's/\?/\\?/g')"
  /usr/bin/printf "%s\n" "$1" | sed 's/\?/\\?/g'
  /usr/bin/printf "%s\n" "`/usr/bin/printf "%s\n" "$1" | sed 's/\?/\\?/g'`"
  /usr/bin/printf "%s\n" "$(/usr/bin/printf "%s\n" "$1" | sed 's/\?/\\?/g')"
}
bar "x	g ? \*
f"
#/usr/bin/printf "%s\n" "`bar "x	g ? \*
#f"`"
#/usr/bin/printf "%s\n" "$(bar "x	g ? \*
#f")"
