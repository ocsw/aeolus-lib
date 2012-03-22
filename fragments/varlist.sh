#!/bin/sh

grep '=' aeolus.conf | grep -v '^#' | sed 's/#.*//' | sed 's/ *$//' | \
  sed 's/\(.*\)=.*/\t\1="\$\1\"/' > sendalert.tmp

grep '=' aeolus.conf | grep -v '^#' | sed 's/#.*//' | sed 's/ *$//' | \
  sed 's/\(.*\)=.*/  [ \"${\1+X}\" = \"X\" ] \&\& cl_\1=\"$\1\" \&\& varssaved=\"yes\"/' > savevars.tmp

grep '=' aeolus.conf | grep -v '^#' | sed 's/#.*//' | sed 's/ *$//' | \
  sed 's/\(.*\)=.*/  [ \"${cl_\1+X}\" = \"X\" ] \&\& logstatus \"\1=\\\"$cl_\1\\\"\"/' > logclvars.tmp

grep '=' aeolus.conf | grep -v '^#' | sed 's/#.*//' | sed 's/ *$//' | \
  sed 's/\(.*\)=.*/  [ \"${cl_\1+X}\" = \"X\" ] \&\& \1=\"$cl_\1\"/' > restorevars.tmp

# [ -e aeolus ] && cp -pf aeolus aeolus.bak

sed -n '
  /^INSERTSENDALERT$/ {
    r sendalert.tmp
    b
  }

  /^INSERTSAVEVARS$/ {
    r savevars.tmp
    b
  }

  /^INSERTLOGCLVARS$/ {
    r logclvars.tmp
    b
  }

  /^INSERTRESTOREVARS$/ {
    r restorevars.tmp
    b
  }

  p
' < aeolus.tpl > aeolus

rm sendalert.tmp savevars.tmp logclvars.tmp restorevars.tmp



# alternative sed program:
#
# sed -n '
#   t clear1
#   :clear1
#   s/^INSERTSENDALERT$//
#   t SA
#
#   t clear2
#   :clear2
#   s/^INSERTSAVEVARS$//
#   t SV
#
#   t clear3
#   :clear3
#   s/^INSERTLOGCLVARS$//
#   t LCV
#
#   t clear4
#   :clear4
#   s/^INSERTRESTOREVARS$//
#   t RV
#
#   p
#
#   b
#
#   :SA
#   r sendalert.tmp
#   b
#
#   :SV
#   r savevars.tmp
#   b
#
#   :LCV
#   r logclvars.tmp
#   b
#
#   :RV
#   r restorevars.tmp
#   b
# ' < aeolus.tpl > aeolus
