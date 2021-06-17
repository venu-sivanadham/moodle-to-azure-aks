#!/bin/bash
#
# Bitnami Moodle library

# shellcheck disable=SC1091

# Load generic libraries
. /opt/bitnami/scripts/libphp.sh
. /opt/bitnami/scripts/libfs.sh
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libvalidations.sh
. /opt/bitnami/scripts/libpersistence.sh
. /opt/bitnami/scripts/libwebserver.sh

# Load database library
if [[ -f /opt/bitnami/scripts/libmysqlclient.sh ]]; then
    . /opt/bitnami/scripts/libmysqlclient.sh
elif [[ -f /opt/bitnami/scripts/libmysql.sh ]]; then
    . /opt/bitnami/scripts/libmysql.sh
elif [[ -f /opt/bitnami/scripts/libmariadb.sh ]]; then
    . /opt/bitnami/scripts/libmariadb.sh
fi

########################
# Validate settings in MOODLE_* env vars
# Globals:
#   MOODLE_*
# Arguments:
#   None
# Returns:
#   0 if the validation succeeded, 1 otherwise
#########################
moodle_validate() {
    debug "Validating settings in MOODLE_* environment variables..."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }
    check_multi_value() {
        if [[ " ${2} " != *" ${!1} "* ]]; then
            print_validation_error "The allowed values for ${1} are: ${2}"
        fi
    }

    # Validate credentials
    if is_boolean_yes "$ALLOW_EMPTY_PASSWORD"; then
        warn "You set the environment variable ALLOW_EMPTY_PASSWORD=${ALLOW_EMPTY_PASSWORD}. For safety reasons, do not use this flag in a production environment."
    else
        for empty_env_var in "MOODLE_DATABASE_PASSWORD" "MOODLE_PASSWORD"; do
            is_empty_value "${!empty_env_var}" && print_validation_error "The ${empty_env_var} environment variable is empty or not set. Set the environment variable ALLOW_EMPTY_PASSWORD=yes to allow a blank password. This is only recommended for development environments."
        done
    fi

    # Validate SMTP credentials
    if ! is_empty_value "$MOODLE_SMTP_HOST"; then
        for empty_env_var in "MOODLE_SMTP_USER" "MOODLE_SMTP_PASSWORD"; do
            is_empty_value "${!empty_env_var}" && warn "The ${empty_env_var} environment variable is empty or not set."
        done
        is_empty_value "$MOODLE_SMTP_PORT_NUMBER" && print_validation_error "The MOODLE_SMTP_PORT_NUMBER environment variable is empty or not set."
    fi

    # Compatibility with older images where 'moodledata' was located inside the 'htdocs' directory
    if is_mounted_dir_empty "$MOODLE_DATA_DIR" && [[ -d "${MOODLE_VOLUME_DIR}/moodledata" ]]; then
        warn "Found 'moodledata' directory inside ${MOODLE_VOLUME_DIR}. Support for this configuration is deprecated and will be removed soon. Please create a new volume mountpoint at ${MOODLE_DATA_DIR}, and copy all its files there."
    fi

    # Support for MySQL and MariaDB
    check_multi_value "MOODLE_DATABASE_TYPE" "mysqli mariadb"

    # Check that the web server is properly set up
    web_server_validate || print_validation_error "Web server validation failed"

    return "$error_code"
}

########################
# Bypass Azure for ManagedDB database version check
# We detected some issues in the way that Azure Database for MariaDB
# shows the version. This hack will bypass the Moodle installation check
# Globals:
#   MOODLE_*
# Arguments:
#   None
# Returns:
#   None
#########################
moodle_fix_manageddb_check() {
    info "Changing minimum required MariaDB version to $MOODLE_DATABASE_MIN_VERSION"
    replace_in_file "$MOODLE_VOLUME_DIR/admin/environment.xml" "name=\"mariadb\" version=\"[^\"]+\"" "name=\"mariadb\" version=\"$MOODLE_DATABASE_MIN_VERSION\""
    replace_in_file "$MOODLE_VOLUME_DIR/admin/environment.xml" "name=\"mysql\" version=\"[^\"]+\"" "name=\"mysql\" version=\"$MOODLE_DATABASE_MIN_VERSION\""
}

########################
# Ensure Moodle is initialized
# Globals:
#   MOODLE_*
# Arguments:
#   None
# Returns:
#   None
#########################
moodle_initialize() {
    # Check if Moodle has already been initialized and persisted in a previous run
    local db_type db_host db_port db_name db_user db_pass
    local -r app_name="moodle"
    info "Restoring persisted Moodle installation"
    info "Trying to connect to the database server"
    db_type="$(moodle_conf_get "\$CFG->dbtype")"
    db_host="$(moodle_conf_get "\$CFG->dbhost")"
    db_port="$(moodle_conf_get "'dbport'")"
    db_name="$(moodle_conf_get "\$CFG->dbname")"
    db_user="$(moodle_conf_get "\$CFG->dbuser")"
    db_pass="$(moodle_conf_get "\$CFG->dbpass")"
    [[ "$db_type" = "mariadb" || "$db_type" = "mysqli" ]] && moodle_wait_for_mysql_db_connection "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"

    # Perform Moodle database schema upgrade
    info "Running database upgrade"
    moodle_upgrade

    # Skip the following check for legacy installs where moodledata is in /bitnami/moodle/moodledata and not /bitnami/moodledata (#142)
    if ! is_dir_empty "${MOODLE_DATA_DIR}/sessions"; then
        # This fixes an issue when restoring Moodle, due to cookies/sessions from a previous run being considered closed.
        # Therefore, users are unable to connect to Moodle with their cookies since the server considers them invalid.
        # The problem disappears when removing the old (invalid) session files.
        find "${MOODLE_DATA_DIR}/sessions/" -name "sess_*" -delete
    fi

    # Ensure Moodle cron jobs are created when running setup with a root user
    local -a cron_cmd=("${PHP_BIN_DIR}/php" "${MOODLE_VOLUME_DIR}/admin/cli/cron.php")
    if am_i_root; then
        generate_cron_conf "moodle" "${cron_cmd[*]} > /dev/null 2>> ${MOODLE_DATA_DIR}/moodle-cron.log" --run-as "$WEB_SERVER_DAEMON_USER" --schedule "*/${MOODLE_CRON_MINUTES} * * * *"
    else
        warn "Skipping cron configuration for Moodle because of running as a non-root user"
    fi

    # Avoid exit code of previous commands to affect the result of this function
    true
}

########################
# Get an entry from the Moodle configuration file (config.php)
# Globals:
#   MOODLE_*
# Arguments:
#   $1 - PHP variable name
# Returns:
#   None
#########################
moodle_conf_get() {
    local -r key="${1:?key missing}"
    debug "Getting ${key} from Moodle configuration"
    # Sanitize key (sed does not support fixed string substitutions)
    local sanitized_pattern
    sanitized_pattern="^\s*(//\s*)?$(sed 's/[]\[^$.*/]/\\&/g' <<<"$key")\s*=>?([^;,]+)[;,]"
    grep -E "$sanitized_pattern" "$MOODLE_CONF_FILE" | sed -E "s|${sanitized_pattern}|\2|" | tr -d "\"' "
}

########################
# Wait until a MySQL or MariaDB database is accessible with the currently-known credentials
# Globals:
#   *
# Arguments:
#   $1 - database host
#   $2 - database port
#   $3 - database name
#   $4 - database username
#   $5 - database user password (optional)
# Returns:
#   true if the database connection succeeded, false otherwise
#########################
moodle_wait_for_mysql_db_connection() {
    local -r db_host="${1:?missing database host}"
    local -r db_port="${2:?missing database port}"
    local -r db_name="${3:?missing database name}"
    local -r db_user="${4:?missing database user}"
    local -r db_pass="${5:-}"
    check_mysql_connection() {
        echo "SELECT 1" | mysql_remote_execute "$db_host" "$db_port" "$db_name" "$db_user" "$db_pass"
    }
    if ! retry_while "check_mysql_connection"; then
        error "Could not connect to the database"
        return 1
    fi
}

########################
# Run Moodle install script
# Globals:
#   *
# Arguments:
#   None
# Returns:
#   true if the script succeeded, false otherwise
#########################
moodle_install() {
    local -r http_port="${WEB_SERVER_HTTP_PORT_NUMBER:-"$WEB_SERVER_DEFAULT_HTTP_PORT_NUMBER"}"
    local -a moodle_install_args=(
        "${PHP_BIN_DIR}/php"
        "admin/cli/install.php"
        "--lang=en"
        "--chmod=2775"
        "--wwwroot=http://localhost:${http_port}"
        "--dataroot=${MOODLE_DATA_DIR}"
        "--adminuser=${MOODLE_USERNAME}"
        "--adminpass=${MOODLE_PASSWORD}"
        "--adminemail=${MOODLE_EMAIL}"
        "--fullname=${MOODLE_SITE_NAME}"
        "--shortname=${MOODLE_SITE_NAME}"
        "--non-interactive"
        "--allow-unstable"
        "--agree-license"
        "$@"
    )
    # HACK: Change database version check for Azure Database for MariaDB
    ! is_empty_value "$MOODLE_DATABASE_MIN_VERSION" && moodle_fix_manageddb_check
    pushd "$MOODLE_VOLUME_DIR" >/dev/null || exit
    # Run as web server user to avoid having to change permissions/ownership afterwards
    if am_i_root; then
        debug_execute gosu "$WEB_SERVER_DAEMON_USER" "${moodle_install_args[@]}"
        # Remove write permissions for the web server to the config.php file
        configure_permissions_ownership "$MOODLE_CONF_FILE" -f "644" -u "root" -g "$WEB_SERVER_DAEMON_GROUP"
    else
        debug_execute "${moodle_install_args[@]}"
    fi
    popd >/dev/null || exit
}

########################
# Run Moodle database schema upgrade script
# Globals:
#   *
# Arguments:
#   None
# Returns:
#   true if the script succeeded, false otherwise
#########################
moodle_upgrade() {
    pushd "$MOODLE_VOLUME_DIR" >/dev/null || exit
    local -a moodle_upgrade_args=(
        "${PHP_BIN_DIR}/php"
        "admin/cli/upgrade.php"
        "--non-interactive"
        "--allow-unstable"
    )
    am_i_root && moodle_upgrade_args=("gosu" "$WEB_SERVER_DAEMON_USER" "${moodle_upgrade_args[@]}")
    debug_execute "${moodle_upgrade_args[@]}"
    popd >/dev/null || exit
}

########################
# Configure Moodle www root
# Globals:
#   *
# Arguments:
#   None
# Returns:
#   None
#########################
moodle_configure_wwwroot() {
    local -r http_port="${WEB_SERVER_HTTP_PORT_NUMBER:-"$WEB_SERVER_DEFAULT_HTTP_PORT_NUMBER"}"
    # sed replacement notes:
    # - The ampersand ('&') is escaped due to sed replacing any non-escaped ampersand characters with the matched string
    # - For the replacement text to be multi-line, an \ needs to be specified to escape the newline character
    local -r conf_to_replace="if (empty(\$_SERVER['HTTP_HOST'])) {\\
  \$_SERVER['HTTP_HOST'] = '127.0.0.1:${http_port}';\\
}\\
if (isset(\$_SERVER['HTTPS']) \&\& \$_SERVER['HTTPS'] == 'on') {\\
  \$CFG->wwwroot   = 'https://' . \$_SERVER['HTTP_HOST'];\\
} else {\\
  \$CFG->wwwroot   = 'http://' . \$_SERVER['HTTP_HOST'];\\
}"
    replace_in_file "$MOODLE_CONF_FILE" "\\\$CFG->wwwroot\s*=.*" "$conf_to_replace"
}
