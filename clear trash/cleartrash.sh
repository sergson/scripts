#!/bin/bash
#
DAYS="+30"
BASEDIR="/work"
DIRS=("/acc_arch" "/acc_cur" "/ftp" "/int_docs" "/proj_curr" "/scaner")  
TRASHDIR="/.trash"
for DIR in ${DIRS[@]}; do
	DIRPATH="${BASEDIR}${DIR}${TRASHDIR}"
	if [ -d $DIRPATH ]; then
 		/usr/bin/find $DIRPATH -type f -mtime $DAYS -exec rm -rf {} \;
  		/usr/bin/find $DIRPATH -mindepth 1 -type d -empty -delete
	fi
done
