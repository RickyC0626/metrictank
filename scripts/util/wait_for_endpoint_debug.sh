#!/bin/sh

log () {
	echo "$(date +'%Y/%m/%d %H:%M:%S') $@"
}

# If dlv runs as PID 1 in the container it will not properly kill metrictank during shutdown
# when it receives SIGTERM (docker stop / docker-compose stop / etc...). So, instead we leave
# this script running in an endless sleep loop and trap SIGTERM, SIGINT, and SIGHUP. Then we can
# kill both metrictank and dlv and exit this script which will shutdown the container.
kill_metrictank() {
  echo "Killing metrictank"
  pkill metrictank
  sleep 1
  echo "Killing dlv"
  pkill dlv
  sleep 1
  exit 0
}

trap 'kill_metrictank' SIGTERM
trap 'kill_metrictank' SIGINT
trap 'kill_metrictank' SIGHUP

WAIT_TIMEOUT=${WAIT_TIMEOUT:-10}
CONN_HOLD=${CONN_HOLD:-3}

# test if we're using busybox for timeout
timeout_exec=$(basename "$(readlink $(which timeout))")
if [ "$timeout_exec" = "busybox" ]
then
  _using_busybox=1
else
  _using_busybox=0
fi

for endpoint in $(echo $WAIT_HOSTS | tr "," "\n")
do
  host=${endpoint%:*}
  port=${endpoint#*:}

  _start_time=$(date +%s)
  while true
  do
    _now=$(date +%s)
    _run_time=$(( $_now - $_start_time ))
    if [ $_run_time -gt $WAIT_TIMEOUT ]
    then
        log "timed out waiting for $endpoint"
        exit 1
    fi
    log "waiting for $endpoint to become up..."

    # connect and see if connection stays up.
    # docker-proxy can listen to ports before the actual service is up,
    # in which case it will accept and then close the connection again.
    # this checks not only if the connect succeeds, but also if the 
    # connection stays up for $CONN_HOLD seconds.
    if [ $_using_busybox -eq 1 ]
    then
      timeout $CONN_HOLD busybox nc $host $port -e busybox sleep $(( $CONN_HOLD + 1 )) 2>/dev/null
      retval=$?

      # busybox-timeout on alpine returns 0 on timeout
      expected=143
    else
      timeout $CONN_HOLD nc $host $port
      retval=$?

      # coreutils-timeout returns 124 if it had to kill the slow command
      expected=124
    fi

    if [ $retval -eq $expected ]
    then
      log "$endpoint is up. maintained connection for $CONN_HOLD seconds!"
      break
    fi

    sleep 1
  done
done

# can't use exec if we want to trap signals here
$@ &

while [ 1 ]
do
  # sleep until killed
  sleep 1
done
