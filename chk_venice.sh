#!/bin/sh
chk_shannon_disk() {
nvme_pci=(`lspci |grep -i "Device 1cb0:" |awk -F" " '{print $1}'`)
for i in ${nvme_pci[*]}
do
	pcie_rate=`lspci -s $i -vvv |grep -i LnkSta:|awk '{print $3}'`
	pcie_disk=`ls  /dev/disk/by-path/  -l |grep pci-0000:${i}-nvme-1 |grep -v part|awk -F "/" '{print $NF}'`
	disk_info=(`nvme list|grep ${pcie_disk}|awk '{print $2,$3,$NF}'`)
	echo "${i} ${disk_info[0]} ${disk_info[1]} ${disk_info[2]} ${pcie_rate} ${pcie_disk}"
done
}
chk_shannon_disk
