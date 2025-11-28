#!/bin/bash
# vim: tabstop=2 shiftwidth=2 expandtab softtabstop=2

VERSION="1.0.1"

# Fail if one process fails in a pipe
set -o pipefail

#Executables
INCUS="/usr/bin/incus"
MAIL="/usr/bin/mail"
INCUS_DEFAULT_BACKUP_DIR="/var/lib/incus/backups"

#Variables
HOSTNAME=$(hostname)
ADMIN="monitoring@example.com"
NFS_SERVER="TOSET"
INCUS_LIST="state=running"
BACKUP_LOCAL_ROOT_DIR="TOSET"
#Do not have NFS_REMOTE_ROOT_DIR end with a "/"
NFS_REMOTE_ROOT_DIR="/path/TOSET/$HOSTNAME"
BACKUP_LOCAL_TEMP_DIR="$BACKUP_LOCAL_ROOT_DIR/temp_backups/backups/"

START_TIME=$(date +%Y%m%d.%H%M%S)
LOG_FILE="/tmp/incus_export_to_remote.$START_TIME.txt"

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=export_incus_to_remote.env
if ! source "$SCRIPT_DIR/export_incus_to_remote.env"; then
  echo "Error: Can not find export_incus_to_remote.env file"
  exit 1
fi

#get the actual backup location
INCUS_BACKUP_PATH=$(realpath $INCUS_DEFAULT_BACKUP_DIR)

#
# #Functions:
# Output: Formatted Message String
# Return: 0 on success, non 0 otherwise
function print_v() {
  local level=$1
  THIS_DATE=$(date --iso-8601=seconds)

  case $level in
    d) # Debug
    echo -e "$THIS_DATE [DBUG] ${*:2}"
    ;;
    e) # Error
    echo -e "$THIS_DATE [ERRS] ${*:2}"
    ;;
    w) # Warning
    echo -e "$THIS_DATE [WARN] ${*:2}"
    ;;
    *) # Any other level
    echo -e "$THIS_DATE [INFO] ${*:2}"
    ;;
  esac
}



# return 0 if program version is equal or greater than check version
function check_version()
{
    local version=$1 check=$2
    local winner=

    winner=$(echo -e "$version\n$check" | sed '/^$/d' | sort -Vr | head -1)
    [[ "$winner" = "$version" ]] && return 0
    return 1
}

function incus_version() {
  $INCUS version | awk '/Server version: / { print $3}'
}

# Dependencies check
function dependencies_check() {
   local _ret=0
   local version=

   if [ ! -x "$INCUS" ]; then
      print_v e "'$INCUS' cannot be found or executed"
      _ret=1
   fi

   if [ ! -x "$MAIL" ]; then
      print_v e "'$MAIL' cannot be found or executed"
      _ret=1
   fi

   version=$(incus_version)
   if check_version "$version" '6.18'; then
      if check_version "$version" '1.0.0'; then
         print_v d "incus version '$version' is supported"
      fi
   else
      print_v e "Detected incus version '$version'. Please use incus 6.18 or later"
      _ret=2
   fi

  # Root needed for a few operations.
  if [[ $EUID -ne 0 ]]; then
     print_v e "This script must be run as root: $HOSTNAME" | tee -a "$LOG_FILE"
     _ret=2
  fi

   return $_ret
}

#Return 0 (true) if is running, Return 1 (false) if not running
function is_incus_export_running() {
  if ! INCUSD_PID=$(pgrep -f incusd); then
    print_v e "Can't find incusd process_id. Exiting"
    pgrep -f incusd
    exit 1
  fi

  #There should be only one PID, but let's not assume
  for PID in $INCUSD_PID; do
    print_v d "INCUS_PID=$PID"
    if lsof -p "$PID" | grep "$INCUS_BACKUP_PATH"; then
      return 0
    else
      print_v d "INCUS_PID=$PID: No Backup Running"
      return 1
    fi
  done
}

function restore_incus_backups_dir() {
  #at end of this unmount NFS dir and set all back
  if is_incus_export_running; then
    print_v w "Export still running? It shouldn't be at this point."
    sleep 5
  fi
  if is_incus_export_running; then
    print_v w "Export still running? It shouldn't be at this point."
    read -rp "pausing for human intervention"
    exit 1
  fi
  # remove link to backup NFS dir
  if [ -L $INCUS_DEFAULT_BACKUP_DIR ]; then
    print_v d "Removing softlink"
    rm $INCUS_DEFAULT_BACKUP_DIR;
  else
    print_v e "Something is wrong. Expected softlink for $INCUS_DEFAULT_BACKUP_DIR"
    exit 1
  fi
  # Restoring old link or dir for incus
  if [ ! -e $INCUS_DEFAULT_BACKUP_DIR ]; then
    mv /var/lib/incus/backups.bak $INCUS_DEFAULT_BACKUP_DIR
  fi
}

#Check if dependencies are ok
if ! dependencies_check; then
  print_v e "Dependencies Check failed"
  exit 3
fi

if [[ $NFS_SERVER == "TOSET" ]]; then
  print_v e "See .env file and set variables"
  exit 1
elif [[ $DEBUG == 1 ]]; then
  print_v d "ADMIN=$ADMIN"
  print_v d "NFS_SERVER=$NFS_SERVER"
  print_v d "BACKUP_LOCAL_ROOT_DIR=$BACKUP_LOCAL_ROOT_DIR"
  print_v d "NFS_REMOTE_ROOT_DIR=$NFS_REMOTE_ROOT_DIR"
fi


if [ -n "$STY" ]; then
  print_v d "Running in a screen session."
else
  print_v w "Not running in a screen session. Could be a problem if diconnected"
  read -rp "press enter key to continue"
fi


if is_incus_export_running; then
  print_v e "Do not run this script while an export is already running. Exiting."
  exit 1
else
  print_v d "No other export is running."
fi

#check to make sure this is a network mounted location
if ! mountpoint -q $BACKUP_LOCAL_ROOT_DIR; then
  print_v d "Not a mountpoint, mounting" | tee -a "$LOG_FILE"
  mount -t nfs4 "$NFS_SERVER:$NFS_REMOTE_ROOT_DIR" $BACKUP_LOCAL_ROOT_DIR
fi

#did that mount succeed? One more test.
if ! mountpoint -q $BACKUP_LOCAL_ROOT_DIR; then
  print_v e  "FAIL: $HOSTNAME: NFS connect to $NFS_SERVER failed"| tee -a "$LOG_FILE"
  $MAIL $ADMIN -s "FAIL: $HOSTNAME: NFS connect to $NFS_SERVER failed"  < "$LOG_FILE"
  exit 1
fi

#move incus directory or softlink to backup location
if [ ! -e /var/lib/incus/backups.bak ] && mv $INCUS_DEFAULT_BACKUP_DIR /var/lib/incus/backups.bak; then
  print_v d "move of backups dir $INCUS_DEFAULT_BACKUP_DIR link ok"
else
  print_v e "failure in moving backups dir to /var/lib/incus/backups.bak"
  exit 1
fi

#read -rp "move done: Pausing for human checks"

if ln -s $BACKUP_LOCAL_TEMP_DIR $INCUS_DEFAULT_BACKUP_DIR; then
  print_v d "softlink creation ok"
  #read -rp "softlink done: pausing for human checks"
else
  print_v e "failure in creation of softlink undoing mv"
  if [ -L $INCUS_DEFAULT_BACKUP_DIR ]; then
    print_v d "Removing softlink"
    rm $INCUS_DEFAULT_BACKUP_DIR;
  else
    print_v e "Something is wrong. Expected softlink for $INCUS_DEFAULT_BACKUP_DIR"
    exit 1
  fi
  if [ -e /var/lib/incus/backups.bak ]; then
    mv /var/lib/incus/backups.bak $INCUS_DEFAULT_BACKUP_DIR
  else
    print_v e "Can't move /var/lib/incus/backups.bak back to $INCUS_DEFAULT_BACKUP_DIR"
  fi
    exit 1
fi

print_v i "Starting Incus Exports $(date) using backup version $VERSION"  > "$LOG_FILE"

ROOT_DIR="$BACKUP_LOCAL_ROOT_DIR/$HOSTNAME".incus_export

#How many full exports to keep
END=2
TERM=$((END+1))


#print_v e $ROOT_DIR
#exit

#check to make sure this is a location that is ok.
if [ ! -d "$ROOT_DIR" ]; then
  if ! mkdir -p "$ROOT_DIR"; then
    print_v e "FAIL: Creation of $ROOT_DIR failed" | tee -a "$LOG_FILE"
    $MAIL $ADMIN -s "$HOSTNAME: NFS connect to $NFS_SERVER failed" < /etc/cron.d/backups
    exit 1
  fi
fi

#$MAIL $ADMIN -s "backup starting" < /etc/cron.d/backups

#for INSTANCE in $(incus list state=RUNNING -c n -f csv); do
#$INCUS list state=RUNNING -c nD -f csv | sed -e /Calmail/d | while IFS=',' read -r INSTANCE SIZE; do
#$INCUS list name=Calmail101 -c nD -f csv | while IFS=',' read -r INSTANCE SIZE; do
$INCUS list "$INCUS_LIST" -c nD -f csv | while IFS=',' read -r INSTANCE SIZE; do

  print_v d "Todo: check if size $SIZE for $INSTANCE is ok"

  #Iterate Backup Dir. mv name.2 to name.3 and name.1 to name.2, etc. 
  for i in $(seq $END -1 0); do
    if [ -d "$ROOT_DIR/$INSTANCE.$i" ]; then
      NEXT=$((i+1))
      mv "$ROOT_DIR/$INSTANCE.$i" "$ROOT_DIR/$INSTANCE.$NEXT"
    fi
  done
  if [ -d "$ROOT_DIR/$INSTANCE.$TERM" ]; then
    rm -r "$ROOT_DIR/$INSTANCE.$TERM"
  fi

  #Check if .0 directory exists and if not create it
  if [ ! -d "/$ROOT_DIR/$INSTANCE.0" ] ; then
    print_v d "CREATING $ROOT_DIR/$INSTANCE.0"
    if ! mkdir -p "$ROOT_DIR/$INSTANCE.0"; then
      print_v e "Creating directory failed: $HOSTNAME"
      restore_incus_backups_dir
      exit 1
    fi
  fi

  print_v i "Exporting $INSTANCE to $ROOT_DIR/$INSTANCE.0/$INSTANCE.tgz"  | tee -a "$LOG_FILE"
  if $INCUS export --optimized-storage --instance-only "$INSTANCE" "$ROOT_DIR/$INSTANCE.0/$INSTANCE.tgz" ; then
    print_v i "Success Exporting $INSTANCE" | tee -a "$LOG_FILE"
  else
    print_v e "FAIL: Export of $INSTANCE failed" | tee -a "$LOG_FILE"
    restore_incus_backups_dir
    exit 1
  fi


done
print_v i "Success: $HOSTNAME exports done" "$ADMIN" | tee -a "$LOG_FILE"
$MAIL -s "Success: $HOSTNAME exports done" "$ADMIN" < "$LOG_FILE"

#need to have ssh key-pair setup to get rsync-via-ssh to be enabled, note trailing / is very important
#rsync -n -i -e ssh  -av  /srv/backups/$OBJECT/ backup_user@backup_server.example.com:~/server2/$OBJECT/
#rsync -n -i -e ssh  -av  /srv/backups/$OBJECT backup_user@backup_server.example.com:~/server2/

restore_incus_backups_dir

umount "$BACKUP_LOCAL_ROOT_DIR"
print_v d "Finished with export"
exit 0

