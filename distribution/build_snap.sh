#!/bin/bash

# Build script for creating .snap packages for Cut the Rope DX
# Usage: `./build_snap.sh <version> [arch...]`
#   arch: amd64 and/or arm64 (default: both)
#
# Native AOT is used only when the target arch matches the host arch
# (AOT can't cross-compile without extra toolchains); otherwise a regular
# JIT publish is used.
#
# Requirements:
#   - .NET 10.0 SDK
#   - snapcraft (`sudo snap install snapcraft --classic`)
#   - LXD
#   - wget, tar, xz-utils (for the FFmpeg download script)
#   - For AOT on the host arch: clang and zlib1g-dev

set -e

# Configuration
APP_NAME="cuttherope-dx"
APP_DISPLAY_NAME="Cut the Rope DX"
DESCRIPTION="Cut the Rope DX, a fan-made enhancement of the PC version of Cut the Rope."

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$PROJECT_ROOT/src/CutTheRopeDX.Desktop/CutTheRopeDX.Desktop.csproj"
TEMPLATES_DIR="$SCRIPT_DIR/templates/linux"
RELEASE_DIR="$PROJECT_ROOT/src/CutTheRopeDX.Desktop/bin/release_github"

# Host architecture, in snap naming
case "$(uname -m)" in
    x86_64)          HOST_ARCH="amd64" ;;
    aarch64 | arm64) HOST_ARCH="arm64" ;;
    *)               HOST_ARCH="unknown" ;;
esac

# Resolve version (from arg or csproj)
VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Error: version is required. Usage: $0 <version> [amd64|arm64 ...]"
    exit 1
fi
# "+" in a prerelease version is not kept in GitHub asset names, so file names use "_".
FILE_VERSION="${VERSION//+/_}"

# Build both architectures if not defined
shift
ARCHES=("$@")
[ ${#ARCHES[@]} -eq 0 ] && ARCHES=(amd64 arm64)

# Snap versions: max 32 chars, must start/end alphanumeric.
if [ "${#VERSION}" -gt 32 ]; then
    echo "Error: snap version '$VERSION' is longer than 32 characters."
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/icons/CutTheRopeDXIcon_512.png" ]; then
    echo "Error: icon not found at $SCRIPT_DIR/icons/CutTheRopeDXIcon_512.png"
    exit 1
fi

build_snap() {
    local ARCH="$1"
    local RID
    case "$ARCH" in
        amd64) RID="linux-x64" ;;
        arm64) RID="linux-arm64" ;;
        *) echo "Error: unsupported architecture '$ARCH' (use amd64 or arm64)"; exit 1 ;;
    esac

    local BUILD_DIR="$SCRIPT_DIR/snap_build_$ARCH"
    local PUBLISH_DIR="$PROJECT_ROOT/src/CutTheRopeDX.Desktop/bin/Publish/$RID"
    local SNAP_FILE="${APP_NAME}_${FILE_VERSION}_${ARCH}.snap"

    # Native AOT only when building for the host architecture
    local USE_AOT=false
    if [ "$ARCH" = "$HOST_ARCH" ]; then
        USE_AOT=true
    fi

    echo ""
    echo "=== Building Cut the Rope DX v$VERSION .snap ($ARCH, AOT=$USE_AOT) ==="

    # Step 1: Build the application
    echo "[1/5] Building $RID release (PublishAot=$USE_AOT)..."
    rm -rf "$PUBLISH_DIR"
    dotnet publish "$PROJECT" \
        -c Release \
        -f net10.0 \
        -r "$RID" \
        -p:VersionPrefix="$VERSION" -p:VersionSuffix= \
        -p:PublishAot="$USE_AOT" \
        -o "$PUBLISH_DIR"

    # Step 1b: Bundled FFmpeg shared libraries (amd64 only for now)
    if [ "$ARCH" = "amd64" ]; then
        echo "[1b/5] Downloading FFmpeg shared libraries..."
        "$SCRIPT_DIR/download_ffmpeg_linux.sh" "$PUBLISH_DIR"
    else
        echo "[1b/5] Skipping FFmpeg for $ARCH (not supported yet)"
    fi

    # Step 2: Create directory structure
    echo "[2/5] Creating snap project layout..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/snap/gui" "$BUILD_DIR/app/game" "$BUILD_DIR/app/bin"

    # Step 3: Copy application files
    echo "[3/5] Copying application files..."
    cp -r "$PUBLISH_DIR"/* "$BUILD_DIR/app/game/"
    # AOT builds emit a large .dbg symbols file that isn't needed at runtime
    if [ "$USE_AOT" = true ]; then
        rm -f "$BUILD_DIR"/app/game/*.dbg
    fi
    chmod +x "$BUILD_DIR/app/game/CutTheRope-DX"

    # Create launcher script
    cat > "$BUILD_DIR/app/bin/launcher" << 'EOF'
#!/bin/bash
cd "$SNAP/game"
exec ./CutTheRope-DX "$@"
EOF
    chmod +x "$BUILD_DIR/app/bin/launcher"

    # Step 4: Create metadata files
    echo "[4/5] Creating snap metadata..."
    sed -e "s/{{APP_NAME}}/$APP_NAME/g" \
        -e "s/{{APP_DISPLAY_NAME}}/$APP_DISPLAY_NAME/g" \
        -e "s/{{VERSION}}/$VERSION/g" \
        -e "s/{{DESCRIPTION}}/$DESCRIPTION/g" \
        "$TEMPLATES_DIR/snapcraft.yaml" > "$BUILD_DIR/snap/snapcraft.yaml"

    cp "$SCRIPT_DIR/icons/CutTheRopeDXIcon_512.png" "$BUILD_DIR/snap/gui/$APP_NAME.png"

    # The Icon path is resolved by the snap daemon; ${SNAP} is expanded at install time.
    cat > "$BUILD_DIR/snap/gui/$APP_NAME.desktop" << EOF
[Desktop Entry]
Type=Application
Name=$APP_DISPLAY_NAME
Comment=$DESCRIPTION
Exec=$APP_NAME
Icon=\${SNAP}/meta/gui/$APP_NAME.png
Terminal=false
Categories=Game;
EOF

    # Step 5: Build the snap
    echo "[5/5] Building .snap package ($ARCH)..."
    (
        cd "$BUILD_DIR"
        if [ -n "$SNAPCRAFT_DESTRUCTIVE" ]; then
            snapcraft pack --destructive-mode --build-for "$ARCH" --output "$SNAP_FILE"
        else
            snapcraft pack --build-for "$ARCH" --output "$SNAP_FILE"
        fi
    )

    mv "$BUILD_DIR/$SNAP_FILE" "$PUBLISH_DIR/"
    rm -rf "$BUILD_DIR"

    mkdir -p "$RELEASE_DIR"
    cp "$PUBLISH_DIR/$SNAP_FILE" "$RELEASE_DIR/"

    local SNAP_SIZE
    SNAP_SIZE=$(ls -lh "$PUBLISH_DIR/$SNAP_FILE" | awk '{print $5}')
    echo "Package created: $PUBLISH_DIR/$SNAP_FILE ($SNAP_SIZE)"
}

for ARCH in "${ARCHES[@]}"; do
    build_snap "$ARCH"
done

echo ""
echo "=== Build complete! ==="
echo "Copied to: $RELEASE_DIR/"
echo ""
echo "To install locally: sudo snap install --dangerous <file>.snap"
echo "To uninstall:       sudo snap remove $APP_NAME"