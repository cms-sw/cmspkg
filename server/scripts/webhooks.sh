#!/bin/bash
rpms_json=$1
if [ ! -f "${rpms_json}" ] ; then exit ; fi

basedir=$(cd $(dirname ${rpms_json}); /bin/pwd)
json_name=$(basename ${rpms_json})
repo=$(echo ${basedir} | rev | cut -d/ -f 3 | rev)
arch=$(echo ${basedir} | rev | cut -d/ -f 2 | rev)
script_dir=$(dirname $0)
hooks="$(dirname $0)/webhooks.db"
if [ ! -f "${hooks}" ] ; then exit ; fi
CURL_OPTS="-s -k -f --retry 3 --retry-delay 5 --max-time 30 -X POST"
CMSREP_URI="$(echo ${basedir}/${json_name} | sed 's|^/data/|/|')"
for line in $(cat ${hooks}); do
  reg=$(echo "${line}" | sed 's|=.*$||')
  if [ $(echo "${repo}:${arch}" | grep "^$reg\$" | wc -l) -eq 1 ] ; then
     url=$(echo "${line}" | sed 's|^[^=]*=||')
     DATA="{\"payload_uri\":\"${CMSREP_URI}\",\"architecture\":\"${arch}\",\"repository\":\"${repo}\"}"
     echo "=========================="
     echo "URL=${url}"
     echo "DATA=${DATA}"
     echo "RESPONSE="
     curl $CURL_OPTS -d "${DATA}" --header 'Content-Type: application/json' "${url}" || true
  fi
done
