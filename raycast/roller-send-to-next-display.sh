#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Send Window to Next Display
# @raycast.mode silent
# @raycast.packageName Roller

# Optional parameters:
# @raycast.icon 🎞️
# @raycast.description Move the focused window to the next display

open -g "roller://send_to_next_display"
