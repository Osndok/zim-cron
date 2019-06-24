#!/bin/bash
#
# zim-commit-loop.sh
#

cd $(dirname $(realpath $0))

while true
do
	sleep 3600
	./zim-commit.sh
done

