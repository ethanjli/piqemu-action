#!/bin/bash -eux

mount_image() {
  local image
  image="$1"
  local sysroot
  sysroot="${2:-}"

  device="$(sudo losetup -fP --show "$image")"
  if [ -z "$device" ]; then
    echo "Error: couldn't mount $image!"
    return 1
  fi

  if [ -z "$sysroot" ]; then
    echo "$device"
    return 0
  fi

  sudo mkdir -p "$sysroot"
  sudo mount "${device}p2" "$sysroot" 1>&2
  sudo mount "${device}p1" "$sysroot/boot" 1>&2

  echo $device
}

unmount_image() {
  local device
  device="$1"
  local sysroot
  sysroot="${2:-}"

  if [ ! -z "$sysroot" ]; then
    sudo umount "$sysroot/boot"
    sudo umount "$sysroot"
  fi

  sudo e2fsck -p -f "${device}p2" | grep -v 'could be narrower.  IGNORED.'
  sudo losetup -d "$device"
}

interpolate_boot_run_service_line() {
  local line
  line="$1"
  local user
  user="$2"
  local shell_script_command
  shell_script_command="$3"
  local result_file
  result_file="$4"

  local interpolated
  interpolated="$line"
  local interpolated_next
  # Interpolate {user}:
  interpolated_next="$(\
    printf '%s' "$interpolated" | awk -v r="$user" -e 'gsub(/{user}/, r)' \
  )"
  if [ -z "$interpolated_next" ]; then # line didn't have {user}
    interpolated_next="$interpolated"
  fi
  interpolated="$interpolated_next"

  # Interpolate {command}:
  interpolated_next="$(\
    printf '%s' "$interpolated" | awk -v r="$shell_script_command" -e 'gsub(/{command}/, r)' \
  )"
  if [ -z "$interpolated_next" ]; then # line didn't have {command}
    interpolated_next="$interpolated"
  fi
  interpolated="$interpolated_next"

  # Interpolate {result}:
  interpolated_next="$(\
    printf '%s' "$interpolated" | awk -v r="$result_file" -e 'gsub(/{result}/, r)' \
  )"
  if [ -z "$interpolated_next" ]; then # line didn't have {result}
    interpolated_next="$interpolated"
  fi
  interpolated="$interpolated_next"

  echo "$interpolated"
}

BOOKWORM_RPI_3B_PLUS_DTB_BUILD_SCRIPT="$(cat << 'EOF'
#!/bin/bash -eux
# Adapted from https://forums.raspberrypi.com/viewtopic.php?p=2207807#p2207807

base_dtb="$1"
output_dtb="$2"

intermediate_dtb="$(mktemp --tmpdir=/tmp dtb.XXXXXXX)"
cp "$base_dtb" "$intermediate_dtb"

# dtparam=uart0=on
tmpfile="$(mktemp -u --tmpdir=/tmp dtb.XXXXXXX)"
dtmerge "$intermediate_dtb" "$tmpfile" - uart0=on
mv "$tmpfile" "$intermediate_dtb"

# dtparam=disable-bt
tmpfile="$(mktemp -u --tmpdir=/tmp dtb.XXXXXXX)"
dtmerge "$intermediate_dtb" "$tmpfile" /boot/overlays/disable-bt.dtbo
mv "$tmpfile" "$intermediate_dtb"

cp "$intermediate_dtb" "$output_dtb"
EOF
)"
build_bookworm_rpi_3b_plus_dtb() {
  # This builds a DTB file with Bluetooth disabled, to make RPi OS 12 (bookworm) compatible with
  # QEMU. See https://forums.raspberrypi.com/viewtopic.php?p=2207807#p2207807 for details.

  local sysroot
  sysroot="$1"
  local output
  output="$2"

  # Inject the build script into the container
  # Note: we can't use `/tmp` because it will be remounted by the container
  local tmp_script
  tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" piqemu-script.XXXXXXX)"
  echo "$BOOKWORM_RPI_3B_PLUS_DTB_BUILD_SCRIPT" | sudo tee "$tmp_script" > /dev/null
  sudo chmod a+x "$tmp_script"

  # Run the build script
  local build_result
  build_result="$(sudo mktemp --tmpdir="$sysroot/var/lib" piqemu-dtb.XXXXXXX)"
  sudo systemd-nspawn --directory "$sysroot" --quiet \
    bash -e -c "${tmp_script#"$sysroot"} /boot/bcm2710-rpi-3-b-plus.dtb ${build_result#"$sysroot"}"
  sudo cp "$build_result" "$output"

  # Clean up
  sudo rm "$build_result"
  sudo rm "$tmp_script"
}

image="$1" # e.g. "rpi-os-image.img"
machine="$2"
user="$3" # e.g. "pi"
boot_run_service="$4" # e.g. "/path/to/default-boot-run.service"
args="$5" # e.g. "--bind /path/in/host:/path/in/vm"
shell_command="$6" # e.g. "bash -e {0}"

# Mount the image
sysroot="$(sudo mktemp -d --tmpdir=/mnt sysroot.XXXXXXX)"
device="$(mount_image "$image" "$sysroot")"

# Make a shell script with the run commands
# Note: we can't use `/tmp` because it will be remounted by the vm
tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" piqemu-script.XXXXXXX)"
# Note: this command reads & processes stdin:
sudo tee "$tmp_script" > /dev/null
sudo chmod a+x "$tmp_script"
vm_tmp_script="${tmp_script#"$sysroot"}"
sudo systemd-nspawn --directory "$sysroot" --quiet \
  chown "$user" "$vm_tmp_script"

# Prepare the shell script command
shell_script_command="$(\
  printf '%s' "$shell_command" | awk -v r="$vm_tmp_script" -e 'gsub(/{0}/, r)' \
)"
if [ -z "$shell_script_command" ]; then
  # shell_command didn't have {0}, so we'll just use it verbatim:
  shell_script_command="$shell_command"
fi

# Inject the shell script into the VM
boot_tmp_script="$(sudo mktemp --tmpdir="$sysroot/usr/bin" piqemu-script.XXXXXXX)"
sudo cp "$tmp_script" "$boot_tmp_script"
sudo chmod a+x "$boot_tmp_script"
sudo systemd-nspawn --directory "$sysroot" --quiet \
  chown "$user" "${boot_tmp_script#"$sysroot"}"

# Inject into the VM a service to run the shell script command and record its return value
boot_tmp_result="$(sudo mktemp --tmpdir="$sysroot/var/lib" piqemu-status.XXXXXXX)"
sudo systemd-nspawn --directory "$sysroot" --quiet \
  chown "$user" "${boot_tmp_result#"$sysroot"}"
boot_tmp_service="$(\
  sudo mktemp --tmpdir="$sysroot/etc/systemd/system" --suffix=".service" piqemu.XXXXXXX \
)"
readarray -t lines < "$boot_run_service"
for line in "${lines[@]}"; do
  printf '%s\n' "$(\
    interpolate_boot_run_service_line \
      "$line" "$user" "$shell_script_command" "${boot_tmp_result#"$sysroot"}" \
  )" | \
    sudo tee --append "$boot_tmp_service" > /dev/null
done
sudo chmod a+r "$boot_tmp_service"
echo "Boot run service $boot_tmp_service:"
cat "$boot_tmp_service"
vm_boot_tmp_service="${boot_tmp_service#"$sysroot/etc/systemd/system/"}"
sudo systemd-nspawn --directory "$sysroot" --quiet \
  systemctl enable "$vm_boot_tmp_service"

# Prepare files depending on machine type
args="-append \"rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=/dev/mmcblk0p2 rootdelay=1\" $args"
args="-netdev user,id=net0,hostfwd=tcp::2222-:22 -device usb-net,netdev=net0 $args"
args="-drive file=$image,if=sd,format=raw,index=0,media=disk $args"
args="-cpu cortex-a72 -smp 4 $args"
case "$machine" in
  'rpi-3b+')
    tmp_kernel="$(sudo mktemp --tmpdir="/tmp" piqemu-kernel.XXXXXXX)"
    sudo cp "$sysroot/boot/kernel8.img" "$tmp_kernel"
    tmp_dtb="$(sudo mktemp --tmpdir="/tmp" piqemu-dtb.XXXXXXX)"
    build_bookworm_rpi_3b_plus_dtb "$sysroot" "$tmp_dtb"
    args="-machine raspi3b -dtb $tmp_dtb -kernel $tmp_kernel -m 1G $args"
    ;;
  *)
    echo "Error: unsupported machine type $machine"
    return 1
    ;;
esac
args="-nographic $args"

echo "Running VM with boot..."
# We use eval to work around word splitting in strings inside quotes in args:
unmount_image "$device" "$sysroot"
eval "sudo qemu-system-aarch64 $args"
sysroot="$(sudo mktemp -d --tmpdir=/mnt sysroot.XXXXXXX)"
device="$(mount_image "$image" "$sysroot")"

# Clean up the injected service
sudo systemd-nspawn --directory "$sysroot" --quiet \
  systemctl disable "$vm_boot_tmp_service"
sudo rm -f "$boot_tmp_service"

# Check the return code of the shell script
if [ ! -f "$boot_tmp_result" ]; then
  echo "Error: $boot_run_service did not store a result indicating success/failure!"
  exit 1
elif [ "$(sudo cat "$boot_tmp_result")" != "0" ]; then
  result="$(sudo cat "$boot_tmp_result")"
  echo "Error: $boot_run_service failed while running $shell_script_command: $result"
  case "$result" in
    '' | *[!0-9]*)
      exit 1
      ;;
    *)
      exit "$result"
      ;;
  esac
fi
sudo rm -f "$boot_tmp_result"

# Clean up the shell script
sudo rm -f "$boot_tmp_script"
sudo rm -f "$tmp_script"

# Clean up the mount
unmount_image "$device" "$sysroot"
