#!/bin/bash
rpms_json=$1
if [ ! -f "${rpms_json}" ] ; then exit ; fi

basedir=$(cd $(dirname ${rpms_json}); /bin/pwd)
repo=$(echo ${basedir} | rev | cut -d/ -f 3 | rev)
arch=$(echo ${basedir} | rev | cut -d/ -f 2 | rev)
script_dir=$(dirname $0)
hooks="$(dirname $0)/webhooks.db"
if [ ! -f "${hooks}" ] ; then exit ; fi
CURL_OPTS="-k -f --retry 3 --retry-delay 5 --max-time 30 -X POST"
packages=""
for line in $(cat ${hooks}); do
  reg=$(echo "${line}" | sed 's|=.*$||')
  if [ $(echo "${repo}:${arch}" | grep "^$reg\$" | wc -l) -eq 1 ] ; then
     url=$(echo "${line}" | sed 's|^[^=]*=||')
     if [ "X${packages}" = "X" ] ; then packages=$(grep '\.rpm' ${rpms_json}  | tr '\n' ' ' | sed 's|.${arch}.rpm||;s| ||g;s|,$||') ; fi
     DATA="{\"architecture\":\"${arch}\",\"repository\":\"${repo}\",\"packages\":[$packages]}"
     echo "=========================="
     echo "URL=${url}"
     echo "DATA=${DATA}"
     echo "RESPONSE="
     curl $CURL_OPTS -d "${DATA}" --header 'Content-Type: application/json' "${url}" || true
  fi
done
