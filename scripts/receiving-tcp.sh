#!/bin/sh
PHONE_IP=${PHONE_IP:-192.168.2.15}
echo connecting to $PHONE_IP:5000

ffplay -fflags nobuffer -flags low_delay -f h264 tcp://$PHONE_IP:5000 $@

exit
ffplay -loglevel trace -f h264 -framerate 60 \
  -probesize 32 -analyzeduration 0 \
  -fflags nobuffer -flags low_delay -flags2 +showall \
  -err_detect ignore_err \
  tcp://$PHONE_IP:5000

