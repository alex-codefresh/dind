#!/bin/bash
#
# Cleaning dind
# see README.md for details
#
echo "Entering $0 at $(date) "

CLEAN_PERIOD_SECONDS=${CLEAN_PERIOD_SECONDS:-21600} # 6 hours
CLEAN_PERIOD_BUILDS=${CLEAN_PERIOD_BUILDS:-10}

IMAGE_RETAIN_PERIOD=${IMAGE_RETAIN_PERIOD:-259200}
IMAGE_RETAIN_PERIOD=${VOLUMES_RETAIN_PERIOD:-259200}



