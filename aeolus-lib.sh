#!/bin/bash

#######################################################################
# Aeolus library (originally factored out of the Aeolus backup script)
# by Daniel Malament
#######################################################################

#
# see the ae_license() function or the LICENSE file for license info
#

#
# all variables and functions can be skipped by setting the corresponding
# skip_* variable; this allows the library to be overridden easily,
# even with definitions made before it's sourced
#


############################################################################
#                              VERSION CHECK
############################################################################

#
# if we're not running a high enough version of bash, we shouldn't even try
# to parse the code below
#
# NOTE: despite the use of some bash-specific features, the code has been
# written to be as portable as possible wherever those features are not
# needed
#

# we can't use arithmetical tests because BASH_VERSINFO[1] wasn't always
# purely numeric
case "$BASH_VERSION" in
  ''|1.*|2.*|3.0.*)
    cat <<-EOF 1>&2

	Error: This script requires bash version 3.1 or later.

	EOF
    exit 10  # startup_exitval
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
[ "${skip_newline+X}" = "" ] && {
     newline=$(printf "\nX")
     newline="${newline%X}"
}

# a tab character
[ "${skip_tab+X}" = "" ] && \
     tab='	'


#####################
# initialize globals
#####################

#
# unconditional globals
#

# test for this if you need to know if the library has been sourced yet
[ "${skip_aeolus_lib_sourced+X}" = "" ] && \
     aeolus_lib_sourced="yes"


#
# defaults; we only set them if they aren't already set
#

# exit values
[ "${skip_no_error_exitval+X}" = "" ] && \
     [ "${no_error_exitval+X}" = "" ] && no_error_exitval="0"
# keep this value in sync with the library-sourcing section
[ "${skip_startup_exitval+X}" = "" ] && \
     [ "${startup_exitval+X}" = "" ] && startup_exitval="10"
[ "${skip_lockfile_exitval+X}" = "" ] && \
     [ "${lockfile_exitval+X}" = "" ] && lockfile_exitval="11"
[ "${skip_sshtunnel_exitval+X}" = "" ] && \
     [ "${sshtunnel_exitval+X}" = "" ] && sshtunnel_exitval="20"
[ "${skip_badvarname_exitval+X}" = "" ] && \
     [ "${badvarname_exitval+X}" = "" ] && badvarname_exitval="240"
[ "${skip_nodelim_exitval+X}" = "" ] && \
     [ "${nodelim_exitval+X}" = "" ] && nodelim_exitval="241"

# names of tempfiles stored in the lockfile directory
#
# (note: names are in past tense partly because some shells have issues
# with functions having the same names as variables)
#
[ "${skip_lfalertssilenced+X}" = "" ] && \
     [ "${lfalertssilenced+X}" = "" ] && lfalertssilenced="lfalertssilenced"
[ "${skip_scriptdisabled+X}" = "" ] && \
     [ "${scriptdisabled+X}" = "" ] && scriptdisabled="scriptdisabled"
[ "${skip_timetemp+X}" = "" ] && \
     [ "${timetemp+X}" = "" ] && timetemp="timetemp"
[ "${skip_logfifo+X}" = "" ] && \
     [ "${logfifo+X}" = "" ] && logfifo="logfifo"


############################################################################
#                                FUNCTIONS
############################################################################

#################################
# variable and function handling
#################################

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
[ "${skip_islegalvarname+X}" = "" ] && \
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
[ "${skip_issafesubscript+X}" = "" ] && \
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
# possible states of a non-array variable (see below for arrays):
#
#   unset  {  completely unset                   }
#                                                }  void
#          {  set, but null (blank); var=""      }
#   set    {
#          {  set and not null; var="somevalue"  }  not void
#
# note:
#   * "void" is non-standard; the man page just says "unset or null"
#   * what is called "not void" here would usually just be called "not null",
#     but in this context, that could mean "unset or (set and not null)";
#     this usage has greater precision
#

#
# check if a non-array variable specified by name is unset
# (which is not the same thing as null)
#
# for arrays, use arrayisunset() instead
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname+X}" = "" ]
#
# never strictly necessary if you're willing to be bash-specific;
# if the variable name isn't known until run-time, use:
#   ! declare -p "$name" > /dev/null 2>&1
# where $name contains the name of the variable to check
# (but still, use of this function will make your code cleaner and more
# portable)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
#
[ "${skip_isunset+X}" = "" ] && \
isunset () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}+X}\" = \"\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isunset(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if a non-array variable specified by name is set but null
#
# for arrays, use arrayisempty() instead
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname+X}" = "X" ] && [ -z "$varname" ]
# or
#   [ "${varname+X}" = "X" ] && [ "$varname" = "" ]
#
# never strictly necessary if you're willing to be bash-specific;
# if the variable name isn't known until run-time, use:
#   declare -p "$name" > /dev/null 2>&1 && [ -z "$!name" ]
# where $name contains the name of the variable to check
# (but still, use of this function will make your code cleaner and more
# portable)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
#
[ "${skip_isnull+X}" = "" ] && \
isnull () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}+X}\" = \"X\" ] && [ \"\$$1\" = \"\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isnull(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if a non-array variable specified by name is unset or null
# (we'll call this "void", for convenience)
#
# for arrays, use arrayisvoid() instead
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname:+X}" = "" ]
#
# never strictly necessary if you're willing to be bash-specific;
# if the variable name isn't known until run-time, use:
#   [ -z "$!name" ]
# where $name contains the name of the variable to check
# (but still, use of this function will make your code clearer and more
# portable)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
#
[ "${skip_isvoid+X}" = "" ] && \
isvoid () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}:+X}\" = \"\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isvoid(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if a non-array variable specified by name is set and not null
# (that is, the variable is not "void", in the terminology we're using here)
#
# for arrays, use arrayisnotvoid() instead
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname:+X}" = "X" ]
#
# never strictly necessary if you're willing to be bash-specific;
# if the variable name isn't known until run-time, use:
#   [ -n "$!name" ]
# where $name contains the name of the variable to check
# (but still, use of this function will make your code clearer and more
# portable)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
#
[ "${skip_isnotvoid+X}" = "" ] && \
isnotvoid () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}:+X}\" = \"X\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isnotvoid(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if a non-array variable specified by name is set
# (whether it's null or not)
#
# for arrays, use arrayisset() instead
#
# $1 = the name of the variable to check
#
# IMPORTANT: only pass variables whose names are under your control!
#
# only needed if the variable name isn't known until run-time;
# otherwise, use:
#   [ "${varname+X}" = "X" ]
#
# never strictly necessary if you're willing to be bash-specific;
# if the variable name isn't known until run-time, use:
#   declare -p "$name" > /dev/null 2>&1
# where $name contains the name of the variable to check
# (but still, use of this function will make your code cleaner and more
# portable)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
#
[ "${skip_isset+X}" = "" ] && \
isset () {
  if islegalvarname "$1"; then
    eval "[ \"\${${1}+X}\" = \"X\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in isset(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# possible states of an array variable (see above for non-arrays):
#
#   unset  {  completely unset                      }
#                                                   }  void
#          {  set, but empty (no elements); arr=()  }
#   set    {
#          {  set and not empty                     }  not void
#
# note:
#   * "void" is non-standard
#   * an array with only null elements is still non-empty
#   * what is called "not void" here would usually just be called
#     "not empty", but in this context, that could mean
#     "unset or (set and not empty)"; this usage has greater precision
#

#
# check if an array specified by name is unset
# (which is not the same thing as empty)
#
# for non-array variables, use isunset() instead
#
# $1 = the name of the array to check
#
# never strictly necessary; use:
#   ! declare -p "arrayname" > /dev/null 2>&1
# or if the name of the array isn't known until run-time:
#   ! declare -p "$name" > /dev/null 2>&1
# where $name contains the name of the variable to check
# (but still, use of this function will make your code cleaner, and will
# help centralize the use of bashisms to make porting easier)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
# bashisms: !, declare -p
#
[ "${skip_arrayisunset+X}" = "" ] && \
arrayisunset () {
  # not strictly necessary since bash will throw an error itself,
  # but this standardizes the errors and the exit values
  if islegalvarname "$1"; then
    ! declare -p "$1" > /dev/null 2>&1
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisunset(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if an array specified by name is set but empty
# (has no set elements; null elements still count as set)
#
# for non-array variables, use isnull() instead
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# only needed if the name of the array isn't known until run-time;
# otherwise, use:
#   declare -p "arrayname" > /dev/null 2>&1 && [ "${#arrayname[@]}" = "0" ]
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
# bashisms: declare -p, arrays
#
[ "${skip_arrayisempty+X}" = "" ] && \
arrayisempty () {
  if islegalvarname "$1"; then
    declare -p "$1" > /dev/null 2>&1 && eval "[ \"\${#${1}[@]}\" = \"0\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisempty(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if an array specified by name is unset or empty
# (we'll call this "void", for convenience)
#
# for non-array variables, use isvoid() instead
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# only needed if the name of the array isn't known until run-time;
# otherwise, use:
#   [ "${#arrayname[@]}" = "0" ]
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
# bashisms: arrays
#
[ "${skip_arrayisvoid+X}" = "" ] && \
arrayisvoid () {
  if islegalvarname "$1"; then
    eval "[ \"\${#${1}[@]}\" = \"0\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisvoid(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if an array specified by name is set and not empty
# (that is, the array is not "void", in the terminology we're using here;
# it has at least one set element, which may or may not be null)
#
# for non-array variables, use isnotvoid() instead
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# only needed if the name of the array isn't known until run-time;
# otherwise, use:
#   [ "${#arrayname[@]}" != "0" ]
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
# bashisms: arrays
#
[ "${skip_arrayisnotvoid+X}" = "" ] && \
arrayisnotvoid () {
  if islegalvarname "$1"; then
    eval "[ \"\${#${1}[@]}\" != \"0\" ]"
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisnotvoid(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# check if an array specified by name is set
# (whether it's empty or not)
#
# for non-array variables, use isset() instead
#
# $1 = the name of the array to check
#
# never strictly necessary; use:
#   declare -p "arrayname" > /dev/null 2>&1
# or if the name of the array isn't known until run-time:
#   declare -p "$name" > /dev/null 2>&1
# where $name contains the name of the variable to check
# (but still, use of this function will make your code cleaner, and will
# help centralize the use of bashisms to make porting easier)
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf, [
# bashisms: declare -p
#
[ "${skip_arrayisset+X}" = "" ] && \
arrayisset () {
  # not strictly necessary since bash will throw an error itself,
  # but this standardizes the errors and the exit values
  if islegalvarname "$1"; then
    declare -p "$1" > /dev/null 2>&1
  else
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayisset(); exiting."
    do_exit "$badvarname_exitval"
  fi
}

#
# are all elements of a non-empty array null?
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: skey, skeys, atemp
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript(), arrayisvoid(),
#                    do_exit()
# utilities: printf, [
# bashisms: !, arrays, ${!array[@]} [v3.0]
#
[ "${skip_arrayallnull+X}" = "" ] && \
arrayallnull () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayallnull(); exiting."
    do_exit "$badvarname_exitval"
  fi

  if arrayisvoid "$1"; then
    return 1  # false
  fi

  eval "skeys=(\"\${!${1}[@]}\")"

  for skey in "${skeys[@]}"; do
    # $skey has already been used as a subscript, but we're going to be
    # extra-cautious (paranoid), since we're using eval
    if ! issafesubscript "$skey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$skey'; \$1='$1') in arrayallnull(); exiting."
      do_exit "$badvarname_exitval"
    fi

    eval "atemp=\"\${${1}[\"$skey\"]}\""

    if [ "$atemp" != "" ]; then
      return 1  # false
    fi
  done

  return 0  # true
}

#
# are all elements of a non-empty array non-null?
# (we're calling this "not void": set and not null)
#
# $1 = the name of the array to check
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: skey, skeys, atemp
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript(), arrayisvoid(),
#                    do_exit()
# utilities: printf, [
# bashisms: !, arrays, ${!array[@]} [v3.0]
#
[ "${skip_arrayallnotvoid+X}" = "" ] && \
arrayallnotvoid () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in arrayallnotvoid(); exiting."
    do_exit "$badvarname_exitval"
  fi

  if arrayisvoid "$1"; then
    return 1  # false
  fi

  eval "skeys=(\"\${!${1}[@]}\")"

  for skey in "${skeys[@]}"; do
    # $skey has already been used as a subscript, but we're going to be
    # extra-cautious (paranoid), since we're using eval
    if ! issafesubscript "$skey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$skey'; \$1='$1') in arrayallnotvoid(); exiting."
      do_exit "$badvarname_exitval"
    fi

    eval "atemp=\"\${${1}[\"$skey\"]}\""

    if [ "$atemp" = "" ]; then
      return 1  # false
    fi
  done

  return 0  # true
}

#
# copy between non-array variables specified by name
#
# for arrays, use copyarray() instead
#
# $1 = the name of the source variable
# $2 = the name of the destination variable (must not currently be declared or
#      used as an array)
# $3 = (see below)
#
# if the source variable is unset (not just null), the value of the
# destination variable will depend on $3:
#   * if $3 is non-null, the destination variable will be unset (suggested
#     value for $3: "exact")
#   * if $3 is unset or null, the destination variable will be set but null
#     (standard shell assignment semantics for, e.g., foo="$bar")
#
# note: does not change attributes (such as 'exported') of the destination
# variable
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
# but using this function is cleaner, especially if you have many variables
# to copy; it also has the $3 option, and helps centralize the use of
# bashisms to make porting easier
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), isunset(), do_exit()
# utilities: printf, [
# bashisms: !, unset, ${!var}, printf -v [v3.1]
#
[ "${skip_copyvar+X}" = "" ] && \
copyvar () {
  # not strictly necessary since bash will throw an error itself,
  # but this standardizes the errors and the exit values
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in copyvar(); exiting."
    do_exit "$badvarname_exitval"
  fi
  if ! islegalvarname "$2"; then
    printf "%s\n" "Internal Error: illegal variable name ('$2') in copyvar(); exiting."
    do_exit "$badvarname_exitval"
  fi

  # unset first, in case destination was previously declared as an array
  # -> no - will also remove other attributes, such as exported
  #unset "$2"

  if [ "$3" != "" ] && isunset "$1"; then
    unset "$2"
  else
    printf -v "$2" "%s" "${!1}"
  fi
}

#
# copy between arrays specified by name
#
# for non-array variables, use copyvar() instead
#
# $1 = the name of the source array
# $2 = the name of the destination array
# $3 = (see below)
#
# if the source array is unset (not just empty), the value of the
# destination array will depend on $3:
#   * if $3 is non-null, the destination array will be unset (suggested
#     value for $3: "exact")
#   * if $3 is unset or null, the destination array will be set but empty
#     (similar to the standard shell assignment semantics for, e.g.,
#     foo="$bar")
#
# if the source array is associative, the destination array must be
# declared associative before calling (declare -A)
#
# note: does not change attributes (such as 'exported') of the destination
# variable
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# this function is only needed if one or both of the arrays' names are't
# known until run-time; otherwise, use (in bash v3.0+):
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
#     printf -v "${dest}[$skey]" "%s" "${sourcename["$skey"]}"
# where dest contains the name of the destination array,
# and replace 'unset "destname"' with 'unset "$dest"'
#
# but still, using this function is cleaner, especially if you have many
# arrays to copy; it also has the $3 option, and helps centralize the use of
# bashisms to make porting easier
#
# "local" vars: skey, skeys
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript(), arrayisunset(),
#                    do_exit()
# utilities: printf, [
# bashisms: !, unset, arrays, ${!array[@]} [v3.0]
#
[ "${skip_copyarray+X}" = "" ] && \
copyarray () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in copyarray(); exiting."
    do_exit "$badvarname_exitval"
  fi
  if ! islegalvarname "$2"; then
    printf "%s\n" "Internal Error: illegal variable name ('$2') in copyarray(); exiting."
    do_exit "$badvarname_exitval"
  fi

  if [ "$3" != "" ] && arrayisunset "$1"; then
    unset "$2"
    return
  fi

  eval "skeys=(\"\${!${1}[@]}\")"

  # unset will also remove associative array status,
  # (and other attributes, such as exported),
  # and we can't just redeclare it because that will make it local
  # unless we use -g, which requires bash 4.2
  #unset "$2"
  eval "${2}=()"

  for skey in "${skeys[@]}"; do
    # $skey has already been used as a subscript, but we're going to be
    # extra-cautious (paranoid), since we're using eval
    if ! issafesubscript "$skey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$skey'; \$1='$1') in copyarray(); exiting."
      do_exit "$badvarname_exitval"
    fi

    eval "${2}[\"$skey\"]=\"\${${1}[\"$skey\"]}\""
  done
}

#
# print the contents of a non-array variable specified by name
#
# for arrays, use printarray() instead
#
# $1 = the name of the variable to print (must not currently be declared or
# used as an array)
#
# unset and null variables will both be printed as empty strings
#
# note: when capturing output, you MUST use $(), NOT ``; `` does strange
# things with \ escapes
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
# but using this function is cleaner, especially if you have many variables
# to print; it also helps centralize the use of bashisms to make porting
# easier
#
# library vars: badvarname_exitval
# library functions: islegalvarname(), do_exit()
# utilities: printf
# bashisms: !, ${!var}
#
[ "${skip_printvar+X}" = "" ] && \
printvar () {
  # not strictly necessary since bash will throw an error itself,
  # but this standardizes the errors and the exit values
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in printvar(); exiting."
    do_exit "$badvarname_exitval"
  fi

  printf "%s" "${!1}"
}

#
# print the contents of an array specified by name
#
# for non-array variables, use printvar() instead
#
# $1 = the name of the array to print
# $2 = if not null, print the keys as well as the values (suggested
#      value: "keys")
#
# output format, $2 unset or null:
#    ( 'value1' 'value2' ... )
# output format, $2 not null:
#    ( ['key1']='value1' ['key2']='value2' ... )
#
# unset and empty arrays will both be printed as '( )'
#
# note: when capturing output, you MUST use $(), NOT ``; `` does strange
# things with \ escapes
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: akey, akeys
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript(), do_exit()
# utilities: printf, [
# bashisms: !, arrays, ${!array[@]} [v3.0]
#
[ "${skip_printarray+X}" = "" ] && \
printarray () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in printarray(); exiting."
    do_exit "$badvarname_exitval"
  fi

  eval "akeys=(\"\${!${1}[@]}\")"

  printf "%s" "( "
  for akey in "${akeys[@]}"; do
    # $akey has already been used as a subscript, but we're going to be
    # extra-cautious (paranoid), since we're using eval
    if ! issafesubscript "$akey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$akey'; \$1='$1') in printarray(); exiting."
      do_exit "$badvarname_exitval"
    fi

    if [ "$2" = "" ]; then  # just print values
      eval "printf \"%s\" \"'\${${1}[\"$akey\"]}' \""
    else  # include keys
      eval "printf \"%s\" \"['$akey']='\${${1}[\"$akey\"]}' \""
    fi
  done
  printf "%s" ")"
}

#
# un-sparse an indexed array specified by name
#
# $1 = the name of the array to un-sparse
#
# note: does not change attributes (such as 'exported') of the array
#
# IMPORTANT: only pass arrays whose names are under your control!
#
# "local" vars: akey, akeys, unsparsetmp
# library vars: badvarname_exitval
# library functions: islegalvarname(), issafesubscript(), arrayisvoid(),
#                    copyarray(), do_exit()
# utilities: printf
# bashisms: !, unset, arrays, ${!array[@]} [v3.0], array+=() [v3.1]
#
[ "${skip_unsparsearray+X}" = "" ] && \
unsparsearray () {
  if ! islegalvarname "$1"; then
    printf "%s\n" "Internal Error: illegal variable name ('$1') in unsparsearray(); exiting."
    do_exit "$badvarname_exitval"
  fi

  if arrayisvoid "$1"; then
    return
  fi

  eval "akeys=(\"\${!${1}[@]}\")"

  # copy to unsparsetmp array, un-sparsing
  unset unsparsetmp
  for akey in "${akeys[@]}"; do
    # $akey has already been used as a subscript, but we're going to be
    # extra-cautious (paranoid), since we're using eval
    if ! issafesubscript "$akey"; then
      printf "%s\n" "Internal Error: illegal subscript name ('$akey'; \$1='$1') in unsparsearray(); exiting."
      do_exit "$badvarname_exitval"
    fi

    eval "unsparsetmp+=(\"\${${1}[\"$akey\"]}\")"
  done

  # replace original array
  copyarray unsparsetmp "$1"
  unset unsparsetemp
}

#
# check if a function specified by name is not defined
#
# $1 = the name of the function to check
#
# (just here to make code cleaner, and to help centralize the use of bashisms
# to make porting easier)
#
# bashisms: !, declare -F
#
[ "${skip_funcisnotdefined+X}" = "" ] && \
funcisnotdefined () {
  ! declare -F "$1" > /dev/null 2>&1
}

#
# check if a function specified by name is defined
#
# $1 = the name of the function to check
#
# (just here to make code cleaner, and to help centralize the use of bashisms
# to make porting easier)
#
# bashisms: declare -F
#
[ "${skip_funcisdefined+X}" = "" ] && \
funcisdefined () {
  declare -F "$1" > /dev/null 2>&1
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
[ "${skip_clarifyargs+X}" = "" ] && \
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
[ "${skip_checkextcmds+X}" = "" ] && \
checkextcmds () {
  # get column width
  cmdlen=0
  for extcmd in $externalcmds; do
    # if [ "${#extcmd}" -gt "$cmdlen" ]; then
    # slower but more portable; see http://mywiki.wooledge.org/BashFAQ/007
    if [ "$(expr \( "X$extcmd" : ".*" \) - 1)" -gt "$cmdlen" ]; then
      cmdlen=$(expr \( "X$extcmd" : ".*" \) - 1)
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

#
# turn on shell command printing for particular commands
#
# commands will be printed preceded by 'cmd: '
#
# note that any variables set on the same line as the command will be
# printed on separate lines, one variable per line, e.g.:
#   cmd: foo=bar
#   cmd: baz=quux
#   cmd: do_something arg1 arg2 arg3
#
# global vars: PS4, PS4save, xtracereset
# config settings: printcmds
# utilities: grep, [
# bashisms: set +o
#
[ "${skip_begincmdprint+X}" = "" ] && \
begincmdprint () {
  if [ "$printcmds" = "yes" ]; then
    PS4save="$PS4"
    xtracereset=$(set +o | grep xtrace)

    PS4="cmd: "
    set -x
  fi
}

#
# turn off shell command printing for particular commands and get exit value
#
# you probably want to call this with 2>/dev/null, so as not to print
# lines like this:
#   cmd: cmdexitval=0
#   cmd: '[' yes = yes ']'
#   cmd: eval 'set +o xtrace'
#   ccmd: set +o xtrace
# however, there is no way to avoid printing this:
#   cmd: endcmdprint
#
# global vars: cmdexitval, PS4, PS4save, xtracereset
# config settings: printcmds
# utilities: [
#
[ "${skip_endcmdprint+X}" = "" ] && \
endcmdprint () {
  cmdexitval="$?"

  if [ "$printcmds" = "yes" ]; then
    eval "$xtracereset"
    PS4="$PS4save"
  fi
}

#
# turn off shell command printing for particular bg commands and get PID
#
# you probably want to call this with 2>/dev/null, so as not to print
# lines like this:
#   cmd: cmdpid=21546
#   cmd: '[' yes = yes ']'
#   cmd: eval 'set +o xtrace'
#   ccmd: set +o xtrace
# however, there is no way to avoid printing this:
#   cmd: endcmdprint
# and it will generally (always?) be printed _before_ the line with the
# command, due to buffering
#
# global vars: cmdpid, PS4, PS4save, xtracereset
# config settings: printcmds
# utilities: [
#
[ "${skip_endcmdprint+X}" = "" ] && \
endcmdprintbg () {
  cmdpid="$!"

  if [ "$printcmds" = "yes" ]; then
    eval "$xtracereset"
    PS4="$PS4save"
  fi
}


################################
# shutdown, including callbacks
################################

#
# add a function to the list of functions to call before exiting the script
#
# $1 = the name of the function to add
# $2 through $9 = optional arguments to call the function with
#                 (limited to 8 to avoid various difficulties
#                 and incompatibilities)
#
# also works with external commands in the $PATH rather than functions
#
# note that the callback function/command will be called with nulls for any
# arguments that were not supplied to addexitcallback(); for this reason,
# adding external commands is usually a bad idea without a wrapper
#
# returns 1 if the function doesn't exist, otherwise 0
#
# global vars: exitcallbacks, exitcallbackarg1 through 8
# user-defined functions: (contents of $1)
# library functions: funcisdefined()
# bashisms: arrays, array+=() [v3.1]
#
[ "${skip_addexitcallback+X}" = "" ] && \
addexitcallback () {
  # command -v also includes functions, but I don't know if that behavior
  # is reliable
  if funcisdefined "$1" || command -v "$1" > /dev/null 2>&1; then
    exitcallbacks+=("$1")
    exitcallbackarg1+=("$2")
    exitcallbackarg2+=("$3")
    exitcallbackarg3+=("$4")
    exitcallbackarg4+=("$5")
    exitcallbackarg5+=("$6")
    exitcallbackarg6+=("$7")
    exitcallbackarg7+=("$8")
    exitcallbackarg8+=("$9")
    return 0  # success
  else
    return 1  # failure
  fi
}

#
# remove a function from the list of functions to call before exiting
# the script
#
# removes only the most-recently-added incidence matching both the function
# and its arguments
#
# $1 = the name of the function to remove
# $2 through $9 = optional arguments to the callback function (trailing
#                 nulls can be omitted)
#
# returns 1 if the function is not in the list, otherwise 0
#
# "local" vars: ecbkeys, ecbkey
# global vars: exitcallbacks, exitcallbackarg1 through 8
# user-defined functions: (contents of $1)
# utilities: printf, sort, [
# bashisms: arrays, ${!array[@]} [v3.0], unset
#
[ "${skip_removeexitcallback+X}" = "" ] && \
removeexitcallback () {
  ecbkeys=("${!exitcallbacks[@]}")

  # this 'for $()' approach is unsafe in general
  # (see http://mywiki.wooledge.org/DontReadLinesWithFor),
  # but it works in this case because the range of values is known;
  # also, printf doubles here as a way to put the values on separate lines
  for ecbkey in $(printf "%s\n" "${ecbkeys[@]}" | sort -nr); do
    if [ "${exitcallbacks["$ecbkey"]}" = "$1" ] && \
       [ "${exitcallbackarg1["$ecbkey"]}" = "$2" ] && \
       [ "${exitcallbackarg2["$ecbkey"]}" = "$3" ] && \
       [ "${exitcallbackarg3["$ecbkey"]}" = "$4" ] && \
       [ "${exitcallbackarg4["$ecbkey"]}" = "$5" ] && \
       [ "${exitcallbackarg5["$ecbkey"]}" = "$6" ] && \
       [ "${exitcallbackarg6["$ecbkey"]}" = "$7" ] && \
       [ "${exitcallbackarg7["$ecbkey"]}" = "$8" ] && \
       [ "${exitcallbackarg8["$ecbkey"]}" = "$9" ]; then
      unset "exitcallbacks[$ecbkey]"
      unset "exitcallbackarg1[$ecbkey]"
      unset "exitcallbackarg2[$ecbkey]"
      unset "exitcallbackarg3[$ecbkey]"
      unset "exitcallbackarg4[$ecbkey]"
      unset "exitcallbackarg5[$ecbkey]"
      unset "exitcallbackarg6[$ecbkey]"
      unset "exitcallbackarg7[$ecbkey]"
      unset "exitcallbackarg8[$ecbkey]"
      return 0  # success
    fi
  done

  return 1  # failure
}

#
# exit the script in an orderly fashion
#
# before exiting, calls callbacks (starting with the most recently added;
# see addexitcallback())
#
# $1 = exit value (required)
#
# "local" vars: ecbkeys, ecbkey
# global vars: exitcallbacks, exitcallbackarg1 through 8
# user-defined functions: (contents of exitcallbacks)
# utilities: printf, sort, [
# bashisms: arrays, ${!array[@]} [v3.0]
#
[ "${skip_do_exit+X}" = "" ] && \
do_exit () {
  ecbkeys=("${!exitcallbacks[@]}")

  # this 'for $()' approach is unsafe in general
  # (see http://mywiki.wooledge.org/DontReadLinesWithFor),
  # but it works in this case because the range of values is known;
  # also, printf doubles here as a way to put the values on separate lines
  for ecbkey in $(printf "%s\n" "${ecbkeys[@]}" | sort -nr); do
    if [ "${exitcallbacks["$ecbkey"]}" != "" ]; then
      "${exitcallbacks["$ecbkey"]}" \
          "${exitcallbackarg1["$ecbkey"]}" \
          "${exitcallbackarg2["$ecbkey"]}" \
          "${exitcallbackarg3["$ecbkey"]}" \
          "${exitcallbackarg4["$ecbkey"]}" \
          "${exitcallbackarg5["$ecbkey"]}" \
          "${exitcallbackarg6["$ecbkey"]}" \
          "${exitcallbackarg7["$ecbkey"]}" \
          "${exitcallbackarg8["$ecbkey"]}"
    fi
  done

  exit "$1"
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
[ "${skip_throwerr+X}" = "" ] && \
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
[ "${skip_logstatlog+X}" = "" ] && \
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
[ "${skip_logprint+X}" = "" ] && \
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
[ "${skip_logprinterr+X}" = "" ] && \
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
[ "${skip_do_syslog+X}" = "" ] && \
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
[ "${skip_logstatus+X}" = "" ] && \
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
[ "${skip_logalert+X}" = "" ] && \
logalert () {
  # use "$1" to preserve spacing

  if { [ "$2" != "all" ] && [ "$usesyslog" != "no" ]; } \
     || \
     { [ "$2" = "all" ] && [ "$usesyslog" = "all" ]; }; then
    do_syslog "$1" "$syslogerr" "$syslogtag"
  fi

  logprinterr "$1"
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
[ "${skip_logstatusquiet+X}" = "" ] && \
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
[ "${skip_logalertquiet+X}" = "" ] && \
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
# config settings: suppressemail, alertmailto, alertsubject
# user-defined functions: sendalert_body()
# library functions: logalert()
# utilities: mailx, [
#
[ "${skip_sendalert+X}" = "" ] && \
sendalert () {
  if [ "$suppressemail" != "yes" ]; then
    mailx -s "$alertsubject" $alertmailto <<-EOF
	$1
	$(sendalert_body)
	EOF
  fi

  if [ "$2" = "log" ]; then
    logalert "$1"
  fi

  if [ "$suppressemail" != "yes" ]; then
    logalert "alert email sent to $alertmailto"
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
[ "${skip_startoutputlog+X}" = "" ] && \
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
[ "${skip_stopoutputlog+X}" = "" ] && \
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
[ "${skip_newerthan+X}" = "" ] && \
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
    greprv="$?"
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
[ "${skip_filecomp+X}" = "" ] && \
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
# similarly, now also used for getting the file size portably
#
# utilities: ls, echo, [
#
[ "${skip_getfilemetadata+X}" = "" ] && \
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
[ "${skip_getparentdir+X}" = "" ] && \
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
[ "${skip_escglob+X}" = "" ] && \
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
[ "${skip_escregex+X}" = "" ] && \
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
[ "${skip_escereg+X}" = "" ] && \
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
[ "${skip_escsedrepl+X}" = "" ] && \
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
# library vars: tab
# utilities: printf, tr, [
#
[ "${skip_getseddelim+X}" = "" ] && \
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
    # without Xs, this breaks if $1 ends in a newline
    if [ "${1}X" = "$(printf "%sX\n" "$1" | tr -d "$char")" ]; then
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
[ "${skip_escsedsubst+X}" = "" ] && \
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
[ "${skip_ae_license+X}" = "" ] && \
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
# the calling script must define configsettingtype(), which takes the name
# of a config setting and prints "scalar", "array", or "function"
#
# "local" vars: setting
# global vars: configsettings, clsetsaved
# config settings: (*, cl_*)
# user-defined functions: configsettingtype()
# library functions: arrayisset(), copyarray(), isset()
# bashisms: ${!var}, printf -v [v3.1]
#
[ "${skip_saveclset+X}" = "" ] && \
saveclset () {
  # so we know if anything was saved, when we want to use logclconfig()
  clsetsaved="no"

  for setting in $configsettings; do
    case "$(configsettingtype "$setting")" in
      scalar)
        if isset "$setting"; then
          printf -v "cl_$setting" "%s" "${!setting}"
          clsetsaved="yes"
        fi
        ;;
      array)
        if arrayisset "$setting"; then
          copyarray "$setting" "cl_$setting"
          clsetsaved="yes"
        fi
        ;;
      function)
        :  # ignore
        ;;
    esac
  done
}

#
# restore setting variables supplied on the command line, overriding the
# config file
#
# the calling script must define configsettingtype(), which takes the name
# of a config setting and prints "scalar", "array", or "function"
#
# "local" vars: setting
# global vars: configsettings
# config settings: (*, cl_*)
# user-defined functions: configsettingtype()
# library functions: arrayisset(), copyarray(), isset(), copyvar()
#
[ "${skip_restoreclset+X}" = "" ] && \
restoreclset () {
  for setting in $configsettings; do
    case "$(configsettingtype "$setting")" in
      scalar)
        if isset "cl_$setting"; then
          copyvar "cl_$setting" "$setting"
        fi
        ;;
      array)
        if arrayisset "cl_$setting"; then
          copyarray "cl_$setting" "$setting"
        fi
        ;;
      function)
        :  # ignore
        ;;
    esac
  done
}

#
# log config file, current working directory, and setting variables supplied
# on the command line
#
# saveclset() must be called before this function, to set up $cl_*
#
# the calling script must define configsettingtype(), which takes the name
# of a config setting and prints "scalar", "array", or "function"
#
# "local" vars: setting
# global vars: configsettings, noconfigfile, configfile, clsetsaved
# config settings: (*, cl_*)
# user-defined functions: configsettingtype()
# library functions: logstatus(), arrayisset(), printarray(), isset(),
#                    printvar()
# utilities: pwd, [
#
[ "${skip_logclconfig+X}" = "" ] && \
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
      case "$(configsettingtype "$setting")" in
        scalar)
          if isset "cl_$setting"; then
            logstatus "$setting='$(printvar "cl_$setting")'"
          fi
          ;;
        array)
          if arrayisset "cl_$setting"; then
            logstatus "$setting=$(printarray "cl_$setting")"
          fi
          ;;
        function)
          :  # ignore
          ;;
      esac
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
# the calling script must define configsettingtype(), which takes the name
# of a config setting and prints "scalar", "array", or "function"
#
# "local" vars: setting
# global vars: configsettings
# config settings: (all)
# user-defined functions: configsettingtype()
# library functions: printarray()
# utilities: printf
# bashisms: ${!var}
#
[ "${skip_printsettings+X}" = "" ] && \
printsettings () {
  for setting in $configsettings; do
    case "$(configsettingtype "$setting")" in
      scalar)
        printf "%s\n" "$setting='${!setting}'"
        ;;
      array)
        printf "%s\n" "$setting=$(printarray "$setting")"
        ;;
      function)
        :  # ignore
        ;;
    esac
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
[ "${skip_printconfig+X}" = "" ] && \
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

	(check quoting before re-using; list includes settings
	that are currently ignored, and may not be valid)

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
# the calling script must define configsettingtype(), which takes the name
# of a config setting and prints "scalar", "array", or "function"
#
# note: this function is mostly meant to be run from a manual command line
# mode, but for flexibility, it does not call do_exit() itself
#
# "local" vars: setting
# global vars: configfile, noconfigfile, configsettings
# user-defined functions: configsettingtype()
# utilities: printf, [
# FDs: 4
#
[ "${skip_createblankconfig+X}" = "" ] && \
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
    case "$(configsettingtype "$setting")" in
      scalar)
        printf "%s\n" "#$setting=\"\""
        ;;
      array)
        printf "%s\n" "#$setting=()"
        ;;
      function)
        printf "%s\n" "#$setting () { }"
        ;;
    esac
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
[ "${skip_throwstartuperr+X}" = "" ] && \
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
[ "${skip_throwusageerr+X}" = "" ] && \
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
[ "${skip_throwsettingerr+X}" = "" ] && \
throwsettingerr () {
  vname="$1"
  vval="${!vname}"

  throwstartuperr "Error: invalid setting for $vname ('$vval'); exiting."
}

#
# validate a setting that can't be unset or null
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: throwstartuperr()
# utilities: [
# bashisms: ${!var}
#
[ "${skip_validnotvoid+X}" = "" ] && \
validnotvoid () {
  vname="$1"
  vval="${!vname}"

  if [ "$vval" = "" ]; then
    throwstartuperr "Error: $vname is unset or blank; exiting."
  fi
}

#
# validate two settings that can't both be unset/null
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
[ "${skip_validnotbothvoid+X}" = "" ] && \
validnotbothvoid () {
  vname1="$1"
  vname2="$2"
  vval1="${!vname1}"
  vval2="${!vname2}"

  if [ "$vval1" = "" ] && [ "$vval2" = "" ]; then
    throwstartuperr "Error: $vname1 and $vname2 cannot both be blank; exiting."
  fi
}

#
# validate an array setting that can't be unset or empty
#
# $1 = array name
#
# "local" vars: aname
# config settings: (contents of $1)
# library functions: arrayisvoid(), throwstartuperr()
#
[ "${skip_validarrnotvoid+X}" = "" ] && \
validarrnotvoid () {
  aname="$1"

  if arrayisvoid "$aname"; then
    throwstartuperr "Error: $aname is unset or has no elements; exiting."
  fi
}

#
# validate an array setting that can't have any null elements
#
# if the array also can't be unset or empty, combine with validarrnotvoid()
#
# $1 = array name
#
# "local" vars: aname
# config settings: (contents of $1)
# library functions: arrayisvoid(), arrayallnotvoid(), throwstartuperr()
# bashisms: !
#
[ "${skip_validarrnonulls+X}" = "" ] && \
validarrnonulls () {
  aname="$1"

  if arrayisvoid "$aname" || arrayallnotvoid "$aname"; then
    return
  fi

  throwstartuperr "Error: $aname may not contain blank elements; exiting."
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
[ "${skip_validnum+X}" = "" ] && \
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
# "local" vars: vname, vval, nochar, charname
# config settings: (contents of $1)
# library vars: tab, newline
# library functions: throwstartuperr()
# utilities: printf, tr, [
# bashisms: ${!var}
#
[ "${skip_validnochar+X}" = "" ] && \
validnochar () {
  vname="$1"
  vval="${!vname}"
  nochar="$2"

  case "$nochar" in
    ' ')
      charname="space"
      ;;
    $tab)
      charname="tab"
      ;;
    $newline)
      charname="newline"
      ;;
    *)
      charname="'$nochar'"
      ;;
  esac

  # use tr so we don't have to worry about metacharacters
  # (we could use escregex(), but that's rather heavyweight for this)
  # without Xs, this breaks if $1 ends in a newline
  if [ "${vval}X" != "$(printf "%sX\n" "$vval" | tr -d "$nochar")" ]; then
    throwstartuperr "Error: $vname cannot contain $charname characters; exiting."
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
[ "${skip_validlist+X}" = "" ] && \
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
# validate a directory setting, for directories in which we need to create
# and/or rotate files:
# setting must not be unset or null, and directory must exist,
# be a directory or a symlink to a one, and have full permissions
# (r/w/x; r for rotation, wx for creating files)
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: validnotvoid(), throwstartuperr()
# utilities: [
# bashisms: ${!var}
#
[ "${skip_validrwxdir+X}" = "" ] && \
validrwxdir () {
  vname="$1"
  vval="${!vname}"

  validnotvoid "$vname"

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
# 1) the setting may not be unset or null
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
# library functions: validnotvoid(), throwstartuperr(), getparentdir()
# utilities: ls, [
# bashisms: ${!var}
#
[ "${skip_validcreate+X}" = "" ] && \
validcreate () {
  vname="$1"
  vval="${!vname}"

  # condition 1
  validnotvoid "$vname"

  # condition 2
  #
  # note: [ -e ] isn't portable, so try ls, even though it's probably not
  # robust enough to be a general solution...
  if ls -d "$vval" > /dev/null 2>&1; then
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
# setting must not be unset or null, and file must exist,
# be a file or a symlink to one, and be readable
#
# $1 = variable name ("configfile" treated specially)
#
# "local" vars: vname, vval
# global vars: (contents of $1, if "configfile")
# config settings: (contents of $1, usually)
# library functions: validnotvoid(), throwstartuperr()
# utilities: [
# bashisms: ${!var}
#
[ "${skip_validreadfile+X}" = "" ] && \
validreadfile () {
  vname="$1"
  vval="${!vname}"

  # unset/null?
  validnotvoid "$vname"

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
# setting must not be unset or null, and file must exist,
# be a file or a symlink to a file, and be readable and writable
#
# $1 = variable name
#
# "local" vars: vname, vval
# config settings: (contents of $1)
# library functions: validreadfile(), throwstartuperr()
# utilities: [
# bashisms: ${!var}
#
[ "${skip_validrwfile+X}" = "" ] && \
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
# validate a user-supplied config function
#
# $1 = variable name
#
# config functions: (contents of $1)
# library functions: funcisnotdefined(), throwstartuperr()
#
[ "${skip_validfunction+X}" = "" ] && \
validfunction () {
  if funcisnotdefined "$1"; then
    throwstartuperr "Error: $1 function is not defined; exiting."
  fi
}

#
# warn about non-existent settings that the user might have tried to set
# by accident
#
# the calling script must define configsettingtype(), which takes the name
# of a bogus setting and prints "scalar", "array", or "function"
#
# "local" vars: bogus
# global vars: bogusconfig
# library vars: newline
# user-defined functions: configsettingtype()
# library functions: isset(), arrayisset(), funcisdefined(), sendalert()
# utilities: [
# bashisms: unset
#
[ "${skip_warnbogusconf+X}" = "" ] && \
warnbogusconf () {
  for bogus in $bogusconfig; do
    if { \
         [ "$(configsettingtype "$bogus")" = "scalar" ] \
         && \
         isset "$bogus"; \
       } \
       || \
       { \
         [ "$(configsettingtype "$bogus")" = "array" ] \
         && \
         arrayisset "$bogus"; \
       }; then
      sendalert "warning: variable '$bogus' is set, but there is no such setting;${newline}value will be ignored" log
      unset "$bogus"
    fi

    if [ "$(configsettingtype "$bogus")" = "function" ] \
       && \
       funcisdefined "$bogus"; then
      sendalert "warning: function '${bogus}()' is defined, but there is no such hook;${newline}definition will be ignored" log
      unset "$bogus"
    fi
  done
}

#
# process command-line settings and the config file
#
# the calling script must define applydefaults() and validconf();
# neither needs to return anything
#
# global vars: configfile, noconfigfile, defaultconfigfile
# user-defined functions: applydefaults(), validconf()
# library functions: saveclset(), restoreclset(), validreadfile(),
#                    warnbogusconf()
# utilities: printf, grep, [
#
[ "${skip_do_config+X}" = "" ] && \
do_config () {
  # save variables set on the command line
  saveclset

  # check and source config file
  if [ "$noconfigfile" != "yes" ]; then
    # apply default config file if applicable
    if [ "$configfile" = "" ]; then
      configfile="$defaultconfigfile"
    fi

    validreadfile "configfile"

    # . won't work with no directory (unless ./ is in the PATH);
    # the cwd has to be specified explicitly
    # -> this seems not to be true, since I can't get it to fail again;
    #    leaving the code alone just in case
    if printf "%s\n" "$configfile" | grep -v '/' > /dev/null 2>&1; then
      . "./$configfile"
    else
      . "$configfile"
    fi
  fi

  # restore variables set on the command line, overriding the config file
  restoreclset

  # warn about and ignore bogus variables that the user might have
  # accidentally set
  warnbogusconf

  # apply default settings where applicable
  applydefaults

  # validate the config settings
  validconf
}


##################################
# status checks and modifications
##################################

#
# exit callback: clean up lockfile
#
# removes the lockfile, unless the scriptdisabled semaphore exists
#
# note: we could use a trap to automatically remove the lockfile,
# but we explicitly remove it instead so that its unexpected presence
# serves as notice that something went wrong previously;
# this is also the reason for not using -f
#
# global vars: scriptdisabled
# config settings: lockfile
# utilities: rm, [
# files: $lockfile, $lockfile/$scriptdisabled
#
[ "${skip_lockfile_cleanup+X}" = "" ] && \
lockfile_cleanup () {
  if [ ! -f "$lockfile/$scriptdisabled" ]; then
    rm -r "$lockfile"
  fi
  # otherwise, a disable command must have been run while we were
  # doing this backup; leave the lockfile dir alone, so future backups
  # will be disabled
}

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
# global vars: lfalertssilenced, scriptdisabled, timetemp
# config settings: runevery, startedfile, lockfile, ifrunning, alertfile
# library vars: no_error_exitval, lockfile_exitval
# library functions: newerthan(), logstatus(), logalert(), sendalert(),
#                    addexitcallback(), lockfile_cleanup(), do_exit()
# utilities: mkdir, rm, touch, [
# files: $startedfile, $lockfile, $alertfile, $lockfile/$lfalertssilenced,
#        $lockfile/$scriptdisabled, $lockfile/timetemp
#
[ "${skip_checkstatus+X}" = "" ] && \
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
    # add callback to remove the lockfile on exit
    addexitcallback "lockfile_cleanup"

    # clear lock-alert status
    if [ -f "$alertfile" ]; then  # -f is more portable than -e
      rm "$alertfile"
      sendalert "lockfile created; cancelling previous alert status" log
    fi
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
# $1 is a description of the script's purpose, such as "backup"; this is
# used in messages like "starting backup"
#
# config settings: startedfile
# library functions: logstatus()
# utilities: touch, printf, date
# files: $startedfile
# FDs: 3
#
[ "${skip_do_start+X}" = "" ] && \
do_start () {
  logstatus "starting $1"
  touch "$startedfile"
  printf "%s\n" "$1 started $(date)" >&3
}

#
# done working
#
# log finished messages and timestamp
#
# $1 is a description of the script's purpose, such as "backup"; this is
# used in messages like "backup finished"
#
# library functions: logstatus()
# utilities: printf, date
# FDs: 3
#
[ "${skip_do_finish+X}" = "" ] && \
do_finish () {
  logstatus "$1 finished"
  printf "%s\n" "$1 finished $(date)" >&3
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
[ "${skip_silencelfalerts+X}" = "" ] && \
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
[ "${skip_unsilencelfalerts+X}" = "" ] && \
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
[ "${skip_disablescript+X}" = "" ] && \
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
[ "${skip_enablescript+X}" = "" ] && \
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
[ "${skip_clearlock+X}" = "" ] && \
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
# filenames can have an optional .gz, .bz2, .lz, or .xz after $3
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
[ "${skip_rotatenumfiles+X}" = "" ] && \
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.xz$" > /dev/null 2>&1 ; then
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2\.new$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz\.new$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.xz\.new$" > /dev/null 2>&1 ; then
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.bz2$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$suffix")\.xz$" > /dev/null 2>&1 ; then
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
# filenames can have an optional .gz, .bz2, .lz, or .xz after $3
#
# also works on directories
#
# "local" vars: prefix, sep, suffix, numf, daysf, filename, filenum, D
# library vars: nodelim_exitval
# library functions: escregex(), getseddelim(), sendalert(), do_exit()
# utilities: printf, grep, sed, rm, find, [
#
[ "${skip_prunenumfiles+X}" = "" ] && \
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
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
       && \
       printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep")[0-9][0-9]*$(escregex "$suffix")\.xz$" > /dev/null 2>&1 ; then
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
      # -r for dirs; redirect because of issues with out-of-order deletions
      find "$filename" -mtime "+$(expr "$daysf" - 1)" -exec rm -rf {} \; >/dev/null 2>&1
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
# filenames can have an optional .gz, .bz2, .lz, or .xz after $3
#
# also works on directories
#
# re numbered pruning:
#   note: "current" file must exist before calling this function, so that
#   it can be counted
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
[ "${skip_prunedatefiles+X}" = "" ] && \
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
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.bz2$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.lz$" > /dev/null 2>&1 \
         && \
         printf "%s\n" "$filename" | grep -v "^$(escregex "$prefix$sep").*$(escregex "$suffix")\.xz$" > /dev/null 2>&1 ; then
        continue
      fi

      # delete by date
      #
      # -r for dirs; redirect because of issues with out-of-order deletions
      find "$filename" -mtime "+$(expr "$daysf" - 1)" -exec rm -rf {} \; >/dev/null 2>&1
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
# filenames can have an optional .gz, .bz2, .lz, or .xz after $4
#
# also works on directories
#
# library functions: prunenumfiles(), prunedatefiles()
#
[ "${skip_prunefiles+X}" = "" ] && \
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
# filenames can have an optional trailing .gz, .bz2, .lz, or .xz
#
# config settings: outputlog, outputlog_layout, outputlog_sep, numlogs,
#                  dayslogs
# library functions: logstatus(), rotatenumfiles(), prunefiles()
# utilities: [
# files: $outputlog, (previous outputlogs)
#
[ "${skip_rotatepruneoutputlogs+X}" = "" ] && \
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
# $2 = type of zip to check for ("gzip", "pigz", "bzip2", "lzip", "xz",
# "all" for all of the above, or "none"; default is "all")
#
# if they exist, files must be regular files or symlinks to regular files
#
# returns 0/1 (true/false)
#
# utilities: [
#
[ "${skip_existsfilezip+X}" = "" ] && \
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
      [ -f "$1" ] || [ -f "$1.bz2" ]
      ;;
    lzip)
      [ -f "$1" ] || [ -f "$1.lz" ]
      ;;
    xz)
      [ -f "$1" ] || [ -f "$1.xz" ]
      ;;
    all|*)  # default
      [ -f "$1" ] || [ -f "$1.gz" ] || [ -f "$1.bz2" ] || \
          [ -f "$1.lz" ] || [ -f "$1.xz" ]
      ;;
  esac
}

#
# remove a file, including zipped versions of it
#
# $1 = file to remove
# $2 = type of zip to remove ("gzip", "pigz", "bzip2", "lzip", "xz",
# "all" for all of the above, or "none"; default is "none")
# note that $1 will still be removed if $2 is "none"
#
# utilities: rm
#
[ "${skip_removefilezip+X}" = "" ] && \
removefilezip () {
  rm -f "$1"

  case "$2" in
    gzip|pigz)
      rm -f "$1.gz"
      ;;
    bzip2)
      rm -f "$1.bz2"
      ;;
    lzip)
      rm -f "$1.lz"
      ;;
    xz)
      rm -f "$1.xz"
      ;;
    all)
      rm -f "$1.gz"
      rm -f "$1.bz2"
      rm -f "$1.lz"
      rm -f "$1.xz"
      ;;
    none|*)
      :  # nothing else to remove
      ;;
  esac
}

#
# move a file, including zipped versions of it
#
# $1 = file to move
# $2 = destination directory
# $3 = type of zip to move ("gzip", "pigz", "bzip2", "lzip", "xz",
# "all" for all of the above, or "none"; default is "none")
# note that $1 will still be moved if $3 is "none"
#
# utilities: mv
#
[ "${skip_movefilezip+X}" = "" ] && \
movefilezip () {
  mv -f "$1" "$2" >/dev/null 2>&1

  case "$3" in
    gzip|pigz)
      mv -f "$1.gz" "$2" >/dev/null 2>&1
      ;;
    bzip2)
      mv -f "$1.bz2" "$2" >/dev/null 2>&1
      ;;
    lzip)
      mv -f "$1.lz" "$2" >/dev/null 2>&1
      ;;
    xz)
      mv -f "$1.xz" "$2" >/dev/null 2>&1
      ;;
    all)
      mv -f "$1.gz" "$2" >/dev/null 2>&1
      mv -f "$1.bz2" "$2" >/dev/null 2>&1
      mv -f "$1.lz" "$2" >/dev/null 2>&1
      mv -f "$1.xz" "$2" >/dev/null 2>&1
      ;;
    none|*)
      :  # nothing else to move
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
# global vars: cmdexitval
# config settings: ssh_port, ssh_keyfile, ssh_options, ssh_user, ssh_host,
#                  ssh_rcommand
# library functions: begincmdprint(), endcmdprint()
# utilities: ssh
# files: $ssh_keyfile
# bashisms: arrays
#
[ "${skip_sshremotecmd+X}" = "" ] && \
sshremotecmd () {
  begincmdprint
  ssh \
    ${ssh_port:+-p "$ssh_port"} \
    ${ssh_keyfile:+-i "$ssh_keyfile"} \
    "${ssh_options[@]}" \
    ${ssh_user:+-l "$ssh_user"} \
    "$ssh_host" \
    "${ssh_rcommand[@]}"
  endcmdprint 2>/dev/null

  return "$cmdexitval"
}

#
# run a remote SSH command in the background
#
# $1 is the name of a global variable to store the ssh PID in, to
# differentiate between multiple commands; if unset or null, it defaults to
# "sshpid"
#
# if $2 is unset or null, a callback function to kill the ssh process when
# the script exits will be registered; to prevent this, make $2 non-null
# (suggested value: "noauto")
#
# (to set $2 while leaving $1 as the default, use "" for $1)
#
# ssh_options and ssh_rcommand must be indexed, non-sparse arrays
#
# "local" vars: sshpid_var, sshpid_l
# global vars: (contents of $1, or sshpid), cmdpid
# config settings: ssh_port, ssh_keyfile, ssh_options, ssh_user, ssh_host,
#                  ssh_rcommand
# library functions: begincmdprint(), endcmdprintbg(), addexitcallback(),
#                    killsshremotebg()
# utilities: ssh, printf, [
# files: $ssh_keyfile
# bashisms: arrays, printf -v [v3.1]
#
[ "${skip_sshremotebgcmd+X}" = "" ] && \
sshremotebgcmd () {
  # apply default
  sshpid_var="sshpid"

  # get value, if set
  [ "$1" != "" ] && sshpid_var="$1"

  # run the command
  begincmdprint
  ssh \
    ${ssh_port:+-p "$ssh_port"} \
    ${ssh_keyfile:+-i "$ssh_keyfile"} \
    "${ssh_options[@]}" \
    ${ssh_user:+-l "$ssh_user"} \
    "$ssh_host" \
    "${ssh_rcommand[@]}" \
    &
  endcmdprintbg 2>/dev/null

  # register the exit callback
  [ "$2" = "" ] && addexitcallback "killsshremotebg" "$sshpid_var"

  # get the PID
  sshpid_l="$cmdpid"
  printf -v "$sshpid_var" "%s" "$sshpid_l"  # set the global
}

#
# kill a backgrounded remote SSH command
#
# $1 is the name of a global variable that contains the ssh PID, to
# differentiate between multiple commands; if unset or null, it defaults to
# "sshpid"
#
# if $2 is unset or null, the callback function to kill the ssh process when
# the script exits will be unregistered (see sshremotebgcmd()); to prevent
# this, make $2 non-null (suggested value: "noauto")
#
# (to set $2 while leaving $1 as the default, use "" for $1)
#
# can be run even if the command was already killed / died
#
# "local" vars: sshpid_var, sshpid_l
# global vars: (contents of $1, or sshpid)
# library functions: removeexitcallback()
# utilities: printf, kill, [
# bashisms: ${!var}, printf -v [v3.1]
#
[ "${skip_killsshremotebg+X}" = "" ] && \
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

  # unregister the exit callback
  [ "$2" = "" ] && removeexitcallback "killsshremotebg" "$sshpid_var"
}

#
# run an SSH tunnel command
#
# $1 is the name of a global variable to store the ssh PID in, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid"
#
# if $2 is unset or null, a callback function to kill the ssh process when
# the script exits will be registered; to prevent this, make $2 non-null
# (suggested value: "noauto")
#
# (to set $2 while leaving $1 as the default, use "" for $1)
#
# tun_sshoptions must be an indexed, non-sparse array
#
# "local" vars: tunpid_var, tunpid_l
# global vars: (contents of $1, or tunpid), cmdpid
# config settings: tun_localport, tun_remotehost, tun_remoteport,
#                  tun_sshport, tun_sshkeyfile, tun_sshoptions, tun_sshuser,
#                  tun_sshhost
# library functions: begincmdprint(), endcmdprintbg(), addexitcallback(),
#                    killsshtunnel()
# utilities: ssh, printf, [
# files: $tun_sshkeyfile
# bashisms: arrays, printf -v [v3.1]
#
[ "${skip_sshtunnelcmd+X}" = "" ] && \
sshtunnelcmd () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # run the command
  begincmdprint
  ssh \
    -L "${tun_localport}:${tun_remotehost}:${tun_remoteport}" -N \
    ${tun_sshport:+-p "$tun_sshport"} \
    ${tun_sshkeyfile:+-i "$tun_sshkeyfile"} \
    "${tun_sshoptions[@]}" \
    ${tun_sshuser:+-l "$tun_sshuser"} \
    "$tun_sshhost" \
    &
  endcmdprintbg 2>/dev/null

  # register the exit callback
  [ "$2" = "" ] && addexitcallback "killsshtunnel" "$tunpid_var"

  # get the PID
  tunpid_l="$cmdpid"
  printf -v "$tunpid_var" "%s" "$tunpid_l"  # set the global
}

#
# kill an SSH tunnel
#
# $1 is the name of a global variable that contains the ssh PID, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid"
#
# if $2 is unset or null, the callback function to kill the ssh process when
# the script exits will be unregistered (see sshtunnelcmd()); to prevent
# this, make $2 non-null (suggested value: "noauto")
#
# (to set $2 while leaving $1 as the default, use "" for $1)
#
# can be run even if the tunnel already died / was closed / was killed
#
# note: this will hang if the remote port isn't open; you should be using
# opensshtunnel(), or duplicating its functionality
#
# "local" vars: tunpid_var, tunpid_l
# global vars: (contents of $1, or tunpid)
# library functions: removeexitcallback()
# utilities: printf, kill, [
# bashisms: ${!var}, printf -v [v3.1]
#
[ "${skip_killsshtunnel+X}" = "" ] && \
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

  # unregister the exit callback
  [ "$2" = "" ] && removeexitcallback "killsshtunnel" "$tunpid_var"
}

#
# open an SSH tunnel, including testing and logging
#
# $1 is the name of a global variable to store the ssh PID in, to
# differentiate between multiple tunnels; if unset or null, it defaults to
# "tunpid" (example setting suggestion: "rsynctunpid")
#
# $tun_descr should be a description of the tunnel's purpose (e.g.
# "mysql dumps" or "rsync backups"); this is used in status and error
# messages
# a global variable with name "$1_descr" (defaults to "tunpid_descr"
# if $1 is unset or null) will be used to save the current value of
# $tun_descr
#
# if $2 is unset or null, a callback function to close the tunnel when
# the script exits will be registered; to prevent this, make $2 non-null
# (suggested value: "noauto")
#
# (to set $2 while leaving $1 as the default, use "" for $1)
#
# returns 0 on success
# on error, calls sendalert(), then acts according to the value of
# tun_on_err:
#   "exit": exits the script with exitval $sshtunnel_exitval
#   "phase": returns 1 ("abort this phase of the script")
# if tun_on_err is unset or null, it defaults to "exit"
#
# FD 3 gets a start message and the actual output (stdout and stderr) of
# ssh
#
# "local" vars: tunpid_var, tunpid_l, waited, sshexit
# global vars: (contents of $1, or tunpid, and the corresponding *_descr),
#              tun_descr, phaseerr
# config settings: tun_localhost, tun_localport, tun_sshtimeout, tun_on_err
# library vars: newline, sshtunnel_exitval
# library functions: sshtunnelcmd(), logstatus(), logstatusquiet(),
#                    sendalert(), addexitcallback(), closesshtunnel(),
#                    do_exit()
# utilities: nc, printf, sleep, kill, expr, [
# FDs: 3
# bashisms: ${!var}, printf -v [v3.1]
#
[ "${skip_opensshtunnel+X}" = "" ] && \
opensshtunnel () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # save tun_descr
  printf -v "${tunpid_var}_descr" "%s" "$tun_descr"

  # log that we're running the command
  logstatusquiet "running SSH tunnel command for $tun_descr"
  printf "%s\n" "running SSH tunnel command for $tun_descr" >&3

  # run the command and get the PID
  sshtunnelcmd "$tunpid_var" "noauto" >&3 2>&1
  tunpid_l="${!tunpid_var}"

  # register the exit callback
  [ "$2" = "" ] && addexitcallback "closesshtunnel" "$tunpid_var"

  # make sure it's actually working;
  # see http://mywiki.wooledge.org/ProcessManagement#Starting_a_.22daemon.22_and_checking_whether_it_started_successfully
  waited="1"  # will be 1 once we actually enter the loop
  while sleep 1; do
    nc -z "$tun_localhost" "$tun_localport" && break

    # not working yet, but is it still running?
    if kill -0 "$tunpid_l" > /dev/null 2>&1; then  # quiet if already dead
      # expr is more portable than $(())
      waited=$(expr "$waited" + 1)

      if [ "$waited" -ge "$tun_sshtimeout" ]; then
        kill "$tunpid_l" > /dev/null 2>&1  # quiet if it's already dead
        wait "$tunpid_l"
        # so we know it's not running anymore
        printf -v "$tunpid_var" "%s" ""

        case "$tun_on_err" in
          phase)
            sendalert "could not establish SSH tunnel for $tun_descr (timed out);${newline}aborting $tun_descr" log
            phaseerr="$sshtunnel_exitval"
            return 1  # abort this phase of the script
            ;;
          *)  # exit
            sendalert "could not establish SSH tunnel for $tun_descr (timed out); exiting" log
            do_exit "$sshtunnel_exitval"
            ;;
        esac
      fi
    else  # process is already dead
      wait "$tunpid_l"
      sshexit="$?"

      # so we know it's not running anymore
      printf -v "$tunpid_var" "%s" ""

      case "$tun_on_err" in
        phase)
          sendalert "could not establish SSH tunnel for $tun_descr (status code $sshexit);${newline}aborting $tun_descr" log
          phaseerr="$sshtunnel_exitval"
          return 1  # abort this phase of the script
          ;;
        *)  # exit
          sendalert "could not establish SSH tunnel for $tun_descr (status code $sshexit); exiting" log
          do_exit "$sshtunnel_exitval"
          ;;
      esac
    fi  # if kill -0
  done  # while sleep 1

  logstatus "SSH tunnel for $tun_descr established"

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
# if $2 is unset or null, the callback function to kill the ssh process when
# the script exits will be unregistered (see opensshtunnel()); to prevent
# this, make $2 non-null (suggested value: "noauto")
#
# (to set $2 while leaving $1 as the default, use "" for $1)
#
# can be run even if the tunnel already died / was closed / was killed,
# but should not be run before the tunnel was started, or the logs won't
# make sense
#
# "local" vars: tunpid_var, tunpid_l, descr_l
# global vars: (contents of $1, or tunpid, and the corresponding *_descr)
# library functions: copyvar(), logstatus(), removeexitcallback()
# utilities: printf, kill, [
# bashisms: ${!var}, printf -v [v3.1]
#
[ "${skip_closesshtunnel+X}" = "" ] && \
closesshtunnel () {
  # apply default
  tunpid_var="tunpid"

  # get value, if set
  [ "$1" != "" ] && tunpid_var="$1"

  # get the PID and the descr
  tunpid_l="${!tunpid_var}"
  copyvar "${tunpid_var}_descr" "descr_l"

  if [ "$tunpid_l" != "" ]; then
    kill "$tunpid_l" > /dev/null 2>&1  # don't complain if it's already dead
    wait "$tunpid_l"
    printf -v "$tunpid_var" "%s" ""  # so we know it's been closed

    logstatus "SSH tunnel for $descr_l closed"
  else
    logstatus "SSH tunnel for $descr_l was already closed"
  fi

  # unregister the exit callback
  [ "$2" = "" ] && removeexitcallback "closesshtunnel" "$tunpid_var"
}


###################################
# database calls and manipulations
###################################

#
# run a database command
#
# $1 is the command to run
#
# dbms_prefix must be one of the accepted values (currently "mysql" or
# "postgres")
#
# when using an SSH tunnel, set host to "localhost" (or "127.0.0.1" /
# "::1" / etc. as necessary) and port to the local port of the tunnel
#
# (in the notes below, [dbms] = the value of $dbms_prefix)
#
# [dbms]_options must be an indexed, non-sparse array
#
# global vars: dbms_prefix, cmdexitval
# config settings: [dbms]_user, [dbms]_pwfile, [dbms]_protocol, [dbms]_host,
#                  [dbms]_port, [dbms]_socketfile, [dbms]_options,
#                  [dbms]_connectdb
# library functions: begincmdprint(), endcmdprint()
# utilities: mysql, psql
# files: $[dbms]_pwfile, $[dbms]_socketfile
# bashisms: arrays
#
[ "${skip_dbcmd+X}" = "" ] && \
dbcmd () {
  case "$dbms_prefix" in
    mysql)
      begincmdprint
      # --defaults-extra-file must be the first option if present
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socketfile:+-S "$mysql_socketfile"} \
        ${mysql_connectdb:+"$mysql_connectdb"} \
        "${mysql_options[@]}" \
        ${1+-e "$1"}
      endcmdprint 2>/dev/null
      ;;
    postgres)
      begincmdprint
      PGPASSFILE=${postgres_pwfile:+"$postgres_pwfile"} \
        psql \
        ${postgres_user:+-U "$postgres_user"} \
        ${postgres_host:+-h "$postgres_host"} \
        ${postgres_port:+-p "$postgres_port"} \
        ${postgres_connectdb:+-d "$postgres_connectdb"} \
        "${postgres_options[@]}" \
        ${1+-c "$1"}
      endcmdprint 2>/dev/null
      ;;
  esac

  return "$cmdexitval"
}

#
# run a get-database-list command
#
# (may not be possible/straightforward for all DBMSes)
#
# dbms_prefix must be one of the accepted values (currently "mysql" or
# "postgres")
#
# when using an SSH tunnel, set host to "localhost" (or "127.0.0.1" /
# "::1" / etc. as necessary) and port to the local port of the tunnel
#
# some options are pre-included:
#   MySQL:
#     -BN -e "SHOW DATABASES;"
#   PostgreSQL:
#     -At -c "SELECT datname FROM pg_catalog.pg_database;"
#
# (in the notes below, [dbms] = the value of $dbms_prefix)
#
# [dbms]_options must be an indexed, non-sparse array
#
# global vars: dbms_prefix, cmdexitval
# config settings: [dbms]_user, [dbms]_pwfile, [dbms]_protocol, [dbms]_host,
#                  [dbms]_port, [dbms]_socketfile, [dbms]_connectdb,
#                  [dbms]_options
# library functions: begincmdprint(), endcmdprint()
# utilities: mysql, psql
# files: $[dbms]_pwfile, $[dbms]_socketfile
# bashisms: arrays
#
[ "${skip_dblistcmd+X}" = "" ] && \
dblistcmd () {
  case "$dbms_prefix" in
    mysql)
      begincmdprint
      # --defaults-extra-file must be the first option if present
      mysql \
        ${mysql_pwfile:+"--defaults-extra-file=$mysql_pwfile"} \
        ${mysql_user:+-u "$mysql_user"} \
        ${mysql_protocol:+"--protocol=$mysql_protocol"} \
        ${mysql_host:+-h "$mysql_host"} \
        ${mysql_port:+-P "$mysql_port"} \
        ${mysql_socketfile:+-S "$mysql_socketfile"} \
        "${mysql_options[@]}" \
        -BN -e "SHOW DATABASES;"
      endcmdprint 2>/dev/null
      ;;
    postgres)
      begincmdprint
      PGPASSFILE=${postgres_pwfile:+"$postgres_pwfile"} \
        psql \
        ${postgres_user:+-U "$postgres_user"} \
        ${postgres_host:+-h "$postgres_host"} \
        ${postgres_port:+-p "$postgres_port"} \
        ${postgres_connectdb:+-d "$postgres_connectdb"} \
        "${postgres_options[@]}" \
        -At -c "SELECT datname FROM pg_catalog.pg_database;"
      endcmdprint 2>/dev/null
      ;;
  esac

  return "$cmdexitval"
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
#   PostgreSQL:
#     (none; DB names with newlines or tabs may cause problems)
#
# (that is, this function will carry out the mappings above, which are the
# reverse of the mappings used by the DBMSes)
#
# dbms_prefix must be one of the accepted values (currently "mysql" or
# "postgres")
#
# global vars: dbms_prefix
# library vars: tab
# utilities: printf, sed
#
[ "${skip_dbunescape+X}" = "" ] && \
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
    postgres)
      printf "%s\n" "$1"  # just echo the input
      ;;
  esac
}


###########################
# backups and file syncing
###########################

#
# run an rsync command
#
# for "tunnel" mode, SSH tunnel must be opened/closed separately; use
# "localhost" (or "127.0.0.1" / "::1" / etc.) for the host (in
# rsync_source/dest) and set rsync_port to the local port of the tunnel
#
# rsync_sshoptions can't contain spaces in "nodaemon" mode
#
# rsync_sshoptions, rsync_options, and rsync_source must be indexed,
# non-sparse arrays
#
# global vars: cmdexitval
# config settings: rsync_mode, rsync_pwfile, rsync_port, rsync_sshkeyfile,
#                  rsync_sshport, rsync_sshoptions, rsync_filterfile,
#                  rsync_options, rsync_source, rsync_dest
# library functions: begincmdprint(), endcmdprint()
# utilities: rsync, ssh
# files: $rsync_sshkeyfile, $rsync_pwfile, $rsync_filterfile
# bashisms: arrays
#
[ "${skip_rsynccmd+X}" = "" ] && \
rsynccmd () {
  case "$rsync_mode" in
    tunnel|direct)
      begincmdprint
      rsync \
        ${rsync_port:+"--port=$rsync_port"} \
        ${rsync_pwfile:+"--password-file=$rsync_pwfile"} \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        "${rsync_options[@]}" \
        "${rsync_source[@]}" \
        "$rsync_dest"
      endcmdprint 2>/dev/null
      ;;
    nodaemon)
      begincmdprint
      # the ssh command has to be on one line, and every way I tried to embed
      # it had problems; this is the best method I can come up with, although
      # it breaks with spaces in the options array
      RSYNC_RSH="ssh ${rsync_sshkeyfile:+-i "$rsync_sshkeyfile"} ${rsync_sshport:+-p "$rsync_sshport"} ${rsync_sshoptions[@]}" \
        rsync \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        "${rsync_options[@]}" \
        "${rsync_source[@]}" \
        "$rsync_dest"
      endcmdprint 2>/dev/null
      ;;
    local)
      begincmdprint
      rsync \
        ${rsync_filterfile:+-f "merge $rsync_filterfile"} \
        "${rsync_options[@]}" \
        "${rsync_source[@]}" \
        "$rsync_dest"
      endcmdprint 2>/dev/null
      ;;
  esac

  return "$cmdexitval"
}

#
# run an rdiff-backup command
#
# rsync_sshoptions can't contain spaces
#
# rdb_sshoptions and rdb_options must be indexed arrays
#
# "local" vars: rdb_cmdopt_tmp, rschemastr
# global vars: cmdexitval
# config settings: rdb_mode, rdb_sshkeyfile, rdb_sshport, rdb_sshoptions,
#                  rdb_options, rdb_cmdopt, rdb_source, rdb_dest
# library functions: copyarray(), begincmdprint(), endcmdprint()
# utilities: rdiff-backup, ssh, [
# files: $rdb_sshkeyfile
# bashisms: arrays, array+=() [v3.1]
#
[ "${skip_rdbcmd+X}" = "" ] && \
rdbcmd () {
  # use a copy so we don't change the real array, below
  copyarray "rdb_cmdopt" "rdb_cmdopt_tmp" exact

  # put rdb_source in the rdb_cmdopt_tmp array; this lets us omit it
  # completely with "${[@]}" instead of leaving a "" in the command,
  # if it's not set
  if [ "$rdb_source" != "" ]; then
    rdb_cmdopt_tmp+=("$rdb_source")
  fi

  case "$rdb_mode" in
    remote)
      # the ssh command has to be on one line, and every way I tried to embed
      # it had problems; this is the best method I can come up with, although
      # it breaks with spaces in the options array
      rschemastr="ssh ${rdb_sshkeyfile:+-i "$rdb_sshkeyfile"} ${rdb_sshport:+-p "$rdb_sshport"} ${rdb_sshoptions[@]} %s rdiff-backup --server"
      begincmdprint
      rdiff-backup \
        --remote-schema "$rschemastr" \
        "${rdb_options[@]}" \
        "${rdb_cmdopt_tmp[@]}" \
        "$rdb_dest"
      endcmdprint 2>/dev/null
      ;;
    local)
      begincmdprint
      rdiff-backup \
        "${rdb_options[@]}" \
        "${rdb_cmdopt_tmp[@]}" \
        "$rdb_dest"
      endcmdprint 2>/dev/null
      ;;
  esac

  return "$cmdexitval"
}

#
# run an rdiff-backup prune command; this is a wrapper around rdbcmd()
#
# "local" vars: rdbcmdexit, rdb_cmdopt_bak, rdb_source_bak
# config settings: rdb_cmdopt, rdb_source, rdb_prune
# library functions: copyarray(), rdbcmd()
# bashisms: arrays
#
[ "${skip_rdbprunecmd+X}" = "" ] && \
rdbprunecmd () {
  copyarray "rdb_cmdopt" "rdb_cmdopt_bak" exact
  rdb_cmdopt=(--remove-older-than "$rdb_prune" --force)
  rdb_source_bak="$rdb_source"
  rdb_source=""

  rdbcmd
  rdbcmdexit="$?"

  rdb_source="$rdb_source_bak"
  copyarray "rdb_cmdopt_bak" "rdb_cmdopt" exact
  return "$rdbcmdexit"
}
