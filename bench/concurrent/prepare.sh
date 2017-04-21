#!/bin/bash
# vim: et:ts=2:sw=2

set -e

img="$1"
mnt=/tmp/fscq

if [ -z "$img" ]; then
  echo "Usage: $0 <disk.img>"
  exit 1
fi

mkfs --data-bitmaps 16 --inode-bitmaps 16 "$img"
fscq --use-downcalls=false $img "$mnt" -- -f &
sleep 1

dd if=/dev/urandom of="$mnt/small" bs=4k count=1
dd if=/dev/urandom of="$mnt/large" bs=1k count=100000

for num in $(seq 1 20); do
  mkdir "$mnt/dir$num"
  touch "$mnt/dir$num/file1"
  touch "$mnt/dir$num/file2"
done

path1="a/b/c/d/e/f"
path2="a____/b____/c____/d____/e____/f____"
mkdir -p "$mnt/$path1"
mkdir -p "$mnt/$path2"
touch "$mnt/$path1/file"
touch "$mnt/$path2/file"

mkdir "$mnt/linux-source"
cp $HOME/linux.tar.xz "$mnt/linux-source/"

cd "$mnt"
tar -xf $HOME/linux.tar.xz

for file in $mnt/**; do
  sync $file
done