#!/bin/sh

# list will require editing, and will not include utils not in functions

sed -e ':a' -e '/,$/N; s/,\n//; ta' aeolus aeolus-lib.sh | \
  grep '# utilities: ' | sed 's/# utilities: //' | tr ',#' '\n\n' | \
  sed 's/^ *//' | sed 's/ *$//' | sort -u
