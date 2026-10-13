#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Move Window Left
# @raycast.mode silent
# @raycast.packageName Roller

# Optional parameters:
# @raycast.icon 🎞️
# @raycast.description Swap the focused column with its left neighbour

open -g "roller://move_left"
