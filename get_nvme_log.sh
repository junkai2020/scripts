#!/bin/bash

if [ $# -lt 1 ]; then
	echo "usage: $0 [options] device(ex:/dev/nvme0n1)"
	echo ""
 	echo "options:"
	exit 0
fi

if [ $UID != "0" ]
then
	echo "Error: Need root privilege to run this script."
	exit 1
fi

which nvme &> /dev/null
if [ $? -ne "0" ];then
	echo "error! plz install nvme-cli!"
	exit 1
fi

dev=$1
nvme admin-passthru $dev -o 0xc2 --cdw10 0x1000 --cdw12 0x40 --cdw13 0 --cdw15 0x3 -l 16384 -r &>/dev/null
if [ $? != 0 ]; then
	echo "dev $1 not support"
	exit 1
fi

time_stamp=`date +%Y%m%d-%H%M%S`
log_dir="/tmp/sp4-bugreport-${time_stamp}"
mkdir -p ${log_dir} && cd ${log_dir}
rm -rf *

#Save system information
lspci -vvvvv > lspci
uname -a > os_info
dmidecode > hw_info
lsblk  > disk_info
nvme list >> disk_info

#Save Phy Log
nvme admin-passthru $dev -o 0xc0 --cdw12 0x2c &> /dev/null
page_size=16384

fwset=`nvme admin-passthru $dev -o 0xc2 --cdw10 0x1000 --cdw12 0x40 --cdw13 0 --cdw15 0x3 -l 16384 -r 2>/dev/null| sed -n '6p'|awk  '{print $15}'`
plane_num=$(((( $((16#$fwset)) >> 5) & 0x3 ) + 1 ))

page0=`nvme admin-passthru $dev -o 0xc2 --cdw10 0x1000 --cdw12 0x40 --cdw13 0 --cdw15 0x3 -l 16384 -r 2>/dev/null| sed -n '43p' | awk  '{print $16 $17}'`
page1=`nvme admin-passthru $dev -o 0xc2 --cdw10 0x1000 --cdw12 0x40 --cdw13 0 --cdw15 0x3 -l 16384 -r 2>/dev/null| sed -n '555p' | awk  '{print $16 $17}' `

page0=$((16#$page0 -1 ))
page1=$((16#$page1 -1 ))
page_size=$(($page_size * $plane_num))

for((i=$page0;i>=0;i--)); do
	nvme admin-passthru $dev -o 0xc2 --cdw10 $(($page_size / 4)) --cdw12 0x57 --cdw13 $i --cdw15 0x1 -l $page_size -r -b >> EventLog_"$(basename $dev)"_BE0;
done

for((i=$page1;i>=0;i--)); do
	nvme admin-passthru $dev -o 0xc2 --cdw10 $(($page_size / 4)) --cdw12 0x57 --cdw13 $i --cdw15 0x2 -l $page_size -r -b >> EventLog_"$(basename $dev)"_BE1;
done

cd /tmp
chmod -R u+w sp4-bugreport-${time_stamp}
tar czf sp4-bugreport-${time_stamp}.tar.gz sp4-bugreport-${time_stamp} &> /dev/null

echo "Tarball: /tmp/sp4-bugreport-${time_stamp}.tar.gz"


