#!/bin/bash -ex
[ $(pgrep -x -f "^/bin/bash .*/private-upload.sh  *($2:|)$3 .*" | wc -l) -gt 2 ] && exit 20

#This script can only be run from upload.sh script. Any other attempt will not process
#Check if script was run from upload.sh otherwise exit
[ $(ps -o args= $PPID | grep "$(dirname $0)/upload.sh CLONE $2 $3 " | wc -l) -eq 0 ] && echo "Error: Looks like it was not run from upload.sh" && exit 19

#Command line args pass from upload.sh
ARCH=$2
DES_REPO=$3
SRC_REPO=$4
TMPREPO_BASE=$5
RSYNC_SOURCES=false

#For debug purposes, Just create a stamp file 
touch ${TMPREPO_BASE}/running

#Only one process with CLONE request for DES_REPO/ARCH should be running this part of code

#Make sure parent hash is still the same for sync-back requests
#For upload, we do not care about the parent change at this point
if [ "${SRC_REPO}" = "${DES_REPO}" -a "${CREATE_REPO}" = "NO" ] ; then
  RES="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} ${ARCH})" || exit 19
  if [ "X${RES}" != "X${ACTUAL_SRC_REPO}" ] ; then
    echo "Parent mismatch, please re-try"
    exit 1
  fi
  RES=$(readlink "${PARENT_REPO_DIR_PATH}" | sed 's|^.*/||')
  if [ "X${RES}" != "X${ORIG_PARENT_HASH}" ] ; then
    echo "Parent mismatch, please re-try"
    exit 1
  fi
fi

#We use ORIG_PARENT_HASH as the hash to initialize new repo. For sync-back
#both are identical anyway and for upload-only we do not care if PARENT_HASH
#is changed
PARENT_HASH="${ORIG_PARENT_HASH}"

#No one should be able to change the PARENT REPO now
TMPREPO_DES="${TMPREPO_BASE}/${DES_REPO}"
TMPREPO_ARCH="${TMPREPO_DES}/${ARCH}"
mkdir -p ${TMPREPO_ARCH}

#Initialize the DES_REPO is needed
if [ "${CREATE_REPO}" = "YES" ] ; then
  #No need to do any initialization for new repo
  echo "No initialization needed."
  INCREMENTAL="false"
elif [ "X${ACTUAL_SRC_REPO}" = "X${DES_REPO}" ] ; then
  #Sync-back requested for a repo which already has this arch initialized
  echo "No initialization needed."
  INCREMENTAL="false"
elif [ "${INCREMENTAL}" = "false" ] ; then
  #New style repo exists
  #Either a upload without sync back is requested (so initialization is always needed) or
  #sync-back is requested but actual src repo with this arch is one of the 
  #parent of src_repo (so need to initialize)

  #We just sync current ACTUAL_SRC_REPO in to DES_REPO with all the transactions in to DEFAULT_HASH
  #We create hardlinks for RPMs and merge of meta data (RPMS.json) files of transactions
  #Note, in new style repo, each transaction has a symlink (parent) pointing to its parent

  SRC_REPO_DIR="${CMSPKG_REPOS}/${ACTUAL_SRC_REPO}"

  #Keep on sync-ing if REPO_HASH is set. In case parent symlink in repo is broken (due to cleanup job)
  #then fall back to DEFAULT_HASH (where cleanup job should have copied all RPMS).
  #Note that DEFAULT_HASH has no parent
  #Start from the current parent hash
  mkdir -p ${TMPREPO_ARCH}/${DEFAULT_HASH}/RPMS/
  REPO_HASH="${PARENT_HASH}"
  ALL_HASHES=""
  while [ "X${REPO_HASH}" != "X" ] ; do
    #Check for a valid transaction/commit hash i.e. [0-9a-f}{64}
    if [ $(echo ${REPO_HASH} | grep '^[0-9a-f]\{64\}$' | wc -l) -eq 0 ] ; then
      echo "Error: Looks like repository ${SRC_REPO} was man handled. An invalid hash found: ${REPO_HASH}"
      exit 19
    fi

    #Check for cyclic dependency
    if [ $(echo " ${ALL_HASHES} " | grep " ${REPO_HASH} " | wc -l) -gt 0 ] ; then
      echo "Error: Looks like repository ${SRC_REPO} was man handled. Cyclic dependency found:"
      echo "${REPO_HASH}"
      echo "${ALL_HASHES}" | sed "s| *${REPO_HASH} .*$||" | tr ' ' '\n'
      echo "${REPO_HASH}"
      exit 19
    fi
    
    #First create hard-links for every thing except meta data files (RPMS.json)
    rsync -a --chmod=a+rX --link-dest ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/RPMS/ ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/RPMS/ ${TMPREPO_ARCH}/${DEFAULT_HASH}/RPMS/

    if $RSYNC_SOURCES ; then
      #Hard links for WEB and SOURCES/cache
      for subdir in WEB SOURCES/cache ; do
        if [ -d ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${subdir} ] ; then
          mkdir -p ${TMPREPO_DES}/${subdir}
          rsync -a --ignore-existing --chmod=a+rX --link-dest ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${subdir}/ ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${subdir}/ ${TMPREPO_DES}/${subdir}/
        fi
      done

      #Copy any SOURCES symlinks/drivers files
      for subdir in SOURCES/${ARCH} drivers ; do
        if [ -d ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${subdir} ] ; then
          mkdir -p ${TMPREPO_DES}/${subdir}
          rsync -a --ignore-existing --chmod=a+rX ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${subdir}/ ${TMPREPO_DES}/${subdir}/
        fi
      done

      #copy any common files
      for cfile in cmsos ; do
        [ -f ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${cfile} ] && cp ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/${cfile} ${TMPREPO_DES}/${cfile}
      done
    fi

    #If it is default hash then stop processing as default repo has no parent
    if [ "${REPO_HASH}" = "${DEFAULT_HASH}" ] ; then
      cp ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/RPMS.json ${TMPREPO_ARCH}/${DEFAULT_HASH}/RPMS.json
      break
    fi

    #List of all hashes: we add it here so that DEFAULT HASH does not go in this list
    #Keep the order as we use this order to merge the RPMS.json files later
    ALL_HASHES="${REPO_HASH} ${ALL_HASHES}"

    #Get the parent by reading the parent symlink. Be prepared that it could be broken (due to cleanup job)
    REPO_HASH="$(readlink ${SRC_REPO_DIR}/${ARCH}/${REPO_HASH}/parent | sed 's|^.*/||' || true)"
    [ "X${REPO_HASH}" = "X" ] && REPO_HASH="${DEFAULT_HASH}"
  done
  #Merge the transactions. Read the trnasactions hashes and merge them back to DEFAULT
  MERGE_META_SCRIPT=$(dirname $0)/merge-meta.py
  for h in ${ALL_HASHES} ; do
    ${MERGE_META_SCRIPT} ${TMPREPO_ARCH}/${DEFAULT_HASH}/RPMS.json ${SRC_REPO_DIR}/${ARCH}/${h}/RPMS.json
  done

  #create symlink latest pointing to the new parent hash i.e. DEFAULT_HASH
  ln -sf ${DEFAULT_HASH} ${TMPREPO_ARCH}/latest
  PARENT_HASH=${DEFAULT_HASH}
fi

#Find the new upload hash
NEW_UPLOAD_HASH=$(ls ${TMPREPO_BASE}/upload | grep '^[0-9a-f]\{64\}$')

#For new arch/repo, we just rename new upload hash to default hash
if [ "${CREATE_REPO}" = "YES" ] ; then
  mv ${TMPREPO_BASE}/upload/${NEW_UPLOAD_HASH} ${TMPREPO_BASE}/upload/${DEFAULT_HASH}
  NEW_UPLOAD_HASH=${DEFAULT_HASH}
fi

#create the RPMS.json file with md5 sum of all rpms
$(dirname $0)/genpkg.py ${TMPREPO_BASE}/upload/${NEW_UPLOAD_HASH}
rm -f ${TMPREPO_BASE}/upload/${NEW_UPLOAD_HASH}/rpms.md5cache
rm -f ${TMPREPO_BASE}/upload/${NEW_UPLOAD_HASH}/RPMS/*/*/*.dep >/dev/null 2>&1 || true

#Move the new uploaded files in to the initialized dest repo
if [ ! -d ${TMPREPO_ARCH}/${NEW_UPLOAD_HASH} ] ; then
  mv ${TMPREPO_BASE}/upload/${NEW_UPLOAD_HASH} ${TMPREPO_ARCH}
fi

#We do not need upload directory any more, so delete it
rm -rf ${TMPREPO_BASE}/upload

#create a symlink parent in new upload hash to point to current repo hash
#parent symlink should be missing for incremental uploads
if [ "${NEW_UPLOAD_HASH}" != "${DEFAULT_HASH}" -a "${INCREMENTAL}" = "false" ] ; then
  ln -s ../${PARENT_HASH} ${TMPREPO_ARCH}/${NEW_UPLOAD_HASH}/parent
fi

#if upload/new repo is requested then we just move the newly initialized dest repo back to repos directory
#for sync back , if des repo does not have arch in it then we just move the full arch directory
#normal sync back we only move the newly upload hash to the des repo
if [ "${SRC_REPO}" != "${DES_REPO}" -o ! -d ${CMSPKG_REPOS}/${DES_REPO} ] ; then
  #Upload/new repo creation is requested
  #move old repo to delete directory for garbage collection
  [ -d ${CMSPKG_REPOS}/${DES_REPO} ] && mv ${CMSPKG_REPOS}/${DES_REPO} ${TMPDIR}/delete/$(date +%Y%m%d%H%M%S)-${DES_REPO}
  #Move the newly tmp repo back to repos
  mv ${TMPREPO_DES} ${CMSPKG_REPOS}/${DES_REPO}
  touch ${CMSPKG_REPOS}/${DES_REPO}/.cmspkg-auto-cleanup
else
  #sync back is requested
  if [ ! -d ${CMSPKG_REPOS}/${DES_REPO}/${ARCH} ] ; then
    #ARCH was already migrated to new style repo but DES_REPO does not have it
    #In this case we move full ARCH directory in to DES_REPO and create symlinks for SOURCES/links
    mv ${TMPREPO_ARCH} ${CMSPKG_REPOS}/${DES_REPO}
    if [ -d ${TMPREPO_DES}/SOURCES/links ] ; then
      mkdir -p ${CMSPKG_REPOS}/${DES_REPO}/SOURCES/links
      rsync -a --chmod=a+rX --include "${ARCH}-*" --exclude '*' ${TMPREPO_DES}/SOURCES/links/ ${CMSPKG_REPOS}/${DES_REPO}/SOURCES/links/  
    fi
    if [ -d ${TMPREPO_DES}/drivers ] ; then
      mkdir -p ${CMSPKG_REPOS}/${DES_REPO}/drivers
      rsync -a --ignore-existing --chmod=a+rX ${TMPREPO_DES}/drivers/ ${CMSPKG_REPOS}/${DES_REPO}/drivers/
    fi
    if [ -f ${TMPREPO_DES}/cmsos ] ; then
      [ -e ${CMSPKG_REPOS}/${DES_REPO}/cmsos ] || cp -f ${TMPREPO_DES}/cmsos ${CMSPKG_REPOS}/${DES_REPO}/cmsos
    fi
  else
    #Syncback is requested
    mv ${TMPREPO_ARCH}/${NEW_UPLOAD_HASH} ${CMSPKG_REPOS}/${DES_REPO}/${ARCH}/
  fi
fi

#create latest symlink pointing to new upload hash
#We know mv is a atomic operation, so we create a temp next symlink and then use mv command
ln -sf ${NEW_UPLOAD_HASH} ${CMSPKG_REPOS}/${DES_REPO}/${ARCH}/next-${NEW_UPLOAD_HASH}
mv -T ${CMSPKG_REPOS}/${DES_REPO}/${ARCH}/next-${NEW_UPLOAD_HASH} ${CMSPKG_REPOS}/${DES_REPO}/${ARCH}/latest

#if new sources are upload then create a symlink
if [ -d ${CMSPKG_REPOS}/${DES_REPO}/${ARCH}/${NEW_UPLOAD_HASH}/SOURCES ] ; then
  mkdir -p ${CMSPKG_REPOS}/${DES_REPO}/SOURCES/links
  ln -s  ../../${ARCH}/${NEW_UPLOAD_HASH} ${CMSPKG_REPOS}/${DES_REPO}/SOURCES/links/${ARCH}-${NEW_UPLOAD_HASH}
fi

#We do not need temp directory any more
rm -rf ${TMPREPO_BASE}
