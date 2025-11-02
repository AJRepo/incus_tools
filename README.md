Preamble Warning:  "incus delete pool POOLNAME" deletes everything in that
directory on down. So beware of setting `incus storage create POOL dir source=/XXX/YYY`
because everything in /XXX/YYY will be deleted.

So if src=... is your remote server's directory.
It acts as `rm -rf /XXX/YYY` which 
will delete everything in that directory without warning.

This applies even to files and directories you created outisde of incus commands.

--End Preamble Warning--

This connects to an NFS directory /path/to/backup and creates a temporary directory
/path/to/temp_backup 

/path/to/backup will create iterative backups as 
/path/to/backup/INSTANCE.0/INSTANCE.tgz
/path/to/backup/INSTANCE.1/INSTANCE.tgz
/path/to/backup/INSTANCE.2/INSTANCE.tgz

where 0 is the earliest and 1, 2, are older backups.

The temporary directory replaces /var/lib/incus/backups while incus backs up the 
instance "locally" and moves it to /path/to/backup/INSTANCE.0/INSTANCE.tgz . By
keeping the temporary and final exports on the same file system there's no additional
file writing time cost. 

To use, create a file named "export_incus_to_remote.env" and place in this same directory. 

The file will look like
```
#PUT CONFIG FILES HERE
ADMIN="monitoring@example.com"
NFS_SERVER="INSERT_IP_ADDRESS_HERE"
BACKUP_LOCAL_ROOT_DIR="THE_DIRECTORY_HERE_ON_THE_INCUS_SERVER"
#Do not have NFS_REMOTE_ROOT_DIR end with a "/"
NFS_REMOTE_ROOT_DIR="/THE_DIRECTORY_ON_THE_REMOTE_SERVER"
```

