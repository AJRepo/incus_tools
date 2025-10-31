#!/bin/bash
#set -x

DEBUG=1

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

#Variables
HOSTNAME=$(hostname)
ADMIN="monitoring@example.com"
NFS_SERVER="TOSET"
BACKUP_LOCAL_ROOT_DIR="TOSET"
#Do not have NFS_REMOTE_ROOT_DIR end with a "/"
NFS_REMOTE_ROOT_DIR="/path/TOSET/$HOSTNAME"

LOG_FILE="/tmp/last_incus_export.txt"

if ! source ./export_incus_to_NFS.env; then
	echo "Can't find .env file"
	exit 1
fi


if [[ $NFS_SERVER == "TOSET" ]]; then
	echo "See .env file and set variables"
	exit 1
elif [[ $DEBUG == 1 ]]; then
	print_v d "ADMIN=$ADMIN"
	print_v d "NFS_SERVER=$NFS_SERVER"
	print_v d "BACKUP_LOCAL_ROOT_DIR=$BACKUP_LOCAL_ROOT_DIR"
	print_v d "NFS_REMOTE_ROOT_DIR=$NFS_REMOTE_ROOT_DIR"
fi


echo "TEST"
exit 0



echo "TODO: check for disk full issues"
echo "TODO: have #s of backups"

print_v i "Starting Incus Exports $(date)"  > $LOG_FILE

ROOT_DIR="$BACKUP_LOCAL_ROOT_DIR/$HOSTNAME".incus_export

END=2
TERM=$((END+1))


#echo $ROOT_DIR
#exit
if [[ $EUID -ne 0 ]]; then
   print_v e "This script must be run as root: $HOSTNAME" | tee -a $LOG_FILE
   exit 1
fi

#check to make sure this is a network mounted location
if ! mountpoint -q $BACKUP_LOCAL_ROOT_DIR; then
  print_v e "Not a mountpoint, mounting" | tee -a $LOG_FILE
  mount -t nfs4 "$NFS_SERVER:$NFS_REMOTE_ROOT_DIR" $BACKUP_LOCAL_ROOT_DIR
fi

if ! mountpoint -q $BACKUP_LOCAL_ROOT_DIR; then
  print_v e  "FAIL: $HOSTNAME: NFS connect to $NFS_SERVER failed"| tee -a $LOG_FILE
  mail $ADMIN -s "FAIL: $HOSTNAME: NFS connect to $NFS_SERVER failed"  < $LOG_FILE
  exit 1
fi

#check to make sure this is a location that is ok.
if [ ! -d "$ROOT_DIR" ]; then
  if ! mkdir -p "$ROOT_DIR"; then
    print_v e "FAIL: Creation of $ROOT_DIR failed" | tee -a $LOG_FILE
    mail $ADMIN -s "$HOSTNAME: NFS connect to $NFS_SERVER failed" < /etc/cron.d/backups
    exit 1
  fi
fi

#mail $ADMIN -s "backup starting" < /etc/cron.d/backups

for INSTANCE in $(incus list state=RUNNING -c n -f csv); do
  print_v i "Exporting $INSTANCE to $ROOT_DIR/$INSTANCE.tgz"  | tee -a "$LOG_FILE"
  if incus export --optimized-storage --instance-only "$INSTANCE" "$ROOT_DIR/$INSTANCE.tgz" ; then
    print_v i "Success Exporting $INSTANCE" | tee -a $LOG_FILE
  else
    print_v e "FAIL: Export of $INSTANCE failed" | tee -a $LOG_FILE
    exit 1
  fi
done
print_v i "Success: $HOSTNAME exports done" "$ADMIN" | tee -a $LOG_FILE
mail -s "Success: $HOSTNAME exports done" "$ADMIN" < $LOG_FILE

#need to have ssh key-pair setup to get rsync-via-ssh to be enabled, note trailing / is very important
#rsync -n -i -e ssh  -av  /srv/backups/$OBJECT/ backup_user@backup_server.example.com:~/server2/$OBJECT/
#rsync -n -i -e ssh  -av  /srv/backups/$OBJECT backup_user@backup_server.example.com:~/server2/

#at end of this unmount NFS dir
umount $BACKUP_LOCAL_ROOT_DIR
exit 0
