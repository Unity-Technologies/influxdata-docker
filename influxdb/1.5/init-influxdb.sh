#!/bin/bash
set -e

# This init script takes the environment variables from the Docker run command
# and creates a single admin user, multiple Read,Write,All users and multiple databases.
# ENV_VARS:
# 	INFLUXDB_HTTP_AUTH_ENABLED
# 	INFLUXDB_ADMIN_USER
# 	INFLUXDB_ADMIN_PASSWORD
# 	INFLUXDB_DB
# 	INFLUXDB_USER
#	INFLUXDB_USER_PASSWORD
#	INFLUXDB_WRITE_USER
#	INFLUXDB_WRITE_PASSWORD
#	INFLUXDB_READ_USER
#	INFLUXDB_READ_PASSWORD
# 
# E.g. `docker run -e INFLUXDB_DB=db0,db1 -e INFLUXDB_ADMIN_ENABLED=true \
#  -e INFLUXDB_ADMIN_USER=admin -e INFLUXDB_ADMIN_PASSWORD=supersecretpassword \
#  -e INFLUXDB_USER=telegraf,pop -e INFLUXDB_USER_PASSWORD=secretpassword,bang \ 
#  influxdb`

# General Functions
function create_user(){
	# Create a new user that has no permissions to any database
	USER=$1
	PASSWORD=$2

	if [ ! -z "$USER" ]; then
		if [ -z "$PASSWORD" ]; then
			PASSWORD="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32;echo;)"
			echo "INFLUXDB_USER_PASSWORD:$INFLUXDB_USER_PASSWORD"
		fi

		$INFLUX_CMD "CREATE USER \"$USER\" WITH PASSWORD '$PASSWORD'"
		$INFLUX_CMD "REVOKE ALL PRIVILEGES FROM \"$USER\""
	fi
}

function grant_permission(){
	# Grant permissions ALL, WRITE, READ on a database for a user
	DB=$1
	USER=$2
	PERMISSION=$3

	if [ ! -z "$INFLUXDB_DB" ]; then
		$INFLUX_CMD "GRANT $PERMISSION ON \"$DB\" TO \"$USER\""
	fi
}

# Start of Script

# Work out if HTTP Auth is enabled and set it in the config file
AUTH_ENABLED="$INFLUXDB_HTTP_AUTH_ENABLED"
if [ -z "$AUTH_ENABLED" ]; then
	AUTH_ENABLED="$(grep -iE '^\s*auth-enabled\s*=\s*true' /etc/influxdb/influxdb.conf | grep -io 'true' | cat)"
else
	AUTH_ENABLED="$(echo "$INFLUXDB_HTTP_AUTH_ENABLED" | grep -io 'true' | cat)"
fi

INIT_USERS=$([ ! -z "$AUTH_ENABLED" ] && [ ! -z "$INFLUXDB_ADMIN_USER" ] && echo 1 || echo)
if ( [ ! -z "$INIT_USERS" ] || [ ! -z "$INFLUXDB_DB" ] || [ "$(ls -A /docker-entrypoint-initdb.d 2> /dev/null)" ] ) && [ ! "$(ls -d /var/lib/influxdb/meta 2>/dev/null)" ]; then
	echo $INIT_USERS
	if [ -z "$INIT_USERS" ]; then
		if [ -z "$INFLUXDB_ADMIN_PASSWORD" ]; then
			INFLUXDB_ADMIN_PASSWORD="$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c32;echo;)"
			echo "INFLUXDB_ADMIN_PASSWORD:$INFLUXDB_ADMIN_PASSWORD"
		fi
		INIT_QUERY="CREATE USER \"$INFLUXDB_ADMIN_USER\" WITH PASSWORD '$INFLUXDB_ADMIN_PASSWORD' WITH ALL PRIVILEGES"
		echo "I AM USING THE ADMIN PATH"
	else
		INIT_QUERY="SHOW DATABASES"
		echo "I AM USING THE DATABASE PATH"
	fi

	# Start influxdb in the background
	INFLUXDB_INIT_PORT="8086"
	INFLUXDB_HTTP_BIND_ADDRESS=127.0.0.1:$INFLUXDB_INIT_PORT INFLUXDB_HTTP_HTTPS_ENABLED=false influxd "$@" &
	pid="$!"

	# Wait for influxdb to start and run the inital query
	INFLUX_CMD="influx -host 127.0.0.1 -port $INFLUXDB_INIT_PORT -execute "
	for i in {30..0}; do
		if $INFLUX_CMD "$INIT_QUERY" &> /dev/null; then
			break
		fi
		echo 'influxdb init process in progress...'
		sleep 1
	done

	# If it fails exit the script & container process
	if [ "$i" = 0 ]; then
		echo >&2 'influxdb init process failed.'
		exit 1
	fi

	# Create the databases from the csv string 
	if [ ! -z "$INFLUXDB_DB" ]; then
		database_array=(${INFLUXDB_DB//,/ })
		for i in "${!database_array[@]}"; do
			if [ ! -z "$i" ]; then
				$INFLUX_CMD "CREATE DATABASE ${database_array[$i]}"
			fi
		done
	fi

	# If we have users then loop and create them with db grants
	if ( [ ! -z "$INFLUXDB_USER" ] || [ ! -z "$INIT_USERS" ] ); then
		INFLUX_CMD="influx -host 127.0.0.1 -port $INFLUXDB_INIT_PORT -username ${INFLUXDB_ADMIN_USER} -password ${INFLUXDB_ADMIN_PASSWORD} -execute "
		user_array=(${INFLUXDB_USER//,/ })
		user_password_array=(${INFLUXDB_USER_PASSWORD//,/ })
		user_write_array=(${INFLUXDB_WRITE_USER//,/ })
		user_write_password_array=(${INFLUXDB_WRITE_PASSWORD//,/ })
		user_read_array=(${INFLUXDB_READ_USER//,/ })
		user_read_password_array=(${INFLUXDB_READ_PASSWORD//,/ })

		for i in "${!user_array[@]}"; do
			create_user "${user_array[$i]}" "${user_password_array[$i]}"
			if [ ! -z "$INFLUXDB_DB" ]; then
				for a in "${!database_array[@]}"; do
					grant_permission "${database_array[$a]}" "${user_array[$i]}" "ALL"
				done
			fi
		done
		
		for i in "${!user_read_array[@]}"; do
			create_user "${user_read_array[$i]}" "${user_read_password_array[$i]}"
			if [ ! -z "$INFLUXDB_DB" ]; then
				for a in "${!database_array[@]}"; do
					grant_permission "${database_array[$a]}" "${user_read_array[$i]}" "READ"
				done
			fi
		done

		for i in "${!user_write_array[@]}"; do
			create_user "${user_write_array[$i]}" "${user_write_password_array[$i]}"
			if [ ! -z "$INFLUXDB_DB" ]; then
				for a in "${!database_array[@]}"; do
					grant_permission "${database_array[$a]}" "${user_write_array[$i]}" "WRITE"
				done
			fi
		done
	fi

	# Run other scripts if founds
	for f in /docker-entrypoint-initdb.d/*; do
		case "$f" in
			*.sh)     echo "$0: running $f"; . "$f" ;;
			*.iql)    echo "$0: running $f"; $INFLUX_CMD "$(cat ""$f"")"; echo ;;
			*)        echo "$0: ignoring $f" ;;
		esac
		echo
	done

	# Stop the influx that is running in the background
	if ! kill -s TERM "$pid" || ! wait "$pid"; then
		echo >&2 'influxdb init process failed. (Could not stop influxdb)'
		exit 1
	fi

fi
