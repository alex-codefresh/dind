#!/bin/bash

DIR=$(dirname $0)

echo "Entering $0 at $(date) "
DIND_VOLUME_STAT_DIR=${DIND_VOLUME_STAT_DIR:-/var/lib/docker/dind-volume}
DIND_VOLUME_CREATED_TS_FILE=${DIND_VOLUME_STAT_DIR}/created
DIND_VOLUME_LAST_USED_TS_FILE=${DIND_VOLUME_STAT_DIR}/last_used
DIND_VOLUME_USED_BY_PODS_FILE=${DIND_VOLUME_STAT_DIR}/pods

DIND_IMAGES_LIB_DIR=${DIND_IMAGES_LIB_DIR:-"/opt/codefresh/dind/images-libs"}

mkdir -p ${DIND_VOLUME_STAT_DIR}
if [ ! -f ${DIND_VOLUME_STAT_DIR}/created ]; then
  echo "This is first usage of the dind-volume"
  date +%s > ${DIND_VOLUME_CREATED_TS_FILE}
fi

CURRENT_TS=$(date +%s)
echo ${CURRENT_TS} > ${DIND_VOLUME_LAST_USED_TS_FILE}

export POD_NAME=${POD_NAME:-$(hostname)}
echo "${POD_NAME} ${CURRENT_TS}" >> ${DIND_VOLUME_USED_BY_PODS_FILE}

sigterm_trap(){
   echo "${1:-SIGTERM} received at $(date)"
   export SIGTERM=1
   CURRENT_TS=$(date +%s)
   echo ${CURRENT_TS} > ${DIND_VOLUME_LAST_USED_TS_FILE}

   #### Saving Current Docker events
   DOCKER_EVENTS_DIR=${DIND_VOLUME_STAT_DIR}/events
   mkdir -p ${DOCKER_EVENTS_DIR}
   DOCKER_EVENTS_FILE="${DOCKER_EVENTS_DIR}"/${CURRENT_TS}
   DOCKER_EVENTS_FORMAT='{{ json . }}'
   echo -e "\nSaving current docker events to ${DOCKER_EVENTS_FILE} "
   docker events --until 0s --format "${DOCKER_EVENTS_FORMAT}" > "${DOCKER_EVENTS_FILE}"

   if [[ -n "${CLEANER_AGENT_PID}" ]]; then
      echo "killing CLEANER_AGENT_PID ${CLEANER_AGENT_PID}"
      kill $CLEANER_AGENT_PID
   fi

   if [[ -n "${CLEAN_DOCKER}" ]]; then
     echo "Starting Cleaner"
     ${DIR}/cleaner/docker-clean.sh
   fi
   
   echo "Cleaning old events files"
   find ${DOCKER_EVENTS_DIR} -type f -mtime +10 -exec rm -fv {} \;

   echo "killing MONITOR_PID ${MONITOR_PID}"
   kill $MONITOR_PID

   echo "killing DOCKERD_PID ${DOCKERD_PID}"
   kill $DOCKERD_PID
   sleep 2

   if [[ -n "${USE_DIND_IMAGES_LIB}" && "${USE_DIND_IMAGES_LIB}" != "false" && -n "${DOCKERD_DATA_ROOT}" ]]; then
     echo "We used DIND_IMAGES_LIB directory, removing DOCKERD_DATA_ROOT = ${DOCKERD_DATA_ROOT}"
     time rm -rf ${DOCKERD_DATA_ROOT}
   fi

   echo "Running processes: "
   ps -ef
   echo "Exiting at $(date) "
}
trap sigterm_trap SIGTERM SIGINT

# Starting run daemon
rm -fv /var/run/docker.pid
mkdir -p /var/run/codefresh

# Setup Client certificate ca
if [[ -n "${CODEFRESH_CLIENT_CA_DATA}" ]]; then
  CODEFRESH_CLIENT_CA_FILE=${CODEFRESH_CLIENT_CA_FILE:-/etc/ssl/cf-client/ca.pem}
  mkdir -pv $(dirname ${CODEFRESH_CLIENT_CA_FILE} )
  echo ${CODEFRESH_CLIENT_CA_DATA} | base64 -d >> ${CODEFRESH_CLIENT_CA_FILE}
fi

# creating daemon json
if [[ ! -f /etc/docker/daemon.json ]]; then
  DAEMON_JSON=${DAEMON_JSON:-default-daemon.json}
  mkdir -p /etc/docker
  cp -v ${DIR}/docker/${DAEMON_JSON} /etc/docker/daemon.json
fi
echo "$(date) - Starting dockerd with /etc/docker/daemon.json: "
cat /etc/docker/daemon.json

# Docker registry self-signed Certs - workaround for problem where kubernetes cannot mount 
for cc in $(find /etc/docker/certs.d -type d -maxdepth 1)
do
  echo "Trying to process Registery Self-Signed certs dir $cc "
  ls -l "${cc}"
  NEW_CERTS_DIR=$(echo $cc | sed -E 's/(.*)_([0-9]+)/\1\:\2/g')

  if [[ "${cc}" != "${NEW_CERTS_DIR}" ]]; then
    echo "Creating Registry Registery Self-Signed certs dir ${NEW_CERTS_DIR}"
    mkdir -pv "${NEW_CERTS_DIR}"
    cp -vrfL "${cc}"/{ca.crt,client.key,client.cert} "${NEW_CERTS_DIR}"/
  fi
done

#DOCKERD_PARAMS=""
if [[ -n "${USE_DIND_IMAGES_LIB}" && "${USE_DIND_IMAGES_LIB}" != "false" ]]; then
   mkdir -p ${DIND_IMAGES_LIB_DIR}/../pods
   DOCKERD_DATA_ROOT=$(realpath ${DIND_IMAGES_LIB_DIR}/..)/pods/${POD_NAME}
   echo "USE_DIND_IMAGES_LIB is set - using --data-root ${DOCKERD_DATA_ROOT} "
   # looking for first available
   for ii in $(find ${DIND_IMAGES_LIB_DIR} -mindepth 1 -maxdepth 1 -type d | grep -E 'lib-[[:digit:]]{1,3}$')
   do
     echo "Trying to use image-lib-dir $ii ... "
     [[ -d "${DOCKERD_DATA_ROOT}" ]] && rm -rf "${DOCKERD_DATA_ROOT}"
     mv $ii "${DOCKERD_DATA_ROOT}" && \
     DOCKERD_PARAMS="${DOCKERD_PARAMS} --data-root ${DOCKERD_DATA_ROOT}" && \
     export DOCKERD_DATA_ROOT && \
     echo "Successfully moved ${ii} to ${DOCKERD_DATA_ROOT} " && \
     break
   done
fi
echo "DOCKERD_PARAMS = ${DOCKERD_PARAMS}"

# Starting monitor
${DIR}/monitor/start.sh  <&- &
MONITOR_PID=$!

### start docker with retry
DOCKERD_PID_FILE=/var/run/docker.pid
DOCKERD_PID_MAXWAIT=${DOCKERD_PID_MAXWAIT:-20}
DOCKER_UP_MAXWAIT=${DOCKERD_UP_MAXWAIT:-90}
while true
do
  [[ -n "${SIGTERM}" ]] && break
  echo "Starting docker ..."
  if [[ -f ${DOCKERD_PID_FILE} || pgrep -l dockerd ]]; then
      DOCKERD_PID=$(cat ${DOCKERD_PID_FILE})
      echo "  Waiting for dockerd pid ${DOCKERD_PID_FILE} to exit ..."
      local CNT=0
      pkill dockerd 
      while pgrep -l dockerd
      do
        (( CNT++ ))
        echo ".... old dockerd is still running - $(date)"
        if [[ ${CNT} -ge 120 ]]; then
          echo "Killing old dockerd"
          pkill -9 dockerd
          break
        fi
        sleep 0.5
      done
      rm -f ${DOCKERD_PID_FILE}
  fi

  dockerd ${DOCKERD_PARAMS} <&- &
  echo "Waiting at most 20s for docker pid"
  local CNT=0
  while ! test -f "${DOCKERD_PID_FILE}" || test -z "$(cat ${DOCKERD_PID_FILE})"
  do
    echo "$(date) - Waiting for docker pid file ${DOCKERD_PID_FILE}"
    (( CNT++ ))
    if (( CNT > ${DOCKERD_PID_MAXWAIT} )); then
      echo "Waited more than ${DOCKERD_PID_MAXWAIT}s for docker pid, retry dockerd start"
      continue 2
    fi
    sleep 1
  done

  echo "Waiting at most 2m for docker pid"
  local CNT=0
  while ! docker ps
  do
    echo "$(date) - Waiting for docker running by check docker ps "
    (( CNT++ ))
    if (( CNT > ${DOCKER_UP_MAXWAIT} )); then
      echo "Waited more than ${DOCKER_UP_MAXWAIT}s for dockerd, retry dockerd start"
      continue 2
    fi
    sleep 1
  done
  echo "$(date) - dockerd has been started"
done

# dockerd ${DOCKERD_PARAMS} <&- &
# CNT=0
# while ! test -f /var/run/docker.pid || test -z "$(cat /var/run/docker.pid)" || ! docker ps
# do
#   echo "$(date) - Waiting for docker to start"
#   sleep 2
# done

DOCKERD_PID=$(cat /var/run/docker.pid)
echo "DOCKERD_PID = ${DOCKERD_PID} "

# Starting cleaner agent
if [[ -z "${DISABLE_CLEANER_AGENT}" ]]; then
  ${DIR}/cleaner/cleaner-agent.sh  <&- &
  CLEANER_AGENT_PID=$!
fi

wait ${DOCKERD_PID}
