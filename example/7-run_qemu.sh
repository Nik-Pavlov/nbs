#!/usr/bin/env bash

set -Eeuo pipefail

find_bin_dir() {
    readlink -e "$(dirname "$0")"
}

BIN_DIR=$(find_bin_dir)

show_help() {
    cat << EOF
Usage: ./7-run_qemu.sh [-hkds]
Run qemu
-h, --help                     Display help
-d, --diskid                   NBS Disk ID
-s, --socket                   Socket path
-k, --encryption-key-path      Encryption key path
-e, --encrypted                Use default encryption key
EOF
}

#defaults
encryption=()
diskid=""
socket=""
if ! options=$(getopt -l "help,diskid:,socket:,encryption-key-path:,encrypted" -o "hk:d:s:e" -a -- "$@"); then
    echo "Incorrect options provided"
    exit 1
fi
eval set -- "$options"

while true
do
    case "$1" in
    -h | --help )
        show_help
        exit 0
        ;;
    -k | --encryption-key-path )
        encryption=("--encryption-mode=aes-xts" "--encryption-key-path=${2}")
        shift 2
        ;;
    -e | --encrypted )
        encryption=("--encryption-mode=aes-xts" "--encryption-key-path=encryption-key.txt")
        shift 1
        ;;
    -d | --diskid )
        diskid=${2}
        shift 2
        ;;
    -s | --socket )
        socket=${2}
        shift 2
        ;;
    --)
        shift
        break;;
    esac
done

if [ -z "$diskid" ] ; then
    echo "Disk id shouldn't be empty"
    exit 1
fi

if [ -z "$socket" ] ; then
    socket="/tmp/$diskid.sock"
fi

if [[ ! -e /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "No read/write access to /dev/kvm." >&2
    echo "Add the current user to the kvm group and reconnect:" >&2
    echo "  sudo usermod -aG kvm $(id -un)" >&2
    exit 1
fi

# prepare qemu image

BUILD_ROOT="$BIN_DIR/../cloud/blockstore/buildall"
BLOCKSTORE_CLIENT_BIN="$BUILD_ROOT/cloud/blockstore/apps/client/blockstore-client"
QEMU_BIN_DIR="$BUILD_ROOT/cloud/storage/core/tools/testing/qemu/bin"
QEMU_BIN_TAR="$QEMU_BIN_DIR/qemu-bin.tar.gz"
QEMU="$QEMU_BIN_DIR/usr/bin/qemu-system-x86_64"
QEMU_FIRMWARE="$QEMU_BIN_DIR/usr/share/qemu"
DISK_IMAGE="$QEMU_BIN_DIR/../image-noble/rootfs.img"

missing_artifact() {
    echo "Required artifact not found: $1" >&2
    echo "Build it from the repository root with:" >&2
    echo "  ./ya make cloud/blockstore/buildall -r" >&2
    exit 1
}

[[ -x "$BLOCKSTORE_CLIENT_BIN" ]] || missing_artifact "$BLOCKSTORE_CLIENT_BIN"

if [[ ! -x "$QEMU" ]]; then
    [[ -f "$QEMU_BIN_TAR" ]] || missing_artifact "$QEMU_BIN_TAR"
    [[ -d "$QEMU_BIN_DIR" && -w "$QEMU_BIN_DIR" ]] || {
        echo "QEMU directory is not writable: $QEMU_BIN_DIR" >&2
        exit 1
    }
    echo "expand qemu tar from [$QEMU_BIN_TAR]"
    tar -xzf "$QEMU_BIN_TAR" -C "$QEMU_BIN_DIR"
fi

[[ -x "$QEMU" ]] || missing_artifact "$QEMU"
[[ -d "$QEMU_FIRMWARE" ]] || missing_artifact "$QEMU_FIRMWARE"
[[ -f "$DISK_IMAGE" ]] || missing_artifact "$DISK_IMAGE"

socket_dir=$(dirname "$socket")
[[ -d "$socket_dir" ]] || {
    echo "Socket parent directory does not exist: $socket_dir" >&2
    exit 1
}
[[ -w "$socket_dir" ]] || {
    echo "Socket parent directory is not writable: $socket_dir" >&2
    exit 1
}

function blockstore-client {
    LD_LIBRARY_PATH=$(dirname "$BLOCKSTORE_CLIENT_BIN") "$BLOCKSTORE_CLIENT_BIN" "$@"
}

# start endpoint for disk
echo "stopping any existing endpoint [${socket}]"
blockstore-client stopendpoint --socket "$socket"
echo "starting endpoint [${socket}] for disk [${diskid}]"
if ! blockstore-client startendpoint --ipc-type vhost --socket "$socket" \
    --client-id client-1 --instance-id localhost --disk-id "$diskid" \
    --persistent "${encryption[@]}"; then
    echo "Failed to start endpoint [$socket] for disk [$diskid]." >&2
    echo "An NBS volume cannot have two concurrent read-write local mounts." >&2
    echo "Disconnect its existing NBD endpoint or create a dedicated volume for QEMU." >&2
    exit 1
fi

endpoint_created=true
cleanup_endpoint() {
    status=$?
    trap - EXIT INT TERM
    if $endpoint_created; then
        endpoint_created=false
        echo "stopping endpoint [$socket]"
        blockstore-client stopendpoint --socket "$socket" || \
            echo "Failed to stop endpoint [$socket] during cleanup." >&2
    fi
    exit "$status"
}
trap cleanup_endpoint EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for ((attempt = 0; attempt < 100; ++attempt)); do
    if [[ -S "$socket" ]]; then
        break
    fi
    sleep 0.1
done
if [[ ! -S "$socket" ]]; then
    echo "Timed out waiting for endpoint socket [$socket]." >&2
    exit 1
fi

# run qemu with secondary disk
qmp_port=8678
ssh_port=8679

MACHINE_ARGS=" \
    -L $QEMU_FIRMWARE \
    -snapshot \
    -nodefaults
    -cpu host \
    -smp 4,sockets=1,cores=4,threads=1 \
    -enable-kvm \
    -m 16G \
    -name debug-threads=on \
    -qmp tcp:127.0.0.1:${qmp_port},server,nowait \
    "

MEMORY_ARGS=" \
    -object memory-backend-memfd,id=mem,size=16G,share=on \
    -numa node,memdev=mem \
    "

NET_ARGS=" \
    -netdev user,id=netdev0,hostfwd=tcp::${ssh_port}-:22 \
    -device virtio-net-pci,netdev=netdev0,id=net0 \
    "

DISK_ARGS=" \
    -object iothread,id=iot0 \
    -drive format=qcow2,file=$DISK_IMAGE,id=lbs0,if=none,aio=native,cache=none,discard=unmap \
    -device virtio-blk-pci,scsi=off,drive=lbs0,id=virtio-disk0,iothread=iot0,bootindex=1 \
    "

NBS_ARGS=" \
    -chardev socket,id=vhost0,path=$socket \
    -device vhost-user-blk-pci,chardev=vhost0,id=vhost-user-blk0,num-queues=1 \
    "

echo "Running qemu with disk [$diskid]"
# These variables intentionally contain multiple QEMU arguments.
# shellcheck disable=SC2086
"$QEMU" \
    $MACHINE_ARGS \
    $MEMORY_ARGS \
    $NET_ARGS \
    $DISK_ARGS \
    $NBS_ARGS \
    -nographic \
    -serial stdio \
    -s
