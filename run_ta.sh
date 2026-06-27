#!/usr/bin/env bash

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Path to Quake 3 Arena Steam files
Q3_PATH="/var/mnt/nvme1n1p4/SteamLibrary/steamapps/common/Quake 3 Arena/"

# Find the compiled binary
CLIENT_BIN=$(find build -type f -name "ioquake3*" -executable -print -quit 2>/dev/null)

if [ -z "$CLIENT_BIN" ]; then
    echo "Error: ioquake3 binary not found. Please run ./compile.sh first."
    exit 1
fi

echo "Launching Quake 3: Team Arena..."
# Team Arena is launched by setting the game directory to 'missionpack'
"./${CLIENT_BIN}" +set fs_basepath "${Q3_PATH}" +set fs_game missionpack "$@"
