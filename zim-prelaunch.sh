#!/bin/bash
#
# _zim_prelaunch - merge 'other' branches just before launch.
#
# WARNING: The local repo must have a checkout of each remote branch
# that you would like to auto-merge/push.
#
# WARNING: This assumes ALL branches are intended to *CONVERGE*.
# This is not how development repos work, but zim repos do.
#

set -vexu

# If we are *launching* zim, then it is terminated... and the stale sockets
# and whatnot can get in the way...
rm -rf /tmp/zim-$USER &

# Longest common prefix (optional, but makes for even nicer commit messages)
LCP=/usr/local/bin/lcp

if ! which online 2>/dev/null 1>&2
then
	function online()
	{
		echo "online script not found, so assuming network connection is up"
		return 0;
	}
fi

NOTEBOOKS=$HOME/Notebooks

test -d $NOTEBOOKS || exit 1

for NOTEBOOK in $NOTEBOOKS/*
do

cd $NOTEBOOK

if [ -e .git/index.lock ] && [ -z "$(pgrep git)" ]
then
	rm -fv .git/index.lock
fi

CURRENT_BRANCH=$(basename $(git symbolic-ref HEAD))

BRANCHES=$(git for-each-ref refs/ --format='%(refname:short)' | egrep -v "(HEAD|$CURRENT_BRANCH)") || echo "no branches?"

MSG="$(hostname): pre-launch merge"

online && git fetch --all || true

# NB: We should only merge if there are NO UNCOMMITTED CHANGES!
DIRTY="$(git status --porcelain)"

# NB: *COPIED* from the etc/cron.hourly/zim-commit.sh (so that commit messages will be the same)
if [ -n "$DIRTY" ]
then

	git add -A .

		MESSAGE=""

		if [ -x "$LCP" ]
		then
			# Journal entries are second-class citizens here, so first... let's try to get a prefix *ignoring* all the Journal entries
			PREFIX=$(git status --porcelain | cut -c4- | grep -v '^Journal' | $LCP)
			# If the lcp is an actual file or directory, then we use it, otherwise ignore it.
			# This will let us have more descriptive commit messages when all the changes are
			# related, without introducing non-sensical word-bit prefixes from unrelated paths.
			if [ -e "$PREFIX" ]
			then
				MESSAGE=":$(echo $PREFIX | sed -e 's/\.txt//g' | tr '/' ':'),"
			else
				echo "Unusable PREFIX 1: $PREFIX"
			fi

			# If filtering out the Journal entries leaves us with nothing, then maybe we can try again and still get
			# more detailed journal path than the old way, which would just present us with "Journal" as a commit message.
			if [ -z "$MESSAGE" ]
			then
				PREFIX=$(git status --porcelain | cut -c4- | $LCP)
				# If the lcp is an actual file or directory, then we use it, otherwise ignore it.
				# This will let us have more descriptive commit messages when all the changes are
				# related, without introducing non-sensical word-bit prefixes from unrelated paths.
				if [ -e "$PREFIX" ]
				then
					MESSAGE=":$(echo $PREFIX | sed -e 's/\.txt$//g' | tr '/' ':')"
				else
					echo "Unusable PREFIX 2: $PREFIX"
				fi
			fi


			# Since the below-action will trim the last character of the string, we must add a character... unless we already have an extra one.
			if [ -n "$MESSAGE" ] && [[ "$MESSAGE" != *: ]]
			then
				MESSAGE="$MESSAGE,"
			fi
		fi

		if [ -z "$MESSAGE" ]
		then
		# NB: when active, Zim will routinely run 'git add -u' and 'git add -a' !
		#MESSAGE=$(git status --porcelain | sed -e 's/\.txt//g' | tr / '\t' | cut -c4- | uniq -w3 | cut -f1 | tr -s '[:space:]' , )
		MESSAGE=$(git status --porcelain | tr '/. ' '\t' | cut -c4- | uniq -w3 | cut -f1 | tr -s '[:space:]' , )
		fi

		if [ -z "$MESSAGE" ]; then
			MESSAGE='zim pre-launch commitX'
		fi

		# 'Journal' (by itself) is a bit uninteresting... unless it is the only thing changed!
		if [ "$MESSAGE" != "Journal," ]
		then
			# Limit the message length to 512 characters
			MESSAGE=$(echo "$MESSAGE" | cut -c-512 | sed -E 's/,Journal|Journal,//g')
		fi

		git commit -m"${MESSAGE%?}"

fi

git merge -m "$MSG" $BRANCHES || ( git add -A . && git commit -m "$MSG" )

done

# Here, we are waiting on the 'rm -rf' command, at the very top of the script.
wait

