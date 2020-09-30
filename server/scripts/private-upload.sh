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
elif [ "${NEW_STYLE_SRC_REPO}" = "YES" -a "X${ACTUAL_SRC_REPO}" = "X${DES_REPO}" ] ; then
  #Sync-back requested for a repo which already has this arch initialized
  echo "No initialization needed."
elif [ "${NEW_STYLE_SRC_REPO}" = "YES" ] ; then
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
else   #i.e  [ "X${APT_REPO}" != "X" ] ; then
  #There was no new style repo found but we have a apt repo which we have to
  #use to initialize. In this case we just find all the RPMS from APT REPO
  #and create hard-links and generate the meta-data for DEFAULT_HASH
  #Migrating from APT to new style repo takes time (order of 30-60 mins mostly due to WEB and SOURCE files)

  #SRC Repo now points to old style directory
  SRC_REPO_DIR="${BASEREPO_DIR}/${APT_REPO}-cache/${PARENT_HASH}"
  #Look for rpms in the RPMS directory and create hard-links 
  if [ "${NEW_ARCH}" = "NO" ] ; then
    for r in $(find ${SRC_REPO_DIR}/RPMS/${ARCH} -maxdepth 1 -name "*.rpm" -type l | xargs -i  readlink "{}" | sed "s|.*/RPMS/cache/||;s|/[^/]*/|/|") ; do
      HASH=$(echo $r | sed 's|/.*||')
      RPM=$(echo $r | sed 's|.*/||')
      HASH_INIT=$(echo $HASH | sed 's|^\(..\).*|\1|')
      RPM_FILE="${SRC_REPO_DIR}/RPMS/cache/$HASH/$ARCH/$RPM"
      mkdir -p ${TMPREPO_ARCH}/${DEFAULT_HASH}/RPMS/$HASH_INIT/$HASH
      ln ${RPM_FILE} ${TMPREPO_ARCH}/${DEFAULT_HASH}/RPMS/${HASH_INIT}/${HASH}/${RPM}
    done
    #Once hard-links are created then generate the meta-data (package name, rpm name, size, md5sum etc.)
    #We can make use of md5sum available in genpkglist to make this process fast
    $(dirname $0)/genpkg.py "${TMPREPO_ARCH}/${DEFAULT_HASH}" "${SRC_REPO_DIR}/md5cache/${ARCH}/genpkglist"

    #create symlink latest pointing to the DEFAULT_HASH
    ln -sf ${DEFAULT_HASH} ${TMPREPO_ARCH}/latest
  fi

  #Create hard-links for the SOURCE caches if needed.
  #If one of the new style parent has SOURCES then we do not need to initialize SOURCES
  RES="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} SOURCES)" || exit 19
  if [ "X${RES}" = "X" ] ; then
    #Create hard-links for the SOURCE caches
    mkdir -p ${TMPREPO_DES}/SOURCES/links
    for r in $(find ${SRC_REPO_DIR}/SOURCES/cache -maxdepth 2 -mindepth 2 -type f | sed "s|${SRC_REPO_DIR}/SOURCES/cache/||") ; do
      HASH=$(echo $r | sed 's|/.*||')
      SRC=$(echo $r | sed 's|.*/||')
      HASH_INIT=$(echo ${HASH} | sed 's|^\(..\).*|\1|')
      SRC_FILE="${SRC_REPO_DIR}/SOURCES/cache/${r}"
      mkdir -p ${TMPREPO_DES}/SOURCES/cache/${HASH_INIT}/${HASH}
      ln ${SRC_FILE} ${TMPREPO_DES}/SOURCES/cache/${HASH_INIT}/${HASH}/${SRC}
    done

    #Create sources symlinks for easy browsing via web
    for r in $(find ${SRC_REPO_DIR}/SOURCES -maxdepth 5 -mindepth 5 -type l) ; do
      DES_LINK=${TMPREPO_DES}/SOURCES/$(echo $r | sed "s|^${SRC_REPO_DIR}/SOURCES/||")
      [ -e ${DES_LINK} ] && continue
      SLINK=$(readlink $r || true)
      [ "X${SLINK}" = "X" ] && continue
      HASH=$(echo ${SLINK} | sed 's|^.*/SOURCES/cache/||;s|/.*||')
      HASH_INIT=$(echo ${HASH} | sed 's|^\(..\).*|\1|')
      SRC=$(echo ${SLINK} | sed 's|^.*/||')
      [ -e ${SRC_REPO_DIR}/SOURCES/cache/${HASH}/${SRC} ] || continue
      SRC_FILE=../../../../cache/${HASH_INIT}/${HASH}/${SRC}
      mkdir -p $(dirname ${DES_LINK})
      ln -s ${SRC_FILE} ${DES_LINK}
    done
  fi

  #Create hard-links for the WEB caches if needed
  #If one of the new style parent has WEB then we do not need to initialize WEB
  RES="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} WEB)" || exit 19
  if [ "X${RES}" = "X" ] ; then
    #Create hard-links for the WEB caches
    rsync -a --chmod=a+rX --link-dest ${SRC_REPO_DIR}/WEB/ ${SRC_REPO_DIR}/WEB/ ${TMPREPO_DES}/WEB/
  fi

  #Make a copy of driver files
  RES="$(findRepo ${CMSPKG_REPOS} ${SRC_REPO} drivers)" || exit 19
  if [ "X${RES}" = "X" ] ; then
    mkdir -p ${TMPREPO_DES}/drivers/
    cp ${SRC_REPO_DIR}/*-driver.txt ${TMPREPO_DES}/drivers/ || true
    for xdir in ${SRC_REPO_DIR} ${CMSPKG_REPOS} ; do
      for xfile in cmsos bootstrap.sh ; do
        [ -e ${xdir}/${xfile} ] && cp -f ${xdir}/${xfile} ${TMPREPO_DES}/${xfile}
      done
    done
  fi
  PARENT_HASH=${DEFAULT_HASH}
fi

#Find the new upload hash
NEW_UPLOAD_HASH=$(ls ${TMPREPO_BASE}/upload | grep '^[0-9a-f]\{64\}$')

#For new arch, we just rename new upload hash to default hash
if [ "${NEW_ARCH}" = "YES" -o "${CREATE_REPO}" = "YES" ] ; then
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
if [ "${NEW_UPLOAD_HASH}" != "${DEFAULT_HASH}" ] ; then
  ln -s ../${PARENT_HASH} ${TMPREPO_ARCH}/${NEW_UPLOAD_HASH}/parent
fi

#if upload/new pero is requested then we just move the newly initialized dest repo back to repos directory
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

#Delete old apt style repo link if exists and it is upload request
[ -e ${BASEREPO_DIR}/${DES_REPO} -a "${SRC_REPO}" != "${DES_REPO}" ] && rm -f ${BASEREPO_DIR}/${DES_REPO}

#if new sources are upload then create a symlink
if [ -d ${CMSPKG_REPOS}/${DES_REPO}/${ARCH}/${NEW_UPLOAD_HASH}/SOURCES ] ; then
  mkdir -p ${CMSPKG_REPOS}/${DES_REPO}/SOURCES/links
  ln -s  ../../${ARCH}/${NEW_UPLOAD_HASH} ${CMSPKG_REPOS}/${DES_REPO}/SOURCES/links/${ARCH}-${NEW_UPLOAD_HASH}
fi

#We do not need temp directory any more
rm -rf ${TMPREPO_BASE}
