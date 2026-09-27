#!/bin/sh
gst-launch-1.0 -v udpsrc port=5001 caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! \
  rtpjitterbuffer latency=100 ! rtph264depay ! h264parse ! avdec_h264 ! videoconvert ! autovideosink

