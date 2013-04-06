#!/bin/sh

case "$1" in
  system)
    cp aeolus-lib.sh /usr/local/lib/
    chmod 755 /usr/local/lib/aeolus-lib.sh
    ;;
  user)
    mkdir -p ~/bin  # don't complain if it exists
    chmod u=rwx ~/bin
    cp aeolus-lib.sh ~/bin/
    chmod u=rwx ~/bin/aeolus-lib.sh
    ;;
  *)
    cat 1>&2 <<-EOF

	Usage:

	  $0 { system | user }

	"system" installs systemwide;
	"user" installs to the home directory of the current user

	EOF
    ;;
esac
