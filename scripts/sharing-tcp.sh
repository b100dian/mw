#!/bin/sh
GST_DEBUG=droidscreencapsrc:4 gst-launch-1.0 -v \
  droidscreencapsrc width=1080 height=2520 target-bitrate=8000000 fps=60 ! \
  tcpserversink host=0.0.0.0 port=5000 sync=false
