#!/bin/sh
PHONE_IP=${PHONE_IP:-192.168.2.15}
echo connecting to $PHONE_IP:5000
ffplay -fflags nobuffer -flags low_delay -f h264 -framerate 60 tcp://$PHONE_IP:5000 $@

