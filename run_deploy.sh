#!/bin/bash
set -o errexit
set -o errtrace
set -o functrace
#set -o nounset
set -o pipefail
[ -n "${DEBUG:=}" ] && set -x # xtrace

Here=$PWD
ScriptPath=$( dirname "$0" )
cd "${ScriptPath}"
ScriptPath=$PWD
cd "${Here}"

# -------------------------------------------------------------------------------------------------
# setup auxiliary routines

CommonsPath=${ScriptPath}/.common
. "${CommonsPath}/common.sh"

LogFolder="${ScriptPath}"
LogFileStub=run_deploy
#ErrorNotificationMailRecipients=
. "${CommonsPath}/error_handling.sh"

DoLog  ---------------------------------------------------------------------------------------------------

# ------------------------------------------------------------------------------------------------

InfoMessage "Configuring the deployer script"

InfoMessage "    running as "$( id -a )
InfoMessage "    current path = \"${Here}\""
InfoMessage "    script path = \"${ScriptPath}\""
InfoMessage "    path to commons = \"${CommonsPath}\""
InfoMessage "    filename token = \"${RndToken}\""

Action=${2:-all}
Env=${1:-as-set}

InfoMessage "    action = \"${Action}\""
InfoMessage "    client-defined environment = \"${Env}\""

# ------------------------------------------------------------------------------------------------

set -o nounset

if [ "x${Env}" != "xas-set" ] ; then
	InfoMessage "Seeking for deployment sources root"
	EnvPath=
	DeploySrcRoot=

	cd "${Here}"
	InfoMessage "    Starting from \"${Here}\""
	while true ; do
		thisLevel=$(pwd)
		if [ -d .env ] ; then
			DeploySrcRoot="${thisLevel}"
			EnvPath="${thisLevel}/.env"
			break
		else if [ "${thisLevel}" = / ] ; then
			break
		else
			InfoMessage "    Now getting one level higher"
			cd ..
		fi ; fi
	done

	if [ "x${EnvPath}" = "x" ] ; then
		InfoMessage "    Not found; Restarting from \"${ScriptPath}\""

		cd "${ScriptPath}"
		while true ; do
			thisLevel=$(pwd)
			if [ -d .env ] ; then
				DeploySrcRoot="${thisLevel}"
				EnvPath="${thisLevel}/.env"
				break
			else if [ "${thisLevel}" = / ] ; then
				break
			else
				InfoMessage "    Now getting one level higher"
				cd ..
			fi ; fi
		done
	fi

	if [ "x${EnvPath}" = "x" ] ; then
		ThrowException "No \".env\" folder found anywhere above \"${ScriptPath}\""
	fi

	DeployTargetConfigFile="${EnvPath}/targets.${Env}.cfg"

	. "${EnvPath}/targets.${Env}.cfg" || ThrowException "Cannot use the ${EnvPath}/targets.${Env}.cfg config file"
else
	DeploySrcRoot="${ScriptPath}"
	EnvPath=
	DeployTargetConfigFile="${ScriptPath}/settings.cfg"
	. "${ScriptPath}/settings.cfg" || ThrowException "No ${ScriptPath}/settings.cfg config file present"
fi

InfoMessage "    determined deployment sources root = \"${DeploySrcRoot}\""
InfoMessage "    environment config file in use = \"${DeployTargetConfigFile}\""

. "${DeployTargetConfigFile}" || ThrowException "No \"${DeployTargetConfigFile}\" config file present"

InfoMessage "    note: switching log output from \"${LogFolder}\" to \"${DeploySrcRoot}\""
formerLogFolder="${LogFolder}"
LogFolder="${DeploySrcRoot}"
. "${CommonsPath}/error_handling.sh"
InfoMessage "    note: log output folder switched from \"${formerLogFolder}\" to \"${LogFolder}\""

GlobalPluginsPath="${ScriptPath}/.plugin"
# 2do! determine the local plugins folders; can be in two places - at ScriptPath, at Here

# ------------------------------------------------------------------------------------------------

InfoMessage "Further configuring the deployer"

if [ -z "${ORACLE_HOME:-}" -a -z "${cfg_oracle_home:-}" ] ; then
	ThrowException 'Neither the ORACLE_HOME env. var. nor the "cfg_oracle_home" config var. is set'
fi

cfg_deploy_repo_tech=tech.${dpltgt_deploy_repo_tech:-oracle}
cfg_deploy_repo_db=${dpltgt_deploy_repo_user}/${dpltgt_deploy_repo_password}@${dpltgt_deploy_repo_db} || ThrowException "Deployment repository DB-config vars not set"
InfoMessage "    deployment repository = \"${dpltgt_deploy_repo_user}/******@${dpltgt_deploy_repo_db}\""

LogPath=$( FolderAbsolutePath "${LogPath:-${DeploySrcRoot}}" )
TmpPath=$( FolderAbsolutePath "${TmpPath:-${DeploySrcRoot}}" )

InfoMessage "    temporary files path = \"${TmpPath}\""
InfoMessage "    log files path = \"${LogPath}\""
InfoMessage "    environment id = \"${cfg_environment}\""

cd "${TmpPath}"

# ------------------------------------------------------------------------------------------------

InfoMessage "Prechecks"

touch "${TmpPath}/touch.${RndToken}.tmp" || ThrowException "Temporary files folder not writable"
rm "${TmpPath}/touch.${RndToken}.tmp"

# ------------------------------------------------------------------------------------------------

InfoMessage "Cleaning up the temporary folder"

cd "${TmpPath}"
rm ${Env}.*.tmp 2> /dev/null || InfoMessage '    Note: No TMP files to clean up'
rm ${Env}.*.sql 2> /dev/null || InfoMessage '    Note: No SQL files to clean up'
rm ${Env}.*.stderr.out 2> /dev/null || InfoMessage '    Note: No STDERR.OUT files to clean up'
rm ${Env}.*.tbz2 2> /dev/null || InfoMessage '    Note: No TBZ2 files to clean up'
[ -n "${DEBUG}" ] && rm ${Env}.*.log 2> /dev/null || InfoMessage '    Note: No LOG files to clean up'

# ------------------------------------------------------------------------------------------------

InfoMessage "Shell/OS-specific setup"

. "${CommonsPath}/os_specific_utils.sh"

InfoMessage "    You are on \"${OStype}\""

TmpPath=$( PathWinToUnix "${TmpPath}" )
ScriptPath=$( PathWinToUnix "${ScriptPath}" )
Here=$( PathWinToUnix "${Here}" )

InfoMessage "    OK: Path conversion routines set up"

export ORACLE_HOME="${ORACLE_HOME:-${cfg_oracle_home}}"
. "${CommonsPath}/oracle_home_utils.sh"

InfoMessage "    Oracle home in use = ${ORACLE_HOME}"

# ================================================================================================

if [ "${Action}" != "help" ] ; then
	InfoMessage "Generating the SQL*Plus defines script"

	dbDefinesScriptFile="${TmpPath}/${Env}.deployment_db_defines.${RndToken}.sql"

	set \
		| ${local_grep} -Ei '^dpltgt_' \
		| ${local_sed} 's/^dpltgt_\(.*\)\s*=\s*\(.*\)\s*$/define \1 = \2/g' \
		| ${local_sed} "s/= '\(.*\)'$/= \1/g" \
		>> "${dbDefinesScriptFile}"

	InfoMessage "    defines file = \"${dbDefinesScriptFile}\""
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" != "help" ] ; then
	InfoMessage "Executing pre-deployment plugins"

	"${local_find}" "${GlobalPluginsPath}" -name 'pre-*.sh' | "${local_sort}" -t - -k 2 -n | while read -r preScriptfile ; do
		InfoMessage "    ${preScriptfile}"
		( . "${preScriptfile}" )
	done
	# 2do! execute the local plugins
fi

# ------------------------------------------------------------------------------------------------

InfoMessage "Preparing the deployment"

if [ "${Action}" = "delta" -o "${Action}" = "all" -o "${Action}" = "sync" -o "${Action}" = "delta-prep" ] ; then
	InfoMessage "    Fetching the complete list of increment script files"
	cd "${DeploySrcRoot}"

	if [ ${OStype} = "cygwin" ] ; then
		${local_find} . -mindepth 2 -not -path './.*/*' -not -name '*.~???' -not -name '*.???~' -type f | ${local_sed} 's/^\.\///g' > "${TmpPath}/${Env}.script_full_paths.${RndToken}.tmp"
	else if [ ${OStype} = "SunOS" ] ; then
		${local_find} . ! -name '*.???~' ! -name '*.~???' -type f | ${local_grep} -Evi '^\.\/\..*\/' 2> /dev/null | ${local_gawk} -v depf=2 -v FS='/' 'NF>=(1+depf)' > "${TmpPath}/${Env}.script_full_paths.${RndToken}.tmp"
	else
		ThrowException "ERROR: Unknown OS type!"
	fi ; fi
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" = "delta" -o "${Action}" = "all" -o "${Action}" = "sync" -o "${Action}" = "delta-prep" ] ; then
	InfoMessage "    Merging the list of found script files to (unfinished increments in) deployment repository"
	cd "${TmpPath}"

	cat > "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql" <<-EOF
		whenever sqlerror exit 1 rollback
		whenever oserror exit 2 rollback

		set trimspool on
		set trimout on
		set linesize 32767
		set termout off
		set echo off
		set feedback on
		spool "${Env}.merge_increments_to_repo.${RndToken}.log"

		col "It's ..." format a40
		select user||'@'||global_name as "It's ..." from global_name;

		prompt --- loading the list of script files to DB

		set feedback off

		select count(1) as temp_records_before from tt_db_full_inc_script_path;

	EOF

	cat "${TmpPath}/${Env}.script_full_paths.${RndToken}.tmp" \
		| ${local_gawk} -f "${CommonsPath}/full_script_list_to_sql_inserts.awk" \
		>> "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql"

	cat >> "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql" <<-EOF

		select count(1) as temp_records_after from tt_db_full_inc_script_path;

		set feedback on

	EOF

	echo '@@"'$( PathUnixToWin "${CommonsPath}/merge_increments_to_repo.sql" )'"' >> "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql"

	cat >> "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql" <<-EOF
		prompt --- DONE synchronizing repository

		commit;

		spool off
		exit success
	EOF

	l_sqlplus_script_file=$( PathUnixToWin "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql" )
	"${SqlPlusBinary}" -L -S ${cfg_deploy_repo_db} @"${l_sqlplus_script_file}" \
		|| ThrowException "SQL*Plus failed"

	[ -z "${DEBUG}" ] && (
		rm "${TmpPath}/${Env}.script_full_paths.${RndToken}.tmp"
		rm "${TmpPath}/${Env}.merge_increments_to_repo.${RndToken}.sql"
	)
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" = "delta" -o "${Action}" = "all" -o "${Action}" = "sync" -o "${Action}" = "delta-prep" ] ; then
	InfoMessage "    Setting up a deployment run"
	cd "${DeploySrcRoot}"

	cat > "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql" <<-EOF
		whenever sqlerror exit 1 rollback
		whenever oserror exit 2 rollback

		set trimspool on
		set trimout on
		set linesize 32767
		set termout off
		set echo off
		set feedback on

	EOF

	echo 'spool "'$( PathUnixToWin "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.log" )'"' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	echo '' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"

	echo 'prompt --- loading deployment targets to tmp' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	declare | ${local_grep} -E '^(dpltgt|dbgrp)_.*=' | ${local_sed} "s/^.*$/insert into tt_db_deploy_tgt (txt_config_var_assignment) values (q'{&}');/gi" >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	echo '' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"

	echo 'prompt --- calling set_up_deployment_run.sql' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	if [ "${Action}" = "sync" ] ; then
		echo '@@"'$( PathUnixToWin "${CommonsPath}/prepare_or_sync_deployment_run.sql" )'" sync-only' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	else
		echo '@@"'$( PathUnixToWin "${CommonsPath}/prepare_or_sync_deployment_run.sql" )'" normal' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	fi
	echo '' >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"

	cat >> "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql" <<-EOF
		prompt --- DONE setting up a deployment run

		commit;

		spool off
		exit success
	EOF

	l_sqlplus_script_file=$( PathUnixToWin "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql" )
	"${SqlPlusBinary}" -L -S ${cfg_deploy_repo_db} @"${l_sqlplus_script_file}" \
		|| ThrowException "SQL*Plus failed"

	[ -z "${DEBUG}" ] && (
		rm "${TmpPath}/${Env}.set_up_deployment_run.${RndToken}.sql"
	)
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" = "delta" -o "${Action}" = "all" -o "${Action}" = "delta-prep" ] ; then
	InfoMessage "    Fetching the ultimate list of scripts to run from repository"
	cd "${DeploySrcRoot}"

	cat > "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.sql" <<-EOF
		whenever sqlerror exit 1 rollback
		whenever oserror exit 2 rollback

		set autoprint off
		set autotrace off
		set echo off
		set define off
		set feedback off
		set heading off
		set headsep off
		set linesize 2048
		set newpage none
		set recsep off
		set tab on
		set termout off
		set trimout on
		set trimspool on
		set verify off
		set wrap off
		set sqlterminator ';'

		set exitcommit off

	EOF

	echo 'spool "'$( PathUnixToWin "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.tmp" )'"' >> "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.sql"
	echo '@@"'$( PathUnixToWin "${CommonsPath}/retrieve_the_deployment_setup.sql" )'"' >> "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.sql"

	cat >> "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.sql" <<-EOF

		spool off
		exit success
	EOF

	l_sqlplus_script_file=$( PathUnixToWin "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.sql" )
	"${SqlPlusBinary}" -L -S ${cfg_deploy_repo_db} @"${l_sqlplus_script_file}" \
		|| ThrowException "SQL*Plus failed"
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" = "delta" -o "${Action}" = "all" ] ; then
	InfoMessage "Running the deployment"
	cd "${DeploySrcRoot}"

	IFS='|'
	cat "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.tmp" \
		| while read -r l_id_script_execution l_num_order l_id_script l_id_increment l_schema_id l_script_folder l_script_file l_sqlplus_defines_flag || break
	do
		InfoMessage "    script \"${l_script_folder}/${l_script_file}\" (ID \"${l_id_script}\", exec \"${l_id_script_execution}\") in schema \"${l_schema_id}\""

		if ( echo ",${cfg_target_no_run:-}," | ${local_grep} -q ",${l_schema_id}," ) ; then
			fakeExec=yes
		else if [ "${Action}" = "sync" ] ; then
			fakeExec=yes
		else
			fakeExec=no
		fi ; fi

		# ----------------------------------------------------------------------------------------------

		if [ "${fakeExec}" = "no" ] ; then
			l_script_tech_var=dpltgt_${l_schema_id}_tech
			l_db_user_var=dpltgt_${l_schema_id}_user
			l_db_password_var=dpltgt_${l_schema_id}_password
			l_db_db_var=dpltgt_${l_schema_id}_db

			l_script_tech=tech.${!l_db_tech_var:-oracle}
			l_db_user=${!l_db_user_var}
			l_db_password=${!l_db_password_var}
			l_db_db=${!l_db_db_var}

			# ----------------------------------------------------------------------------------------------

			InfoMessage "        pre-phase"

			. "${CommonsPath}/${cfg_deploy_repo_tech}/repo_update.sh" \
				pre-phase-run \
				"${RndToken}" "${l_id_script}" "${l_id_script_execution}" \
				"${cfg_deploy_repo_db}"

			# ----------------------------------------------------------------------------------------------

			InfoMessage "        execution"

			. "${CommonsPath}/${l_script_tech}/script_exec.sh" \
				run \
				"${RndToken}" "${l_id_script}" "${l_id_script_execution}" \
				"${l_db_user}/${l_db_password}@${l_db_db}" \
				"${l_script_folder}" "${l_script_file}" "${dbDefinesScriptFile}" "${l_sqlplus_defines_flag}"

			scriptReturnCode=$?

			# ----------------------------------------------------------------------------------------------

			if [ "${scriptReturnCode}" -eq 0 ] ; then
				InfoMessage "        completion check"
				. "${CommonsPath}/${l_script_tech}/script_exec.sh" \
					post-run-check \
					"${RndToken}" "${l_id_script}" "${l_id_script_execution}"
			fi

			# ----------------------------------------------------------------------------------------------

			InfoMessage "        post-phase"

			. "${CommonsPath}/${cfg_deploy_repo_tech}/repo_update.sh" \
				post-phase-run \
				"${RndToken}" "${l_id_script}" "${l_id_script_execution}" \
				"${cfg_deploy_repo_db}" \
				"${scriptReturnCode}"

			# ----------------------------------------------------------------------------------------------

			if [ ${scriptReturnCode} -gt 0 ] ; then
				ThrowException "The most recent increment script exited with status of ${scriptReturnCode}"
			fi

			[ -z "${DEBUG}" ] && (
				. "${CommonsPath}/${l_script_tech}/script_exec.sh" cleanup "${RndToken}" "${l_id_script}" "${l_id_script_execution}"
				. "${CommonsPath}/${cfg_deploy_repo_tech}/repo_update.sh" cleanup "${RndToken}" "${l_id_script}" "${l_id_script_execution}"
			)

		# ----------------------------------------------------------------------------------------------
		else
			InfoMessage "        fake execution for deployment repository synchronization"

			. "${CommonsPath}/${cfg_deploy_repo_tech}/repo_update.sh" fake-exec "${RndToken}" "${l_id_script}" "${l_id_script_execution}"
			scriptReturnCode=$?

			[ -z "${DEBUG}" ] && (
				. "${CommonsPath}/${cfg_deploy_repo_tech}/repo_update.sh" fake-exec-cleanup "${RndToken}" "${l_id_script}" "${l_id_script_execution}"
			)
		fi
	done

	scriptReturnCode=$?
	[ ${scriptReturnCode} -gt 0 ] && exit ${scriptReturnCode}

	unset IFS
	[ -z "${DEBUG}" ] && rm "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.sql"
	[ -z "${DEBUG}" ] && rm "${TmpPath}/${Env}.retrieve_the_deployment_setup.${RndToken}.tmp"
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" != "help" ] ; then
	InfoMessage "Executing post-deployment plugins"

	"${local_find}" "${GlobalPluginsPath}" -name 'post-*.sh' | "${local_sort}" -t - -k 2 -n | while read -r postScriptfile ; do
		InfoMessage "    ${postScriptfile}"
		( . "${postScriptfile}" )
	done
	# 2do! execute the local plugins
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" = "help" ] ; then
	DoLog "Help screen invoked!"

	cat <<-EOF
		-------------------------------------------------------------------------------------
		Each deployment increment consists of a "package" of "scripts".

		Each "package" is a leaf-level folder of name of "yyyymmdd-hh24mi;some_comment" where
		the ";some_comment" part is optional.

		    * The "yyyymmdd-hh24mi" part is parsed and stored in T_DB_INCREMENT.DAT_FOLDER
		      column and will be used for ordering of the "packages" during a deployment.
		    * The "some_comment" part is stored in T_DB_INCREMENT.TXT_COMMENT column.

		Each "script" is a leaf-level file of name "nnnnnnnn;target_id.extension" placed in
		the "package" folder.

		    * The "nnnnnnnn" part is an arbitrary positive integer with arbitrary number of
		      leading zeroes, is parsed and stored in the T_DB_SCRIPT.NUM_ORDER column and
		      will be used for ordering of the "scripts" within a package during a deployment.
		    * The "target_id" part is mandatory and contains the deployment target identifier
		      under which the script has to be executed. The target identifier refers to the
		      dpltgt_<target_id>_<something> and dbgrp_<target_id> variables defined on the
              level of a deployment tool.
		    * The "extension" part can be anything. Usually it is "sql" for any scripts,
		      "pck" for packages, "vw" for views, "trg" for triggers, and so on. You decide.
		-------------------------------------------------------------------------------------
		List of deployment targets available for environment "${Env}":
	EOF

	declare | ${local_grep} -E '^(dpltgt|dbgrp)_' \
		| ${local_gawk} '
			$0 ~ /^dpltgt_/ {
				match($0, /^dpltgt_(.*)_(db|user|password)\s*=/, xx);
				targetName = xx[1];
				if (targetName != "")
					targetList[targetName] = "atomic";
			}

			$0 ~ /^dbgrp_/ {
				match($0, /^dbgrp_(.*)\s*=/, xx);
				targetName = xx[1];
				if (targetName != "")
					targetList[targetName] = "composite";
			}

			END {
				asorti(targetList, tlistOrder);
				for (i in tlistOrder)
				{
					j = tlistOrder[i];
					print "    * " j (targetList[j] != "atomic" ? " (" targetList[j] ")" : "");
				}
			}
		'

	cat <<-EOF
		-------------------------------------------------------------------------------------
	EOF
fi

# ------------------------------------------------------------------------------------------------

if [ "${Action}" != "help" ] ; then
	InfoMessage "CleanUp"

	[ -z "${DEBUG}" ] && rm "${dbDefinesScriptFile}"
fi

# ------------------------------------------------------------------------------------------------

InfoMessage "DONE"

cd "${Here}"
