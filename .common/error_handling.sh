#!/bin/bash

[ -n "${LogFolder}" ] || LogFolder="${DeploySrcRoot}" || LogFolder=$( dirname "$0" )/log
[ -d "${LogFolder}" ] || mkdir "${LogFolder}"

LogFileStub="${LogFileStub:-run_deploy}"

LogFile="${LogFolder}/${LogFileStub}."$( date +%Y%m%d )".log"


function DoLog()
{
	local LogTimeStamp=$( date "+%Y-%m-%d %H:%M:%S" )
	for param in "$@" ; do
		echo \[${LogTimeStamp}/$$\] "${param}" >> "${LogFile}"
	done
}

function InfoMessage()
{
	echo "$*"
	DoLog "$*"
}

trap 'ThrowException "Uncaught exception!"' ERR
trap 'ThrowException "EWS shell script KILLed"' KILL
trap 'ThrowException "EWS shell script TERMed"' TERM

function ThrowException()
{
	local exitStatus=$?

	# display error
	echo ------------------------------------------------------------------------------
	echo ERROR IN $0 !
	for msg in "$@" ; do
		InfoMessage "${msg}"
	done
	InfoMessage "Command return code = ${exitStatus}"

	if [ -n "${ErrorNotificationMailRecipients:=}" ] ; then
		(
			echo ERROR IN $0 !
			for msg in "$@" ; do
				echo "${msg}"
			done
			echo Command return code = ${exitStatus}
		) | mailx -s "ERROR: EWS Shell script failure" -r ${ErrorNotificationMailSender+EWS} ${ErrorNotificationMailRecipients}
	fi

	echo ------------------------------------------------------------------------------

	if [ ${exitStatus} -le 0 ] ; then
		exitStatus=254
	fi

	exit ${exitStatus}
}