#!/bin/bash -e
cd $(dirname $0)
deploy="$1"
xtype="$2"
[ "${deploy}" != "" ] || exit 1
[ -d "${deploy}" ] || exit 1
for sfile in client/bootstrap.sh client/cmspkg.py README.md; do
  dfile=$(basename $sfile)
  if [ "${xtype}" != "" ]; then
    dfile=$(echo $dfile | sed -r -e "s|^(.+)\.([^.]+)|\1-${xtype}.\2|")
  fi
  gpg=1
  cpy=1
  sig="${deploy}/${dfile}.sig"
  if [ -e "${deploy}/${dfile}" ] ; then
    if diff "${deploy}/${dfile}" "${sfile}" ; then
      cpy=0
      if [ -e "${sig}" ] ; then
        gpg=0
      fi
    fi
  fi
  [ $cpy -eq 1 ] && install -D "${sfile}" "${deploy}/${dfile}"
  if [ $gpg -eq 1 ] ; then
    sha=$(sha256sum ${sfile} | cut -d' ' -f1)
    if ./server/scripts/gpg-signature.py $sha > "${sig}.tmp" ; then
      mv "${sig}.tmp" "${sig}"
    else
      rm -f "${sig}.tmp"
    fi
  fi
done
