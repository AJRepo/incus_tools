# Backup to a separate location without duplication of backup.

Why this script?

* Because "incus export" is an API client call to the server. EVEN IF CALLED ON the server
  Thus "incus export," if you specify any location to save the export, will create a duplicate
  of the export file. I.e. `incus export` creates, copies, then deletes the file.

* If you can have the "backup directory" already be the remote loction that understands inode cp then the
  copy/delete step is nearly instantaneous (e.g. NFS).

* For security (or other) purposes, you might want your backup directory to be OFFline except when running a backup/export.

This script can backup both your /var/lib/incus directory (if you select the -F flag) and export instances.
By default it will backup all running instances. You can override this to specify any filter applicable to `incus list`

If backing up instances, this script does the following:

1. Moves /var/lib/incus/backup to /var/lib/incus/backup.bak

1. Mounts (if not already mounted) your remote backup location

1. Links /var/lib/incus/backup to the remote backup location

1. Does the export

1. Moves the export into a versioned directory INSTANCE\_NAME.0, INSTANCE\_NAME.1, ... 

1. Unmounts the remote backup location (to be a flag option in the future)

1. Moves /var/lib/incus/backup.bak back to /var/lib/incus/backup


Currently, this remote location is an NFS mount. Future work will allow it to be anything.

Quick Start:

1. Copy the file `export_incus_to_remote.env.dist` to `export_incus_to_remote.env` and update it.

1. Run `export_incus_to_remote.env.sh -F -n -d` to see what it would do before it actually does a backup.

1. If all looks ok Run `export_incus_to_remote.env.sh -F -d` 

The "-n" flag = dry run. The "-d" flag = debug messages



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
