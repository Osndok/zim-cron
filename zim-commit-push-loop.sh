#!/bin/bash
#
# zim-commit-push-loop.sh
#

cd $(dirname $(realpath $0))

while true
do
	sleep 3600
	./zim-commit.sh
	./zim-push.sh
done

