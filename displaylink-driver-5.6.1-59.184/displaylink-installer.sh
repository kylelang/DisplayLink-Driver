#!/usr/bin/env bash
# Copyright (c) 2015 - 2020 DisplayLink (UK) Ltd.

export LC_ALL=C
readonly SELF=$0
readonly COREDIR=/opt/displaylink
readonly LOGSDIR=/var/log/displaylink
readonly PRODUCT="DisplayLink Linux Software"
VERSION=5.6.1-59.184
ACTION=install
NOREBOOT=false

DEB_DEPENDENCIES=(libdrm-dev libc6-dev)
if grep -Ei 'raspb(erry|ian)' /proc/cpuinfo /etc/os-release &>/dev/null ; then
  DEB_DEPENDENCIES+=(raspberrypi-kernel-headers)
fi
readonly DEB_DEPENDENCIES

prompt_yes_no()
{
  read -rp "$1 (Y/n) " CHOICE
  [[ ! ${CHOICE:-Y} == "${CHOICE#[Yy]}" ]]
}

prompt_command()
{
  echo "> $*"
  prompt_yes_no "Do you want to continue?" || exit 0
  "$@"
}

install_evdi()
{
  local TARGZ=$1
  local EVDI=$2
  local ERRORS=$3
  local EVDI_DRM_DEPS

  if ! tar xf "$TARGZ" -C "$EVDI"; then
    echo "Unable to extract $TARGZ to $EVDI" > "$ERRORS"
    return 1
  fi

  local dkms_evdi_path='/var/lib/dkms/evdi'
  local make_log_regex="$dkms_evdi_path/[[:alnum:]./]+/make\\.log"
  local dkms_log="${EVDI}/dkms.log"
  local evdi_make_log_path
  evdi_make_log_path="${LOGSDIR}/evdi_install_make.$(date '+%F-%H%M').log"

  echo "[[ Installing EVDI DKMS module ]]"

  dkms install "${EVDI}/module" 2>&1 | tee "$dkms_log" | sed -E "s~$make_log_regex~$evdi_make_log_path~"
  local retval=${PIPESTATUS[0]}

  if [[ $retval == 3 ]]; then
    echo "EVDI DKMS module already installed."
  elif [[ $retval != 0 ]]; then
    echo "Failed to install evdi to the kernel tree." > "$ERRORS"
    grep -Eo "$make_log_regex" "$dkms_log" | head -n1 | xargs -r -I '{}' cp '{}' "$evdi_make_log_path"
    make -sC "${EVDI}/module" uninstall_dkms
    return 1
  fi

  echo "[[ Installing module configuration files ]]"

  printf '%s\n' 'evdi' > /etc/modules-load.d/evdi.conf

  printf '%s\n' 'options evdi initial_device_count=4' \
        > /etc/modprobe.d/evdi.conf
  EVDI_DRM_DEPS=$(sed -n -e '/^drm_kms_helper/p' /proc/modules | awk '{print $4}' | tr ',' ' ')
  EVDI_DRM_DEPS=${EVDI_DRM_DEPS/evdi/}

  [[ "${EVDI_DRM_DEPS}" ]] && printf 'softdep %s pre: %s\n' 'evdi' "${EVDI_DRM_DEPS}" \
        >> /etc/modprobe.d/evdi.conf


  echo "[[ Installing EVDI library ]]"

  if ! make -C "${EVDI}/library"; then
    echo "Failed to build evdi library." > "$ERRORS"
    return 1
  fi

  if ! install "${EVDI}/library/libevdi.so" "$COREDIR"; then
    echo "Failed to copy evdi library to $COREDIR." > "$ERRORS"
    return 1
  fi
}

uninstall_evdi_module()
{
  local TARGZ=$1
  local EVDI=$2

  if ! tar xf "$TARGZ" -C "$EVDI"; then
    echo "Unable to extract $TARGZ to $EVDI"
    return 1
  fi

  make -C "${EVDI}/module" uninstall_dkms
}

is_32_bit()
{
  [[ $(getconf LONG_BIT) == 32 ]]
}

is_armv7()
{
  grep -qi -F armv7 /proc/cpuinfo
}

is_armv8()
{
  [[ "$(uname -m)" == "aarch64" ]]
}

add_upstart_script()
{
  cat > /etc/init/displaylink-driver.conf <<EOF
description "DisplayLink Driver Service"
# Copyright (c) 2015 - 2019 DisplayLink (UK) Ltd.

start on login-session-start
stop on desktop-shutdown

# Restart if process crashes
respawn

# Only attempt to respawn 10 times in 5 seconds
respawn limit 10 5

chdir /opt/displaylink

pre-start script
    . /opt/displaylink/udev.sh

    if [ "\$(get_displaylink_dev_count)" = "0" ]; then
        stop
        exit 0
    fi
end script

script
    [ -r /etc/default/displaylink ] && . /etc/default/displaylink
    modprobe evdi || (dkms install \$(ls -t /usr/src | grep evdi | head -n1  | sed -e "s:-:/:") && modprobe evdi)
    exec /opt/displaylink/DisplayLinkManager
end script
EOF

  chmod 0644 /etc/init/displaylink-driver.conf
}

add_systemd_service()
{
  cat > /lib/systemd/system/displaylink-driver.service <<EOF
[Unit]
Description=DisplayLink Driver Service
After=display-manager.service
Conflicts=getty@tty7.service

[Service]
ExecStartPre=/bin/sh -c 'modprobe evdi || (dkms install \$(ls -t /usr/src | grep evdi | head -n1  | sed -e "s:-:/:") && modprobe evdi)'
ExecStart=/opt/displaylink/DisplayLinkManager
Restart=always
WorkingDirectory=/opt/displaylink
RestartSec=5

EOF

  chmod 0644 /lib/systemd/system/displaylink-driver.service
}

get_runit_sv_dir()
{
  local runit_dir=/etc/runit/sv
  [[ -d $runit_dir ]] || runit_dir=/etc/sv
  echo -n "$runit_dir"
}

get_runit_service_dir()
{
  local service_dir=/service
  local search_service_dir
  search_service_dir=$(pgrep -a runsvdir | sed -nE 's~^.*-P[[:space:]]+([^[:space:]]+).*$~\1~p')

  [[ -n $search_service_dir && -d $search_service_dir ]] \
    && service_dir=$search_service_dir
  echo -n "$service_dir"
}

add_runit_service()
{
  local runit_dir
  runit_dir=$(get_runit_sv_dir)
  local driver_name='displaylink-driver'
  mkdir -p "$runit_dir/$driver_name/log"

  cat > "$runit_dir/$driver_name/run" <<EOF
#!/bin/sh
set -e
cd /opt/displaylink
modprobe evdi || (dkms install "\$(ls -t /usr/src | grep evdi | head -n1  | sed -e "s:-:/:")" && modprobe evdi)
exec /opt/displaylink/DisplayLinkManager
EOF

cat > "$runit_dir/$driver_name/log/run" <<EOF
#!/bin/sh
exec svlogd -tt '$LOGSDIR'
EOF

  chmod -R 0755 "$runit_dir/$driver_name"

  local service_dir
  service_dir=$(get_runit_service_dir)
  touch "$runit_dir/displaylink-driver/down"
  ln -s "$runit_dir/displaylink-driver" "$service_dir"
}

remove_upstart_service()
{
  local driver_name="displaylink-driver"
  if grep -sqi displaylink /etc/init/dlm.conf; then
    driver_name="dlm"
  fi

  echo "Stopping displaylink-driver upstart job"
  stop "$driver_name"
  rm -f "/etc/init/$driver_name.conf"
}

remove_systemd_service()
{
  local driver_name="displaylink-driver"
  if grep -sqi displaylink /lib/systemd/system/dlm.service; then
    driver_name="dlm"
  fi
  echo "Stopping ${driver_name} systemd service"
  systemctl stop "$driver_name.service"
  systemctl disable "$driver_name.service"
  rm -f "/lib/systemd/system/$driver_name.service"
}

remove_runit_service()
{
  local runit_dir
  runit_dir=$(get_runit_sv_dir)
  local service_dir
  service_dir=$(get_runit_service_dir)
  local driver_name='displaylink-driver'

  echo "Stopping $driver_name runit service"
  sv stop "$driver_name"
  rm -f "$service_dir/$driver_name"
  # shellcheck disable=SC2115
  rm -rf "$runit_dir/$driver_name"
}

add_pm_script()
{
  cat > "$COREDIR/suspend.sh" << EOF
#!/usr/bin/env bash
# Copyright (c) 2015 - 2019 DisplayLink (UK) Ltd.

suspend_displaylink-driver()
{
  #flush any bytes in pipe
  while read -n 1 -t 1 SUSPEND_RESULT < /tmp/PmMessagesPort_out; do : ; done;

  #suspend DisplayLinkManager
  echo "S" > /tmp/PmMessagesPort_in

  if [[ -p /tmp/PmMessagesPort_out ]]; then
    #wait until suspend of DisplayLinkManager finish
    read -n 1 -t 10 SUSPEND_RESULT < /tmp/PmMessagesPort_out
  fi
}

resume_displaylink-driver()
{
  #resume DisplayLinkManager
  echo "R" > /tmp/PmMessagesPort_in
}

EOF

  if [[ $1 == "upstart" ]]
  then
    cat >> "$COREDIR/suspend.sh" << 'EOF'
case "$1" in
  thaw)
    resume_displaylink-driver
    ;;
  hibernate)
    suspend_displaylink-driver
    ;;
  suspend)
    suspend_displaylink-driver
    ;;
  resume)
    resume_displaylink-driver
    ;;
esac

EOF
  elif [[ $1 == "systemd" ]]
  then
    cat >> "$COREDIR/suspend.sh" << 'EOF'
main_systemd()
{
  case "$1/$2" in
  pre/*)
    suspend_displaylink-driver
    ;;
  post/*)
    resume_displaylink-driver
    ;;
  esac
}
main_pm()
{
  case "$1" in
    suspend|hibernate)
      suspend_displaylink-driver
      ;;
    resume|thaw)
      resume_displaylink-driver
      ;;
  esac
  true
}

DIR=$(cd "$(dirname "$0")" && pwd)

if [[ $DIR == *systemd* ]]; then
  main_systemd "$@"
elif [[ $DIR == *pm* ]]; then
  main_pm "$@"
fi

EOF
  elif [[ $1 == "runit" ]]
  then
    cat >> "$COREDIR/suspend.sh" << 'EOF'
case "$ZZZ_MODE" in
  noop)
    suspend_displaylink-driver
    ;;
  standby)
    suspend_displaylink-driver
    ;;
  suspend)
    suspend_displaylink-driver
    ;;
  hibernate)
    suspend_displaylink-driver
    ;;
  resume)
    resume_displaylink-driver
    ;;
  *)
    echo "Unknown ZZZ_MODE $ZZZ_MODE" >&2
    exit 1
    ;;
esac

EOF
  fi

  chmod 0755 "$COREDIR/suspend.sh"
  case $1 in
    upstart)
      ln -sf "$COREDIR/suspend.sh" /etc/pm/sleep.d/displaylink.sh
      ;;
    systemd)
      ln -sf "$COREDIR/suspend.sh" /lib/systemd/system-sleep/displaylink.sh
      [[ -d "/etc/pm/sleep.d" ]] && \
        ln -sf "$COREDIR/suspend.sh" /etc/pm/sleep.d/10_displaylink
      ;;
    runit)
      if [[ -d "/etc/zzz.d" ]]
      then
        ln -sf "$COREDIR/suspend.sh" /etc/zzz.d/suspend/displaylink.sh
        cat >> /etc/zzz.d/resume/displaylink.sh << EOF
#!/bin/sh
ZZZ_MODE=resume '$COREDIR/suspend.sh'
EOF
        chmod 0755 /etc/zzz.d/resume/displaylink.sh
      fi
      ;;
  esac
}

remove_pm_scripts()
{
  rm -f /etc/pm/sleep.d/displaylink.sh
  rm -f /etc/pm/sleep.d/10_displaylink
  rm -f /lib/systemd/system-sleep/displaylink.sh
  rm -f /etc/zzz.d/suspend/displaylink.sh /etc/zzz.d/resume/displaylink.sh
}

cleanup_logs()
{
  rm -rf "$LOGSDIR"
}

cleanup()
{
  rm -rf "$COREDIR"
  rm -f /usr/bin/displaylink-installer
  rm -f ~/.dl.xml
  rm -f /root/.dl.xml
  rm -f /etc/modprobe.d/evdi.conf
  rm -rf /etc/modules-load.d/evdi.conf
}

binary_location()
{
  if is_armv7; then
    echo "arm-linux-gnueabihf"
  elif is_armv8; then
     echo "aarch64-linux-gnu"
  else
    local PREFIX="x64"
    local POSTFIX="ubuntu-1604"

    is_32_bit && PREFIX="x86"
    echo "$PREFIX-$POSTFIX"
  fi
}

install_displaylink()
{
  local  scriptDir
  scriptDir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
  if [[ $scriptDir == "$COREDIR" ]]; then
    echo "DisplayLink driver is already installed"
    exit 1
  fi

  printf '\n%s\n' "Installing"

  install -d "$COREDIR" "$LOGSDIR"

  install "$SELF" "$COREDIR"
  ln -sf "$COREDIR/$(basename "$SELF")" /usr/bin/displaylink-installer

  echo "[ Installing EVDI ]"

  local temp_dir
  temp_dir=$(mktemp -d)
  finish() {
    rm -rf "$temp_dir"
  }
  trap finish EXIT

  local evdi_errors="$temp_dir/errors"
  local evdi_dir="$temp_dir/evdi"

  touch "$evdi_errors"
  mkdir "$evdi_dir"

  if ! install_evdi 'evdi.tar.gz' "$evdi_dir" "$evdi_errors"; then
    echo "ERROR: $(< "$evdi_errors")" >&2
    cleanup
    finish
    exit 1
  fi

  finish

  local BINS DLM LIBUSB_SO LIBUSB_PATH
  BINS=$(binary_location)
  DLM="$BINS/DisplayLinkManager"
  LIBUSB_SO="libusb-1.0.so.0.2.0"
  LIBUSB_PATH="$BINS/$LIBUSB_SO"

  install -m 0644 'evdi.tar.gz' "$COREDIR"

  echo "[ Installing $DLM ]"
  install "$DLM" "$COREDIR"

  echo "[ Installing libraries ]"
  install "$LIBUSB_PATH" "$COREDIR"
  ln -sf "$LIBUSB_SO" "$COREDIR/libusb-1.0.so.0"
  ln -sf "$LIBUSB_SO" "$COREDIR/libusb-1.0.so"

  echo "[ Installing firmware packages ]"
  install -m 0644 ./*.spkg "$COREDIR"

  echo "[ Installing licence file ]"
  install -m 0644 LICENSE "$COREDIR"
  if [[ -f 3rd_party_licences.txt ]]; then
    install -m 0644 3rd_party_licences.txt "$COREDIR"
  fi

  source udev-installer.sh
  local displaylink_bootstrap_script="$COREDIR/udev.sh"
  create_bootstrap_file "$SYSTEMINITDAEMON" "$displaylink_bootstrap_script"

  echo "[ Adding udev rule for DisplayLink DL-3xxx/4xxx/5xxx/6xxx devices ]"
  create_udev_rules_file /etc/udev/rules.d/99-displaylink.rules
  xorg_running || udevadm control -R
  xorg_running || udevadm trigger

  echo "[ Adding upstart and powermanager sctripts ]"
  case $SYSTEMINITDAEMON in
    upstart)
      add_upstart_script
      add_pm_script "upstart"
      ;;
    systemd)
      add_systemd_service
      add_pm_script "systemd"
      ;;
    runit)
      add_runit_service
      add_pm_script "runit"
      ;;
  esac

  xorg_running || trigger_udev_if_devices_connected

  xorg_running || "$displaylink_bootstrap_script" START

  printf '\n%s\n%s\n' "Please read the FAQ" \
        "http://support.displaylink.com/knowledgebase/topics/103927-troubleshooting-ubuntu"

  printf '\n%s\n\n%s\n' "Installation complete!" \
        "Please reboot your computer if you're intending to use Xorg."

  "$NOREBOOT" && exit 0

  xorg_running || exit 0
  prompt_yes_no "Xorg is running. Do you want to reboot now?" && reboot
  exit 0
}

uninstall()
{
  printf '\n%s\n\n' "Uninstalling"

  echo "[ Removing EVDI from kernel tree, DKMS, and removing sources. ]"

  local temp_dir
  temp_dir=$(mktemp -d)
  (
    cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && \
      uninstall_evdi_module "evdi.tar.gz" "$temp_dir"
  )
  rm -rf "$temp_dir"

  case $SYSTEMINITDAEMON in
    upstart)
      remove_upstart_service ;;
    systemd)
      remove_systemd_service ;;
    runit)
      remove_runit_service ;;
  esac

  echo "[ Removing suspend-resume hooks ]"
  remove_pm_scripts

  echo "[ Removing udev rule ]"
  rm -f /etc/udev/rules.d/99-displaylink.rules
  udevadm control -R
  udevadm trigger

  echo "[ Removing Core folder ]"
  cleanup
  cleanup_logs

  printf '\n%s\n' "Uninstallation steps complete."
  if [[ -f /sys/devices/evdi/version ]]; then
    echo "Please note that the evdi kernel module is still in the memory."
    echo "A reboot is required to fully complete the uninstallation process."
  fi
}

missing_requirement()
{
  echo "Unsatisfied dependencies. Missing component: $1." >&2
  echo "This is a fatal error, cannot install $PRODUCT." >&2
  exit 1
}

version_lt()
{
  local left
  left=$(echo "$1" | cut -d. -f-2)
  local right
  right=$(echo "$2" | cut -d. -f-2)

  local greater
  greater=$(printf '%s\n%s' "$left" "$right" | sort -Vr | head -1)

  [[ "$greater" != "$left" ]]
}

program_exists()
{
  command -v "${1:?}" >/dev/null
}

install_dependencies()
{
  program_exists apt || return 0
  install_dependencies_apt
}

check_installed()
{
  program_exists apt || return 0
  apt list -qq --installed "${1:?}" 2>/dev/null | sed 's:/.*$::' | grep -q -F "$1"
}

apt_ask_for_dependencies()
{
  apt --simulate install "$@" 2>&1 |  grep  "^E: " > /dev/null && return 1
  apt --simulate install "$@" | grep -v '^Inst\|^Conf'
}

apt_ask_for_update()
{
  echo "Need to update package list."
  prompt_yes_no "apt update?" || return 1
  apt update
}

install_dependencies_apt()
{
  local packages=()
  program_exists dkms || packages+=(dkms)

  for item in "${DEB_DEPENDENCIES[@]}"; do
    check_installed "$item" || packages+=("$item")
  done

  if [[ ${#packages[@]} -gt 0 ]]; then
    echo "[ Installing dependencies ]"

    if ! apt_ask_for_dependencies "${packages[@]}"; then
      # shellcheck disable=SC2015
      apt_ask_for_update && apt_ask_for_dependencies "${packages[@]}" || check_requirements
    fi

    prompt_command apt install -y "${packages[@]}" || check_requirements
  fi
}

perform_install_steps()
{
  install_dependencies
  check_requirements
  check_preconditions
  install_displaylink
}

install_and_save_log()
{
  local install_log_path="${LOGSDIR}/displaylink_installer.log"

  install -d "$LOGSDIR"

  perform_install_steps 2>&1 | tee -a "$install_log_path"
}

check_requirements()
{
  local missing=()
  program_exists dkms || missing+=("DKMS")

  for item in "${DEB_DEPENDENCIES[@]}"; do
    check_installed "$item" || missing+=("${item%-dev}")
  done

  [[ ${#missing[@]} -eq 0 ]] || missing_requirement "${missing[*]}"

  # Required kernel version
  local KVER
  KVER=$(uname -r)
  local KVER_MIN="4.15"
  version_lt "$KVER" "$KVER_MIN" && missing_requirement "Kernel version $KVER is too old. At least $KVER_MIN is required"

  # Linux headers
  [[ -d "/lib/modules/$KVER/build" ]] || missing_requirement "Linux headers for running kernel, $KVER"
}

usage()
{
  echo
  echo "Installs $PRODUCT, version $VERSION."
  echo "Usage: $SELF [ install | uninstall | noreboot | version ]"
  echo
  echo "The default operation is install."
  echo "If unknown argument is given, a quick compatibility check is performed but nothing is installed."
  exit 1
}

detect_init_daemon()
{
  local init
  init=$(readlink /proc/1/exe)

  if [[ $init == "/sbin/init" ]]; then
    init=$(/sbin/init --version)
  fi

  case $init in
    *upstart*)
      SYSTEMINITDAEMON="upstart" ;;
    *systemd*)
      SYSTEMINITDAEMON="systemd" ;;
    *runit*)
      SYSTEMINITDAEMON="runit" ;;
    *)
      echo "ERROR: the installer script is unable to find out how to start DisplayLinkManager service automatically on your system." >&2
      echo "Please set an environment variable SYSTEMINITDAEMON to 'upstart', 'systemd' or 'runit' before running the installation script to force one of the options." >&2
      echo "Installation terminated." >&2
      exit 1
  esac
}

detect_distro()
{
  if hash lsb_release 2>/dev/null; then
    echo -n "Distribution discovered: "
    lsb_release -d -s
  else
    echo "WARNING: This is not an officially supported distribution." >&2
    echo "Please use DisplayLink Forum for getting help if you find issues." >&2
  fi
}

xorg_running()
{
  local SESSION_NO
  SESSION_NO=$(loginctl | awk "/$(logname)/ {print \$1; exit}")
  [[ $(loginctl show-session "$SESSION_NO" -p Type) == *=x11 ]]
}

check_preconditions()
{
  if [[ -f /sys/devices/evdi/version ]]; then
    local V
    V=$(< /sys/devices/evdi/version)

    echo "WARNING: Version $V of EVDI kernel module is already running." >&2
    if [[ -d $COREDIR ]]; then
      echo "Please uninstall all other versions of $PRODUCT before attempting to install." >&2
    else
      echo "Please reboot before attempting to re-install $PRODUCT." >&2
    fi
    echo "Installation terminated." >&2
    exit 1
  fi
}

if [[ $(id -u) != "0" ]]; then
  echo "You need to be root to use this script." >&2
  exit 1
fi

[[ -z $SYSTEMINITDAEMON ]] && detect_init_daemon || echo "Trying to use the forced init system: $SYSTEMINITDAEMON"
detect_distro

while [[ $# -gt 0 ]]; do
  case "$1" in
    install)
      ACTION="install"
      ;;

    uninstall)
      ACTION="uninstall"
      ;;
    noreboot)
      NOREBOOT=true
      ;;
    version)
      ACTION="version"
      ;;
    *)
      usage
      ;;
  esac
  shift
done

case "$ACTION" in
  install)
    install_and_save_log
    ;;

  uninstall)
    check_requirements
    uninstall
    ;;

  version)
    echo "$PRODUCT $VERSION"
    ;;
esac
