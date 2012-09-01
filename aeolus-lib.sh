#!/bin/bash

#######################################################################
# Aeolus library (originally factored out of the Aeolus backup script)
# by Daniel Malament
# see ae_license() for license info
#######################################################################

# TODO:
# prune dated files by number
#
# better handling of long errors?
# i18n?
# pathological cases in getparentdir()?
# squeeze // in getparentdir() output?
# strange test problems in validcreate()?
# actually parse vars on cl, in config file?
# queue sendalert()s for non-fatal messages (e.g., skipping many DB dumps)?
# allow char devs / fifos in cases where we currently test for -f?
#  (but could cause problems with, e.g., rm...)
#
# do more to protect against leading - in settings?


############################################################################
#                              VERSION CHECK
############################################################################

#
# if we're not running a high enough version of bash, we shouldn't even try
# to parse the code below
#

# we can't use arithmetical tests because BASH_VERSINFO[1] wasn't always
# purely numeric
case "$BASH_VERSION" in
  1.*|2.*|3.0.*)
    cat <<-EOF 1>&2

	This script requires bash version 3.1 or later.

	EOF
    exit 1
    ;;
esac


############################################################################
#                                VARIABLES
############################################################################

###################
# useful constants
###################

# a newline character
# see section 8 of http://www.dwheeler.com/essays/filenames-in-shell.html
newline=$(printf "\nX")
newline="${newline%X}"

# a tab character
tab='	'


#####################
# initialize globals
#####################

#
# unconditional globals
#

# test for this if you need to know if the library has been sourced yet
aeolus_lib_sourced="yes"


#
# defaults; we only set them if they aren't already set
#

# exit values
[ "${no_error_exitval+X}" = "" ] && no_error_exitval="0"
[ "${startup_exitval+X}" = "" ] && startup_exitval="1"
[ "${lockfile_exitval+X}" = "" ] && lockfile_exitval="2"
[ "${badvarname_exitval+X}" = "" ] && badvarname_exitval="3"
[ "${nodelim_exitval+X}" = "" ] && nodelim_exitval="4"
[ "${sshtunnel_exitval+X}" = "" ] && sshtunnel_exitval="5"

# on-error flags
[ "${on_tunerr+X}" = "" ] && on_tunerr="exit"  # see opensshtunnel()

# names of tempfiles stored in the lockfile directory
#
# (note: past tense partly because some shells have issues with functions
# having the same names as variables)
#
[ "${lfalertssilenced+X}" = "" ] && lfalertssilenced="lfalertssilenced"
[ "${scriptdisabled+X}" = "" ] && scriptdisabled="scriptdisabled"
[ "${timetemp+X}" = "" ] && timetemp="timetemp"
[ "${logfifo+X}" = "" ] && logfifo="logfifo"


############################################################################
#                                FUNCTIONS
############################################################################

####################
# variable handling
####################

#
# check if a string is a legal variable name
#
# $1 is the string to check
#
# returns 0/1 (true/false)
#
# see http://mywiki.wooledge.org/BashFAQ/048
#
# utilities: [
#
islegalvarname () {
  if [ "$1" = "" ]; then
    return 1  # false
  fi

  case "$1" in
    [!a-zA-Z_]*|*[!a-zA-Z_0-9]*)
      return 1  # false
      ;;
  esac

  return 0  # true
}

#
# check if a string is a safe subscript name for an associative array
# (where "safe" means safe to pass to eval)
#
# to be paranoid, we only allow alphanumerics, _, and spaces
#
# $1 is the string to check
#
# returns 0/1 (true/false)
#
issafesubscript () {
  if [ "$1" = "" ]; then
    return 1  # false
  fi

  case "$1" in
    *[!a-zA-Z_0-9\ ]*)
      return 1  # false
      ;;
  esac

  return 0  # true
}

#
# check if a non-array variable specified by name is set
# (whether it's blank or not)
#
# for arrays, use arrayisset() instead
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname+X}" = "X" ]
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# library vars: badvarname_exitval
# library functions: islegalvarname()
# utilities: printf, [
#
isset () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}+X}\" = \"X\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isset(); exiting."
    exit "$badvarname_exitval"
  fi
}

#
# check if a non-array variable specified by name is unset
# (which is not the same thing as blank)
#
# for arrays, use arrayisunset() instead
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname+X}" = "" ]
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# library vars: badvarname_exitval
# library functions: islegalvarname()
# utilities: printf, [
#
isunset () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}+X}\" = \"\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isunset(); exiting."
    exit "$badvarname_exitval"
  fi
}

#
# check if an array specified by name is set
#
# an array is considered set if it has any set elements, even if those
# elements are blank
#
# only needed if the name of the array isn't known until run-time;
# otherwise, use:
#   [ "${#arrayname[@]}" != "0" ]
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# library vars: badvarname_exitval
# library functions: islegalvarname()
# utilities: printf, [
# bashisms: arrays
#
arrayisset () {
  if islegalvarname "$1"; then
    eval "[ \"\${#${1}[@]}\" != \"0\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisset(); exiting."
    exit "$badvarname_exitval"
  fi
}

#
# check if an array specified by name is unset
#
# an array is considered unset if it has no set elements
# (blank still counts as set)
#
# only needed if the name of the array isn't known until run-time;
# otherwise, use:
#   [ "${#arrayname[@]}" = "0" ]
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# library vars: badvarname_exitval
# library functions: islegalvarname()
# utilities: printf, [
# bashisms: arrays
#
arrayisunset () {
  if islegalvarname "$1"; then
    eval "[ \"\${#${1}[@]}\" = \"0\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisunset(); exiting."
    exit "$badvarname_exitval"
  fi
}

#
# copy between non-array variables specified by name
#
# $1 = the name of the source variable
# $2 = the name of the destination variable
#
# this function is usually unnecessary; use one of these instead:
#   foo="$bar"
#   foo="${!bar}"                       [bash only]
#   printf -v "foo" "%s" "$bar"         [bash v3.1]
#   printf -v "foo" "%s" "${!bar}"      [bash v3.1]
#   printf -v "$foo" "%s" "$bar"        [bash v3.1]
#   printf -v "$foo" "%s" "${!bar}"     [bash v3.1]
#   printf -v "${!foo}" "%s" "$bar"     [bash v3.1]
#   printf -v "${!foo}" "%s" "${!bar}"  [bash v3.1]
# depending on the degree of indirection required and (relatedly) which
# variable names are known prior to run-time
#
# an example in which this function _is_ useful:
#   copyvar "q_$foo" "bar"
# the equivalent direct command doesn't work, because ${!var} won't
# perform substitution on 'var':
#   printf -v "bar" "%s" "${!q_$foo}"  [wrong!]
# the extra evaluation during the function call makes the first example
# work; alternatively, you can set a temp variable to "q_$foo" and then do
#   printf -v "bar" "%s" "${!temp}"  [bash v3.1]
# but using this function is neater, especially if you have many assignments
# to do
#
# library vars: badvarname_exitval
# library functions: islegalvarname()
# utilities: printf
# bashisms: if !, ${!var}, printf -v [v3.1]
#
copyvar () {
  # not strictly necessary since bash will throw an error itself,
  # but this standardizes the errors and the exit values
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in copyvar(); exiting."
    exit "$badvarname_exitval"
  fi
  if ! islegalvarname "$2"; then
    printf "%s\n" "Internal Error: illegal variable name ('$2') in copyvar(); exiting."
    exit "$badvarname_exitval"
  fi

  printf -v "$2" "%s" "${!1}"
}

#
# copy between arrays specified by name
#
# $1 = the name of the source array
# $2 = the name of the destination array
#
# if the source array is associative, the destination array must be
# declared associative before calling (declare -A)
#
# this function is only needed if one or both of the arrays' names are't
# known until run-time; otherwise, use:
#   skeys=("${!sourcename[@]}")
#
#   unset "destname"
#   for skey in "${skeys[@]}"; do
#     destname["$skey"]="${sourcename["$skey"]}"
#   done
#
# in bash 4.1+, printf -v can take array[key] as an argument, which would
# make this function unnecessary if the source name is known but the
# destination name isn't; replace the line starting with destname, above,
# with:
#     printf -v "$dest[$skey]" "%s" "${sourcename["$skey"]}"
# where dest contains the name of the destination array
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: skey, skeys
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript()
# utilities: printf
# bashisms: if !, unset, ${!array[@]} [v3.0]
#
copyarray () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in copyarray(); exiting."
    exit "$badvarname_exitval"
  fi
  if ! islegalvarname "$2"; then
    printf "%s\n" "Internal Error: illegal variable name ('$2') in copyarray(); exiting."
    exit "$badvarname_exitval"
  fi

  eval "skeys=(\"\${!${1}[@]}\")"

  # unset will also remove associative array status,
  # and we can't just redeclare it because that will make it local
  # unless we use -g, which requires bash 4.2
  #unset "$2"
  eval "${2}=()"

  for skey in "${skeys[@]}"; do
    if ! issafesubscript "$skey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$skey') in copyarray(); exiting."
      exit "$badvarname_exitval"
    fi
    eval "${2}[\"$skey\"]=\"\${${1}[\"$skey\"]}\""
  done
}

#
# print the contents of a non-array variable specified by name
#
# $1 = the name of the variable to print
#
# this function is usually unnecessary; use one of these instead:
#   printf "%s" "$foo"
#   printf "%s" "${!foo}"  [bash only]
# depending on the degree of indirection required and (relatedly) which
# variable names are known prior to run-time
#
# an example in which this function _is_ useful:
#   printvar "q_$foo"
# the equivalent direct command doesn't work, because ${!var} won't
# perform substitution on 'var':
#   printf "%s" "${!q_$foo}"  [wrong!]
# the extra evaluation during the function call makes the first example
# work; alternatively, you can set a temp variable to "q_$foo" and then do
#   printf "%s" "${!temp}"  [bash only]
# but using this function is neater, especially if you have many variables
# to print
#
# note: when capturing output, you MUST use $(), NOT ``; `` does strange
# things with \ escapes
#
# library vars: badvarname_exitval
# library functions: islegalvarname()
# utilities: printf
# bashisms: if !, ${!var}
#
printvar () {
  # not strictly necessary since bash will throw an error itself,
  # but this standardizes the errors and the exit values
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in printvar(); exiting."
    exit "$badvarname_exitval"
  fi

  printf "%s" "${!1}"
}

#
# print the contents of an array specified by name
#
# $1 = the name of the array to print
# $2 = if not null, print the keys as well as the values (suggested
#      value: "keys")
#
# output format, $2 null:
#    ( 'value1' 'value2' ... )
# output format, $2 not null:
#    ( ['key1']='value1' ['key2']='value2' ... )
#
# (there is no way in bash to tell the difference between a completely
# undeclared variable and an array with no elements; both produce '( )'
# here)
#
# note: when capturing output, you MUST use $(), NOT ``; `` does strange
# things with \ escapes
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: akey, akeys
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript()
# utilities: printf, [
# bashisms: if !, ${!array[@]} [v3.0]
#
printarray () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in printarray(); exiting."
    exit "$badvarname_exitval"
  fi

  eval "akeys=(\"\${!${1}[@]}\")"

  printf "%s" "( "
  if [ "$2" = "" ]; then  # just print values
    for akey in "${akeys[@]}"; do
      # probably don't need to test $akey, because it's already been set,
      # implying that it's legal; but just in case...
      if ! issafesubscript "$akey"; then
        printf "%s\n" "Internal Error: illegal subscript name ('$akey') in printarray(); exiting."
        exit "$badvarname_exitval"
      fi
      eval "printf \"%s\" \"'\${${1}[\"$akey\"]}' \""
    done
  else  # include keys
    for akey in "${akeys[@]}"; do
      # in theory we don't need to test $akey, because it's already been set,
      # implying that it's legal; but we're going to be more restrictive
      # (paranoid) than that anyway
      if ! issafesubscript "$akey"; then
        printf "%s\n" "Internal Error: illegal subscript name ('$akey') in printarray(); exiting."
        exit "$badvarname_exitval"
      fi
      eval "printf \"%s\" \"['$akey']='\${${1}[\"$akey\"]}' \""
    done
  fi
  printf "%s\n" ")"
}

#
# un-sparse an indexed array specified by name
#
# $1 = the name of the array to un-sparse
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: akey, akeys, unsparsetmp
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript(), copyarray()
# utilities: printf
# bashisms: if !, unset, ${!array[@]} [v3.0], array+=() [v3.1]
#
unsparsearray () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in unsparsearray(); exiting."
    exit "$badvarname_exitval"
  fi

  eval "akeys=(\"\${!${1}[@]}\")"

  # copy to unsparsetmp array, un-sparsing
  unset unsparsetmp
  for akey in "${akeys[@]}"; do
    # in theory we don't need to test $akey, because it's already been set,
    # implying that it's legal; but we're going to be more restrictive
    # (paranoid) than that anyway
    if ! issafesubscript "$akey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$akey') in unsparsearray(); exiting."
      exit "$badvarname_exitval"
    fi
    eval "unsparsetmp+=(\"\${${1}[\"$akey\"]}\")"
  done

  # replace original array
  copyarray unsparsetmp "$1"
}


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

#
# check for the existence of external commands in the PATH
#
# "local" vars: extcmd, cmdlen
# global vars: externalcmds
# utilities: printf, echo
#
checkextcmds () {
  # get column width
  cmdlen=0
  for extcmd in $externalcmds; do
     # if [ "${#extcmd}" -gt "$cmdlen" ]; then
     # slower but more portable; see http://mywiki.wooledge.org/BashFAQ/007
     if [ "$(expr \( "X$extcmd" : ".*" \) - 1)" -gt "$cmdlen" ]; then
      cmdlen="${#extcmd}"
    fi
  done

  echo
  echo "checking for commands in the PATH..."
  echo "(note that missing commands may not matter, depending on the command"
  echo "and the settings used; on the other hand, commands may be present"
  echo "but not support required options)"
  echo
  for extcmd in $externalcmds; do
    if command -v "$extcmd" > /dev/null 2>&1; then
      printf "%-${cmdlen}s %s\n" "$extcmd" "was found"
    else
      printf "%-${cmdlen}s %s\n" "$extcmd" "was NOT found"
    fi
  done
  echo
}


###########################
# shutdown and exit values
###########################

#
# update an exit value for the script
#
# $1 = exit value
#
# if the value has already been set, don't change it,
# so that we can return the value corresponding to
# the first error encountered
#
# global vars: exitval
# utilities: [
#
setexitval () {
  if [ "${exitval:+X}" = "" ]; then
    exitval="$1"
  fi
}

#
# update exit value (see setexitval()) and exit, possibly doing some cleanup
#
# $1 = exit value (required)
#
# if cleanup_on_exit is non-null, calls do_exit_cleanup(), which must be
# defined by the calling script
#
# for clarity, a value of "yes" is recommended when setting cleanup_on_exit
#
# global vars: cleanup_on_exit, exitval
# user-defined functions: do_exit_cleanup()
# library functions: setexitval()
# utilities: [
#
do_exit () {
  if [ "$cleanup_on_exit" != "" ]; then
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


########################################################################
# logging and alerts: stdout/err, syslog, email, status log, output log
########################################################################

#
# log a message ($1) to the status log
# (depending on $statuslog)
#
# message is preceded by the date and the script's PID
#
# config settings: statuslog
# utilities: printf, date, [
# files: $statuslog
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
# config settings: usesyslog, syslogerr, syslogtag
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
# log an alert/error message ($1) to syslog and/or the status log,
# (depending on $usesyslog and $statuslog), but not to stdout, regardless of
# the setting of $quiet
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
logalertquiet () {
  savequiet="$quiet"
  quiet="yes"
  logalert "$1" "$2"
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

#
# start the output log pipe
#
# set up a fifo for logging; this has two benefits:
# 1) we can handle multiple output options in one place
# 2) we can run commands without needing pipelines, so we can get the
#    return values
#
# NOTE: this function also gets the datestring for the output log name, so
# if you need to get other datestrings close to that one, get them right
# *before* calling this function
#
# "local" vars: outputlog_filename, outputlog_datestring
# global vars: logfifo
# config settings: lockfile, outputlog, outputlog_layout, outputlog_sep,
#                  outputlog_date, quiet
# library functions: rotatepruneoutputlogs()
# utilities: date, touch, mkfifo, tee, cat, [
# files: $lockfile/$logfifo, $outputlog, (previous outputlogs)
# FDs: 3
#
startoutputlog () {
  # get the full filename, including datestring if applicable
  outputlog_filename="$outputlog"
  if [ "$outputlog" != "" ] && [ "$outputlog_layout" = "date" ]; then
    if [ "$outputlog_date" != "" ]; then
      outputlog_datestring=$(date "$outputlog_date")
    else
      outputlog_datestring=$(date)
    fi
    outputlog_filename="$outputlog_filename$outputlog_sep$outputlog_datestring"

    # needed for prunedayslogs(), for pruning by number
    touch "$outputlog_filename"
  fi

  mkfifo "$lockfile/$logfifo"

  # rotate and prune output logs
  # (also tests in case there is no output log, and prints status
  # accordingly)
  rotatepruneoutputlogs

  if [ "$outputlog" != "" ]; then
    # append to the output log and possibly stdout
    # appending is always safe / the right thing to do, because either the
    # file won't exist, or it will have been moved out of the way by the
    # rotation - except in one case:
    # if we're using a date layout, and the script has been run more
    # recently than the datestring allows for, we should append so as not to
    # lose information
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
}

#
# stop the output log pipe
#
# remove the fifo and kill the reader process;
# note that we don't have to worry about doing this if we exit abnormally,
# because exiting will close the fd, and the fifo is in the lockfile dir
#
# global vars: logfifo
# config settings: lockfile
# utilities: rm
# files: $lockfile/$logfifo
# FDs: 3
#
stopoutputlog () {
  exec 3>&-  # close the fd, this should kill the reader
  rm -f "$lockfile/$logfifo"
}

#
# see also rotatepruneoutputlogs()
#


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
# utilities: find, grep, date, expr, echo, awk, gawk, touch, [
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
      # note that expr returns an integer; unclear if it's rounded or
      # truncated
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
# stderr is left alone; redirect it for completely silent operation even
# under error conditions
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

# tests for getparentdir():
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
#   * ? [ \
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
  # note: \ must be first
  printf "%s\n" "$1" | sed \
      -e 's/\\/\\\\/g' \
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
              a b c d e f g h i j k l m n o p q r s t u v w x y z \
              ' ' "$tab" ; do
    # use tr instead of grep so we don't have to worry about metacharacters
    # (we could use escregex(), but that's rather heavyweight for this)
    if [ "$1" = "$(printf "%s\n" "$1" | tr -d "$char")" ]; then
      seddelim="$char"
      break
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
# utilities: echo, printf, [
#
escsedsubst () {
  seddelim=$(getseddelim "$1$2")
  if [ "$seddelim" = "" ]; then
    echo
  else
    lhs_esc=$(escregex "$1")
    rhs_esc=$(escsedrepl "$2")
    printf "%s\n" "s$seddelim$lhs_esc$seddelim$rhs_esc$seddelim"
  fi
}


####################################
# startup and config settings/files
####################################

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
# the calling script must define configsettingisarray(), which takes the
# name of a config setting and returns 0 (true) or 1 (false)
#
# "local" vars: setting
# global vars: configsettings, clsetsaved
# config settings: (*, cl_*)
# user-defined functions: configsettingisarray()
# library functions: arrayisset(), copyarray(), isset()
# bashisms: ${!var}, printf -v [v3.1]
#
saveclset () {
  # so we know if anything was saved, when we want to use logclconfig()
  clsetsaved="no"

  for setting in $configsettings; do
    if configsettingisarray "$setting"; then
      if arrayisset "$setting"; then
        copyarray "$setting" "cl_$setting"
        clsetsaved="yes"
      fi
    else
      if isset "$setting"; then
        printf -v "cl_$setting" "%s" "${!setting}"
        clsetsaved="yes"
      fi
    fi
  done
}

#
# restore setting variables supplied on the command line, overriding the
# config file
#
# the calling script must define configsettingisarray(), which takes the
# name of a config setting and returns 0 (true) or 1 (false)
#
# "local" vars: setting
# global vars: configsettings
# config settings: (*, cl_*)
# user-defined functions: configsettingisarray()
# library functions: arrayisset(), copyarray(), isset(), copyvar()
#
restoreclset () {
  for setting in $configsettings; do
    if configsettingisarray "$setting"; then
      if arrayisset "cl_$setting"; then
        copyarray "cl_$setting" "$setting"
      fi
    else
      if isset "cl_$setting"; then
        copyvar "cl_$setting" "$setting"
      fi
    fi
  done
}

#
# log config file, current working directory, and setting variables supplied
# on the command line
#
# saveclset() must be called before this function, to set up $cl_*
#
# the calling script must define configsettingisarray(), which takes the
# name of a config setting and returns 0 (true) or 1 (false)
#
# "local" vars: setting
# global vars: configsettings, noconfigfile, configfile, clsetsaved
# config settings: (*, cl_*)
# user-defined functions: configsettingisarray()
# library functions: logstatus(), arrayisset(), printarray(), isset(),
#                    printvar()
# utilities: pwd, [
#
logclconfig () {
  # $(pwd) is more portable than $PWD
  if [ "$noconfigfile" = "yes" ]; then
    logstatus "no config file, cwd: '$(pwd)'"
  else
    logstatus "using config file: '$configfile', cwd: '$(pwd)'"
  fi

  if [ "$clsetsaved" = "yes" ]; then
    logstatus "settings passed on the command line:"
    for setting in $configsettings; do
      if configsettingisarray "$setting"; then
        if arrayisset "cl_$setting"; then
          logstatus "$setting=$(printarray "cl_$setting")"
        fi
      else
        if isset "cl_$setting"; then
          logstatus "$setting='$(printvar "cl_$setting")'"
        fi
      fi
    done
  else
    logstatus "no settings passed on the command line"
  fi
}

#
# print all of the current config settings
#
# note: does not print all types of sub-quoting correctly (i.e., in a format
# that can be used on the command line or in a config file)
#
# the calling script must define configsettingisarray(), which takes the
# name of a config setting and returns 0 (true) or 1 (false)
#
# "local" vars: setting
# global vars: configsettings
# config settings: (all)
# user-defined functions: configsettingisarray()
# library functions: printarray()
# utilities: printf
# bashisms: ${!var}
#
printsettings () {
  for setting in $configsettings; do
    if configsettingisarray "$setting"; then
      printf "%s\n" "$setting=$(printarray "$setting")"
    else
      printf "%s\n" "$setting='${!setting}'"
    fi
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

	(check quoting before re-using)

	Config file: $cfgfilestring
	CWD: $(pwd)

	$(printsettings)
	EOF
}

#
# output a "blank" config file
#
# $1 is a string to use as the header of the config file, e.g.:
# "# see CONFIG for details"
#
# returns 1 if the config file already exists, else 0
#
# the calling script must define configsettingisarray(), which takes the
# name of a config setting and returns 0 (true) or 1 (false)
#
# note: this function is mostly meant to be run from a manual command line
# mode, but for flexibility, it does not call do_exit() itself
#
# "local" vars: setting
# global vars: configfile, noconfigfile, configsettings
# user-defined functions: configsettingisarray()
# utilities: printf, [
# FDs: 4
#
createblankconfig () {
  if [ "$noconfigfile" = "no" ] && [ "$configfile" != "" ]; then
    if [ -f "$configfile" ]; then
      return 1
    else
      # use a separate FD to make the code cleaner
      exec 4>&1  # save for later
      exec 1>"$configfile"
    fi
  fi

  # header
  printf "\n"
  printf "%s\n" "$1"
  printf "\n"

  # config settings
  for setting in $configsettings; do
    if configsettingisarray "$setting"; then
      printf "%s\n" "#$setting=()"
    else
      printf "%s\n" "#$setting=\"\""
    fi
  done

  if [ "$noconfigfile" = "no" ] && [ "$configfile" != "" ]; then
    exec 1>&4  # put stdout back
  fi

  return 0
}

#
# print a startup error to stderr and exit
#
# $1 = message
#
# library vars: startup_exitval
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
# global vars: scriptname
# library vars: newline
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
# bashisms: ${!var}
#
throwsettingerr () {
  vname="$1"
  vval="${!vname}"

  throwstartuperr "Error: invalid setting for $vname ('$vval'); exiting."
}

#
# validate a setting that can't be blank
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: [
# bashisms: ${!var}
#
validnoblank () {
  vname="$1"
  vval="${!vname}"

  if [ "$vval" = "" ]; then
    throwstartuperr "Error: $vname is unset or blank; exiting."
  fi
}

#
# validate an array setting that can't be blank
# (i.e. there must be at least one non-null member of the array)
#
# $1 = variable name
#
# "local" vars: aname, arrcopy, val
# config settings: (contents of $1)
# library functions: copyarray(), throwstartuperr()
# utilities: [
# bashisms: arrays
#
validnoblankarr () {
  aname="$1"
  copyarray "$aname" "arrcopy"

  # go through the array; if we use [*] or [@] we won't we able to tell the
  # difference between ("" "") and (" ")
  for val in "${arrcopy[@]}"; do
    if [ "$val" != "" ]; then
      return
    fi
  done

  throwstartuperr "Error: $aname is unset or blank; exiting."
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
# utilities: [
# bashisms: ${!var}
#
validnotbothblank () {
  vname1="$1"
  vname2="$2"
  vval1="${!vname1}"
  vval2="${!vname2}"

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
# bashisms: ${!var}
#
validnum () {
  vname="$1"
  vval="${!vname}"

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
# "local" vars: vname, vval, nochar
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: printf, tr, [
# bashisms: ${!var}
#
validnochar () {
  vname="$1"
  vval="${!vname}"
  nochar="$2"

  # use tr so we don't have to worry about metacharacters
  # (we could use escregex(), but that's rather heavyweight for this)
  if [ "$vval" != "$(printf "%s\n" "$vval" | tr -d "$nochar")" ]; then
    throwstartuperr "Error: $vname cannot contain '$nochar' characters; exiting."
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
# utilities: [
# bashisms: ${!var}
#
validrwxdir () {
  vname="$1"
  vval="${!vname}"

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
# utilities: ls, [
# bashisms: ${!var}
#
validcreate () {
  vname="$1"
  vval="${!vname}"

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
        throwstartuperr "Internal Error: illegal file-type value ('$2') in validcreate(); exiting."
        ;;
    esac
  fi

  # condition 3
  parentdir=$(getparentdir "$vval")
  # [ dereferences symlinks for us
  if [ ! -d "$parentdir" ]; then
    # ... or a non-directory, but this is more concise
    throwstartuperr "Error: $vname is in a non-existent directory ('$parentdir'); exiting."
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
# utilities: [
# bashisms: ${!var}
#
validreadfile () {
  vname="$1"
  vval="${!vname}"

  # blank?
  validnoblank "$vname"

  # from here on, we will only be using $vname for printing purposes,
  # so we can doctor it
  if [ "$vname" = "configfile" ]; then
    vname="config file '$vval'"
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
# utilities: [
# bashisms: ${!var}
#
validrwfile () {
  vname="$1"
  vval="${!vname}"

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
# utilities: [
# bashisms: ${!var}
#
validlist () {
  vname="$1"
  vval="${!vname}"
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

#
# process command-line settings and the config file
#
# the calling script must define applydefaults() and validconf();
# neither needs to return anything
#
# global vars: configfile, noconfigfile, defaultconfigfile
# user-defined functions: applydefaults(), validconf()
# library functions: saveclset(), restoreclset(), validreadfile()
# utilities: printf, grep, [
#
do_config () {
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
}


##################################
# status checks and modifications
##################################

#
# check if we should actually start running
#
# * has $runevery passed?
# * does the $lockfile already exist?
# * send alerts about it if necessary
# * has the script been disabled?
#
# $1 is a description of the script's purpose, such as "backup"; this is
# used in messages like "backup interval has not expired"
# $2 is the plural of $1, used in messages like "backups have been manually
# disabled"
#
# global vars: cleanup_on_exit, lfalertssilenced, scriptdisabled, timetemp
# config settings: runevery, startedfile, lockfile, ifrunning, alertfile
# library vars: no_error_exitval, lockfile_exitval
# library functions: newerthan(), logstatus(), logalert(), sendalert(),
#                    do_exit()
# utilities: mkdir, rm, touch, [
# files: $startedfile, $lockfile, $alertfile, $lockfile/$lfalertssilenced,
#        $lockfile/$scriptdisabled, $lockfile/timetemp
#
checkstatus () {
  if [ "$runevery" != "0" ]; then
    # has it been long enough since the script was last started
    # (sucessfully)?
    #
    # if $startedfile exists and is newer than $runevery, exit
    # (-f instead of -e because it's more portable)
    if [ -f "$startedfile" ] \
       && \
       newerthan "$startedfile" "$runevery" "$lockfile/$timetemp"; then
      logstatus "$1 interval has not expired; exiting"
      do_exit "$no_error_exitval"
    else
      logstatus "$1 interval has expired; continuing"
    fi
  else
    logstatus "interval checking has been disabled; continuing"
  fi

  # did the previous run finish?
  #
  # use an atomic command to check and create the lock
  # (could also be ln -s, but we might not be able to set the metadata, and
  # it could cause issues with commands that don't manipulate symlinks
  # directly; plus, now we have a tempdir)
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
    # but that could be because we manually disabled the script
    if [ -f "$lockfile/$scriptdisabled" ]; then
      logalert "$2 have been manually disabled; exiting"
    else
      logalert "could not create lockfile (previous $1 still running or failed?); exiting"
    fi
    # don't actually exit yet

    # send the initial alert email (no "log", we already logged it)
    #
    # (-f instead of -e because it's more portable)
    if [ ! -f "$alertfile" ]; then
      touch "$alertfile"
      if [ -f "$lockfile/$scriptdisabled" ]; then
        sendalert "$2 have been manually disabled; exiting"
      else
        sendalert "could not create lockfile (previous $1 still running or failed?); exiting"
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
    if [ -f "$lockfile/$lfalertssilenced" ]; then
      logalert "alerts have been silenced; no email sent"
      do_exit "$lockfile_exitval"
    fi

    # if $alertfile is newer than $ifrunning, log it but don't send email
    if newerthan "$alertfile" "$ifrunning" "$lockfile/$timetemp"; then
      logalert "alert interval has not expired; no email sent"
      do_exit "$lockfile_exitval"
    fi

    # send an alert email (no "log", we already logged it)
    touch "$alertfile"
    if [ -f "$lockfile/$scriptdisabled" ]; then
      sendalert "$2 have been manually disabled; exiting"
    else
      sendalert "could not create lockfile (previous $1 still running or failed?); exiting"
    fi
    do_exit "$lockfile_exitval"
  fi  # if mkdir "$lockfile"
}

#
# begin working
#
# log starting messages and timestamp, and touch $startedfile
#
# config settings: startedfile
# library functions: logstatus()
# utilities: touch, printf, date
# files: $startedfile
# FDs: 3
#
do_start () {
  logstatus "starting backup"
  touch "$startedfile"
  printf "%s\n" "backup started $(date)" >&3
}

#
# done working
#
# log finished messages and timestamp
#
# library functions: logstatus()
# utilities: printf, date
# FDs: 3
#
do_finish () {
  logstatus "backup finished"
  printf "%s\n" "backup finished $(date)" >&3
}

#
# note: below functions are meant to be run from manual command line modes,
# not autonomous operation; they only log actual status changes, and they
# exit when finished
#

#
# silence lockfile-exists alerts
#
# global vars: lfalertssilenced
# config settings: lockfile, quiet (value not actually used)
# library vars: no_error_exitval, startup_exitval
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: touch, echo, [
# files: $lockfile, $lockfile/$lfalertssilenced
#
silencelfalerts () {
  echo
  if [ ! -d "$lockfile" ]; then  # -e isn't portable
    echo "lockfile directory doesn't exist; nothing to silence"
    echo
    do_exit "$startup_exitval"
  fi
  if [ -f "$lockfile/$lfalertssilenced" ]; then  # -e isn't portable
    echo "lockfile alerts were already silenced"
    echo
    do_exit "$startup_exitval"
  fi
  # using a file in the lockfile dir means that we automatically
  # get the silencing cleared when the lockfile is removed
  touch "$lockfile/$lfalertssilenced"
  echo "lockfile alerts have been silenced"
  echo
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "lockfile alerts have been silenced, lockfile='$lockfile'"
  do_exit "$no_error_exitval"
}

#
# unsilence lockfile-exists alerts
#
# global vars: lfalertssilenced
# config settings: lockfile, quiet (value not actually used)
# library vars: no_error_exitval, startup_exitval
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: rm, echo, [
# files: $lockfile/$lfalertssilenced
#
unsilencelfalerts () {
  echo
  if [ ! -f "$lockfile/$lfalertssilenced" ]; then  # -e isn't portable
    echo "lockfile alerts were already unsilenced"
    echo
    do_exit "$startup_exitval"
  fi
  rm -f "$lockfile/$lfalertssilenced"
  echo "lockfile alerts have been unsilenced"
  echo
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "lockfile alerts have been unsilenced, lockfile='$lockfile'"
  do_exit "$no_error_exitval"
}

#
# disable the script
#
# $1 is the article to use with $2, such as "a" or "an"; this is used in
# messages like "a backup is probably running"
# $2 is a description of the script's purpose, such as "backup"; this is
# used in messages like "after the current backup finishes"
# $3 is the plural of $2, used in messages like "backups have been disabled"
#
# global vars: scriptdisabled
# config settings: lockfile, quiet (value not actually used)
# library vars: no_error_exitval, startup_exitval
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: mkdir, touch, echo, printf, [
# files: $lockfile, $lockfile/scriptdisabled
#
disablescript () {
  echo
  if [ -f "$lockfile/$scriptdisabled" ]; then  # -e isn't portable
    printf "%s\n" "$3 were already disabled"
    echo
    do_exit "$startup_exitval"
  fi
  if [ -d "$lockfile" ]; then  # -e isn't portable
    printf "%s\n" "lockfile directory exists; $1 $2 is probably running"
    printf "%s\n" "disable command will take effect after the current $2 finishes"
    echo
  fi
  mkdir "$lockfile" > /dev/null 2>&1  # ignore already-exists errors
  touch "$lockfile/$scriptdisabled"
  printf "%s\n" "$3 have been disabled; remember to re-enable them later!"
  echo
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "$3 have been disabled, lockfile='$lockfile'"
  do_exit "$no_error_exitval"
}

#
# (re-)enable the script
#
# $1 is the article to use with $2, such as "a" or "an"; this is used in
# messages like "a backup is probably running"
# $2 is a description of the script's purpose, such as "backup"; this is
# used in messages like "after the current backup finishes"
# $3 is the plural of $2, used in messages like "backups have been disabled"
#
# global vars: scriptdisabled
# config settings: lockfile, quiet (value not actually used)
# library vars: no_error_exitval, startup_exitval
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: rm, echo, printf, [
# files: $lockfile/$scriptdisabled
#
enablescript () {
  echo
  if [ ! -f "$lockfile/$scriptdisabled" ]; then  # -e isn't portable
    printf "%s\n" "$3 were already enabled"
    echo
    do_exit "$startup_exitval"
  fi
  rm -f "$lockfile/$scriptdisabled"
  printf "%s\n" "$3 have been re-enabled"
  echo
  printf "%s\n" "if $1 $2 is not currently running, you should now remove the lockfile"
  printf "%s\n" "with the unlock command"
  echo
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "$3 have been re-enabled, lockfile='$lockfile'"
  do_exit "$no_error_exitval"
}

#
# forcibly remove the lockfile directory
#
# $1 is the article to use with $2, such as "a" or "an"; this is used in
# messages like "a backup is probably running"
# $2 is a description of the script's purpose, such as "backup"; this is
# used in messages like "after the current backup finishes"
#
# "local" vars: type_y
# config settings: lockfile, quiet (value not actually used)
# library vars: no_error_exitval, startup_exitval
# library functions: logclconfig(), logstatus(), do_exit()
# utilities: rm, echo, printf, [
# files: $lockfile
#
clearlock () {
  echo
  if [ ! -d "$lockfile" ]; then  # -e isn't portable
    echo "lockfile has already been removed"
    echo
    do_exit "$startup_exitval"
  fi
  printf "%s\n" "WARNING: the lockfile should only be removed if you're sure $1 $2 is not"
  printf "%s\n" "currently running."
  printf "%s\n" "Type 'y' (without the quotes) to continue."
  # it would be nice to have this on the same line as the prompt,
  # but the portability issues aren't worth it for this
  read type_y
  if [ "$type_y" != "y" ]; then
    echo
    echo "Exiting."
    echo
    do_exit "$no_error_exitval"
  fi
  rm -rf "$lockfile"
  echo
  echo "lockfile has been removed"
  echo
  quiet="yes"  # don't print to the terminal again
  logclconfig  # so we know what the status message means
  logstatus "lockfile '$lockfile' has been manually removed"
  do_exit "$no_error_exitval"
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
# library vars: nodelim_exitval
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 ; then
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
    if printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.new$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz\.new$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz\.new$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2\.new$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz\.new$" > /dev/null 2>&1 ; then
      continue
    else
      mv "$filename" "$(printf "%s\n" "$filename" | sed 's|\.new$||')"
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz2$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.lz$" > /dev/null 2>&1 ; then
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
# library vars: nodelim_exitval
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 ; then
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

    # check the number and delete
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
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.gz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 ; then
        continue
      fi

      # delete by date
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
# (see prunedatefiles())
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
    single|singledir|append)
      # not generally called for these, but here for future use / FTR
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
# files: $outputlog, (previous outputlogs)
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
# check if a file exists, including zipped versions of it
#
# $1 = filename
# $2 = type of zip to check for ("gzip", "pigz", "bzip2", "lzip", "all" for
# all of the above, or "none")
#
# if they exist, files must be regular files or symlinks to regular files
#
# returns 0/1 (true/false)
#
# utilities: [
#
existsfilezip () {
  [ "$1" = "" ] && return 1;  # false

  case "$2" in
    none)
      [ -f "$1" ]
      ;;
    gzip|pigz)
      [ -f "$1" ] || [ -f "$1.gz" ]
      ;;
    bzip2)
      [ -f "$1" ] || [ -f "$1.bz" ] || [ -f "$1.bz2" ]
      ;;
    lzip)
      [ -f "$1" ] || [ -f "$1.lz" ]
      ;;
    all)
      [ -f "$1" ] || [ -f "$1.gz" ] || [ -f "$1.bz" ] || [ -f "$1.bz2" ] || \
          [ -f "$1.lz" ]
      ;;
    *)  # just in case
      return 1  # false
  esac
}

#
# remove a file, including zipped versions of it
#
# $1 = file to remove
# $2 = type of zip to remove ("gzip", "pigz", "bzip2", "lzip", "all" for all
# of the above, or "none")
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
    all)
      rm -f "$1.gz"
      rm -f "$1.bz"
      rm -f "$1.bz2"
      rm -f "$1.lz"
      ;;
  esac
}


##################################
# SSH remote commands and tunnels
##################################

#
# run a remote SSH command
#
# ssh_options and ssh_rcommand must be indexed, non-sparse arrays
#
# config settings: ssh_port, ssh_keyfile, ssh_options, ssh_user, ssh_host,
#                  ssh_rcommand
# utilities: ssh
# files: $ssh_keyfile
# bashisms: arrays
#
sshremotecmd () {
  ssh \
    ${ssh_port:+-p "$ssh_port"} \
    ${ssh_keyfile:+-i "$ssh_keyfile"} \
    ${ssh_options+"${ssh_options[@]}"} \
    ${ssh_user:+-l "$ssh_user"} \
    "$ssh_host" \
    ${ssh_rcommand+"${ssh_rcommand[@]}"}
}

#
# run a remote SSH command in the background
#
# $1 is the name of a global variable to store the ssh PID in, to
# differentiate between multiple commands; if unset or null, it defaults to
# "sshpid"
#
# ssh_options and ssh_rcommand must be indexed, non-sparse arrays
#
# "local" vars: sshpid_var, sshpid_l
# global vars: (contents of $1, or sshpid)
# config settings: ssh_port, ssh_keyfile, ssh_options, ssh_user, ssh_host,
#                  ssh_rcommand
# utilities: ssh, printf, [
# files: $ssh_keyfile
# bashisms: arrays, printf -v [v3.1]
#
sshremotebgcmd () {
  # apply default
  sshpid_var="sshpid"

  # get value, if set
  [ "$1" != "" ] && sshpid_var="$1"

  # run the command
  ssh \
    ${ssh_port:+-p "$ssh_port"} \
    ${ssh_keyfile:+-i "$ssh_keyfile"} \
    ${ssh_options+"${ssh_options[@]}"} \
    ${ssh_user:+-l "$ssh_user"} \
    "$ssh_host" \
    ${ssh_rcommand+"${ssh_rcommand[@]}"} \
    &

  # get the PID
  sshpid_l="$!"

  printf -v "$sshpid_var" "%s" "$sshpid_l"  # set the global
}

#
# kill a backgrounded remote SSH command
#
# $1 is the name of a global variable that contains the ssh PID, to
# differentiate between multiple commands; if unset or null, it defaults to
# "sshpid"
#
# can be run even if the command was already killed / died
#
# "local" vars: sshpid_var, sshpid_l
# global vars: (contents of $1, or sshpid)
# utilities: printf, kill, [
# bashisms: ${!var}, printf -v [v3.1]
#
killsshremotebg () {
  # apply default
  sshpid_var="sshpid"

  # get value, if set
  [ "$1" != "" ] && sshpid_var="$1"

  # get the PID
  sshpid_l="${!sshpid_var}"

  if [ "$sshpid_l" != "" ]; then
    kill "$sshpid_l" > /dev/null 2>&1  # don't complain if it's already dead
    wait "$sshpid_l"
    printf -v "$sshpid_var" "%s" ""  # so we know it's been killed
  fi
}

#
# run an SSH tunnel command
#
# $1 is the name of a global variable to store the ssh PID in, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid"
#
# tun_sshoptions must be an indexed, non-sparse array
#
# "local" vars: tunpid_var, tunpid_l
# global vars: (contents of $1, or tunpid)
# config settings: tun_localport, tun_remoteport, tun_sshport,
#                  tun_sshkeyfile, tun_sshoptions, tun_sshuser, tun_sshhost
# utilities: ssh, printf, [
# files: $tun_sshkeyfile
# bashisms: arrays, printf -v [v3.1]
#
sshtunnelcmd () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # run the command
  ssh \
    -L "$tun_localport:localhost:$tun_remoteport" -N \
    ${tun_sshport:+-p "$tun_sshport"} \
    ${tun_sshkeyfile:+-i "$tun_sshkeyfile"} \
    ${tun_sshoptions+"${tun_sshoptions[@]}"} \
    ${tun_sshuser:+-l "$tun_sshuser"} \
    "$tun_sshhost" \
    &

  # get the PID
  tunpid_l="$!"
  printf -v "$tunpid_var" "%s" "$tunpid_l"  # set the global
}

#
# kill an SSH tunnel
#
# $1 is the name of a global variable that contains the ssh PID, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid"
#
# can be run even if the tunnel already died / was closed / was killed
#
# note: this will hang if the remote port isn't open; you should be using
# opensshtunnel(), or duplicating its functionality
#
# "local" vars: tunpid_var, tunpid_l
# global vars: (contents of $1, or tunpid)
# utilities: printf, kill, [
# bashisms: ${!var}, printf -v [v3.1]
#
killsshtunnel () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # get the PID
  tunpid_l="${!tunpid_var}"

  if [ "$tunpid_l" != "" ]; then
    kill "$tunpid_l" > /dev/null 2>&1  # don't complain if it's already dead
    wait "$tunpid_l"
    printf -v "$tunpid_var" "%s" ""  # so we know it's been killed
  fi
}

#
# open an SSH tunnel, including testing and logging
#
# $1 is the name of a global variable to store the ssh PID in, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid"
#
# $tun_prefix should be a label for this tunnel (e.g., "rsync");
# a global variable with name "$1_prefix" (defaults to "tunpid_prefix"
# if $1 is unset or null) will be used to save the current value of
# $tun_prefix
#
# returns 0 on success
# on error, calls sendalert(), then acts according to the value of
# $on_tunerr:
#   "exit": exits with exitval $sshtunnel_exitval
#   "phase": returns 1 ("skip to the next phase of the script")
#
# FD 3 gets a start message and the actual output (stdout and stderr) of
# ssh
#
# "local" vars: tunpid_var, tunpid_l, waited, sshexit
# global vars: (contents of $1, or tunpid, and the corresponding *_prefix),
#              tun_prefix
# config settings: tun_localport, tun_sshtimeout
# library vars: on_tunerr, sshtunnel_exitval
# library functions: sshtunnelcmd(), logstatus(), logstatusquiet(),
#                    sendalert(), do_exit()
# utilities: nc, printf, sleep, kill, expr, [
# FDs: 3
# bashisms: ${!var}, printf -v [v3.1]
#
opensshtunnel () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # save tun_prefix
  printf -v "${tunpid_var}_prefix" "%s" "$tun_prefix"

  # log that we're running the command
  logstatusquiet "running SSH tunnel command for $tun_prefix"
  printf "%s\n" "running SSH tunnel command for $tun_prefix" >&3

  # run the command and get the PID
  sshtunnelcmd "$tunpid_var" >&3 2>&1
  tunpid_l="${!tunpid_var}"

  # make sure it's actually working;
  # see http://mywiki.wooledge.org/ProcessManagement#Starting_a_.22daemon.22_and_checking_whether_it_started_successfully
  waited="0"
  while sleep 1; do
    nc -z localhost "$tun_localport" && break

    # not working yet, but is it still running?
    if kill -0 "$tunpid_l" > /dev/null 2>&1; then  # quiet if already dead
      # expr is more portable than $(())
      waited=$(expr "$waited" + 1)

      if [ "$waited" -ge "$tun_sshtimeout" ]; then
        kill "$tunpid_l" > /dev/null 2>&1  # quiet if it's already dead
        wait "$tunpid_l"
        # so we know it's not running anymore
        printf -v "$tunpid_var" "%s" ""

        case "$on_tunerr" in
          phase)
            sendalert "could not establish SSH tunnel for $tun_prefix (timed out); skipping" log
            return 1  # skip to the next phase
            ;;
          *)  # exit
            sendalert "could not establish SSH tunnel for $tun_prefix (timed out); exiting" log
            do_exit "$sshtunnel_exitval"
            ;;
        esac
      fi
    else  # process is already dead
      wait "$tunpid_l"
      sshexit="$?"

      # so we know it's not running anymore
      printf -v "$tunpid_var" "%s" ""

      case "$on_tunerr" in
        phase)
          sendalert "could not establish SSH tunnel for $tun_prefix (error code $sshexit); skipping" log
          return 1  # skip to the next phase
          ;;
        *)  # exit
          sendalert "could not establish SSH tunnel for $tun_prefix (error code $sshexit); exiting" log
          do_exit "$sshtunnel_exitval"
          ;;
      esac
    fi  # if kill -0
  done  # while sleep 1

  logstatus "SSH tunnel for $tun_prefix established"

  return 0
}

#
# close an SSH tunnel, including logging
# (tunnel must have been opened with opensshtunnel())
#
# $1 is the name of a global variable that contains the ssh PID, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid"
#
# can be run even if the tunnel already died / was closed / was killed,
# but should not be run before the tunnel was started, or the logs won't
# make sense
#
# "local" vars: tunpid_var, tunpid_l, prefix_l
# global vars: (contents of $1, or tunpid, and the corresponding *_prefix)
# library functions: copyvar(), logstatus()
# utilities: printf, kill, [
# bashisms: ${!var}, printf -v [v3.1]
#
closesshtunnel () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # get the PID and the prefix
  tunpid_l="${!tunpid_var}"
  copyvar "${tunpid_var}_prefix" "prefix_l"

  if [ "$tunpid_l" != "" ]; then
    kill "$tunpid_l" > /dev/null 2>&1  # don't complain if it's already dead
    wait "$tunpid_l"
    printf -v "$tunpid_var" "%s" ""  # so we know it's been closed

    logstatus "SSH tunnel for $prefix_l closed"
  else
    logstatus "SSH tunnel for $prefix_l was already closed"
  fi
}


###################################
# database calls and manipulations
###################################

#
# run a database command
#
# dbms_prefix must be one of the accepted values (currently only
# "mysql"
#
# when using an SSH tunnel, set host to "localhost" and port to the local
# port of the tunnel
#
# (in the notes below, [dbms] = the value of $dbms_prefix)
#
# [dbms]_options and [dbms]_command must be indexed, non-sparse arrays
#
# global vars: dbms_prefix
# config settings: [dbms]_user, [dbms]_pwfile, [dbms]_protocol, [dbms]_host,
#                  [dbms]_port, [dbms]_socketfile, [dbms]_options,
#                  [dbms]_dbname, [dbms]_command
# utilities: mysql
# files: $[dbms]_pwfile, $[dbms]_socketfile
# bashisms: arrays
#
dbcmd () {
  case "$dbms_prefix" in
    mysql)
      # --defaults-extra-file must be the first option if present
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socketfile:+-S "$mysql_socketfile"} \
        ${mysql_options+"${mysql_options[@]}"} \
        ${mysql_dbname:+"$mysql_dbname"} \
        ${mysql_command+-e "${mysql_command[@]}"}
      ;;
  esac
}

#
# run a get-database-list command
#
# (may not be possible/straightforward for all DBMSes)
#
# dbms_prefix must be one of the accepted values (currently only
# "mysql"
#
# when using an SSH tunnel, set host to "localhost" and port to the local
# port of the tunnel
#
# for MySQL, '-BN' is already included in the options
#
# (in the notes below, [dbms] = the value of $dbms_prefix)
#
# [dbms]_options must be an indexed, non-sparse array
#
# global vars: dbms_prefix
# config settings: [dbms]_user, [dbms]_pwfile, [dbms]_protocol, [dbms]_host,
#                  [dbms]_port, [dbms]_socketfile, [dbms]_options
# utilities: mysql
# files: $[dbms]_pwfile, $[dbms]_socketfile
# bashisms: arrays
#
dblistcmd () {
  case "$dbms_prefix" in
    mysql)
      # --defaults-extra-file must be the first option if present
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socketfile:+-S "$mysql_socketfile"} \
        ${mysql_options+"${mysql_options[@]}"} \
        -BN -e "SHOW DATABASES;"
      ;;
  esac
}

#
# convert DB name escape sequences to the real characters
# used, e.g., on the output of dblistcmd()
#
# $1 = DB name to un-escape
#
# sequences to un-escape:
#
#   MySQL:
#     \n -> newline
#     \t -> tab
#     \\ -> \
#
# (that is, this function will carry out the mappings above, which are the
# reverse of the mappings used by the DBMSes)
#
# dbms_prefix must be one of the accepted values (currently only
# "mysql"
#
# global vars: dbms_prefix, tab
# utilities: printf, sed
#
dbunescape () {
  case "$dbms_prefix" in
    mysql)
      # note: \\ must be last; \t isn't portable in sed
      printf "%s\n" "$1" | \
        sed \
          -e 's/^\\n/\n/' -e 's/\([^\]\)\\n/\1\n/g' \
          -e "s/^\\\\t/$tab/" -e "s/\\([^\\]\)\\\\t/\\1$tab/g" \
          -e 's/\\\\/\\/g'
      ;;
  esac
}


################
# rsync backups
################

#
# run an rsync command
#
# for "tunnel" mode, SSH tunnel must be opened/closed separately; use
# "localhost" for the host (in rsync_source/dest) and set rsync_port to the
# local port of the tunnel
#
# rsync_sshoptions, rsync_options, rsync_add, and rsync_source must be
# indexed, non-sparse arrays
#
# config settings: rsync_mode, rsync_pwfile, rsync_port, rsync_sshport,
#                  rsync_sshkeyfile, rsync_sshoptions, rsync_filterfile,
#                  rsync_options, rsync_add, rsync_source, rsync_dest
# utilities: rsync, (ssh)
# files: $rsync_sshkeyfile, $rsync_pwfile, $rsync_filterfile
# bashisms: arrays
#
rsynccmd () {
  case "$rsync_mode" in
    tunnel|direct)
      rsync \
        ${rsync_pwfile:+"--password-file=$rsync_pwfile"} \
        ${rsync_port:+"--port=$rsync_port"} \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options+"${rsync_options[@]}"} \
        ${rsync_add+"${rsync_add[@]}"} \
        "${rsync_source[@]}" \
        "$rsync_dest"
      ;;
    nodaemon)
      rsync \
        -e "ssh
            ${rsync_sshport:+-p "$rsync_sshport"} \
            ${rsync_sshkeyfile:+-i "$rsync_sshkeyfile"} \
            ${rsync_sshoptions+"${rsync_sshoptions[@]}"}" \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options+"${rsync_options[@]}"} \
        ${rsync_add+"${rsync_add[@]}"} \
        "${rsync_source[@]}" \
        "$rsync_dest"
      ;;
    local)
      rsync \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        ${rsync_options+"${rsync_options[@]}"} \
        ${rsync_add+"${rsync_add[@]}"} \
        "${rsync_source[@]}" \
        "$rsync_dest"
      ;;
  esac
}
