#!/bin/sh

export LANG=en_us

# Check root privilege
if [ $UID != "0" ]
then
        echo "Error: Need root privilege to run this script."
        exit 1
fi
# Check fio version
which fio &> /dev/null

if [ $? -eq "0" ]
then
        fioversion=`fio --version`
        echo "Based on ${fioversion}"
        echo
else
        echo "Error: Failed to locate fio program, please go to the following website and fetch the latest version."
        echo "Project page: https://git.kernel.org/pub/scm/linux/kernel/git/axboe/fio.git"
        exit 1
fi

# Check gnuplot
which gnuplot &> /dev/null

if [ $? -eq "0" ]
then
        :
else
        echo "Error: Failed to locate gnuplot program, please install gnuplot."
        exit 1
fi
#check nvme
which nvme &> /dev/null
if [ $? -eq "0" ]
then
        :
else
        echo "Error: Failed to locate nvme command, please install nvme cli."
	echo "https://github.com/linux-nvme/nvme-cli"
        exit 1
fi

# Log
w_log()
{
        time=`date "+%F %T"`
        echo "${time} $1" >> ${basedir}/main_log.txt
}


# erase disk
erasedisk()
{
    if [ -n "${DEV:0:2}" ] &&  [ "${DEV:0:2}" = "df" ]
    then
       CDEV=scta
       shannon-detach /dev/${CDEV}
       shannon-format -y -A 0 /dev/${CDEV}
       shannon-attach  /dev/${CDEV}
       w_log "direct-io format /dev/$DEV done"
   elif [ -n "${DEV:0:4}" ] &&  [ "${DEV:0:4}" = "nvme" ]
   then
      nvme format /dev/$DEV -l 0 -f 
      w_log " nvme format /dev/$DEV done"
   elif [ -n "${DEV:0:2}" ] &&  [ "${DEV:0:2}" = "os" ]
   then
        ocnvme  format /dev/$DEV
        w_log " ocs format /dev/$DEV DONE"
   else
       mkfs.ext4 -F -E discard /dev/$DEV  
       w_log "mkfs.ext4 /dev/$DEV done" 
   fi
}

# Check command exit status
checkexit()
{
        if [ $? -ne "0" ]
        then
                w_log "Error: $1, code=$?"
                exit 1
        fi
}


usage() {
        echo "usage: ssdtest.sh -d block_device  -c character_device  -t runtime "
        echo "eg: ssdtest.sh -d dfa -c scta -t 3600 "
}
# Getopts
while getopts "d:t:c:" arg
do
        case $arg in
                "d")
                DEV="$OPTARG"
                ;;
	        "c")
                CDEV="$OPTARG"
		        ;;
                "t")
                RUNTIME="$OPTARG"
                ;;
                ?)
                usage
                exit 1
                ;;
        esac
done

# Check target block device
if [[ -b /dev/${DEV} ]]
then
    mount |grep ${DEV}
        if [ $? -eq "0" ]
        then
            echo "${DEV} is mounting, plz umount first!"
            exit 1
    fi
else
        echo "Error: device  ${DEV} doesn't exist or isn't a block device!"
        exit 1

fi



# Get test environment
numcpus=$(cat /proc/cpuinfo | grep processor | wc -l) # num of online cpus
cpu=$(cat /proc/cpuinfo | grep "model name" | head -1 | awk '{$1=$2=$3=""; print}')
cpucores=$(cat /proc/cpuinfo | grep "cpu cores" | head -1 | awk '{print $4}')
cpusiblings=$(cat /proc/cpuinfo | grep "siblings" | head -1 | awk '{print $3}')
let "cpucount=($((`cat /proc/cpuinfo | grep processor | tail -1 | awk {'print $3'}`))+1)/$cpusiblings"
machine=`dmidecode |grep -A2 "System Information"|tail -2 |awk -F ":" '{print $NF}' |xargs`
kernel=`uname -r`
memory=`cat /proc/meminfo |grep MemTotal |awk '{printf("%d\n",$2/1000/1000)}'`

#for shannon pcie ssd & nvme ssd
if [ "x${DEV:0:2}" = "xdf" ]
then
   model=`cat /sys/class/block/${DEV}/shannon/model`
   user_capacity=`shannon-status  -l|grep ${DEV}|awk '{print $6}'`
   driver_version=`cat /sys/class/block/${DEV}/shannon/driver_version`
   firmware_build=`cat /sys/class/block/${DEV}/shannon/firmware_build`
   cps_crc=`cat /sys/class/block/${DEV}/shannon/cps_crc`
   serial_number=`cat /sys/class/block/${DEV}/shannon/serial_number`
elif [ "x${DEV:0:4}" = "xnvme" ]
then
   mode=`nvme --list |grep $DEV|awk '{print $3}'`
   user_capacity=`nvme --list |grep $DEV|awk '{print $5,$6}'`
   driver_version=`nvme --version |awk '{print $NF}'`
   #firmware_build=`nvme --list |grep $DEV|awk '{print $NF}'`
   firmware_build=`nvme admin-passthru /dev/$DEV -o 0xC2 --cdw10 0x400 --cdw12 0x40 --cdw15 3 -l 4099 -r|grep 01f0|awk '{print $NF}'`
   serial_number=`nvme --list |grep $DEV|awk '{print $2}'`
   p_status=`nvme get-feature /dev/${DEV} -f 2|awk -F ":" '{print $NF}'`
elif [ "x${DEV:0:2}" = "xos" ]
then
   mode=`ocnvme list |grep $DEV|awk '{print $3}'`
   user_capacity=`ocnvme list |grep $DEV|awk '{print $5,$6}'`
   #driver_version=`ocnvme version |awk '{print $NF}'`
   driver_version=`ocnvme lnvm status $DEV |grep -i driver|awk '{print $NF}'`
   firmware_build=`ocnvme list |grep $DEV|awk '{print $14}'`
   #firmware_build=`nvme admin-passthru /dev/$DEV -o 0xC2 --cdw10 0x400 --cdw12 0x40 --cdw15 3 -l 4099 -r|grep 01f0|awk '{print $NF}'`
   serial_number=`ocnvme list |grep $DEV|awk '{print $2}'`   
fi

# Prepare work directory
homedir=$(pwd)
t_date=$(date +%Y%m%d%H%M)
basedir="${homedir}/${DEV}_${t_date}"
rm -rf ${basedir}
mkdir -p ${basedir}
cd ${basedir}
#open irqbalance
#irqbalance -o
#sh -x /root/smp_affinity.sh 

#prepare sequence write & read
erasedisk
logfile=${DEV}_seqprepare_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Do Fio...seq prepare_test iostatlog: $logfile"
fio --filename=/dev/$DEV --ioengine=libaio --direct=1 --name=init_seq  --output=${DEV}_init_seq.log    --rw=write    --bs=128k --numjobs=1 --norandommap --randrepeat=0 --iodepth=128 --gtod_reduce=1  --loops=2
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV seq prepare test done!"
sleep 60

#seq write bw
logfile=${DEV}_wbw_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log  "Testing 128K Seq  Write Bandwidth:         "
fio --name=wbw --filename=/dev/$DEV --numjobs=1 --bs=128k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=write --group_reporting --iodepth=128  --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME} --time_based --minimal > ${DEV}_wbw
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 128K Seq Write Bandwidth done!"
sleep 60

#seq read bw
logfile=${DEV}_rbw_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Seq 128K Read Bandwidth:                  "
fio --name=rbw --filename=/dev/$DEV --numjobs=1 --bs=128k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=read --group_reporting --iodepth=128  --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME} --time_based --minimal > ${DEV}_rbw
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 128K Seq Read Bandwidth done!"
sleep 60

#prepare rand write & read
erasedisk
logfile=${DEV}_randprepare_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Do Fio...random prepare_test iostatlog: $logfile"
fio --filename=/dev/$DEV --ioengine=libaio --direct=1 --name=init_rand --output=${DEV}_init_random.log --rw=randwrite --bs=4k  --numjobs=4 --norandommap --randrepeat=0 --iodepth=64  --gtod_reduce=1  --loops=1
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV random prepare test done!"
sleep 60

#rand write iops 
logfile=${DEV}_wiops_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=wiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randwrite --group_reporting --iodepth=64  --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_wiops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Random Write IOPS done!"
sleep 60

#rand read iops
logfile=${DEV}_riops_iostat
iostat -dmx /dev/$DEV 1 >$logfile &
bgpid=$!
w_log "Testing 4K Random Read IOPS:            "
fio --name=riops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randread --group_reporting --iodepth=64 --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME} --time_based --minimal > ${DEV}_riops 
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4k Random Read IOPS done!"
sleep 60

#rand rw 1:1 
logfile=${DEV}_mixrw55_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=rwiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randrw --rwmixread=50  --group_reporting --iodepth=64  --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_rw_55_iops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Rand rw 1:1  IOPS done!"
sleep 60

#rand rw 7:3 
logfile=${DEV}_mixrw73_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=rwiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randrw --rwmixread=70  --group_reporting --iodepth=64  --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_rw_73_iops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Rand rw 7:3  IOPS done!"
sleep 60

#rand rw 9:1 
logfile=${DEV}_mixrw91_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=rwiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randrw --rwmixread=90  --group_reporting --iodepth=64  --gtod_reduce=1 --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_rw_91_iops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Rand rw 9:1  IOPS done!"
sleep 60


#test latency
#rand write latency
w_log "Testing 4K Random Write latency:           "
fio --filename=/dev/$DEV --name=randwrite_latency  --numjobs=1  --bs=4k --ioengine=sync --direct=1 --norandommap --randrepeat=0 --rw=randwrite --group_reporting --iodepth=1 --ramp_time=60 --runtime=300 --time_based -minimal > ${DEV}_wlatency
checkexit
w_log "Fio.../dev/$DEV 4K Random Write latency done!"
sleep 60

#rand read latency
w_log "Testing 4K Random Read latency:           "
fio --filename=/dev/$DEV --name=randread_latency --numjobs=1  --bs=4k --ioengine=sync --direct=1 --norandommap --randrepeat=0 --rw=randread --group_reporting --iodepth=1 --ramp_time=60 --runtime=300 --time_based --minimal > ${DEV}_rlatency
checkexit
w_log "Fio.../dev/$DEV 4K Random Read latency done!"
sleep 60

#add max randread iops
for numjob in 1 4 8 16
do 
   for iodept in 32 64 128 256
   do
          fio --name=riops --filename=/dev/${DEV} --numjobs=${numjob} --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randread --group_reporting --iodepth=${iodept}  --gtod_reduce=1 --ramp_time=60 --runtime=300 --time_based -minimal >${numjob}_${iodept}_randread
   done
   sleep 30
done

write_iops=$(cat ${DEV}_wiops | awk -F ';' '{print $49}')
write_55_iops=$(cat ${DEV}_rw_55_iops | awk -F ';' '{print $49}')
write_73_iops=$(cat ${DEV}_rw_73_iops | awk -F ';' '{print $49}')
write_91_iops=$(cat ${DEV}_rw_91_iops | awk -F ';' '{print $49}')
read_iops=$(cat ${DEV}_riops | awk -F ';' '{print $8}')
read_55_iops=$(cat ${DEV}_rw_55_iops | awk -F ';' '{print $8}')
read_73_iops=$(cat ${DEV}_rw_73_iops | awk -F ';' '{print $8}')
read_91_iops=$(cat ${DEV}_rw_91_iops | awk -F ';' '{print $8}')
write_lat=$(cat ${DEV}_wlatency | awk -F ';' '{print $81}')
read_lat=$(cat ${DEV}_rlatency | awk -F ';' '{print $40}')
write_bw=$(cat ${DEV}_wbw | awk -F ';' '{print $48}')
read_bw=$(cat ${DEV}_rbw | awk -F ';' '{print $7}')
for filename in `ls *randread`
do 
     readiops=$(cat ${filename}| awk -F ';' '{print $8}');    
     echo "${filename}: ${readiops}" >>max_randreadiops
done
job=`sort -n -k 2 max_randreadiops|tail -n 1|awk '{print $1}'`
maxiops=`sort -n -k 2 max_randreadiops|tail -n 1|awk '{print $2}'`

#consist count
avg_rbw=$(($read_bw / 1000))
min_rbw=$( echo "$avg_rbw*0.95"|bc)
max_rbw=$( echo "$avg_rbw*1.05"|bc)
echo $avg_rbw  $min_rbw $max_rbw
avg_wbw=$(($write_bw / 1000))
min_wbw=$( echo "$avg_wbw*0.95"|bc)
max_wbw=$( echo "$avg_wbw*1.05"|bc)
echo $avg_wbw  $min_wbw  $max_wbw
avg_riops=$read_iops
min_riops=$( echo "$avg_riops*0.95"|bc)
max_riops=$( echo "$avg_riops*1.05"|bc)
echo $avg_riops  $min_riops $max_riops
avg_wiops=$write_iops
min_wiops=$( echo "$avg_wiops*0.95"|bc)
max_wiops=$( echo "$avg_wiops*1.05"|bc)
echo $avg_wiops $min_wiops  $max_wiops

#get result
grep ${DEV}  ${DEV}_riops_iostat|awk '{print $4}'  >riops
grep ${DEV}  ${DEV}_wiops_iostat|awk '{print $5}'  >wiops
grep ${DEV}  ${DEV}_wbw_iostat|awk '{print $7}'  >wbw
grep ${DEV}  ${DEV}_rbw_iostat|awk '{print $6}'  >rbw

#count
#rbw
consist_cnt=`awk -v min=$min_rbw -v max=$max_rbw '$1 >=min && $1 <=max'  rbw|wc -l |awk '{print $1}'`
total_cnt=`wc -l rbw|awk '{print $1}'`
rbw_consist_percent=$(echo "scale=4;$consist_cnt/$total_cnt*100"|bc)

#wbw 
consist_cnt=`awk -v min=$min_wbw -v max=$max_wbw '$1 >=min && $1 <=max'  wbw|wc -l |awk '{print $1}'`
total_cnt=`wc -l wbw|awk '{print $1}'`
wbw_consist_percent=$(echo "scale=4;$consist_cnt/$total_cnt*100"|bc)

#riops
consist_cnt=`awk -v min=$min_riops -v max=$max_riops '$1 >=min && $1 <=max'  riops|wc -l |awk '{print $1}'`
total_cnt=`wc -l riops|awk '{print $1}'`
riops_consist_percent=$(echo "scale=4;$consist_cnt/$total_cnt*100"|bc)

#wiops
consist_cnt=`awk -v min=$min_wiops -v max=$max_wiops '$1 >=min && $1 <=max'  wiops|wc -l |awk '{print $1}'`
total_cnt=`wc -l wiops|awk '{print $1}'`
wiops_consist_percent=$(echo "scale=4;$consist_cnt/$total_cnt*100"|bc)


#iostat plot
for file in ${DEV}*iostat
do
   test_type=`echo "$file"|awk -F "_" '{print $2}'`
   if [ $test_type == "seqprepare" ] || [ $test_type == "wbw" ];then
       no=7
   elif [ $test_type == "rbw" ];then
       no=6
   elif [ $test_type == "randprepare" ] || [ $test_type == "wiops" ];then
       no=5
   else
       no=4
   fi
echo $no 
grep ${DEV} $file |awk  -v no=$no '{print $no }'  >iostat_plot
         echo " 
            set terminal png size 1600, 900
            set output \"$file.png\"
            set title \"$file \"
            set xlabel \"Time\"
            set ylabel \"$file \"
            set grid 
            plot  \"iostat_plot\" using 1  title \"$file\"
        " |gnuplot
done
w_log "plot iostat finished!"

w_log "型号|代号|容量|固件:CPS|主控|Flash颗粒|顺序读带宽(128K 1job qd128)|顺序写带宽(128K 1job qd128)|随机读IOPS(4K 4job qd64)|随机读IOPS MAX(标注条件)|随机写IOPS(4K 4job qd64)||随机写延迟(us)||随机读延迟(us)|补充说明 "
w_log "${mode}||${user_capacity}|${firmware_build}:${cps_crc}|||$(( ${read_bw} / 1000 )) MB/s|$(( ${write_bw} / 1000 )) MB/s|$(( ${read_iops} / 1000 ))K|$(( ${maxiops} /1000 ))K($job)|$(( ${write_iops} / 1000 ))K||${write_lat}||${read_lat}|$machine  $cpucount * $cpucores  $cpu  $memory GB SSD: $model SN:$serial_number Kernel:$kernel  $fioversion DRIVER:${driver_version} `date "+%F %T"`"

w_log "
 -------------Test environment -----------------
 machine: $machine   kernel:$kernel
 cpu: $cpucount * $cpucores  $cpu 
 memory: $memory GB  
 fio : $fioversion   ssd: $model ${user_capacity}  $serial_number 功耗: ${p_status}
 -------------Performance Summary---------------
 Seq Write Bandwidth:   $(( ${write_bw} / 1000 )) MB/s($wbw_consist_percent)
 Seq Read Bandwidth:    $(( ${read_bw} / 1000 )) MB/s($rbw_consist_percent)
 4K Random Write Latency:  ${write_lat} us
 4K Random Write IOPS:     $(( ${write_iops} / 1000 ))K($wiops_consist_percent)
 4K Random Read Latency:   ${read_lat} us
 4K Random Read IOPS:      $(( ${read_iops} / 1000 ))K($riops_consist_percent)
 
--------------------------------------------------
 4k Random rw 5:5 IOPS(rw):   $(( ${read_55_iops} / 1000 ))K  $(( ${write_55_iops} / 1000 ))K
 4k Random rw 7:3 IOPS(rw):   $(( ${read_73_iops} / 1000 ))K  $(( ${write_73_iops} / 1000 ))K
 4k Random rw 9:1 IOPS(rw):   $(( ${read_91_iops} / 1000 ))K  $(( ${write_91_iops} / 1000 ))K

 see more: $basedir
 -------------------End-------------------------"

