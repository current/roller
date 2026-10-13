#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Stop / Start Roller
# @raycast.mode silent
# @raycast.packageName Roller

# Optional parameters:
# @raycast.icon 🎞️
# @raycast.description Pause or resume window management

open -g "roller://toggle_manager"
