#!/bin/sh

#######################################################################
# Aeolus library (originally factored out of the Aeolus backup script)
# by Daniel Malament
# see ae_license() for license info
#######################################################################

# all commands used should be listed in $externalcmds and the usage notes

# TODO:
# prune dated files by number
#
# better handling of long errors?
# i18n?
# setup modes?
# emulate mkdir -p?
# pathological cases in getparentdir()?
# squeeze // in parentdir() output?
# strange test problems in validcreate()?
# actually parse vars on cl, in config file?
# queue sendalert()s for non-fatal messages (e.g., skipping many DB dumps)?
# globbing in dblist?

# do more to protect against leading - in settings?

############
# debugging
############

#
# turn on debugging
#
do_debug () {
  set -vx
}

# unlike the other settings, we use the value of debugme even before we
# check the config file or validate anything, so we can debug those bits
# (also, none of the other settings would do anything before then, anyway)
#
# however, this only applies if debugging is turned on on the command line;
# see also below
if [ "$debugme" = "yes" ]; then
  do_debug
fi


######################
# hardcoded variables
######################

# for all invocations, regardless of config settings

# name of the script, as reported by usage(), etc.
# change this if you rename the script file
scriptname="aeolus"

# external commands used (potentially)
#
# some things can probably be omitted, like 'set' and 'command';
# they should always be builtins, and anyway, by the time we try to
# test them...
#
externalcmds="
rsync
ssh
nc
mysql
mysqldump
gzip
pigz
bzip2
lzip
date
hostname
logger
mailx
grep
awk
gawk
sed
tr
[
expr
echo
printf
cat
tee
ls
find
diff
cmp
touch
mv
rm
mkdir
mkfifo
pwd
kill
sleep
"

# default path to the config file, if one isn't specified
# change usage notes if you change this
defaultconfigfile="/etc/aeolus/aeolus.conf"

# names of all config file settings
configsettings="
"

# a newline character
# see section 8 of http://www.dwheeler.com/essays/filenames-in-shell.html
newline=$(printf "\nX")
newline="${newline%X}"

# a tab character
tab='	'





############
# debugging
############

#
# clarify how arguments are being grouped
#
# prints number of arguments, and each argument in 's
#
# utilities: printf
#
clarifyargs () {
  printf "%s:" "$#"
  for arg in ${1+"$@"}; do
    printf " '%s'" "$arg"
  done
  printf "\n"
}


###########################
# shutdown and exit values
###########################

#
# update an exit value for the script
#
# if the value has already been set, don't change it,
# so that we can return the value corresponding to
# the first error encountered
#
# global vars: exitval
# utilities: [
#
exitval="-1"
setexitval () {
  if [ "$exitval" = "-1" ]; then
    exitval="$1"
  fi
}

#
# update exit value (see setexitval()) and exit, possibly doing some cleanup
#
# $1 = exit value (required)
#
# if cleanup_on_exit="yes", calls do_exit_cleanup(), which must be defined
# by the calling script
#
# global vars: cleanup_on_exit, exitval
# user-defined functions: do_exit_cleanup()
# library functions: setexitval()
# utilities: [
#
cleanup_on_exit="no"
do_exit () {
  if [ "$cleanup_on_exit" = "yes" ]; then
    do_exit_cleanup
  fi

  setexitval "$1"
  exit "$exitval"
}

#
# print an error to stderr and exit
#
# $1 = message
# $2 = exit value
#
# library functions: do_exit()
# utilities: cat
#
throwerr () {
  cat <<-EOF 1>&2

	$1

	EOF
  do_exit "$2"
}


############################################################
# logging and alerts: stdout/err, syslog, email, status log
############################################################

#
# log a message ($1) to the status log
# (depending on $statuslog)
#
# message is preceded by the date and the script's PID
#
# config settings: statuslog
# utilities: printf, date, [
#
logstatlog () {
  if [ "$statuslog" != "" ]; then
    # note: use quotes to preserve spacing, including in the output of date
    printf "%s\n" "$(date) [$$]: $1" >> "$statuslog"
  fi
}

#
# log a message ($1) to stdout and/or the status log
# (depending on $quiet and $statuslog)
#
# config settings: quiet
# library functions: logstatlog()
# utilities: printf, [
#
logprint () {
  # use "$1" to preserve spacing

  if [ "$quiet" = "no" ]; then  # default to yes
    printf "%s\n" "$1"
  fi

  logstatlog "$1"
}

#
# log a message ($1) to stderr and/or the status log
# (depending on $quiet and $statuslog)
#
# config settings: quiet
# library functions: logstatlog()
# utilities: printf, [
#
logprinterr () {
  # use "$1" to preserve spacing

  if [ "$quiet" = "no" ]; then  # default to yes
    printf "%s\n" "$1" 1>&2
  fi

  logstatlog "$1"
}

#
# actually send a syslog message; factored out here so logger
# is only called in one place, for maintainability
#
# note: syslog may turn control characters into octal, including whitespace
# (e.g., newline -> #012)
#
# $1 = message
# $2 = priority (facility.level or numeric)
#      (optional; use "" if not passing priority but passing a tag)
# $3 = tag (optional)
#
# utilities: logger
#
do_syslog () {
  logger -i ${2:+-p "$2"} ${3:+-t "$3"} "$1"
}

#
# log a status message ($1) to syslog, stdout, and/or the status log
# (depending on $usesyslog, $quiet, and $statuslog)
#
# if $2 is "all", only log to syslog if usesyslog="all" (but printing
# and status logging proceed normally)
#
# config settings: usesyslog, syslogstat, syslogtag
# library functions: do_syslog(), logprint()
# utilities: [
#
logstatus () {
  # use "$1" to preserve spacing

  if { [ "$2" != "all" ] && [ "$usesyslog" != "no" ]; } \
     || \
     { [ "$2" = "all" ] && [ "$usesyslog" = "all" ]; }; then
    do_syslog "$1" "$syslogstat" "$syslogtag"
  fi

  logprint "$1"
}

#
# log an alert/error message ($1) to syslog, stdout, and/or the status log
# (depending on $usesyslog, $quiet, and $statuslog)
#
# if $2 is "all", only log to syslog if usesyslog="all" (but printing
# and status logging proceed normally)
#
# config settings: usesyslog, syslogstat, syslogtag
# library functions: do_syslog(), logprint()
# utilities: [
#
logalert () {
  # use "$1" to preserve spacing

  if { [ "$2" != "all" ] && [ "$usesyslog" != "no" ]; } \
     || \
     { [ "$2" = "all" ] && [ "$usesyslog" = "all" ]; }; then
    do_syslog "$1" "$syslogerr" "$syslogtag"
  fi

  logprint "$1"
}

#
# log a status message ($1) to syslog and/or the status log, (depending on
# $usesyslog and $statuslog), but not to stdout, regardless of the setting
# of $quiet
#
# used to avoid duplication when also logging to the output log
#
# if $2 is "all", only log to syslog if usesyslog="all" (but status logging
# proceeds normally)
#
# "local" vars: savequiet
# config settings: quiet
# library functions: logstatus()
#
logstatusquiet () {
  savequiet="$quiet"
  quiet="yes"
  logstatus "$1" "$2"
  quiet="$savequiet"
}

#
# send an alert email, and log to syslog/stdout/status log that an email
# was sent
#
# * message begins with the contents of $1, followed by the output of
#   sendalert_body(), which must be defined by the calling script
# * if $2 is "log", $1 is also logged before the sent notice
#
# note: even if suppressemail="yes", $1 is still logged
# (if settings permit)
#
# config settings: suppressemail, mailto, subject
# user-defined functions: sendalert_body()
# library functions: logalert()
# utilities: mailx, [
#
sendalert () {
  if [ "$suppressemail" != "yes" ]; then
    mailx -s "$subject" $mailto <<-EOF
	$1
	$(sendalert_body)
	EOF
  fi

  if [ "$2" = "log" ]; then
    logalert "$1"
  fi

  if [ "$suppressemail" != "yes" ]; then
    logalert "alert email sent to $mailto"
  fi
}


####################################
# file tests and path manipulations
####################################

#
# check if the file in $1 is less than $2 minutes old
#
# $2 must be an unsigned integer (/[0-9]+/)
# if timecomptype="date-d", "awk", or "gawk", $3 must be the path to a
#   tempfile (which will be deleted when the function exits)
#
# the file in $1 must exist; check before calling
#
# this is factored out for simplicity, but it's also a wrapper to choose
# between different non-portable methods; see the config settings section,
# under 'timecomptype', for details
#
# returns 0 (true) / 1 (false) / other (error)
#
# "local" vars: curtime, filetime, timediff, reftime, greprv
# config settings: timecomptype
# library functions: escregex()
# utilities: find, grep, date, expr, echo, touch, [
#
newerthan () {
  case "$timecomptype" in
    find)
      # find returns 0 even if no files are matched
      find "$1" \! -mmin +"$2" | grep "^$(escregex "$1")$" > /dev/null 2>&1
      return
      ;;
    date-r)
      curtime=$(date "+%s")
      filetime=$(date -r "$1" "+%s")
      # expr is more portable than $(())
      timediff=$(expr \( "$curtime" - "$filetime" \) / 60)
      [ "$timediff" -lt "$2" ]
      return
      ;;
    date-d)
      reftime=$(date -d "$2 minutes ago" "+%Y%m%d%H%M.%S")
      ;;  # continue after esac
    awk|gawk)
      reftime=$(echo | "$timecomptype" \
          '{print strftime("%Y%m%d%H%M.%S", systime() - ('"$2"' * 60))}')
      ;;  # continue after esac
  esac

  if [ "$3" != "" ] && touch -t "$reftime" "$3"; then
    # find returns 0 even if no files are matched
    find "$1" -newer "$3" | grep "^$(escregex "$1")$" > /dev/null 2>&1
    greprv=$?
    rm -f "$3"
    return "$greprv"
  else
    return 2
  fi
}

#
# wrapper: are two files identical?
#
# $1, $2: file paths
#
# returns 0 (true) / 1 (false) / 2 (error), so test for success, not failure
#
# config settings: filecomptype
# utilities: cmp, diff
#
filecomp () {
  # don't redirect stderr, so we can see any actual errors
  case "$filecomptype" in
    # make sure it's something safe before calling it
    cmp|diff)
      "$filecomptype" "$1" "$2" > /dev/null
      ;;
  esac
}

#
# print the metadata of a file/dir if it exists, or "(none)"
#
# originally, the goal was to be able to just print timestamps, but it's
# more or less impossible to to that portably, so this just prints the
# output of 'ls -ld'
#
# utilities: ls, echo, [
#
getfilemetadata () {
  # -e isn't portable, and we're really only dealing with files and dirs
  # (or links to them, which [ handles for us)
  if [ -f "$1" ] || [ -d "$1" ]; then
    ls -ld "$1" 2>&1
  else
    echo "(none)"
  fi
}

#
# get the parent directory of a file or dir
#
# this is more portable and more correct than dirname;
# in particular, dirname returns . for any of . ./ .. ../
# which fits the documentation, but doesn't make sense for our purposes
#
# to get the "standard" behavior, make $2 non-null
#
# note: still doesn't always correctly handle paths starting with /
# and containing . or .., e.g., getparentdir /foo/..
#
# "local" vars: parentdir
# utilities: printf, echo, sed, grep, [
#
getparentdir () {
  # remove trailing /'s
  parentdir=$(printf "%s\n" "$1" | sed 's|/*$||')

  # are there no /'s left?
  if printf "%s\n" "$parentdir" | grep -v '/' > /dev/null 2>&1; then
    if [ "$parentdir" = "" ]; then
      echo "/"  # it was /, and / is its own parent
      return
    fi
    if [ "$2" = "" ]; then
      if [ "$parentdir" = "." ]; then
        echo ".."
        return
      fi
      if [ "$parentdir" = ".." ]; then
        echo "../.."
        return
      fi
    fi
    echo "."
    return
  fi
  parentdir=$(printf "%s\n" "$parentdir" | sed 's|/*[^/]*$||')
  if [ "$parentdir" = "" ]; then
    echo "/"
    return
  fi
  printf "%s\n" "$parentdir"
}

# tests for getparentdir:
#getparentdir //                   # /
#getparentdir //foo                # /
#getparentdir //foo//              # /
#getparentdir //foo//bar           # //foo
#getparentdir //foo//bar//         # //foo
#getparentdir //foo//bar//baz      # //foo//bar
#getparentdir //foo//bar//baz//    # //foo//bar
#getparentdir .                    # ..
#getparentdir .//                  # ..
#getparentdir . x                  # .
#getparentdir .// x                # .
#getparentdir .//foo               # .
#getparentdir .//foo//             # .
#getparentdir .//foo//bar          # .//foo
#getparentdir .//foo//bar//        # .//foo
#getparentdir .//foo//bar//baz     # .//foo//bar
#getparentdir .//foo//bar//baz//   # .//foo//bar
#getparentdir ..                   # ../..
#getparentdir ..//                 # ../..
#getparentdir .. x                 # .
#getparentdir ..// x               # .
#getparentdir ..//foo              # ..
#getparentdir ..//foo//            # ..
#getparentdir ..//foo//bar         # ..//foo
#getparentdir ..//foo//bar//       # ..//foo
#getparentdir ..//foo//bar//baz    # ..//foo//bar
#getparentdir ..//foo//bar//baz//  # ..//foo//bar
#getparentdir foo                  # .
#getparentdir foo//                # .
#getparentdir foo//bar             # foo
#getparentdir foo//bar//           # foo
#getparentdir foo//bar//baz        # foo//bar
#getparentdir foo//bar//baz//      # foo//bar
#getparentdir foo//bar//baz// x    # foo//bar
#exit


###################################
# character escapes and delimiters
###################################

#
# escape shell glob metacharacters:
#   * ? [
#
# usually, just enclosing strings in quotes suffices for the shell itself,
# but some commands, such as find, take arguments which are then globbed
#
# usage example:
#   find /path -name "$(escglob "$somevar")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# see also escregex(), escereg(), escsedrepl()
#
# utilities: printf, sed
#
escglob () {
  printf "%s\n" "$1" | sed \
      -e 's/\*/\\*/g' \
      -e 's/\?/\\?/g' \
      -e 's/\[/\\[/g'
}

#
# escape basic regex metacharacters:
#   . * [ ^ $ \
#
# for grep, sed, etc.; use when including non-sanitized data in a regex
# for example:
#   somecommand | grep "$(escregex "$somevar")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# characters which are special only in extended regexes are not escaped:
#   ? + ( ) { |
# however, some versions of grep/sed/etc. will still accept these in basic
# regexes when they are preceded by \;
# in this case, our existing escape of \ will keep these from having a
# regex meaning (e.g., '\[' will become '\\[')
#
# see also escereg(), escglob(), escsedrepl()
#
# utilities: printf, sed
#
escregex () {
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
      -e 's/\./\\./g' \
      -e 's/\*/\\*/g' \
      -e 's/\[/\\[/g' \
      -e 's/\^/\\^/g' \
      -e 's/\$/\\$/g'
}

#
# escape basic and extended regex metacharacters:
#   . * [ ^ $ \ ? + ( ) { |
#
# for grep, sed, etc.; use when including non-sanitized data in a regex
# for example:
#   somecommand | grep -E "$(escregex "$somevar")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# portability note: ) needs escaping, but ] and } don't; see, e.g.,
# http://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/autoconf-2.68/html_node/Limitations-of-Usual-Tools.html#Limitations-of-Usual-Tools
# under egrep
#
# see also escregex(), escglob(), escsedrepl()
#
# utilities: printf, sed
#
escereg () {
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
      -e 's/\./\\./g' \
      -e 's/\*/\\*/g' \
      -e 's/\[/\\[/g' \
      -e 's/\^/\\^/g' \
      -e 's/\$/\\$/g' \
      -e 's/?/\\?/g' \
      -e 's/+/\\+/g' \
      -e 's/(/\\(/g' \
      -e 's/)/\\)/g' \
      -e 's/{/\\{/g' \
      -e 's/|/\\|/g'
}

#
# escape sed replacement-expression metacharacters:
#   \ &
#
# usage example:
#   somecommand | sed "s/foo/$(escsedrepl "$somevar")/"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# see also escregex(), for escaping the search expression, getseddelim(),
# for finding delimiters, and escglob() and escereg()
#
# utilities: printf, sed
#
escsedrepl () {
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
      -e 's/&/\\\&/g'
}

#
# find a character that can be used as a sed delimiter for a string
#
# $1 is the string to check; for a substitution, this should be the
# concatenation of both halves, without the 's' or delimiters
#
# prints an empty string if no character can be found (highly unlikely),
# otherwise the delimiter
#
# note: assumes your sed can handle any character as a delimiter
#
# portability note: we can't just escape existing separators because
# escaped separators aren't portable; see
# http://www.gnu.org/savannah-checkouts/gnu/autoconf/manual/autoconf-2.68/html_node/Limitations-of-Usual-Tools.html#Limitations-of-Usual-Tools
# under sed
#
# see also escregex() and escsedrepl(), for escaping sed search and replace
# expressions
#
# "local" vars: seddelim, char
# utilities: printf, tr, [
#
getseddelim () {
  seddelim=""

  # note: some characters are left out because they have special meanings
  # to the shell (e.g., we would have to escape " if we used it as the
  # delimiter)
  for char in '/' '?' '.' ',' '<' '>' ';' ':' '|' '[' ']' '{' '}' \
              '=' '+' '_' '-' '(' ')' '*' '&' '^' '%' '#' '@' '!' '~' \
              A B C D E F G H I J K L M N O P Q R S T U V W X Y Z \
              a b c d e f g h i j k l m n o p q r s t u v w x y z ; do
    # use tr instead of grep so we don't have to worry about metacharacters
    # (we could use escregex(), but that's rather heavyweight for this)
    if [ "$1" = "$(printf "%s\n" "$1" | tr -d "$char")" ]; then
      seddelim="$char"
    fi
  done

  printf "%s" "$seddelim"
}

#
# assemble a complete, escaped, delimited sed substitution command
# (only useful if neither side of the substitution has any metacharacters)
#
# $1: search expression
# $2: replace expression
#
# usage example:
#   somecommand | sed "$(escsedsubst "searchexpr" "replexpr")"
# note that you MUST use $(), NOT ``; `` does strange things with \ escapes
#
# prints an empty string if getseddelim() does, otherwise the command
#
# "local" vars: seddelim, lhs_esc, rhs_esc
# library functions: getseddelim(), escregex(), escsedrepl()
# utilities: printf, [
#
escsedsubst () {
  seddelim=$(getseddelim "$1$2")
  if [ "$seddelim" = "" ]; then
    printf ""
  else
    lhs_esc=$(escregex "$1")
    rhs_esc=$(escsedrepl "$2")
    printf "%s\n" "s$seddelim$lhs_esc$seddelim$rhs_esc$seddelim"
  fi
}


##############################
# startup and config settings
##############################

#
# print a license message to stderr
#
# (this is the license for the library)
#
# utilities: cat
#
ae_license () {
  cat <<EOF 1>&2

Copyright 2011 Daniel Malament.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  1. Redistributions of source code must retain the above copyright
     notice, this list of conditions and the following disclaimer.

  2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

EOF
}

#
# save setting variables supplied on the command line (even if they're set
# to null)
#
# "local" vars: setting, cmdtemp
# global vars: configsettings, clsetsaved
# config settings: (*, cl_*)
# utilities: [
#
clsetsaved="no"
saveclset () {
  # so we know if anything was saved, when we want to use logclconfig
  clsetsaved="no"

  for settings in $configsettings; do
    cmdtemp="[ \"\${$setting+X}\" = \"X\" ] &&"
    cmdtemp="$cmdtemp cl_$setting=\"\$$setting\" && clsetsaved=\"yes\""
    eval "$cmdtemp"  # doesn't work if combined into one line
  done
}

#
# restore setting variables supplied on the command line, overriding the
# config file
#
# "local" vars: setting, cmdtemp
# global vars: configsettings
# config settings: (*, cl_*)
# utilities: [
#
restoreclset () {
  for setting in $configsettings; do
    cmdtemp="[ \"\${cl_$setting+X}\" = \"X\" ] &&"
    cmdtemp="$cmdtemp $setting=\"\$cl_$setting\""
    eval "$cmdtemp"  # doesn't work if combined into one line
  done
}

#
# log config file, current working directory, and setting variables supplied
# on the command line
#
# must be run after saveclset()
#
# "local" vars: setting, cmdtemp
# global vars: configsettings, noconfigfile, configfile, clsetsaved
# config settings: (*, cl_*)
# library functions: logstatus()
# utilities: pwd, [
#
logclconfig () {
  # $(pwd) is more portable than $PWD
  if [ "$noconfigfile" = "yes" ]; then
    logstatus "no config file, cwd: \"$(pwd)\""
  else
    logstatus "using config file: \"$configfile\", cwd: \"$(pwd)\""
  fi

  if [ "$clsetsaved" = "yes" ]; then
    logstatus "settings passed on the command line:"
    for setting in $configsettings; do
      cmdtemp="[ \"\${cl_$setting+X}\" = \"X\" ] &&"
      cmdtemp="$cmdtemp logstatus \"$setting='\$cl_$setting'\""
      eval "$cmdtemp"  # doesn't work if combined into one line
    done
  else
    logstatus "no settings passed on the command line"
  fi
}

#
# print all of the current config settings
#
# will print settings with '""' and "\"\"" sub-quoting correctly,
# but not "''" (prints as '''')
#
# "local" vars: setting
# global vars: configsettings
# config settings: (all)
# utilities: printf
#
printsettings () {
  for setting in $configsettings; do
    eval "printf \"%s\n\" \"$setting=\\\"$`printf '%s' $setting`\\\"\""
  done
}

#
# print the current config settings, including config file name, CWD, etc.
#
# see printsettings() about quoting
#
# doesn't print surrounding blank lines; add them if necessary in context
#
# "local" vars: cfgfilestring
# global vars: noconfigfile, configfile
# library functions: printsettings()
# utilities: cat, pwd, [
#
printconfig () {
  if [ "$noconfigfile" = "yes" ]; then
    cfgfilestring="(none)"
  else
    cfgfilestring="$configfile"
  fi

  # $(pwd) is more portable than $PWD
  cat <<-EOF
	-----------------
	Current Settings:
	-----------------

	Config file: $cfgfilestring
	CWD: $(pwd)

	$(printsettings)
	EOF
}

#
# print a startup error to stderr and exit
#
# $1 = message
#
# global vars: startup_exitval
# library functions: throwerr()
#
throwstartuperr () {
  throwerr "$1" "$startup_exitval"
}

#
# print a command-line option error to stderr and exit
#
# $1 = message
#
# assumes "$scriptname --help" works as expected
#
# global vars: newline, scriptname
# library functions: throwstartuperr()
#
throwusageerr () {
  throwstartuperr "$1${newline}${newline}Run '$scriptname --help' for more information."
}

#
# print a bad-setting error to stderr and exit
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf
#
throwsettingerr () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  throwstartuperr "Error: invalid setting for $vname (\"$vval\"); exiting."
}

#
# validate a setting that can't be blank
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf, [
#
validnoblank () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  if [ "$vval" = "" ]; then
    throwstartuperr "Error: $vname is unset or blank; exiting."
  fi
}

#
# validate two settings that can't both be blank
#
# $1 = first variable name
# $2 = second variable name
#
# "local" vars: vname1, vval1, vname2, vval2
# config settings: (contents of $1, contents of $2)
# library functions: throwstartuperr()
# utilities: printf, [
#
validnotbothblank () {
  vname1="$1"
  eval "vval1=\"$`printf '%s' $vname1`\""
  vname2="$2"
  eval "vval2=\"$`printf '%s' $vname2`\""

  if [ "$vval1" = "" ] && [ "$vval2" = "" ]; then
    throwstartuperr "Error: $vname1 and $vname2 cannot both be blank; exiting."
  fi
}

#
# validate a numeric setting (only digits 0-9 allowed, no - or .)
#
# $1 = variable name
# $2 = minimum (optional, use "" if using $3 but not $2)
# $3 = maximum (optional)
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwsettingerr()
# utilities: printf, grep, [
#
validnum () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  # use extra [0-9] to avoid having to use egrep
  if printf "%s\n" "$vval" | grep '^[0-9][0-9]*$' > /dev/null 2>&1; then
    if [ "$2" != "" ] && [ "$vval" -lt "$2" ]; then
      throwsettingerr "$vname"
    fi
    if [ "$3" != "" ] && [ "$vval" -gt "$3" ]; then
      throwsettingerr "$vname"
    fi
  else
    throwsettingerr "$vname"
  fi
}

#
# validate a setting that may not contain a particular character
#
# $1 = variable name
# $2 = character
#
# "local" vars: vname, vval, char
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf, td, [
#
validnochar () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""
  char="$2"

  # use tr so we don't have to worry about metacharacters
  # (we could use escregex(), but that's rather heavyweight for this)
  if [ "$vval" != "$(printf "%s\n" "$vval" | tr -d "$char")" ]; then
    throwstartuperr "Error: $vname cannot contain '$char' characters; exiting."
  fi
}

#
# validate a directory setting, for directories in which we need to create
# and/or rotate files:
# setting must not be blank, and directory must exist, be a directory or a
# symlink to a one, and have full permissions (r/w/x; r for rotation,
# wx for creating files)
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: validnoblank(), throwstartuperr()
# utilities: printf, [
#
validrwxdir () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  validnoblank "$vname"

  # [ dereferences symlinks for us
  if [ ! -d "$vval" ]; then
    throwstartuperr "Error: $vname is not a directory or a symlink to one; exiting."
  fi
  if [ ! -r "$vval" ]; then
    throwstartuperr "Error: $vname is not readable; exiting."
  fi
  if [ ! -w "$vval" ]; then
    throwstartuperr "Error: $vname is not writable; exiting."
  fi
  if [ ! -x "$vval" ]; then
    throwstartuperr "Error: $vname is not searchable; exiting."
  fi
}

#
# validate a file/dir setting, for files/directories we're going to be
# touching, writing to, creating, and/or rotating (but not reading):
# 1) the setting may not be blank
# 2) if the file/dir exists, then:
#    2a) if $2="file", it must be a file or a symlink to one,
#        and it must be writable
#    2b) if $2="dir", it must be a directory or a symlink to one,
#        and it must be writable and searchable (wx; for creating files)
# 3) regardless, the parent directory must exist, be a directory or a
#    symlink to one, and be writable and searchable (wx); if $3 is not
#    null, it must also be readable (for rotation)
#
# $1 = variable name
# $2 = "file" or "dir"
# $3 = if not null (e.g., "rotate"), parent directory must be readable
#
# note: some tests (e.g., -x) seem to silently succeed in some cases in
# which the file/dir isn't readable, even if they should fail, but I'm
# not going to add extra restrictions just for that
#
# "local" vars: vname, vval, parentdir
# config settings: (contents of $1)
# library functions: validnoblank(), throwstartuperr(), getparentdir()
# utilities: printf, ls, [
#
validcreate () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  # condition 1
  validnoblank "$vname"

  # condition 2
  #
  # note: [ -e ] isn't portable, so try ls, even though it's probably not
  # robust enough to be a general solution...
  if ls "$vval" > /dev/null 2>&1; then
    case "$2" in
      file)
        # [ dereferences symlinks for us
        if [ ! -f "$vval" ]; then
          throwstartuperr "Error: $vname is not a file or a symlink to one; exiting."
        fi
        if [ ! -w "$vval" ]; then
          throwstartuperr "Error: $vname is not writable; exiting."
        fi
        ;;
      dir)
        # [ dereferences symlinks for us
        if [ ! -d "$vval" ]; then
          throwstartuperr "Error: $vname is not a directory or a symlink to one; exiting."
        fi
        if [ ! -w "$vval" ]; then
          throwstartuperr "Error: $vname is not writable; exiting."
        fi
        if [ ! -x "$vval" ]; then
          throwstartuperr "Error: $vname is not searchable; exiting."
        fi
        ;;
      *)
        throwstartuperr "Internal Error: illegal file-type value (\"$2\") in validcreate(); exiting."
        ;;
    esac
  fi

  # condition 3
  parentdir=$(getparentdir "$vval")
  # [ dereferences symlinks for us
  if [ ! -d "$parentdir" ]; then
    # ... or a non-directory, but this is more concise
    throwstartuperr "Error: $vname is in a non-existent directory (\"$parentdir\"); exiting."
  fi
  if [ ! -w "$parentdir" ]; then
    throwstartuperr "Error: $vname is in a non-writable directory; exiting."
  fi
  if [ ! -x "$parentdir" ]; then
    throwstartuperr "Error: $vname is in a non-searchable directory; exiting."
  fi
  if [ "$3" != "" ] && [ ! -r "$parentdir" ]; then
    throwstartuperr "Error: $vname is in a non-readable directory; exiting."
  fi
}

#
# validate a file setting, for files we just need to be able to read:
# setting must not be blank, and file must exist, be a file or a symlink
# to one, and be readable
#
# $1 = variable name ("configfile" treated specially)
#
# "local" vars: vname, vval
# global vars: (contents of $1, if "configfile")
# config settings: (contents of $1, usually)
# library functions: validnoblank(), throwstartuperr()
# utilities: printf, [
#
validreadfile () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  # blank?
  validnoblank "$vname"

  # from here on, we will only be using $vname for printing purposes,
  # so we can doctor it
  if [ "$vname" = "configfile" ]; then
    vname="config file \"$vval\""
  fi

  # not a file or symlink to one?
  # ([ dereferences symlinks for us)
  if [ ! -f "$vval" ]; then
    throwstartuperr "Error: $vname does not exist, or is not a file or a symlink to one; exiting."
  fi

  # not readable?
  if [ ! -r "$vval" ]; then
    throwstartuperr "Error: $vname is not readable; exiting."
  fi
}

#
# validate a file setting, for files we need to be able to read and write,
# but not create or rotate:
# setting must not be blank, and file must exist, be a file or a
# symlink to a file, and be readable and writable
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: validreadfile(), throwstartuperr()
# utilities: printf, [
#
validrwfile () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""

  validreadfile "$vname"

  # not writable?
  if [ ! -w "$vval" ]; then
    throwstartuperr "Error: $vname is not writable; exiting."
  fi
}

#
# validate a setting that can be one of a list of possiblities
#
# $1 = variable name ("mode" treated specially)
# other args = list of possiblities (can include "")
#
# "local" vars: vname, vval, poss
# global vars: (contents of $1, if "mode")
# config settings: (contents of $1, usually)
# library functions: throwusageerr(), throwsettingerr()
# utilities: printf, [
#
validlist () {
  vname="$1"
  eval "vval=\"$`printf '%s' $vname`\""
  shift

  # implied $@ isn't supported by ksh
  for poss in ${1+"$@"}; do
    if [ "$vval" = "$poss" ]; then
      return
    fi
  done

  if [ "$vname" = "mode" ]; then
    throwusageerr "Error: invalid mode supplied on the command line; exiting."
  else
    throwsettingerr "$vname"
  fi
}


####################
# assemble commands
####################

#!!! [config settings]
# $ssh_port: SSH port (optional)
# $ssh_keyfile: path to key file (optional)
# $ssh_options: general options (optional)
# $ssh_user: username (optional)
# $ssh_host: hostname
# $ssh_rcommand: remote command (optional, but usually supplied)
# config settings: tun_sshlocalport, tun_sshremoteport, tun_sshport,
#                  tun_sshkeyfile, tun_sshoptions, tun_sshuser, tun_sshhost
#
# $dbms_prefix: DBMS (currently only "mysql")
# $*_user: username (optional*)
# $*_pwfile: path to password file (optional*)
# $*_protocol: protocol (optional*)
# $*_host: hostname (optional*)
# $*_port: port (optional*)
# $*_socket: socket path (optional*)
# $*_options: client options (optional*)
# $*_dbname: database name (optional*)
# $*_command: SQL command (or equivalent)
#
# * optional arguments may only be optional for some DBMSes; OTOH, not all
#   arguments apply to all DBMSes



#
# run a remote ssh command
#
# config settings: ssh_port, ssh_keyfile, ssh_options, ssh_user, ssh_host,
#                  ssh_rcmd
# utilities: ssh
#
sshrcmdcmd () {
  # note no " on ssh_options
  ssh \
    ${ssh_port:+-p "$ssh_port"} \
    ${ssh_keyfile:+-i "$ssh_keyfile"} \
    ${ssh_options:+ $ssh_options} \
    ${ssh_user:+-l "$ssh_user"} \
    "$ssh_host" \
    ${ssh_rcommand:+ "$ssh_rcommand"}
}

#
# run an ssh tunnel command
#
# config settings: tun_sshlocalport, tun_sshremoteport, tun_sshport,
#                  tun_sshkeyfile, tun_sshoptions, tun_sshuser, tun_sshhost
# utilities: ssh
#
sshtunnelcmd () {
  # note no " on tun_sshoptions
  ssh \
    -L "$ssh_localport:localhost:$ssh_remoteport" -N \
    ${tun_sshport:+-p "$tun_sshport"} \
    ${tun_sshkeyfile:+-i "$tun_sshkeyfile"} \
    ${tun_sshoptions:+ $tun_sshoptions} \
    ${tun_sshuser:+-l "$tun_sshuser"} \
    "$tun_sshhost"
}

#
# run a database command
#
# if $1 is non-null, print the command without running it
#
# global vars: dbms_prefix
# config settings: *_user, *_pwfile, *_protocol, *_host, *_port, *_socket,
#                  *_options, *_dbname, *_command
# utilities: mysql
#
dbcmd () {
  case "$dbms_prefix" in
    mysql)
      # --defaults-extra-file must be the first option if present
      # note no " on mysql_options
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socket:+-S "$mysql_socket"} \
        ${mysql_options:+$mysql_options} \
        ${mysql_dbname:+"$mysql_dbname"} \
        ${mysql_command:+-e "$mysql_command"}
      ;;
  esac
}

#
# run a get-database-list command
#
# (may not be possible/straightforward for all DBMSes)
#
# if $1 is non-null, print the command without running it
#
# for MySQL, '-BN' is already included in the options
#
# global vars: dbms_prefix
# config settings: *_user, *_pwfile, *_protocol, *_host, *_port, *_socket,
#                  *_options
# utilities: mysql
#
dblistcmd () {
  case "$dbms_prefix" in
    mysql)
      # --defaults-extra-file must be the first option if present
      # note no " on mysql_options
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socket:+-S "$mysql_socket"} \
        ${mysql_options:+$mysql_options} \
        -BN -e "SHOW DATABASES;"
      ;;
  esac
}

#
# run an rsync command
#
# if $1 is non-null, print the command without running it
#
# config settings: rsync_mode, rsync_pwfile, rsync_localport, rsync_port,
#                  rsync_sshport, rsync_sshkeyfile, rsync_sshoptions,
#                  rsync_filterfile, rsync_options, rsync_add, rsync_source,
#                  rsync_dest
# utilities: rsync, (ssh)
#
rsynccmd () {
  case "$rsync_mode" in
    tunnel)
      # note no " on rsync_options, rsync_add, rsync_source
      rsync \
        ${rsync_pwfile:+"--password-file=$rsync_pwfile"} \
        "--port=$rsync_localport" \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
        "$rsync_dest"
      ;;
    direct)
      # note no " on rsync_options, rsync_add, rsync_source
      rsync \
        ${rsync_pwfile:+"--password-file=$rsync_pwfile"} \
        ${rsync_port:+"--port=$rsync_port"} \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
        "$rsync_dest"
      ;;
    nodaemon)
      # note no " on rsync_sshoptions, rsync_options, rsync_add,
      # rsync_source
      rsync \
        -e "ssh
            ${rsync_sshport:+-p "$rsync_sshport"} \
            ${rsync_sshkeyfile:+-i "$rsync_sshkeyfile"} \
            ${rsync_sshoptions:+$rsync_sshoptions}" \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
        "$rsync_dest"
      ;;
    local)
      # note no " on rsync_options, rsync_add, rsync_source
      rsync \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options:+$rsync_options} \
        ${rsync_add:+$rsync_add} \
        $rsync_source \
      ;;
  esac
}


######################################
# file rotation, pruning, and zipping
######################################

#
# rotate numbered files
#
# $1: full path up to the number, not including any trailing separator
# $2: separator before the number (not in $1 because the most recent
#     file won't have a separator or a number)
# $3: suffix after the number, including any leading separator
#     (cannot begin with a number)
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $3
#
# also works on directories
#
# in the unlikely event that the function can't find a sed delimeter for
# a string, it calls sendalert() and exits with exit value nodelim_exitval
#
# "local" vars: prefix, sep, suffix, filename, filenum, newnum, newname, D
# global vars: nodelim_exitval
# library functions: escregex(), escsedrepl(), getseddelim(), sendalert(),
#                    do_exit()
# utilities: printf, grep, sed, expr, mv, [
#
rotatenumfiles () {
  prefix="$1"
  sep="$2"
  suffix="$3"

  # first pass
  for filename in "$prefix$sep"[0-9]*"$suffix"*; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$sep[0-9]*$suffix*" ]; then
      break
    fi

    # check more precisely
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1; then
      continue
    fi

    # get the file number
    #
    # the regexp could be a bit more concise, but it would be less portable
    D=$(getseddelim "^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1' in function rotatenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    filenum=$(printf "%s\n" "$filename" | \
              sed "s$D^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$$D\\1$D")

    # create the new filename
    D=$(getseddelim "^\\($(escregex "$prefix$sep")\\)[0-9][0-9]*\\1$(escsedrepl "$newnum")")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^\\($(escregex "$prefix$sep")\\)[0-9][0-9]*\\1$(escsedrepl "$newnum")' in function rotatenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    # expr is more portable than $(())
    newnum=$(expr "$filenum" + 1)  # pulled out for readability (ha)
    newname=$(printf "%s\n" "$filename" | \
              sed "s$D^\\($(escregex "$prefix$sep")\\)[0-9][0-9]*$D\\1$(escsedrepl "$newnum")$D")

    # move the file
    #
    # if we renumber the files without going in descending order,
    # we'll overwrite some, but sorting on the $filenum is tricky;
    # instead, add .new, then rename all of them
    mv "$filename" "$newname.new"
  done  # first pass

  # remove .new extensions
  for filename in "$prefix$sep"[0-9]*"$suffix"*".new"; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$sep[0-9]*$suffix*.new" ]; then
      break
    fi

    # check more precisely and move the file
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz\.new$" > /dev/null 2>&1 \
       || \
       printf "%s\n" "$filename" | grep "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2\.new$" > /dev/null 2>&1; then
      mv "$filename" "$(printf "%s\n" "$filename" | sed 's|\.new$||')"
    else
      continue
    fi
  done

  # handle the most recent file
  for filename in "$prefix$suffix"*; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$suffix*" ]; then
      break
    fi

    # check more precisely
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz2$" > /dev/null 2>&1; then
      continue
    fi

    # move the file
    D=$(getseddelim "^$(escregex "$prefix$suffix")$(escsedrepl "$prefix${sep}1$suffix")")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^$(escregex "$prefix$suffix")$(escsedrepl "$prefix${sep}1$suffix")' in function rotatenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    mv "$filename" "$(printf "%s\n" "$filename" | \
                      sed "s$D^$(escregex "$prefix$suffix")$D$(escsedrepl "$prefix${sep}1$suffix")$D")"
  done
}

#
# prune numbered files by number and date
#
# $1: full path up to the number, not including any trailing separator
# $2: separator before the number
# $3: suffix after the number, including any leading separator
#     (cannot begin with a number)
#
# $4: number of files, 0=unlimited
# $5: days worth of files, 0=unlimited
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $3
#
# also works on directories
#
# "local" vars: prefix, sep, suffix, numf, daysf, filename, filenum, D
# global vars: nodelim_exitval
# library functions: escregex(), getseddelim(), sendalert(), do_exit()
# utilities: printf, grep, sed, rm, find, [
#
prunenumfiles () {
  prefix="$1"
  sep="$2"
  suffix="$3"
  numf="$4"
  daysf="$5"

  # anything to do?
  if [ "$numf" = "0" ] && [ "$daysf" = "0" ]; then
    return
  fi

  for filename in "$prefix$sep"[0-9]*"$suffix"*; do
    # if nothing is found, the actual glob will be used for $filename
    if [ "$filename" = "$prefix$sep[0-9]*$suffix*" ]; then
      break
    fi

    # check more precisely
    #
    # do some contortions to avoid needing egrep
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1; then
      continue
    fi

    # get the file number
    #
    # the regexp could be a bit more concise, but it would be less portable
    D=$(getseddelim "^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1")
    if [ "$D" = "" ]; then
      sendalert "can't find a delimiter for string '^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$\\1' in function prunenumfiles(); exiting" log
      do_exit "$nodelim_exitval"
    fi
    filenum=$(printf "%s\n" "$filename" | \
              sed "s$D^$(escregex "$prefix$sep")\\([0-9][0-9]*\\)$(escregex "$suffix").*\$$D\\1$D")

    # check number and delete
    if [ "$numf" != "0" ] && [ "$filenum" -ge "$numf" ]; then
      # -r for dirs
      rm -rf "$filename"
      continue
    fi

    # delete by date
    if [ "$daysf" != "0" ]; then
      # -r for dirs
      find "$filename" -mtime +"$daysf" -exec rm -rf {} \;
    fi
  done
}

#
# prune dated files by date
#
# _should_ also prune by number, but it's practically impossible to do
# it properly in pure shell
#
# $1: full path up to the date, not including any trailing separator
# $2: separator before the date
# $3: suffix after the date, including any leading separator
#
# $4: days worth of files, 0=unlimited
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $3
#
# also works on directories
#
# note: "current" file must exist before calling this function, so that
# it can be counted
#
# also, because we can't make any assumptions about the format of the date
# string, this function can be over-broad in the files it looks at;
# make sure there are no files that match $prefix$sep*$suffix* except for
# the desired ones
#
# "local" vars: prefix, sep, suffix, daysf, filename
# library functions: escregex()
# utilities: printf, grep, find, rm, [
#
prunedatefiles () {
  prefix="$1"
  sep="$2"
  suffix="$3"
  daysf="$4"

  # prune by date
  if [ "$daysf" != "0" ]; then
    for filename in "$prefix$sep"*"$suffix"*; do
      # if nothing is found, the actual glob will be used for $filename
      if [ "$filename" = "$prefix$sep*$suffix*" ]; then
        break
      fi

      # check more precisely
      #
      # do some contortions to avoid needing egrep
      if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1; then
        continue
      fi

      # delete
      #
      # -r for dirs
      find "$filename" -mtime +"$daysf" -exec rm -rf {} \;
    done
  fi
}

#
# wrapper: prune numbered or dated files by number and date
#
# dated files are only pruned by date; _should_ also prune by number,
# but it's practically impossible to do it properly in pure shell
#
# $1: layout type
#
# $2: full path up to the number/date, not including any trailing separator
# $3: separator before the number/date
# $4: suffix after the number/date, including any leading separator
#     (cannot begin with a number if using a numbered layout)
#
# $5: number of files, 0=unlimited
# $6: days worth of files, 0=unlimited
#
# filenames can have an optional .gz, .bz, .bz2, or .lz after $4
#
# also works on directories
#
# library functions: prunenumfiles(), prunedatefiles()
#
prunefiles () {
  case "$1" in
    # currently, the function is not actually called for "append",
    # but put it here for future use / FTR
    single|singledir|append)
      :  # nothing to do
      ;;
    number|numberdir)
      prunenumfiles "$2" "$3" "$4" "$5" "$6"
      ;;
    date|datedir)
      prunedatefiles "$2" "$3" "$4" "$6"
      ;;
  esac
}

#
# rotate and prune output logs
#
# filenames can have an optional trailing .gz, .bz, .bz2, or .lz
#
# config settings: outputlog, outputlog_layout, outputlog_sep, numlogs,
#                  dayslogs
# library functions: logstatus(), rotatenumfiles(), prunefiles()
# utilities: [
#
rotatepruneoutputlogs () {
  if [ "$outputlog" = "" ]; then
    logstatus "output logging is off; not rotating logs"
    return
  fi

  if [ "$outputlog_layout" = "append" ]; then
    logstatus "output logs are being appended to a single file; not rotating logs"
    return
  fi

  logstatus "rotating logs"

  # rotate
  if [ "$outputlog_layout" = "number" ]; then
    rotatenumfiles "$outputlog" "$outputlog_sep" ""
  fi

  # prune
  prunefiles "$outputlog_layout" "$outputlog" "$outputlog_sep" "" \
             "$numlogs" "$dayslogs"
}

#
# remove a file, including zipped versions of it
#
# $1 = file to remove
# $2 = type of zip to remove (same options as *_zipmode)
#
# utilities: rm
#
removefilezip () {
  rm -f "$1"
  case "$2" in
    none)
      :  # nothing else to remove
      ;;
    gzip|pigz)
      rm -f "$1.gz"
      ;;
    bzip2)
      rm -f "$1.bz"
      rm -f "$1.bz2"
      ;;
    lzip)
      rm -f "$1.lz"
      ;;
  esac
}


################
# SSH functions
################

#
# open an SSH tunnel
#
# one tunnel at a time; closesshtunnel() must be run before opening
# another tunnel
#
# returns 1 to mean "skip to the next phase of the backup", else 0
#
# "local" vars: waited, sshexit
# global vars: cmd, sshpid, tun_prefix, tun_localport, tun_sshtimeout,
# library funcs: sshtunnelcmd()
# FDs: 3
#
opensshtunnel () {
  # log that we're starting
  logstatusquiet "running SSH tunnel command for $tun_prefix"
  printf "%s\n" "running SSH tunnel command for $tun_prefix" >&3

  # run the command
  #
  # note & _in the quotes_, so $! contains the correct pid
  sshtunnelcmd >&3 2>&1 &
  sshpid="$!"

  # make sure it's actually working;
  # see http://mywiki.wooledge.org/ProcessManagement#Starting_a_.22daemon.22_and_checking_whether_it_started_successfully
  waited="0"
  while sleep 1; do
    nc -z localhost "$tun_localport" && break
    if kill -0 "$sshpid"; then
      # expr is more portable than $(())
      waited=$(expr "$waited" + 1)
      if [ "$waited" -ge "$tun_sshtimeout" ]; then
        sendalert "could not establish SSH tunnel for $tun_prefix (timed out); exiting" log
        kill "$sshpid"
        wait "$sshpid"
        case "$on_ssherr" in
          exit)
            do_exit "$sshtunnel_exitval"
            ;;
          phase)
            return 1  # skip to the next phase
            ;;
        esac
      fi
    else
      wait "$sshpid"
      sshexit="$?"
      sendalert "could not establish SSH tunnel for $tun_prefix (error code $sshexit); exiting" log
      case "$on_ssherr" in
        exit)
          do_exit "$sshtunnel_exitval"
          ;;
        phase)
          return 1  # skip to the next phase
          ;;
      esac
    fi
  done

  logstatus "SSH tunnel for $tun_prefix established"

  return 0
}

#
# close an SSH tunnel
#
# global vars: sshpid, tun_prefix
#
closesshtunnel () {
  kill "$sshpid"
  wait "$sshpid"
  sshpid=""  # so we know if a tunnel is open
  logstatus "SSH tunnel for $tun_prefix closed"
}


#####################
# database functions
#####################

#
# convert DB name escape sequences to the real characters
#
# $1 = DB name to un-escape
#
# sequences to un-escape:
#   newline -> \n
#   tab -> \t
#   \ -> \\
#
# see also getdblist()
#
dbunescape () {
  # note: \\ must be last; \t isn't portable in sed
  printf "%s\n" "$1" | sed \
      -e 's/^\\n/\n/' -e 's/\([^\]\)\\n/\1\n/g' \
      -e "s/^\\\\t/$tab/" -e "s/\\([^\\]\)\\\\t/\\1$tab/g" \
      -e 's/\\\\/\\/g'
}



##############################################################################

foo () {

  create)
    # output a "blank" config file
    #
    # do this _before_ applying default config file
    if [ "$noconfigfile" = "no" ] && [ "$configfile" != "" ]; then
      if [ -f "$configfile" ]; then
        throwusageerr "Error: specified config file already exists; exiting."
      else
        exec 3>&1  # save for later
        exec 1>"$configfile"
      fi
    fi
    echo
    echo "# see CONFIG for details"
    echo
    for setting in $configsettings; do
      eval 'printf "%s\n" "#$setting=\"\""'
    done
    if [ "$noconfigfile" = "no" ] && [ "$configfile" != "" ]; then
      exec 1>&3  # put stdout back
    fi
    do_exit "$no_error_exitval"
    ;;


# save variables set on the command line
saveclset

# check and source config file
if [ "$noconfigfile" = "no" ]; then
  # apply default config file if applicable
  if [ "$configfile" = "" ]; then
    configfile="$defaultconfigfile"
  fi

  validreadfile "configfile"

  # . won't work with no directory (unless ./ is in the PATH);
  # the cwd has to be specified explicitly
  if printf "%s\n" "$configfile" | grep -v '/' > /dev/null 2>&1; then
    . "./$configfile"
  else
    . "$configfile"
  fi
fi

# restore variables set on the command line, overriding the config file
restoreclset

# apply default settings where applicable
applydefaults

# validate the config settings
validconf


# handle remaining command-line mode options
# these are meant to be run manually from the command line, so only
# log actual status changes
case "$mode" in
  silence)
    # silence lockfile-exists alerts
    if [ ! -d "$lockfile" ]; then  # -e isn't portable
      echo "lockfile directory doesn't exist; nothing to silence"
      do_exit "$startup_exitval"
    fi
    if [ -f "$lockfile/$silencealerts" ]; then  # -e isn't portable
      echo "lockfile alerts were already silenced"
      do_exit "$startup_exitval"
    fi
    # using a file in the lockfile dir means that we automatically
    # get the silencing cleared when the lockfile is removed
    touch "$lockfile/$silencealerts"
    echo "lockfile alerts have been silenced"
    quiet="yes"  # don't print to the terminal again
    logclconfig  # so we know what the status message means
    logstatus "lockfile alerts have been silenced, lockfile=\"$lockfile\""
    do_exit "$no_error_exitval"
    ;;
  unsilence)
    # unsilence lockfile-exists alerts
    if [ ! -f "$lockfile/$silencealerts" ]; then  # -e isn't portable
      echo "lockfile alerts were already unsilenced"
      do_exit "$startup_exitval"
    fi
    rm -f "$lockfile/$silencealerts"
    echo "lockfile alerts have been unsilenced"
    quiet="yes"  # don't print to the terminal again
    logclconfig  # so we know what the status message means
    logstatus "lockfile alerts have been unsilenced, lockfile=\"$lockfile\""
    do_exit "$no_error_exitval"
    ;;
  stop|disable)
    # disable backups
    if [ -f "$lockfile/$disable" ]; then  # -e isn't portable
      echo "backups were already disabled"
      do_exit "$startup_exitval"
    fi
    if [ -d "$lockfile" ]; then  # -e isn't portable
      echo "lockfile directory exists; a backup is probably running"
      echo "disable command will take effect after the current backup finishes"
      echo
    fi
    mkdir "$lockfile" > /dev/null 2>&1  # ignore already-exists errors
    touch "$lockfile/$disable"
    echo "backups have been disabled; remember to re-enable them later!"
    quiet="yes"  # don't print to the terminal again
    logclconfig  # so we know what the status message means
    logstatus "backups have been disabled, lockfile=\"$lockfile\""
    do_exit "$no_error_exitval"
    ;;
  start|enable)
    # re-enable backups
    if [ ! -f "$lockfile/$disable" ]; then  # -e isn't portable
      echo "backups were already enabled"
      do_exit "$startup_exitval"
    fi
    rm -f "$lockfile/$disable"
    echo "backups have been re-enabled"
    echo "if a backup is not currently running, you should now remove the lockfile"
    echo "with the unlock command"
    quiet="yes"  # don't print to the terminal again
    logclconfig  # so we know what the status message means
    logstatus "backups have been re-enabled, lockfile=\"$lockfile\""
    do_exit "$no_error_exitval"
    ;;
  clearlock|unlock)
    # remove lockfile dir
    if [ ! -d "$lockfile" ]; then  # -e isn't portable
      echo "lockfile has already been removed"
      do_exit "$startup_exitval"
    fi
    echo
    echo "WARNING: the lockfile should only be removed if you're sure a backup is not"
    echo "currently running."
    echo "Type 'y' (without the quotes) to continue."
    # it would be nice to have this on the same line as the prompt,
    # but the portability issues aren't worth it for this
    read type_y
    if [ "$type_y" != "y" ]; then
      echo "Exiting."
      do_exit "$no_error_exitval"
    fi
    echo
    rm -rf "$lockfile"
    echo "lockfile has been removed"
    quiet="yes"  # don't print to the terminal again
    logclconfig  # so we know what the status message means
    logstatus "lockfile \"$lockfile\" has been manually removed"
    do_exit "$no_error_exitval"
    ;;
  systemtest)
    echo
    echo "checking for commands in the PATH..."
    echo "(note that missing commands may not matter, depending on the command"
    echo "and the settings used; on the other hand, commands may be present"
    echo "but not support required options)"
    echo
    for cmd in $externalcmds; do
      if command -v "$cmd" > /dev/null 2>&1; then
        printf "%-10s\n" "$cmd was found"
      else
        printf "%-10s\n" "$cmd was NOT found"
      fi
    done
    echo
    do_exit "$no_error_exitval"
    ;;
esac

# log config file, current working directory, and setting variables supplied
# on the command line
logclconfig


################
# status checks
################

if [ "$runevery" != "0" ]; then
  # has it been long enough since the last backup started?
  #
  # if $startedfile exists and is newer than $runevery, exit
  # (-f instead of -e because it's more portable)
  if [ -f "$startedfile" ] && newerthan "$startedfile" "$runevery"; then
    logstatus "backup interval has not expired; exiting"
    do_exit "$no_error_exitval"
  else
    logstatus "backup interval has expired; continuing"
  fi
else
  logstatus "interval checking has been disabled; continuing"
fi

# did the previous backup finish?
#
# use an atomic command to check and create the lock
# (could also be ln -s, but we might not be able to set the metadata, and
#  it could cause issues with commands that don't manipulate links directly;
#  plus, now we have a tempdir)
if mkdir "$lockfile" > /dev/null 2>&1; then
  # got the lock, clear lock-alert status
  if [ -f "$alertfile" ]; then  # -f is more portable than -e
    rm "$alertfile"
    sendalert "lockfile created; cancelling previous alert status" log
  fi
  # set flag to remove the lockfile (etc.) on exit
  cleanup_on_exit="yes"
else
  # assume mkdir failed because it already existed;
  # but that could be because we manually disabled backups
  if [ -f "$lockfile/$disable" ]; then
    logalert "backups have been manually disabled; exiting"
  else
    logalert "could not create lockfile (previous backup still running or failed?); exiting"
  fi
  # don't actually exit yet

  # send the initial alert email (no "log", we already logged it)
  #
  # (-f instead of -e because it's more portable)
  if [ ! -f "$alertfile" ]; then
    touch "$alertfile"
    if [ -f "$lockfile/$disable" ]; then
      sendalert "backups have been manually disabled; exiting"
    else
      sendalert "could not create lockfile (previous backup still running or failed?); exiting"
    fi
    do_exit "$lockfile_exitval"
  fi

  # but what about subsequent emails?

  # if ifrunning=0, log it but don't send email
  if [ "$ifrunning" = "0" ]; then
    logalert "ifrunning=0; no email sent"
    do_exit "$lockfile_exitval"
  fi

  # if alerts have been silenced, log it but don't send email
  # (and don't bother checking $ifrunning)
  if [ -f "$lockfile/$silencealerts" ]; then
    logalert "alerts have been silenced; no email sent"
    do_exit "$lockfile_exitval"
  fi

  # if $alertfile is newer than $ifrunning, log it but don't send email
  if newerthan "$alertfile" "$ifrunning"; then
    logalert "alert interval has not expired; no email sent"
    do_exit "$lockfile_exitval"
  fi

  # send an alert email (no "log", we already logged it)
  touch "$alertfile"
  if [ -f "$lockfile/$disable" ]; then
    sendalert "backups have been manually disabled; exiting"
  else
    sendalert "could not create lockfile (previous backup still running or failed?); exiting"
  fi
  do_exit "$lockfile_exitval"
fi  # if mkdir "$lockfile"


###################
# get date strings
###################

# get them all now, so they're as close together as possible

# for the current output log; set the filename while we're at it
outputlog_filename="$outputlog"
if [ "$outputlog" != "" ] && [ "$outputlog_layout" = "date" ]; then
  if [ "$outputlog_date" != "" ]; then
    outputlog_datestring=$(date "$outputlog_date")
  else
    outputlog_datestring=$(date)
  fi
  outputlog_filename="$outputlog_filename$outputlog_sep$outputlog_datestring"
  touch "$outputlog_filename"  # needed for prunedayslogs()
fi

# for the current DB dump filenames
for dbms in $dbmslist; do
  switchdbms "$dbms"

  if [ "$dbms_dodump" = "yes" ] \
     && \
     { [ "$dbms_layout" = "date" ] || [ "$dbms_layout" = "datedir" ]; }; then
    if [ "$dbms_filedirdate" != "" ]; then
      dbms_datestring=$(date "$dbms_filedirdate")
    else
      dbms_datestring=$(date)
    fi
    eval "`printf '%s\n' $dbms`_datestring=\"$dbms_datestring\""
  fi
done


###################
# start output log
###################

# set up a fifo for logging; this has two benefits:
# 1) we can handle multiple output options in one place
# 2) we can run commands without needing pipelines, so we can get the
#    return values
mkfifo "$lockfile/$logfifo"

# rotate and prune output logs
# (also tests in case there is no output log, and prints status accordingly)
rotatepruneoutputlogs

if [ "$outputlog" != "" ]; then
  # append to the output log and possibly stdout
  # appending is always safe / the right thing to do, because either the
  # file won't exist, or it will have been moved out of the way by the
  # rotation - except in one case:
  # if we're using a date layout, and the script has been run more recently
  # than the datestring allows for, we should append so as not to lose
  # information
  if [ "$quiet" = "no" ]; then  # default to yes
    tee -a "$outputlog_filename" < "$lockfile/$logfifo" &
  else
    cat >> "$outputlog_filename" < "$lockfile/$logfifo" &
  fi
else  # no output log
  if [ "$quiet" = "no" ]; then
    cat < "$lockfile/$logfifo" &
  else
    cat > /dev/null < "$lockfile/$logfifo" &
  fi
fi

# create an fd to write to instead of the fifo,
# so it won't be closed after every line;
# see http://mywiki.wooledge.org/BashFAQ/085
exec 3> "$lockfile/$logfifo"


################
# begin working
################

# starting notifications/timestamps
logstatus "starting backup"
touch "$startedfile"
printf "%s\n" "backup started $(date)" >&3

# are we supposed to actually do anything?
do_something="no"  # set this to yes later if we do something


###########
# DB dumps
###########

########
# rsync
########

###############
# done working
###############

# did we actually do anything?
if [ "$do_something" = "no" ]; then  # everything was turned off
  logstatus "nothing to do, because no actions are turned on"
fi

# finishing notifications
logstatus "backup finished"
printf "%s\n" "backup finished $(date)" >&3


##################
# stop output log
##################

# remove the fifo and kill the reader process;
# note that we don't have to worry about doing this if we exit abnormally,
# because exiting will close the fd, and the fifo is in the lockfile dir

exec 3>&-  # close the fd, this should kill the reader
rm -f "$lockfile/$logfifo"


###########
# clean up
###########

do_exit "$no_error_exitval"

}
