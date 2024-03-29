#!/bin/bash
#
# zim-push.sh - pushes all git-backed notebook repos to all remote branches
#

NOTEBOOKS=$HOME/Notebooks

test -d $NOTEBOOKS || exit 1

if ! which online 2>/dev/null 1>&2
then
	function online()
	{
		echo "online script not found, so assuming network connection is up"
		return 0;
	}
fi

# Called if/when stuff really gets messed up, and you need to know about it.
# You will probably have to replace this with something else.
function panic()
{
	local MESSAGE="$1"
	once-daily pom-objective "$MESSAGE"
}

# TODO: move this below the function definitions.
for NOTEBOOK in $NOTEBOOKS/*
do

cd $NOTEBOOK

test -d .git || git init

LOCK=.git/autopush.pid

if [ -e "$LOCK" ]
then
	PID=$(cat $LOCK)
	if [ -e "/proc/$PID" ]
	then
		if grep zim "/proc/$PID/cmdline"
		then
			echo "ERROR: $LOCK indicates notebook is locked, as pid-$PID is still running"
			continue
		else
			echo "PID=$PID is not self?"
			cat "/proc/$PID/cmdline"
			ps auxw | grep "$PID"
		fi
	fi
fi

echo "$$" > $LOCK

echo "NOTEBOOK=$(basename $NOTEBOOK)"

# Through paranoia, I was hoping to avoid a case where the script blocks in the background waiting
# for a password (when there is no user). Although... I have never actually seen this happen.

# However, it seems to cause a general blockage, and obscure error message:
# git fetch "fatal: the remote end hung up unexpectedly"
#export GIT_SSH_COMMAND="ssh -n"

# ...this one might work, but I haven't tried it:
#export GIT_SSH_COMMAND="ssh -o 'PasswordAuthentication no'"

# Was there some other indication of this? Like... manual testing of scripts that are to be in a cron job?

function _detect_branches()
{
	CURRENT_BRANCH=$(basename $(git symbolic-ref HEAD))
	BRANCHES=$(git for-each-ref refs/heads/ refs/remotes/ --format='%(refname:short)' | grep -v $CURRENT_BRANCH) || echo "ERROR: no remotes?"
}
_detect_branches

# NB: duplicated in ~/bin/zim (for mutual exclusion)
function zim_is_running()
{
	ZIM_PROCESS=$(pgrep -f /usr/bin/zim)
	if [ -z "$ZIM_PROCESS" ]
	then
		ZIM_PROCESS=$(pgrep -f wiki/zim.py)
		test -n "$ZIM_PROCESS"
	fi
}

function kill_zim()
{
	echo "Killing zim..."
	pkill -f /usr/bin/zim
	pkill -f wiki/zim.py
	sleep 2
	if zim_is_running
	then
		echo "Still running, so using more force..."
		pkill -9 -f /usr/bin/zim
		pkill -9 -f wiki/zim.py
	fi
}

function branch_is_newer_or_divergent()
{
	THIS=$(git rev-parse $BRANCH)
	MINE=$(git rev-parse $CURRENT_BRANCH)

	# NB: the *common-case* is that they are equal... which means they are not "newer"!
	if [ "$THIS" = "$MINE" ]
	then
		echo "$BRANCH exactly matches $CURRENT_BRANCH"
		return 1
	elif git merge-base --is-ancestor $MINE $THIS
	then
		echo "$BRANCH is newer than $CURRENT_BRANCH"
		return 0
	elif git merge-base --is-ancestor $THIS $MINE
	then
		echo "$BRANCH is older than $CURRENT_BRANCH"
		return 1
	else
		echo "$BRANCH ($THIS) and $CURRENT_BRANCH ($MINE) have diverged"
		return 0
	fi
}

HOSTNAME=$(hostname | cut -f1 -d.)

function any_other_branch_is_newer_or_divergent()
{
	for BRANCH in $BRANCHES
	do
		if branch_is_newer_or_divergent
		then

			echo "$BRANCH is newer (or diverges from) $CURRENT_BRANCH"

			if [ "$BRANCH" == "$HOSTNAME" ]
			then
				echo "...but ignoring it, b/c that is 'my' branch that has changed."
			else
				return 0
			fi
		fi
	done

	return 1
}

function send_changes()
{
	git remote | while read UPSTREAM
	do
		git push --all "$UPSTREAM" || echo "Upstream push failed"
		git push -f "$UPSTREAM" "$HOSTNAME":"$HOSTNAME" || echo "Unable to push authoritative changes to $UPSTREAM"
	done
}

function send_local_changes()
{
	local HERE=$(git rev-parse "$HOSTNAME")
	local THERE;

	if [ "$HERE" == "$HOSTNAME" ]
	then
		echo 1>&2 "recovering from possibly-incorrect local branch checkout"
		git checkout -b "$HOSTNAME" || git switch "$HOSTNAME"
		HERE=$(git rev-parse "$HOSTNAME")
	fi

	git remote | while read UPSTREAM
	do
		THERE=$(git rev-parse "remotes/$UPSTREAM/$HOSTNAME")
		if [ "$HERE" != "$THERE" ]
		then
			git push -f $UPSTREAM $HOSTNAME:$HOSTNAME || echo "Unable to push authoritative local changes to $UPSTREAM"
		fi
	done
}

function maybe_send_changes()
{
	#todo: if we seem to be the leader, then push to main
	#then
	#	time send_changes
	#else
		# MAYBE... we created one or more commits, but the connection was not available (at the time)?
		send_local_changes
	#fi
}

function fetched_something_new()
{
	if ! online
	then
		echo "network is not online, so not fetching remotes"
		return 1
	fi

	git remote | while read UPSTREAM
	do
		git fetch "$UPSTREAM" || echo "Unable to fetch $UPSTREAM"
	done

	any_other_branch_is_newer_or_divergent
	return $?
}

function fast_forward_where_possible()
{
	for BRANCH in $BRANCHES
	do
		git merge --ff-only $BRANCH || echo "Can't fast-forward: $BRANCH"
	done

	git for-each-ref refs/remotes/ --format='%(refname:short)' | grep -v HEAD | while read REMOTE
	do
		git merge --ff-only $REMOTE || echo "Can't fast-forward: $REMOTE"
	done
}

function fast_forward_master_branch()
{
	local BRANCH=master
	local CURRENT_BRANCH="$HOSTNAME"
	local THIS=$(git rev-parse $BRANCH) || true
	local MINE=$(git rev-parse $CURRENT_BRANCH)

	if [ "$THIS" == "$BRANCH" ]
	then
		echo "$BRANCH does not exist"
		git update-ref refs/heads/$BRANCH "$MINE"
	elif git merge-base --is-ancestor $THIS $MINE
	then
		echo "$BRANCH is older than $CURRENT_BRANCH"
		git update-ref refs/heads/$BRANCH "$MINE" "$THIS"
	fi
}

# There are parallel branch names EVERYWHERE... so if ever we update our local branch, it can
# help to speed things along by sending an 'ack'... which just shifts the remote side's perception
# of where this side's branch tracking is... in practice, this is just another PUSH, but with no data.
function send_ack()
{
	maybe_send_changes
}

# ------------------------------------------------------------------------------

date -Iseconds

set -vx

if zim_is_running
then
	echo "zim is running"

	# If we are "running *THE* process", then we do *NOT* delay our execution.
	# That way, we will form a commit sooner, so that the other scripts can "pass it around"
	maybe_send_changes

	if any_other_branch_is_newer_or_divergent
	then
		echo "At least one incoming branch was updated, killing zim..."
		kill_zim
		fast_forward_where_possible
		send_ack
	elif fetched_something_new
	then
		echo "Noticed & pulling down remote changes, killing zim..."
		kill_zim
		fast_forward_where_possible
		fast_forward_master_branch
		send_ack
	else
		echo "Nothing broken to report or take action on; let zim be..."
		fast_forward_master_branch
		send_ack
	fi
else
	echo "zim is *NOT* running"

	# Assuming that this same script is running multiple places with an unknown
	# amount of bandwith/latency/change-load... it helps to have a bit of delay
	# between everyone forming/sending their commits, and deciding what just
	# happened. So this should give at least LAN and minor-changes time to
	# settle, so we don't have to wait an extra hour for harmony. However, if
	# we are being run directly (from the command line, not cron) then there is
	# really no reason for this sleep here... so we test for a tty.
	# TODO: we could also choose not to delay our execution if we find our local repo has changes
	# Why so high? It is critical to out-wait the originator, or else we will be up to two full period behind (two hours)
	tty || sleep 33
	maybe_send_changes

	if fetched_something_new
	then
		echo "Remote changes detected"
		fast_forward_where_possible
		send_ack
	fi
fi

done

echo "Script ends gracefully"
date


