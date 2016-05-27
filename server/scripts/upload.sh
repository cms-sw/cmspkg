#!/bin/bash -ex

#First call this script with INIT command to get the TMP upload directory path
#then upload RPMs in the TMP upload(1) directory and run this script with CLONE command
#Exit Status:
# 19: Fatel error, fix the issue before automatically re-trying the upload/CLONE
#(1)
#Upload directory structure should always have
#where nn is first two chars of md5sum
#<tmp>/upload/<sha256-upload-hash>/RPMS/<nn>/<md5sum>/*.<arch>.rpm
#<tmp>/upload/<sha256-upload-hash>/rpm.md5cache  (with one line for each rpm e.g. <md5sum> <group>+<name>+<version>-*.arch.rpm)
#Optionally it could have SOURCES, WEB, drivers, cmsos, bootstrap.sh
#<tmp>/upload/<sha256-upload-hash>[/SOURCES/cache/<nn>/<nn><md5sum>/<src-files>]
#<tmp>/upload/<sha256-upload-hash>[/SOURCES/<arch>/<group>/<name>/<version>/<symlink> -> ../../../../cache/nn>/<nn><md5sum>/<src-file>]
#<tmp>/upload/<sha256-upload-hash>[/cmsos|bootstrap.sh|drivers/<arch>-driver.txt|WEB/Files]

######################
# Utility functions  #
######################
#Print the repository name $2 or one of its parent name where it finds direcotry $1/$2/$3
function findRepo {
  local r=$2
  while [ ! -d $1/$r/$3 ] ; do
    local pr="$(echo $r | sed 's|\.[^.]*$||')"
    [ "$pr" = "$r" ] && exit 0
    r="${pr}"
  done
  echo $r
}
export -f findRepo
#######################################################################
#Dafault CMSREP Paths/Values
#######################################################################
#We export some variables so that these are also available to private-upload.sh
#script ran by this script.
export BASEREPO_DIR="/data/cmssw"
export CMSPKG_REPOS="${BASEREPO_DIR}/repos"
export TMPDIR="${CMSPKG_REPOS}/tmp"
export DEFAULT_HASH="0000000000000000000000000000000000000000000000000000000000000000"
REPO_REGEXP="a-zA-Z0-9_"    #Specially not '.' in repo name
USAGE_MSG="Usage: $0 INIT|CLONE architecture src_repo des_repo [tmp-upload-directory-name]"
########################################################################
#Command-line args
########################################################################
COMMAND="$1"             #Required: INIT|CLONE
ARCH="$2"                #Required: Architecture string e.g. slc6_amd64_gcc530, slc6_aarch64_gcc530 etc.
SRC_REPO="$3"            #Required: Name of rpm repository to use e.g. cms , comp, comp.pre etc.
DES_REPO="$4"            #Required: Name of destination repo, for sync-back it should be empty
TMPREPO_BASE="$5"        #Required: Tmp directory name under TMPDIR obtained via INIT request

#Make sure COMMAND, SRC_REPO and ARCH command-line args are provided and have valid values
if [ "X${COMMAND}" = "X" -o "X${SRC_REPO}" = "X" -o "X${ARCH}" = "X" ] ; then
  echo "${USAGE_MSG}"
  exit 19
fi
if [ "X$(echo ${COMMAND} | egrep '^(INIT|CLONE)$')" = "X" ] ; then
  echo "Error: Unknow command type: ${COMMAND}"
  echo "${USAGE_MSG}"
  exit 19
fi

#Check the DES_REPO, if empty (sync-back) then set to SRC_REPO
#In case DES_REPO is provided (upload without sync-back) then
# - make sure that it contains valid characters [a-zA-Z0-9_]
# - set it to SRC_REPO.DES_REPO
if [ "X${DES_REPO}" = "X" ] ; then
  DES_REPO="${SRC_REPO}"
elif [ X$(echo ${DES_REPO} | grep "^[${REPO_REGEXP}]*$" | wc -l) = "X0" ] ; then
  echo "Error: Invalid character in destination repo name: ${DES_REPO}"
  exit 19
else
  DES_REPO="${SRC_REPO}.${DES_REPO}"
fi
#Check for valid SRC_REPO name. Src repo can also contain '.' (but not for new repos)
if [ X$(echo ${SRC_REPO} | grep "^[${REPO_REGEXP}.]*$" | wc -l) = "X0" ] ; then
  echo "Error: Invalid character in source repo name: ${SRC_REPO}"
  exit 19
fi
#For CLONE requests, tmp upload directory should be passed and
#it should have a upload sub-directory
export ORIG_PARENT_HASH=""
if [ "${COMMAND}" = "CLONE" ] ; then
  #make sure that temp upload directory exists
  if [ "X${TMPREPO_BASE}" = "X" -o ! -d "${TMPDIR}/${TMPREPO_BASE}/upload" ] ; then
    echo "Error: Requesting CLONE of repository but no or invalid temp upload directory found"
    echo "${USAGE_MSG}"
    exit 19
  fi
  TMPREPO_BASE="${TMPDIR}/${TMPREPO_BASE}"

  #Read the previously saved parent hash
  ORIG_PARENT_HASH="$(cat ${TMPREPO_BASE}/parent_hash || true)"
  if [ "X${ORIG_PARENT_HASH}" = "X" ] ; then
    echo "Error: Requesting CLONE of repository with syncback but no original parent hash found."
    echo "${USAGE_MSG}"
    exit 19
  fi
fi
############################################################################

export NEW_STYLE_SRC_REPO="YES"      #Assume we do have new upload style repo for this ARCH
export NEW_ARCH="NO"                 #Assume that it is not a new arch
export CREATE_REPO="NO"              #Create new repo if no new style or apt repo found 

###########################################################################
#Search for src repo and get its parent hash.
# - first search in new style repo area
# - then search in old style apt area
# - if no repo found then it is new repo request
export PARENT_HASH=""                #Hash of src repo
export PARENT_REPO_DIR_PATH=""       #path to src repo symlink to get its hash
export APT_REPO=""                   #APT repo name from where to start the migration

#Search for a new style repo for which we already have this arch uploaded
export ACTUAL_SRC_REPO="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} ${ARCH})" || exit 19
if [ "X${ACTUAL_SRC_REPO}" != "X" ] ; then
  #This arch has already been migrated to new upload style
  PARENT_REPO_DIR_PATH="${CMSPKG_REPOS}/${ACTUAL_SRC_REPO}/${ARCH}/latest"
  PARENT_HASH="$(readlink ${PARENT_REPO_DIR_PATH} | sed 's|^.*/||')"
else
  #This arch is not yet migrated to new upload style or it is a new arch
  #or we are asked create a new repo
  NEW_STYLE_SRC_REPO="NO"
  #search the APT repos and get the valid repo name
  APT_REPO="$(findRepo ${BASEREPO_DIR} ${SRC_REPO} apt)" || exit 19
  if  [ "X${APT_REPO}" = "X" ] ; then
    #No APT repo found, so we have to create a new repository
    CREATE_REPO="YES"
    PARENT_HASH="XXX"     #Set hash to some invalid value
    #For new repos, one should always request sync-back and
    #repo name should not have '.' in it i.e it should be a top level repo e.g cms
    if [ "${SRC_REPO}" != "${DES_REPO}" ] ; then
      echo "Error: Trying to create a new repo with out sync-back"
      exit 19
    fi
    if [ "$(echo ${SRC_REPO} | grep '[.]' | wc -l)" -gt 0 ] ; then
      echo "Error: Invalid character in repo name: ${SRC_REPO}"
      exit 19
    fi
  else
    #Found an existing APT src repo
    PARENT_REPO_DIR_PATH="${BASEREPO_DIR}/${APT_REPO}"
    PARENT_HASH="$(readlink ${PARENT_REPO_DIR_PATH} | sed 's|^.*/||')"
    APT_REPO="$(echo ${PARENT_HASH} | sed 's|\.[0-9a-f]\{64\}-[0-9a-f]\{64\}$||')"
    if [ ! -d "${PARENT_REPO_DIR_PATH}/apt/${ARCH}" ] ; then
      #Arch is unknown in the apt repo, so it is a new arch
      NEW_ARCH="YES"
    fi
  fi
fi

#Make sure parent hash is not empty (due to invalid symlink read above)
if [ "X${PARENT_HASH}" = "X" ] ; then
  echo "Error: Unable to find the partent hash."
  exit 19
fi

if [ "${COMMAND}" = "INIT" ] ; then
  #For INIT command, create a temp upload directory and return
  #Create a tmp direcotry with world writeable permissions (comp users uses their own user to upload)
  TMPREPO_BASE="$(mktemp -d -p ${TMPDIR}/ tmp-${DES_REPO}-${ARCH}-XXXXXXXX)"
  echo "${PARENT_HASH}" > ${TMPREPO_BASE}/parent_hash
  echo "NEW_TEMP_REPOSITORY:${TMPREPO_BASE}"
  exit 0
fi

#CLONE request is made
#If it is upload with syncback then we want to make sure that parent hash is
#same as original parent. For upload only, we do not care if parent has changed.
if [ "${SRC_REPO}" = "${DES_REPO}" -a "X${PARENT_HASH}" != "X${ORIG_PARENT_HASH}" ] ; then
  #someone has uploaded new RPMs, so we need to restart
  echo "Parent mismatch, please re-try"
  rm -rf ${TMPREPO_BASE}
  exit 1
fi

#Decide the first arg of the private-upload script. Only one process with this arg should be running
#at one time. By default we allow parallel upload for DES_REPO/ARCH except for the following
# - for upload commands i.e. no sync-back which always create a new des_repo
# - upload with sync-back but src repo is not yet migrated to new style of upload
#   To avoid multiple process copying SOURCES/WEB
# - new repos which also create new des repo
PRIVATE_UPLOAD_ARG1="${DES_REPO}-${ARCH}"
if [ "$CREATE_REPO" = "YES" -o "${SRC_REPO}" != "${DES_REPO}" ] ; then
  PRIVATE_UPLOAD_ARG1="${DES_REPO}"
else
  RES="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} SOURCES)" || exit 19
  if [ "X${RES}" = "X" ] ; then
    PRIVATE_UPLOAD_ARG1="${DES_REPO}"
  fi
fi

#Run the internal private-upload.sh script to process now upload.
#Only one process should be working on PRIVATE_UPLOAD_ARG1 (either DES_REPO or combination of ARCH/DES_REPO)
#We make use of process command-line args to find out if any private-upload.sh is running
#If we find any such process then we wait and try again untill threre is no
#private-upload.sh for PRIVATE_UPLOAD_ARG1. private-upload.sh also checks at the start that it is the
#only process working for PRIVATE_UPLOAD_ARG1
while true ; do
  #Recheck if we can run parallel for des-repo/arch (may be someone has created a new style repo)
  if [ "${PRIVATE_UPLOAD_ARG1}" = "${DES_REPO}" ] ; then
    if [ "$CREATE_REPO" != "YES" -a "${SRC_REPO}" = "${DES_REPO}" ] ; then
      RES="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} SOURCES)" || exit 19
      if [ "X${RES}" != "X" ] ; then
        PRIVATE_UPLOAD_ARG1="${DES_REPO}-${ARCH}"
      fi
    fi
  fi

  #If there is already a process running then wait and continue
  [ $(pgrep -x -f "^/bin/bash .*/private-upload.sh ${PRIVATE_UPLOAD_ARG1} .*" | wc -l) -gt 0 ] && sleep 10 && continue

  #OK looks like there is no process running for this cmspkg transaction
  #A special exit code (20) from private-upload.sh should indicate that there is another
  #private-upload.sh ${ARCH} ${DES_REPO} running. In that case we just wait and re-try
  XCODE=0
  $(dirname $0)/private-upload.sh ${PRIVATE_UPLOAD_ARG1} ${ARCH} ${DES_REPO} ${SRC_REPO} ${TMPREPO_BASE} || XCODE=$?
  rm -f ${TMPREPO_BASE}/running

  #For Special exit code 20 we wait and retry
  [ "$XCODE" = "20" ] && sleep 10 && continue
  
  #OK, we are done here. Just cleanup the tmp directory and exit with the exit code of
  # private-upload script
  rm -rf ${TMPREPO_BASE}
  exit $XCODE
done

