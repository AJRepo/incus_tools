#!/bin/bash
# vim: tabstop=2 shiftwidth=2 expandtab softtabstop=2

VERSION="2.0.0"

# Fail if one process fails in a pipe
set -o pipefail

#Executables
INCUS="/usr/bin/incus"
MAIL="/usr/bin/mail"

#INCUS DEFAULTS
INCUS_CORE="/var/lib/incus"
INCUS_DEFAULT_BACKUP_DIR="/var/lib/incus/backups"
PROMPT_FOR_CONF=0

#Default Variables (see .env file for overrrides)
DRY_RUN=''
SEND_MAIL=''
INCUS_FULL=0
#How many full exports (e.g. backups) to keep
EXPORTS_TO_KEEP=2
#Remote Backup Method: (nfs only now, rsync over ssh later)
BACKUP_METHOD="nfs"
INCUS_ARGS=(--optimized-storage --instance-only)
HOSTNAME=$(hostname)
ADMIN="monitoring@example.com"
REMOTE_SERVER="ip.x.x.x"
INCUS_LIST="state=running"
BACKUP_LOCAL_ROOT_DIR="TOSET"
#Do not have NFS_REMOTE_ROOT_DIR end with a "/"
NFS_REMOTE_ROOT_DIR="/path/TOSET/$HOSTNAME"
BACKUP_LOCAL_TEMP_DIR="$BACKUP_LOCAL_ROOT_DIR/temp_backups/backups/"

START_TIME=$(date +%Y%m%d.%H%M%S)
LOG_FILE="/tmp/incus_export_to_remote.$START_TIME.txt"

SCRIPT_DIR=$(dirname "$0")
# shellcheck disable=SC1091
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
      if [[ $DEBUG == "1" ]]; then
        echo -e "$THIS_DATE [DBUG] ${*:2}"
      fi
    ;;
    e) # Error
    echo -e "$THIS_DATE [ERRS] ${*:2}"
    ;;
    f) # Error
    echo -e "$THIS_DATE [FAIL] ${*:2}"
    ;;
    w) # Warning
    echo -e "$THIS_DATE [WARN] ${*:2}"
    ;;
    *) # Any other level
    echo -e "$THIS_DATE [INFO] ${*:2}"
    ;;
  esac
}

#Start and initialize log file
print_v i "Starting Incus Exports $(date) using backup version $VERSION"  > "$LOG_FILE"

function print_usage() {
  cat <<EOM
  $0 version $VERSION - Afan Ottenheimer (https://github.com/AJRepo/incus_tools)

  Usage:

     $0 [-h] [-d] [-F] [-m] [-t mount_type] [-n] [-v] [-l incus_list ]

     Options:
        -h                help

        -d                debug

        -F                Backup the directory $INCUS_CORE (see variable \$INCUS_CORE)

        -l <incus_list>   list of items to export. Defaults to 'state=running'
                          note: If you only want to backup /var/lib/incus and not
                          any containers use '-F -l state=none'


        -m                Send email reports

        -n                dry run (do not export or iterate backups)

        -p                Pause between steps for a prompt or Ctrl-C

        -v                pass '--verbose' to incus export command

       Options soon to be released:

        -t <mount_type>   mount_type can be nfs, fstab, or none
                          nfs = "mount -t nfs4 ...." and unmount afterwards
                          fstab = "mount \$BACKUP_LOCAL_ROOT_DIR" (Default = $BACKUP_LOCAL_ROOT_DIR)
                          none = Do no mounting or unmounting. Use \$BACKUP_LOCAL_ROOT_DIR:$BACKUP_LOCAL_ROOT_DIR


    Version Requirements:
      incus >= 6.19 (if using the check size before export functionality)

EOM
}

while getopts "Fdhmnlpv:" opt; do
  case "${opt}" in
  F)
    INCUS_FULL=1
    ;;
  d)
    DEBUG=1
    INCUS_ARGS+=(--verbose)
    ;;
  h | \?)
    print_usage
    exit 1
    ;;
  l)
    INCUS_LIST=${OPTARG}
    ;;
  m)
    SEND_MAIL=1
    ;;
  n)
    DRY_RUN=1
    ;;
  p)
    PROMPT_FOR_CONF=1
    ;;
  v)
    INCUS_ARGS+=(--verbose)
    ;;
  esac
done

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

# function: inside_screen. Tests to see if we are in a screen.
# We can't rely on $STY because sudo strips variables.
inside_screen() {
  print_v d "Testing to see if in a screen"
  pid=$$
  while [ "$pid" -ne 1 ]; do
      # Get the command name of this pid
      comm=$(ps -o comm= -p "$pid" | tr -d '[:space:]')
      if [ "$comm" = "screen" ]; then
          print_v d "Inside screen"
          return 0
      fi

      # Get the parent pid, strip whitespace, default to 1 if empty
      ppid=$(ps -o ppid= -p "$pid" | tr -d '[:space:]')
      [ -z "$ppid" ] && ppid=1
      pid=$ppid
  done

  print_v d "Not inside screen"
  return 1
}


# Dependencies check
function dependencies_check() {
   local _ret=0
   local version=

   if [ ! -x "$INCUS" ]; then
     print_v e "'$INCUS' cannot be found or executed"
     _ret=1
   fi

   if [[ ! -x "$MAIL" && $SEND_MAIL -eq 1 ]]; then
     print_v e "'$MAIL' cannot be found or executed"
     print_v e "Either install $MAIL or disable sending mail"
     _ret=1
   fi

   version=$(incus_version)
   if check_version "$version" '6.19'; then
     print_v d "Detected incus version '$version'. Incus>=6.19 supports checking for backup disk space."
     SUPPORTS_DISK_CHECK=1
     LIST_FORMAT="csv,raw"
   else
     print_v e "Detected incus version '$version'. Please use incus 6.19 or later to check backup disk space."
     SUPPORTS_DISK_CHECK=0
     LIST_FORMAT="csv"
   fi

  if [[ $BACKUP_METHOD != "nfs" ]]; then
    print_v e "Only NFS for a backup method is currently supported"
  fi

  if [[ $REMOTE_SERVER == "ip.x.x.x" ]]; then
    print_v e "REMOTE_SERVER is not set. See .env file and set variables"
    _ret=2
  fi


  # Root needed for a few operations.
  if [[ $EUID -ne 0 ]]; then
    print_v e "Depencency check fail: This script must be run as root: HOSTNAME='$HOSTNAME'" | tee -a "$LOG_FILE"
    _ret=2
  fi
    return $_ret
}

#Return 0 (true) if is running, Return 1 (false) if not running
function is_incus_export_running() {
  if ! INCUSD_PID=$(pgrep -f incusd); then
    print_v f "Can't find incusd process_id. Exiting"
    pgrep -f incusd
    exit 1
  fi

  #There should be only one PID, but let's not assume
  for PID in $INCUSD_PID; do
    print_v d "Found INCUS_PID=$PID"
    if lsof -p "$PID" | grep "$INCUS_BACKUP_PATH"; then
      return 0
    else
      print_v d "Checking INCUS_PID=$PID: No Backup Running"
      return 1
    fi
  done
}

function restore_incus_backups_dir() {
  #at end of this unmount NFS dir and set all back
  if is_incus_export_running; then  #return 0 (yes) if it is still running
    print_v w "Export still running? It shouldn't be at this point."
    sleep 5
    if is_incus_export_running; then
      print_v w "Export still running? It shouldn't be at this point."
      read -rp "pausing for human intervention. Will run exit with any key."
      exit 1
    fi
  else
    print_v d "Incus Export completed. Moving forward"
  fi
  # remove link to backup NFS dir
  if [ -L $INCUS_DEFAULT_BACKUP_DIR ]; then
    print_v d "$INCUS_DEFAULT_BACKUP_DIR is a softlink. Removing softlink"
    rm $INCUS_DEFAULT_BACKUP_DIR;
  else
    print_v f "Something is wrong. Expected softlink for $INCUS_DEFAULT_BACKUP_DIR"
    exit 1
  fi
  # Restoring old link or dir for incus
  if [ ! -e $INCUS_DEFAULT_BACKUP_DIR ]; then
    print_v d "Restoring $INCUS_CORE/backups.bak to $INCUS_DEFAULT_BACKUP_DIR"
    mv "$INCUS_CORE/backups.bak" $INCUS_DEFAULT_BACKUP_DIR
  fi
}

function backup_incus_core() {
  print_v d "Backing up $INCUS_CORE to $ROOT_DIR"
  if [ -f /etc/subuid ]; then
    BACKUP_CORE_FILES=(/etc/subuid /etc/subgid "$INCUS_CORE")
  else
    BACKUP_CORE_FILES=("$INCUS_CORE")
  fi
  print_v d "Running: tar --exclude $INCUS_CORE/backups -zcf $ROOT_DIR/var_lib_incus.tmp.tgz" "${BACKUP_CORE_FILES[@]}"
  print_v i "Running: tar --exclude $INCUS_CORE/backups -zcf $ROOT_DIR/var_lib_incus.tmp.tgz" "${BACKUP_CORE_FILES[@]}" >> "$LOG_FILE"
  tar --exclude "$INCUS_CORE/backups" -zcf "$ROOT_DIR/var_lib_incus.tmp.tgz" "${BACKUP_CORE_FILES[@]}" 2> /tmp/tar_error.log
  TAR_EXIT=$?
  if [[ $TAR_EXIT != 0 ]]; then
    #tar can return 1 if some files change while being backed up.
    print_v w "Tar exited with value $TAR_EXIT on backup full incus $INCUS_CORE. Continuing"
    $MAIL $ADMIN -s "$HOSTNAME: tar $INCUS_CORE had non-zero status $TAR_EXIT" < /tmp/tar_error.log
  fi
  if [ -f "$ROOT_DIR/var_lib_incus.tmp.tgz" ]; then
    #mv tmp file to overwrite last backup
    mv "$ROOT_DIR/var_lib_incus.tmp.tgz" "$ROOT_DIR/var_lib_incus.tgz"
    print_v d "Success: Backed up $INCUS_CORE (excluding $INCUS_CORE/backups) to $ROOT_DIR"
  fi
  return 0
}

#Check if dependencies are ok
if ! dependencies_check; then
  print_v f "Some Dependency Checks failed. See above messages for more info."
  exit 3
fi

if [[ $DEBUG == 1 ]]; then
  print_v d "Dependencies Check passed:"
  print_v d "  ADMIN=$ADMIN"
  print_v d "  REMOTE_SERVER=$REMOTE_SERVER"
  print_v d "  Local Mountpoint: BACKUP_LOCAL_ROOT_DIR=$BACKUP_LOCAL_ROOT_DIR"
  print_v d "  Remote Server: NFS_REMOTE_ROOT_DIR=$NFS_REMOTE_ROOT_DIR"
fi

if inside_screen; then
  print_v d "Running in a screen session: '$STY'"
  print_v i "Screen Name = '$STY'" | tee -a "$LOG_FILE"
  if [[ $SEND_MAIL == 1 ]]; then
    $MAIL -s "Starting Incus backup: $HOSTNAME screen: $STY" "$ADMIN" < "$LOG_FILE"
  fi
else
  if tty -s; then
    print_v w "Interactive shell and not running in a screen session! Could be a problem if diconnected."
    print_v w "About to backup $INCUS_LIST"
    read -rp "press enter key to continue. Press Ctrl-C to exit."
  fi
fi

if is_incus_export_running; then
  print_v f "Do not run this script while an export is already running. Exiting."
  exit 1
else
  print_v d "No other export is running."
fi

#check to make sure this is a network mounted location
if ! mountpoint -q $BACKUP_LOCAL_ROOT_DIR; then
  print_v d "Not a mountpoint, mounting" | tee -a "$LOG_FILE"
  if [[ $PROMPT_FOR_CONF == 1 ]]; then
    read -rp "Pausing: Press Ctrl-C to stop. Enter to continue."
  fi
  mount -t nfs4 "$REMOTE_SERVER:$NFS_REMOTE_ROOT_DIR" $BACKUP_LOCAL_ROOT_DIR
fi

#did that mount succeed? One more test.
if ! mountpoint -q $BACKUP_LOCAL_ROOT_DIR; then
  print_v f  "FAIL: $HOSTNAME: NFS connect to $REMOTE_SERVER failed"| tee -a "$LOG_FILE"
  $MAIL $ADMIN -s "FAIL: $HOSTNAME: NFS connect to $REMOTE_SERVER failed"  < "$LOG_FILE"
  exit 1
fi

#move incus directory or softlink to backup location
if [ ! -e $INCUS_CORE/backups.bak ] && mv $INCUS_DEFAULT_BACKUP_DIR $INCUS_CORE/backups.bak; then
  print_v d "move of backups dir $INCUS_DEFAULT_BACKUP_DIR link ok"
else
  print_v f "failure in moving backups dir to $INCUS_CORE/backups.bak"
  exit 1
fi

if [[ $PROMPT_FOR_CONF == 1 ]]; then
  read -rp "Pausing after 'mv backups backups.bak' : Press Ctrl-C to stop. If you stop, move that dir back"
fi

if ln -s $BACKUP_LOCAL_TEMP_DIR $INCUS_DEFAULT_BACKUP_DIR; then
  print_v d "softlink creation ok"
  #read -rp "softlink done: pausing for human checks"
else
  print_v e "failure in creation of softlink undoing mv"
  if [ -L $INCUS_DEFAULT_BACKUP_DIR ]; then
    print_v d "Removing softlink"
    rm $INCUS_DEFAULT_BACKUP_DIR;
  else
    print_v f "Something is wrong. Expected softlink for $INCUS_DEFAULT_BACKUP_DIR"
    exit 1
  fi
  if [ -e $INCUS_CORE/backups.bak ]; then
    mv $INCUS_CORE/backups.bak $INCUS_DEFAULT_BACKUP_DIR
  else
    print_v f "Can't move $INCUS_CORE/backups.bak back to $INCUS_DEFAULT_BACKUP_DIR"
    exit 1
  fi
fi

SPACE_REMAINING=$(df --output=avail -B1 $BACKUP_LOCAL_ROOT_DIR | tail -1)
SPACE_REMAINING_PRETTY=$(df --output=avail -h $BACKUP_LOCAL_ROOT_DIR | tail -1)
print_v i "Space remaining on $BACKUP_LOCAL_ROOT_DIR: $SPACE_REMAINING_PRETTY" >> "$LOG_FILE"
print_v d "Space remaining on $BACKUP_LOCAL_ROOT_DIR: $SPACE_REMAINING_PRETTY"

ROOT_DIR="$BACKUP_LOCAL_ROOT_DIR/$HOSTNAME".incus_export

TERM=$((EXPORTS_TO_KEEP+1))

#print_v e $ROOT_DIR
#exit

#check to make sure this is a location that is ok.
if [ ! -d "$ROOT_DIR" ]; then
  if ! mkdir -p "$ROOT_DIR"; then
    print_v f "FAIL: Creation of $ROOT_DIR failed" | tee -a "$LOG_FILE"
    $MAIL $ADMIN -s "$HOSTNAME: NFS connect to $REMOTE_SERVER failed" < "$LOG_FILE"
    exit 1
  fi
fi

if [[ $PROMPT_FOR_CONF == 1 ]]; then
  read -rp "Pausing before exports and core backup. Press Ctrl-C to stop."
fi

#Incus Full Backup to include Incus core directory
if [[ "$INCUS_FULL" == 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    print_v i "-F called but also -n, Dry Run: Not backing up $INCUS_CORE"
  else
    backup_incus_core
  fi
fi

if [[ $PROMPT_FOR_CONF == 1 ]]; then
  read -rp "Core backup done. Pausing before exports. Press Ctrl-C to stop."
fi

#$MAIL $ADMIN -s "backup starting" < /etc/cron.d/backups

#for INSTANCE in $(incus list state=RUNNING -c n -f csv); do
#for INSTANCE in $(incus list state=RUNNING -c n -f csv,raw); do

while IFS=',' read -r INSTANCE SIZE; do
  #While loop over above line
  print_v d "DRY_RUN='$DRY_RUN'"
  if [[ $SUPPORTS_DISK_CHECK == "1" ]]; then
    SPACE_REMAINING=$(df --output=avail -B1 $BACKUP_LOCAL_ROOT_DIR | tail -1)
    print_v d "Check if size $INSTANCE ($SIZE) is ok for $BACKUP_LOCAL_ROOT_DIR ($SPACE_REMAINING)"
    #Set a buffer of 10 Gigs
    BUFFER=10000000
    AVAIL=$((SPACE_REMAINING - BUFFER - SIZE))
    if [ $AVAIL -lt 0 ]; then
      print_v f "Can't back up because remaining-buffer-size ($AVAIL) is less than 0 for instance of size=$SIZE"
      exit 1
    else
      print_v d "Disk check: Sufficient space on $BACKUP_LOCAL_ROOT_DIR ($SPACE_REMAINING) for $INSTANCE ($SIZE)"
    fi
  else
    print_v d "Use incus 6.19 or later for backup location disk space checks vs size of backup"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    print_v v "Dry run called: Not doing anything with $INSTANCE of size $SIZE"
  else
    #Iterate Backup Dir. mv name.2 to name.3 and name.1 to name.2, etc.
    for i in $(seq $EXPORTS_TO_KEEP -1 0); do
      if [ -d "$ROOT_DIR/$INSTANCE.$i" ]; then
        NEXT=$((i+1))
        PREVIOUS=$((i-1))
        #don't archive an empty directory
        if [ -d  "$ROOT_DIR/$INSTANCE.$PREVIOUS" ] && [ -z "$(ls -A "$ROOT_DIR/$INSTANCE.$PREVIOUS")" ]; then
          print_v d "Skipping mv of $ROOT_DIR/$INSTANCE.$i since nothing in $ROOT_DIR/$INSTANCE.$PREVIOUS"
        else
          print_v d "mv $ROOT_DIR/$INSTANCE.$i" "$ROOT_DIR/$INSTANCE.$NEXT"
          mv "$ROOT_DIR/$INSTANCE.$i" "$ROOT_DIR/$INSTANCE.$NEXT"
        fi
      fi
    done
    if [ -d "$ROOT_DIR/$INSTANCE.$TERM" ]; then
      rm -r "$ROOT_DIR/$INSTANCE.$TERM"
    fi

    #Check if .0 directory exists and if not create it
    if [ ! -d "/$ROOT_DIR/$INSTANCE.0" ] ; then
      print_v d "CREATING $ROOT_DIR/$INSTANCE.0"
      if ! mkdir -p "$ROOT_DIR/$INSTANCE.0"; then
        print_v f "Creating directory failed: $HOSTNAME"
        restore_incus_backups_dir
        if [[ $SEND_MAIL == 1 ]]; then
          $MAIL -s "FAIL: $HOSTNAME incus export ceating $ROOT_DIR for $INSTANCE" "$ADMIN" < "$LOG_FILE"
        fi
        exit 1
      fi
    fi

    print_v i "Exporting $INSTANCE to $ROOT_DIR/$INSTANCE.0/$INSTANCE.tgz"  | tee -a "$LOG_FILE"
    print_v i "Command: $INCUS export $INSTANCE $ROOT_DIR/$INSTANCE.0/$INSTANCE.tgz" "${INCUS_ARGS[@]}"
    if $INCUS export "$INSTANCE" "$ROOT_DIR/$INSTANCE.0/$INSTANCE.tgz" "${INCUS_ARGS[@]}"; then
      print_v i "Success Exporting $INSTANCE" | tee -a "$LOG_FILE"
    else
      print_v e "FAIL: The export of $INSTANCE failed" | tee -a "$LOG_FILE"
      print_v d "Restoring incus backup dir"
      if [[ $SEND_MAIL == 1 ]]; then
        $MAIL -s "FAIL: $HOSTNAME incus export $INSTANCE" "$ADMIN" < "$LOG_FILE"
      fi
      restore_incus_backups_dir
      exit 1
    fi

  fi
done < <($INCUS list "$INCUS_LIST" -c nD --format="$LIST_FORMAT")
print_v i "Success: All $HOSTNAME exports done" "$ADMIN" | tee -a "$LOG_FILE"
SPACE_REMAINING=$(df --output=avail -B1 $BACKUP_LOCAL_ROOT_DIR | tail -1)
SPACE_REMAINING_PRETTY=$(df --output=avail -h $BACKUP_LOCAL_ROOT_DIR | tail -1)
print_v d "Space remaining on $BACKUP_LOCAL_ROOT_DIR: $SPACE_REMAINING"
print_v i "Space remaining on $BACKUP_LOCAL_ROOT_DIR: $SPACE_REMAINING_PRETTY" >> "$LOG_FILE"

if [[ $SEND_MAIL == 1 ]]; then
  $MAIL -s "Success: All $HOSTNAME exports done" "$ADMIN" < "$LOG_FILE"
fi
#need to have ssh key-pair setup to get rsync-via-ssh to be enabled, note trailing / is very important
#rsync -n -i -e ssh  -av  /srv/backups/$OBJECT/ backup_user@backup_server.example.com:~/server2/$OBJECT/
#rsync -n -i -e ssh  -av  /srv/backups/$OBJECT backup_user@backup_server.example.com:~/server2/

restore_incus_backups_dir

umount "$BACKUP_LOCAL_ROOT_DIR"
print_v d "Finished with exports"
exit 0

