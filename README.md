# Backup to a separate location without duplication of backup.

Why this script?

* Because "incus export" is an API client call to the server. Thus the API call creates a duplication of the export file as incus creates, copies, then deletes the file.

If you can have the "backup directory" already be the remote loction then the copy/delete step (e.g. mv) can be nearly instantaneous.

* For security (or other) purposes you might want your backup directory to be OFFline except when running a backup/export.

This script

1. Moves /var/lib/incus/backup to /var/lib/incus/backup.bak

1. Mounts (if not already mounted) your remote backup location

1. Links /var/lib/incus/backup to the remote backup location

1. Does the export

1. Moves the export into a versioned directory INSTANCE\_NAME.0, INSTANCE\_NAME.1, ... 

1. Unmounts the remote backup location (to be a flag option in the future)

1. Moves /var/lib/incus/backup.bak back to /var/lib/incus/backup

Currently, this remote location is an NFS mount. Future work will allow it to be anything.

Quick Start:

1) Use the "-n" flag for a dry run. Use the "-d" flag for debug messages

2) Copy the file export\_incus\_to\_remote.env.dist to export\_incus\_to\_remote.env with your info

3) Run `export_incus_to_remote.env.sh -n -d` to see what it would do before it actually does a backup.

---

Preamble Warning:  "incus delete pool POOLNAME" deletes everything in that
directory on down. So beware of setting `incus storage create POOL dir source=/XXX/YYY`
because everything in /XXX/YYY will be deleted.

So if src=... is your remote server's directory.
It acts as `rm -rf /XXX/YYY` which 
will delete everything in that directory without warning.

This applies even to files and directories you created outisde of incus commands.

--End Preamble Warning--

This connects to an NFS directory /path/to/backup and creates a temporary directory
/path/to/temp\_backup 

/path/to/backup will create iterative backups as 
/path/to/backup/INSTANCE.0/INSTANCE.tgz
/path/to/backup/INSTANCE.1/INSTANCE.tgz
/path/to/backup/INSTANCE.2/INSTANCE.tgz

where 0 is the earliest and 1, 2, are older backups.

The temporary directory replaces /var/lib/incus/backups while incus backs up the 
instance "locally" and moves it to /path/to/backup/INSTANCE.0/INSTANCE.tgz . By
keeping the temporary and final exports on the same file system there's no additional
file writing time cost. 
