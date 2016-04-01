#!/bin/bash

# ci-lxc.sh	: This script will deploy a lxc image and provision it with an ansible playbook.
#		  The playbook can have roles and modules but than you need to use the best practices
#		  from ansible.
#
# Author	: Harald van der Laan
# Version	: v0.2
# Date		: 2016/04/01
#
# Requirements
#  - lxc / lxd
#  - ansible
#
# Changelog
#  - v0.1: initial version
#  - v0,2: added syntax and idempotency checking

# functions
checks() {
	# This function will check all requirements.
	local lxcimage=${1}
	local playbook=${2}
	
	for f in ansible lxc; do
		# check if required applications are installed.
		if [ -z $(which ${f}) ]; then
			echo "[error]: ${f} not installed."
			exit 1
		fi
	done
	
	if [ $(lxc image list | grep ${lxcimage} | awk '{print $2}' &> /dev/null; echo ${?}) -ne 0 ]; then
		# The lxc image to use does not exist.
		echo "[error]: ${lxcimage} does not exist."
		exit 1
	fi
	
	if [ ! -f ${playbook} ]; then
		echo "[error]: could not find playbook: ${playbook}"
		exit 1
	fi 
}

# variables
lxcname=${1}
lxcimagename=${2}
ansibleplaybook=${3}
lxcusername="ubuntu"

# checks
if [[ ${#} -lt 2 ]] || [[ ${#} -gt 3 ]]; then
	echo "[usage]: ${0} <lxc name> <lxc image> [ansible playbook]"
	exit 1
fi

checks ${lxcimagename} ${ansibleplaybook}

# main script - stage 1: create lxc
lxc init ${lxcimagename} ${lxcname} &> /dev/null
lxc start ${lxcname} &> /dev/null
sleep 5
lxcip=$(lxc list | grep ${lxcname} | awk '{print $6}')
echo "[ok]: lxc ${lxcname} created"

# main script - stage 2: insert public key to normal user
if [ ! -f ~/.ssh/id_rsa.pub ]; then
	echo "[error]: no public key found."
	echo "[error]: please create a public key by running:  ssh-keygen"
	lxc stop ${lxcname} &> /dev/null
	lxc delete ${lxcname} &> /dev/null
	echo "[ok]: lxc ${lxcname} stopped and deleted."
	exit 1
fi

lxc exec ${lxcname} mkdir /home/${lxcusername}/.ssh
lxc file push --uid=1000 --gid=1000 ~/.ssh/id_rsa.pub ${lxcname}/home/${lxcusername}/.ssh/authorized_keys
echo "[ok]: public key inserted in ${lxcname}"

# main script - stage 3: insert temp sudoers file and run ansible playbook
if [ ! -z ${3} ]; then
	# only run when playbook is provided
	echo "${lxcusername} ALL=(ALL) NOPASSWD:ALL" > 00-lxc
	lxc file push --uid=0 --gid=0 --mode=0440 00-lxc ${lxcname}/etc/sudoers.d/00-lxc
	rm 00-lxc
	echo "[ok]: temp sudoers file inserted"
	echo "${lxcip} ansible_user=${lxcusername}" > hosts-lxc
	
	# syntax check of playbook
	if [ $(ansible-playbook -i hosts-lxc ${ansibleplaybook} --syntax-check &> /dev/null; echo ${?}) -ne 0 ]; then
		echo "[error]: syntax check for ${ansibleplaybook} has failed."
		lxc stop ${lxcname}
		lxc delete ${lxcname}
		exit 1
	else
		echo "[ok]: syntax for ${ansibleplaybook} is ok."
		# run 1: run playbook 
		ansible-playbook -i hosts-lxc ${ansibleplaybook}
		
		# run 2: idempotency run
		ansible-playbook -i hosts-lxc ${ansibleplaybook} &> /tmp/output.txt
		grep -q 'changed=0.*failed=0' /tmp/output.txt && (echo "[ok] idempotence test: pass") || (echo "[error] idempotence test: fail")
		rm /tmp/output.txt
		
		lxc stop ${lxcname}
		lxc delete ${lxcname}
	fi
else
	echo "[ok]: container ${lxcname} with ip: ${lxcip} created"
fi
