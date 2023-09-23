#!/bin/sh

format_table() {
	first_row=""
	table_lines=""
	while read line
	do	first_row="$first_row$line"
		if test "$line" = "</tr>"
		then	break
		fi
	done
	while read line
	do	if test "$line" = "</table>"
		then	break
		fi
		table_lines="$table_lines $line"
	done
	printf '%s' "$first_row" | sed \
		-e 's/<tr>/|/g' \
		-e 's/<\/tr>/|\n/g' \
		-e 's/<\/t[hd]> *<t[hd]>/|/g' \
		-e 's/<\/\?t[hd]>//g' \
		-e 's/^ *//g;s/ *$//g'
	printf '%s\n' "$first_row" | sed \
		-e 's/<tr>/|/g' \
		-e 's/<\/tr>/|\n/g' \
		-e 's/<\/t[hd]> *<t[hd]>/|/g' \
		-e 's/<\/\?t[hd]>//g' \
		-e 's/[^|]/-/g' \
		-e 's/^ *//g;s/ *$//g'
	printf '%s\n' "$table_lines" | sed \
		-e 's/<tr>/|/g' \
		-e 's/<\/tr>/|\n/g' \
		-e 's/<\/t[hd]> *<t[hd]>/|/g' \
		-e 's/<\/\?t[hd]>//g' \
		-e 's/^ *//g;s/ *$//g'
}

while read line
do	if test "$line" = "<table>"
	then	format_table
	else
		printf '%s\n' "$line"
	fi
done