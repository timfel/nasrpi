#!/bin/bash

MISSING=()
for mp in /media/media /media/media_backup /media/nas /media/nas_backup; do
    if ! findmnt -s "$mp"; then
        MISSING+=("$mp")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "WARNING: The following mount points are not mounted via fstab"
    for mp in "${MISSING[@]}"; do
        echo "  - $mp"
    done
    echo "The following devices (UUID, size, device, usb path, manufacturer id) are available"
    lsblk -t -o UUID,SIZE,NAME,LABEL,FSTYPE,MOUNTPOINTS
    echo "FSTAB EXAMPLES

    UUID=aad89fad          /media/media   ext4           defaults,users,noatime,nofail                         0 0
    UUID=78247AAC247A6D4E  /media/media   ntfs-3g        defaults,users,noatime,uid=1000,gid=1000,umask=0002   0 0
    /media/mybook12t       /media/media   none           defaults,users,bind,nofail                            0 0
    /mnt/disk1:/mnt/disk2  /media/media   fuse.mergerfs  defaults,users,nofail,allow_other,cache.files=off,dropcacheonclose=true,category.create=mfs,moveonenospc=true,minfreespace=4G,fsname=mergerfs  0  0"
    exit 1
fi

exit 0
