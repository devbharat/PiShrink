#!/bin/bash

version="v0.1.2"

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"
REQUIRED_TOOLS="parted losetup tune2fs md5sum e2fsck resize2fs"
ZIPTOOLS=("gzip xz")
declare -A ZIP_PARALLEL_TOOL=( [gzip]="pigz" [xz]="xz" ) # parallel zip tool to use in parallel mode
declare -A ZIP_PARALLEL_OPTIONS=( [gzip]="-f9" [xz]="-T0" ) # options for zip tools in parallel mode
declare -A ZIPEXTENSIONS=( [gzip]="gz" [xz]="xz" ) # extensions of zipped files

function info() {
	echo "$SCRIPTNAME: $1 ..."
}

function error() {
	echo -n "$SCRIPTNAME: ERROR occured in line $1: "
	shift
	echo "$@"
}

function cleanup() {
	if losetup "$loopback" &>/dev/null; then
		losetup -d "$loopback"
	fi
	if [ "$debug" = true ]; then
		local old_owner=$(stat -c %u:%g "$src")
		chown "$old_owner" "$LOGFILE"
	fi

}

function logVariables() {
	if [ "$debug" = true ]; then
		echo "Line $1" >> "$LOGFILE"
		shift
		local v var
		for var in "$@"; do
			eval "v=\$$var"
			echo "$var: $v" >> "$LOGFILE"
		done
	fi
}

function checkFilesystem() {
	info "Checking filesystem"
	e2fsck -pf "$loopback"
	(( $? < 4 )) && return

	info "Filesystem error detected!"

	info "Trying to recover corrupted filesystem"
	e2fsck -y "$loopback"
	(( $? < 4 )) && return

if [[ $repair == true ]]; then
	info "Trying to recover corrupted filesystem - Phase 2"
	e2fsck -fy -b 32768 "$loopback"
	(( $? < 4 )) && return
fi
	error $LINENO "Filesystem recoveries failed. Giving up..."
	exit 9

}

function set_autoexpand() {
    #Make pi expand rootfs on next boot
    mountdir=$(mktemp -d)
    partprobe "$loopback"
    mount "$loopback" "$mountdir"

    if [ ! -d "$mountdir/etc" ]; then
        info "/etc not found, autoexpand will not be enabled"
        umount "$mountdir"
        return
    fi
#
#    if [[ -f "$mountdir/etc/rc.local" ]] && [[ "$(md5sum "$mountdir/etc/rc.local" | cut -d ' ' -f 1)" != "1c579c7d5b4292fd948399b6ece39009" ]]; then
#      echo "Creating new /etc/rc.local"
#    if [ -f "$mountdir/etc/rc.local" ]; then
#        mv "$mountdir/etc/rc.local" "$mountdir/etc/rc.local.bak"
#    fi

    #####Do not touch the following lines#####
cat <<\EOF1 > "$mountdir/etc/rc.local"
#!/bin/bash
do_expand_rootfs() {
  ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')

  PART_NUM=${ROOT_PART#mmcblk0p}
  if [ "$PART_NUM" = "$ROOT_PART" ]; then
    echo "$ROOT_PART is not an SD card. Don't know how to expand"
    return 0
  fi

  # Get the starting offset of the root partition
  PART_START=$(parted /dev/mmcblk0 -ms unit s p | grep "^${PART_NUM}" | cut -f 2 -d: | sed 's/[^0-9]//g')
  [ "$PART_START" ] || return 1
  # Return value will likely be error for fdisk as it fails to reload the
  # partition table because the root fs is mounted
  fdisk /dev/mmcblk0 <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$PART_START

p
w
EOF

cat <<EOF > /etc/rc.local &&
#!/bin/sh
echo "Expanding /dev/$ROOT_PART"
resize2fs /dev/$ROOT_PART
rm -f /etc/rc.local; cp -f /etc/rc.local.bak /etc/rc.local; /etc/rc.local

EOF
sync
sleep 2
echo "WINGTRA: Reboot after autoexpand 1"
sleep 2
/sbin/reboot -f
exit
}

echo "WINGTRA: Autoexpanding file system"
do_expand_rootfs
echo "ERROR: Expanding failed..."
sleep 5
if [[ -f /etc/rc.local.bak ]]; then
  cp -f /etc/rc.local.bak /etc/rc.local
  /etc/rc.local
fi
exit 0
EOF1
    #####End no touch zone#####
    chmod +x "$mountdir/etc/rc.local"
    cat "$mountdir/etc/rc.local"
    sync
    umount "$mountdir"
}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-adhrspvzZ] imagefile.img [newimagefile.img]

  -s         Don't expand filesystem when image is booted the first time
  -v         Be verbose
  -r         Use advanced filesystem repair option if the normal one fails
  -z         Compress image after shrinking with gzip
  -Z         Compress image after shrinking with xz
  -a         Compress image in parallel using multiple cores
  -p         Remove logs, apt archives, dhcp leases and ssh hostkeys
  -d         Write debug messages in a debug log file
EOM
	echo "$help"
	exit 1
}

should_skip_autoexpand=false
debug=false
repair=false
parallel=false
verbose=false
prep=false
ziptool=""

while getopts ":adhprsvzZ" opt; do
  case "${opt}" in
    a) parallel=true;;
    d) debug=true;;
    h) help;;
    p) prep=true;;
    r) repair=true;;
    s) should_skip_autoexpand=true ;;
    v) verbose=true;;
    z) ziptool="gzip";;
    Z) ziptool="xz";;
    *) help;;
  esac
done
shift $((OPTIND-1))

if [ "$debug" = true ]; then
	info "Creating log file $LOGFILE"
	rm "$LOGFILE" &>/dev/null
	exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
	exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo "${0##*/} $version"

#Args
src="$1"
img="$1"

#Usage checks
if [[ -z "$img" ]]; then
  help
fi

if [[ ! -f "$img" ]]; then
  error $LINENO "$img is not a file..."
  exit 2
fi
if (( EUID != 0 )); then
  error $LINENO "You need to be running as root."
  exit 3
fi

# check selected compression tool is supported and installed
if [[ -n $ziptool ]]; then
	if [[ ! " ${ZIPTOOLS[@]} " =~ $ziptool ]]; then
		error $LINENO "$ziptool is an unsupported ziptool."
		exit 17
	else
		if [[ $parallel == true && $ziptool == "gzip" ]]; then
			REQUIRED_TOOLS="$REQUIRED_TOOLS pigz"
		else
			REQUIRED_TOOLS="$REQUIRED_TOOLS $ziptool"
		fi
	fi
fi

#Check that what we need is installed
for command in $REQUIRED_TOOLS; do
  command -v $command >/dev/null 2>&1
  if (( $? != 0 )); then
    error $LINENO "$command is not installed."
    exit 4
  fi
done

#Copy to new file if requested
if [ -n "$2" ]; then
  f="$2"
  if [[ -n $ziptool && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then	# remove zip extension if zip requested because zip tool will complain about extension
    f="${f%.*}"
  fi
  info "Copying $1 to $f..."
  cp --reflink=auto --sparse=always "$1" "$f"
  if (( $? != 0 )); then
    error $LINENO "Could not copy file..."
    exit 5
  fi
  old_owner=$(stat -c %u:%g "$1")
  chown "$old_owner" "$f"
  img="$f"
fi

# cleanup at script exit
trap cleanup EXIT

#Gather info
info "Gathering data"
beforesize="$(ls -lh "$img" | cut -d ' ' -f 5)"
parted_output="$(parted -ms "$img" unit B print)"
rc=$?
if (( $rc )); then
	error $LINENO "parted failed with rc $rc"
	info "Possibly invalid image. Run 'parted $img unit B print' manually to investigate"
	exit 6
fi
partnum="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 1)"
partstart="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 2 | tr -d 'B')"
if [ -z "$(parted -s "$img" unit B print | grep "$partstart" | grep logical)" ]; then
    parttype="primary"
else
    parttype="logical"
fi
loopback="$(losetup -f --show -o "$partstart" "$img")"
tune2fs_output="$(tune2fs -l "$loopback")"
rc=$?
if (( $rc )); then
    echo "$tune2fs_output"
    error $LINENO "tune2fs failed. Unable to shrink this type of image"
    exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output partnum partstart parttype tune2fs_output currentsize blocksize

#Check if we should make pi expand rootfs on next boot
if [ "$parttype" == "logical" ]; then
  echo "WARNING: PiShrink does not yet support autoexpanding of this type of image"
elif [ "$should_skip_autoexpand" = false ]; then
  echo "set autoexpand partition..."
  set_autoexpand
else
  echo "Skipping autoexpanding process..."
fi

# WINGTRA: Always do this
info "Syspreping: Removing logs, apt archives, dhcp leases"
mountdir=$(mktemp -d)
mount "$loopback" "$mountdir"
rm -rvf $mountdir/var/cache/apt/archives/* $mountdir/var/lib/dhcpcd5/* $mountdir/var/log/* $mountdir/var/tmp/* $mountdir/tmp/*
mkdir $mountdir/var/log/journal
rm -rvf $mountdir/home/pi/obclogs/* $mountdir/home/pi/log/* $mountdir/home/pi/metadata/* $mountdir/home/pi/init_history
echo "0" > $mountdir/home/pi/boot_cnt.txt
umount "$mountdir"


#Make sure filesystem is ok
checkFilesystem

# DISABLED # if ! minsize=$(resize2fs -P "$loopback"); then
# DISABLED # 	rc=$?
# DISABLED # 	error $LINENO "resize2fs failed with rc $rc"
# DISABLED # 	exit 10
# DISABLED # fi
# DISABLED # minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
# DISABLED # logVariables $LINENO currentsize minsize
# DISABLED # if [[ $currentsize -eq $minsize ]]; then
# DISABLED #   error $LINENO "Image already shrunk to smallest size"
# DISABLED #   exit 11
# DISABLED # fi
# DISABLED # 
# DISABLED # #Add some free space to the end of the filesystem
# DISABLED # extra_space=$(($currentsize - $minsize))
# DISABLED # logVariables $LINENO extra_space
# DISABLED # for space in 5000 1000 100; do
# DISABLED #   if [[ $extra_space -gt $space ]]; then
# DISABLED #     minsize=$(($minsize + $space))
# DISABLED #     break
# DISABLED #   fi
# DISABLED # done
# DISABLED # logVariables $LINENO minsize
# DISABLED # 
# DISABLED # #Shrink filesystem
# DISABLED # info "Shrinking filesystem"
# DISABLED # resize2fs -p "$loopback" $minsize
# DISABLED # rc=$?
# DISABLED # if (( $rc )); then
# DISABLED #   error $LINENO "resize2fs failed with rc $rc"
# DISABLED #   mount "$loopback" "$mountdir"
# DISABLED #   mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
# DISABLED #   umount "$mountdir"
# DISABLED #   losetup -d "$loopback"
# DISABLED #   exit 12
# DISABLED # fi
# DISABLED # sleep 1
# DISABLED # 
# DISABLED # #Shrink partition
# DISABLED # partnewsize=$(($minsize * $blocksize))
# DISABLED # newpartend=$(($partstart + $partnewsize))
# DISABLED # logVariables $LINENO partnewsize newpartend
# DISABLED # parted -s -a minimal "$img" rm "$partnum"
# DISABLED # rc=$?
# DISABLED # if (( $rc )); then
# DISABLED # 	error $LINENO "parted failed with rc $rc"
# DISABLED # 	exit 13
# DISABLED # fi
# DISABLED # 
# DISABLED # parted -s "$img" unit B mkpart "$parttype" "$partstart" "$newpartend"
# DISABLED # rc=$?
# DISABLED # if (( $rc )); then
# DISABLED # 	error $LINENO "parted failed with rc $rc"
# DISABLED # 	exit 14
# DISABLED # fi
# DISABLED # 
# DISABLED # #Truncate the file
# DISABLED # info "Shrinking image"
# DISABLED # endresult=$(parted -ms "$img" unit B print free)
# DISABLED # rc=$?
# DISABLED # if (( $rc )); then
# DISABLED # 	error $LINENO "parted failed with rc $rc"
# DISABLED # 	exit 15
# DISABLED # fi
# DISABLED # 
# DISABLED # endresult=$(tail -1 <<< "$endresult" | cut -d ':' -f 2 | tr -d 'B')
# DISABLED # logVariables $LINENO endresult
# DISABLED # truncate -s "$endresult" "$img"
# DISABLED # rc=$?
# DISABLED # if (( $rc )); then
# DISABLED # 	error $LINENO "trunate failed with rc $rc"
# DISABLED # 	exit 16
# DISABLED # fi
# DISABLED # 
# DISABLED # # handle compression
# DISABLED # if [[ -n $ziptool ]]; then
# DISABLED # 	options=""
# DISABLED # 	envVarname="${MYNAME^^}_${ziptool^^}" # PISHRINK_GZIP or PISHRINK_XZ environment variables allow to override all options for gzip or xz
# DISABLED # 	[[ $parallel == true ]] && options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
# DISABLED # 	[[ -v $envVarname ]] && options="${!envVarname}" # if environment variable defined use these options
# DISABLED # 	[[ $verbose == true ]] && options="$options -v" # add verbose flag if requested
# DISABLED # 
# DISABLED # 	if [[ $parallel == true ]]; then
# DISABLED # 		parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
# DISABLED # 		info "Using $parallel_tool on the shrunk image"
# DISABLED # 		if ! $parallel_tool ${options} "$img"; then
# DISABLED # 			rc=$?
# DISABLED # 			error $LINENO "$parallel_tool failed with rc $rc"
# DISABLED # 			exit 18
# DISABLED # 		fi
# DISABLED # 
# DISABLED # 	else # sequential
# DISABLED # 		info "Using $ziptool on the shrunk image"
# DISABLED # 		if ! $ziptool ${options} "$img"; then
# DISABLED # 			rc=$?
# DISABLED # 			error $LINENO "$ziptool failed with rc $rc"
# DISABLED # 			exit 19
# DISABLED # 		fi
# DISABLED # 	fi
# DISABLED # 	img=$img.${ZIPEXTENSIONS[$ziptool]}
# DISABLED # fi
# DISABLED # 
# DISABLED # aftersize=$(ls -lh "$img" | cut -d ' ' -f 5)
# DISABLED # logVariables $LINENO aftersize
# DISABLED # 
# DISABLED # info "Shrunk $img from $beforesize to $aftersize"
# DISABLED # 