To use, create a file named "export_incus_to_NFS.env" and place in this same directory. 

The file will look like
```
#PUT CONFIG FILES HERE
ADMIN="monitoring@example.com"
NFS_SERVER="INSERT_IP_ADDRESS_HERE"
BACKUP_LOCAL_ROOT_DIR="THE_DIRECTORY_HERE_ON_THE_INCUS_SERVER"
#Do not have NFS_REMOTE_ROOT_DIR end with a "/"
NFS_REMOTE_ROOT_DIR="/THE_DIRECTORY_ON_THE_REMOTE_SERVER"
```
