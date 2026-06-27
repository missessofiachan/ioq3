#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Color codes for pretty output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default Quake 3 Arena path
Q3_PATH="/var/mnt/nvme1n1p4/SteamLibrary/steamapps/common/Quake 3 Arena/"

# 1. Parse arguments
CLEAN_BUILD=false
RUN_AFTER_BUILD=false
RUN_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -r|--run)
            RUN_AFTER_BUILD=true
            shift
            # Collect all remaining arguments to pass to the game binary
            while [[ $# -gt 0 ]]; do
                RUN_ARGS+=("$1")
                shift
            done
            ;;
        -h|--help)
            echo "Usage: $0 [options] [--game-args...]"
            echo ""
            echo "Options:"
            echo "  -c, --clean     Perform a clean build by deleting the build/ directory first."
            echo "  -r, --run       Run ioquake3 automatically after a successful compilation."
            echo "                  All subsequent arguments are forwarded directly to the game."
            echo "  -h, --help      Display this help menu."
            echo ""
            echo "Examples:"
            echo "  $0 -c"
            echo "  $0 -r +set s_volume 0.5"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information."
            exit 1
            ;;
    esac
done

echo -e "${BLUE}=== ioquake3 Build Script ===${NC}"

if [ "$CLEAN_BUILD" = true ]; then
    echo -e "${YELLOW}Clean build requested. Removing build/ directory...${NC}"
    rm -rf build
fi

# 2. Detect container environment vs host
INSIDE_CONTAINER=false
if [ -f /run/.containerenv ] || [ -f /run/.toolboxenv ] || [ "${container}" = "podman" ] || [ "${container}" = "docker" ]; then
    INSIDE_CONTAINER=true
fi

# Determine how to run commands (directly or via distrobox)
USE_DISTROBOX=false
if [ "$INSIDE_CONTAINER" = false ]; then
    if command -v distrobox &> /dev/null; then
        # Check if bazzite-dev container exists
        if distrobox list 2>/dev/null | grep -q "bazzite-dev"; then
            USE_DISTROBOX=true
        fi
    fi
fi

# Helper function to run commands in the correct context
run_build_cmd() {
    if [ "$USE_DISTROBOX" = true ]; then
        distrobox enter bazzite-dev -- "$@"
    else
        "$@"
    fi
}

if [ "$USE_DISTROBOX" = true ]; then
    echo -e "${BLUE}Running build commands inside 'bazzite-dev' distrobox container...${NC}"
else
    if [ "$INSIDE_CONTAINER" = true ]; then
        echo -e "${BLUE}Running build commands directly inside container...${NC}"
    else
        echo -e "${YELLOW}Warning: Distrobox 'bazzite-dev' not found/not installed. Compiling on host...${NC}"
    fi
fi

# Determine parallel build job factor
if [ -n "$JOBS" ]; then
    NUM_JOBS="$JOBS"
elif command -v nproc &>/dev/null; then
    NUM_JOBS=$(nproc)
elif command -v sysctl &>/dev/null; then
    NUM_JOBS=$(sysctl -n hw.ncpu)
else
    NUM_JOBS=2
fi

# 3. Automatic CMake Reconfiguration Check
NEEDS_CONFIGURE=false
if [ ! -d "build" ] || [ ! -f "build/CMakeCache.txt" ]; then
    NEEDS_CONFIGURE=true
else
    # Find files newer than build/CMakeCache.txt
    NEWER_FILES=$(find CMakeLists.txt code/ cmake/ -type f \( -name "CMakeLists.txt" -o -name "*.cmake" \) -newer build/CMakeCache.txt 2>/dev/null || true)
    if [ -n "$NEWER_FILES" ]; then
        echo -e "${YELLOW}Detected updates to CMake configuration files:${NC}"
        echo "$NEWER_FILES" | sed 's/^/ - /'
        NEEDS_CONFIGURE=true
    fi
fi

if [ "$NEEDS_CONFIGURE" = true ]; then
    echo -e "${YELLOW}Configuring build with CMake...${NC}"
    run_build_cmd cmake -B build -DCMAKE_BUILD_TYPE=Release
else
    echo -e "${GREEN}Build already configured and up-to-date. Skipping CMake configuration...${NC}"
fi

# Start build timer
START_TIME=$(date +%s)

# 4. Build the project
echo -e "${GREEN}Compiling ioquake3 with ${NUM_JOBS} parallel jobs...${NC}"
if ! run_build_cmd cmake --build build -j"${NUM_JOBS}"; then
    echo -e "${RED}Build failed! If you encountered configuration issues, try a clean build:${NC}"
    echo -e "${YELLOW}  ./compile.sh --clean${NC}"
    exit 1
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Locate the compiled client binary
CLIENT_BIN=$(find build -type f -name "ioquake3*" -executable -print -quit 2>/dev/null)

if [ -z "$CLIENT_BIN" ]; then
    echo -e "${RED}Build succeeded, but couldn't locate the ioquake3 client binary under build/!${NC}"
    exit 1
fi

echo -e "${GREEN}Build complete in ${ELAPSED}s! Executable is located at:${NC}"
echo -e "${BLUE}  ${CLIENT_BIN}${NC}"

# 4.5 Package compiled QVMs into a .pk3 to override the Steam base assets
echo -e "${GREEN}Packaging custom UI QVMs into PK3 files...${NC}"
find build -type f -path "*/vm/ui.qvm" | while read -r qvm_path; do
    # Determine directory (baseq3 or missionpack)
    dir_name=$(basename "$(dirname "$(dirname "$qvm_path")")")
    pk3_name="zz_custom_ui.pk3"
    
    # 1. Create PK3 in the build folder
    pk3_build_path="$(dirname "$(dirname "$qvm_path")")/${pk3_name}"
    python3 -c "import zipfile; zip_f = zipfile.ZipFile('${pk3_build_path}', 'w', zipfile.ZIP_DEFLATED); zip_f.write('${qvm_path}', 'vm/ui.qvm')"
    echo -e "${BLUE}  Created ${pk3_build_path}${NC}"

    # 2. Copy to user's legacy homepath target (~/.q3a/baseq3 or ~/.q3a/missionpack)
    legacy_homepath_target="${HOME}/.q3a/${dir_name}"
    mkdir -p "${legacy_homepath_target}"
    cp "${pk3_build_path}" "${legacy_homepath_target}/${pk3_name}"
    echo -e "${BLUE}  Copied to ${legacy_homepath_target}/${pk3_name}${NC}"

    # 3. Copy to user's modern XDG homepath target (~/.local/share/Quake3/baseq3 or ~/.local/share/Quake3/missionpack)
    xdg_homepath_target="${HOME}/.local/share/Quake3/${dir_name}"
    mkdir -p "${xdg_homepath_target}"
    cp "${pk3_build_path}" "${xdg_homepath_target}/${pk3_name}"
    echo -e "${BLUE}  Copied to ${xdg_homepath_target}/${pk3_name}${NC}"

    # 4. Copy directly to the Steam basepath target (if writable)
    steam_target="${Q3_PATH}/${dir_name}"
    if [ -d "${steam_target}" ] && [ -w "${steam_target}" ]; then
        cp "${pk3_build_path}" "${steam_target}/${pk3_name}"
        echo -e "${GREEN}  Copied to Steam directory: ${steam_target}/${pk3_name}${NC}"
    else
        echo -e "${YELLOW}  Warning: Steam directory ${steam_target} not writable or not found. Skipping copy to Steam.${NC}"
    fi
done

# 5. Optional Auto-Run
if [ "$RUN_AFTER_BUILD" = true ]; then
    echo -e "${GREEN}Launching ioquake3 with assets from: ${Q3_PATH}...${NC}"
    
    # We pass the fs_basepath pointing to the Quake 3 Arena directory so it loads the pk3 files
    run_build_cmd "./${CLIENT_BIN}" +set fs_basepath "${Q3_PATH}" "${RUN_ARGS[@]}"
fi
