# Sourced by bin/ scripts after they cd to the repository root. Exports the
# variables defined in ./.env, if the file exists (see .env.example). The file
# is read with shell semantics, like `set -a; . ./.env`, but variables that
# are already set in the environment win, so a one-off override such as
# `AWS_PROFILE=other bin/check.sh` still works.

if [ -f .env ]; then
	while IFS='=' read -r _env_key _env_value; do
		case "$_env_key" in
			PWD | OLDPWD | SHLVL | _ | '') continue ;;
		esac
		if [ -z "${!_env_key+x}" ]; then
			export "$_env_key=$_env_value"
		fi
	done < <(env -i /bin/bash -c 'set -a; . ./.env; env')
	unset _env_key _env_value
fi
