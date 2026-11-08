#!/bin/bash
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
  [ $gpg -eq 1 ] && ./server/scripts/gpg-signature.py $(sha256sum ${sfile} | cut -d' ' -f1) > ${sig}
done
