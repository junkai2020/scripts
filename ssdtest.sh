#!/bin/sh

export LANG=en_us

# Check root privilege
if [ $UID != "0" ]
then
        echo "Error: Need root privilege to run this script."
        exit 1
fi
# check tools list
tool_list=(fio nvme gnuplot iostat bc mkfs.ext4 awk)
for tool in ${tool_list[*]}
do
        which $tool &> /dev/null
        if [ $? -ne "0" ]
        then
                echo "error! plz install $tool!!!"
                exit 1
        fi
done

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
      nvme format /dev/$DEV -s 1 
      #nvme format /dev/$DEV -f -s 1 
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
        echo "eg: sh -x ssdtest.sh -d dfa -c scta -t 3600 >dfa.log 2>&1 & "
        echo "eg: sh -x ssdtest.sh -d nvme0n1 -t 3600 >nvme0n1.log 2>&1 &"
        echo "                                                                  "
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

# Determine iostat output format
tmpstr=$(iostat -dmx | grep "Device")
i=0
for col in ${tmpstr[*]}
do
    ((i=$i+1))
    if [ "$col" = "r/s" ]
    then
        read_iops_col=$i
    elif [ "$col" = "w/s" ]
    then
        write_iops_col=$i
    elif [ "$col" = "rMB/s" ]
    then
        read_bw_col=$i
    elif [ "$col" = "wMB/s" ]
    then
        write_bw_col=$i
    fi  
done


# Get test environment
numcpus=$(cat /proc/cpuinfo | grep processor | wc -l) # num of online cpus
cpu=$(cat /proc/cpuinfo | grep "model name" | head -1 | awk '{$1=$2=$3=""; print}')
cpucores=$(cat /proc/cpuinfo | grep "cpu cores" | head -1 | awk '{print $4}')
cpusiblings=$(cat /proc/cpuinfo | grep "siblings" | head -1 | awk '{print $3}')
let "cpucount=($((`cat /proc/cpuinfo | grep processor | tail -1 | awk {'print $3'}`))+1)/$cpusiblings"
machine=`dmidecode |grep -A2 "System Information"|tail -2 |awk -F ":" '{print $NF}' |xargs`
kernel=`uname -r`
memory=`cat /proc/meminfo |grep MemTotal |awk '{printf("%d\n",$2/1000/1000)}'`
fio_version=`fio --version`
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
fio --filename=/dev/$DEV --ioengine=libaio --direct=1 --name=init_seq  --output=${DEV}_init_seq.log    --rw=write    --bs=128k --numjobs=1 --norandommap --randrepeat=0 --iodepth=128   --loops=2
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV seq prepare test done!"
sleep 60

#seq write bw
logfile=${DEV}_wbw_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log  "Testing 128K Seq  Write Bandwidth:         "
fio --name=wbw --filename=/dev/$DEV --numjobs=1 --bs=128k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=write --group_reporting --iodepth=128   --ramp_time=300 --runtime=${RUNTIME} --time_based --minimal > ${DEV}_wbw
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 128K Seq Write Bandwidth done!"
sleep 60

#seq read bw
logfile=${DEV}_rbw_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Seq 128K Read Bandwidth:                  "
fio --name=rbw --filename=/dev/$DEV --numjobs=1 --bs=128k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=read --group_reporting --iodepth=128   --ramp_time=300 --runtime=${RUNTIME} --time_based --minimal > ${DEV}_rbw
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 128K Seq Read Bandwidth done!"
sleep 60

#seq write trim
logfile=${DEV}_wbw_trim_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Seq 1M trim write  Bandwidth:                  "
fio --name=trim --filename=/dev/$DEV --numjobs=1 --bs=1024k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=trim --group_reporting --iodepth=128   --ramp_time=300 --runtime=${RUNTIME} --time_based  > ${DEV}_trim_write
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV Seq 1M trim write  Bandwidth done!"
sleep 60


#prepare rand write & read
erasedisk
logfile=${DEV}_randprepare_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Do Fio...random prepare_test iostatlog: $logfile"
fio --filename=/dev/$DEV --ioengine=libaio --direct=1 --name=init_rand --output=${DEV}_init_random.log --rw=randwrite --bs=4k  --numjobs=4 --norandommap --randrepeat=0 --iodepth=64    --loops=1
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV random prepare test done!"
sleep 60

#rand write iops 
logfile=${DEV}_wiops_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=wiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randwrite --group_reporting --iodepth=64   --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_wiops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Random Write IOPS done!"
sleep 60

#rand read iops
logfile=${DEV}_riops_iostat
iostat -dmx /dev/$DEV 1 >$logfile &
bgpid=$!
w_log "Testing 4K Random Read IOPS:            "
fio --name=riops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randread --group_reporting --iodepth=64  --ramp_time=300 --runtime=${RUNTIME} --time_based --minimal > ${DEV}_riops 
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4k Random Read IOPS done!"
sleep 60

#rand rw 1:1 
logfile=${DEV}_mixrw55_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=rwiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randrw --rwmixread=50  --group_reporting --iodepth=64   --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_rw_55_iops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Rand rw 1:1  IOPS done!"
sleep 60

#rand rw 7:3 
logfile=${DEV}_mixrw73_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=rwiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randrw --rwmixread=70  --group_reporting --iodepth=64   --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_rw_73_iops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Rand rw 7:3  IOPS done!"
sleep 60

#rand rw 9:1 
logfile=${DEV}_mixrw91_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log "Testing 4K Random Write IOPS:           "
fio --name=rwiops --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randrw --rwmixread=90  --group_reporting --iodepth=64   --ramp_time=300 --runtime=${RUNTIME}  --time_based --minimal > ${DEV}_rw_91_iops
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4K Rand rw 9:1  IOPS done!"
sleep 60

#rand write trim
logfile=${DEV}_wbw_randtrim_iostat
iostat -dmx /dev/$DEV  1 > $logfile &
bgpid=$!
w_log " 4k randtrim write  Bandwidth:                  "
fio --name=randtrim --filename=/dev/$DEV --numjobs=4 --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randtrim --group_reporting --iodepth=64   --ramp_time=300 --runtime=${RUNTIME} --time_based  > ${DEV}_randtrim_write
checkexit
kill -KILL $bgpid
w_log "Fio.../dev/$DEV 4k randtrim write  Bandwidth done!"
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
          fio --name=riops --filename=/dev/${DEV} --numjobs=${numjob} --bs=4k --ioengine=libaio --direct=1 --randrepeat=0 --norandommap --rw=randread --group_reporting --iodepth=${iodept}   --ramp_time=60 --runtime=300 --time_based -minimal >${numjob}_${iodept}_randread
   done
   sleep 30
done

write_55_iops=$(cat ${DEV}_rw_55_iops | awk -F ';' '{print $49}')
write_73_iops=$(cat ${DEV}_rw_73_iops | awk -F ';' '{print $49}')
write_91_iops=$(cat ${DEV}_rw_91_iops | awk -F ';' '{print $49}')
read_55_iops=$(cat ${DEV}_rw_55_iops  | awk -F ';' '{print $8}')
read_73_iops=$(cat ${DEV}_rw_73_iops  | awk -F ';' '{print $8}')
read_91_iops=$(cat ${DEV}_rw_91_iops  | awk -F ';' '{print $8}')

#add trim randtrim
write_trim=(`cat ${DEV}_trim_write|grep BW|awk -F '[ =]+' '{print $6}'`)
write_randtrim=(`cat ${DEV}_randtrim_write|grep BW|awk -F '[ =]+' '{print $6}'`)

#add 99% 99.9 99.99% latency percentiles  remove gtod_reduce=1
write_lat=(`cat ${DEV}_wlatency | awk -F ';' '{print $81,$71,$73,$75}'`)
read_lat=(`cat ${DEV}_rlatency  | awk -F ';' '{print $40,$30,$32,$34}'`)
write_iops=(`cat ${DEV}_wiops   | awk -F ';' '{print $49,$71,$73,$75}'`)
read_iops=(`cat ${DEV}_riops    | awk -F ';' '{print $8,$30,$32,$34}'`)
write_bw=(`cat ${DEV}_wbw       | awk -F ';' '{print $48,$71,$73,$75}'`)
read_bw=(`cat ${DEV}_rbw        | awk -F ';' '{print $7,$30,$32,$34}'`)


for filename in `ls *randread`
do 
     readiops=$(cat ${filename}| awk -F ';' '{print $8}');    
     echo "${filename}: ${readiops}" >>max_randreadiops
done
job=`sort -n -k 2 max_randreadiops|tail -n 1|awk '{print $1}'`
maxiops=`sort -n -k 2 max_randreadiops|tail -n 1|awk '{print $2}'`

#consist count
echo ${read_bw[0]}
avg_rbw=$((${read_bw[0]} / 1000))
min_rbw=$( echo "$avg_rbw*0.95"|bc)
max_rbw=$( echo "$avg_rbw*1.05"|bc)
echo $avg_rbw  $min_rbw $max_rbw
avg_wbw=$((${write_bw[0]} / 1000))
min_wbw=$( echo "$avg_wbw*0.95"|bc)
max_wbw=$( echo "$avg_wbw*1.05"|bc)
echo $avg_wbw  $min_wbw  $max_wbw
avg_riops=${read_iops[0]}
min_riops=$( echo "$avg_riops*0.95"|bc)
max_riops=$( echo "$avg_riops*1.05"|bc)
echo $avg_riops  $min_riops $max_riops
avg_wiops=${write_iops[0]}
min_wiops=$( echo "$avg_wiops*0.95"|bc)
max_wiops=$( echo "$avg_wiops*1.05"|bc)
echo $avg_wiops $min_wiops  $max_wiops

#get result
grep ${DEV}  ${DEV}_riops_iostat|awk '{print $'$read_iops_col'}'  >riops
grep ${DEV}  ${DEV}_wiops_iostat|awk '{print $'$write_iops_col'}'  >wiops
grep ${DEV}  ${DEV}_wbw_iostat|awk '{print $'$write_bw_col'}'  >wbw
grep ${DEV}  ${DEV}_rbw_iostat|awk '{print $'$read_bw_col'}'  >rbw

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
   rno=0
   wno=0
   test_type=`echo "$file"|awk -F "_" '{print $2}'`
   if [ $test_type == "seqprepare" ] || [ $test_type == "wbw" ];then
                wno=1
                no=$write_bw_col
   elif [ $test_type == "rbw" ];then
                rno=1
                no=$read_bw_col
   elif [ $test_type == "randprepare" ] || [ $test_type == "wiops" ];then
        wno=1
                no=$write_iops_col
   elif [ $test_type == "riops" ];then
                rno=1
                no=$read_iops_col
   else
                rno=1
                wno=1
   fi
   echo $no  $rno $wno
   if [ $rno -eq 1 ] && [ $wno -eq 1 ];then
       grep  ${DEV} $file |awk  -v riops=${read_iops_col} -v wiops=${write_iops_col} '{print $riops,$wiops}' >iostat_plot
            echo " 
            set terminal png size 1600, 900
            set output \"$file.png\"
            set title \"$file \"
            set xlabel \"Time\"
            set ylabel \"$file \"
            set grid 
            plot  \"iostat_plot\" using 1  title \"riops\",\"iostat_plot\" using 2  title \"wiops\"
        " |gnuplot
   else
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
   fi
done
w_log "plot iostat finished!"

w_log "型号|代号|容量|固件:CPS|主控|Flash颗粒|顺序读带宽(128K 1job qd128)|顺序写带宽(128K 1job qd128)|随机读IOPS(4K 4job qd64)|随机读IOPS MAX(标注条件)|随机写IOPS(4K 4job qd64)||随机写延迟(us)||随机读延迟(us)|补充说明 "
w_log "${mode}||${user_capacity}|${firmware_build}:${cps_crc}|||$(( ${read_bw} / 1000 )) MB/s|$(( ${write_bw} / 1000 )) MB/s|$(( ${read_iops} / 1000 ))K|$(( ${maxiops} /1000 ))K($job)|$(( ${write_iops} / 1000 ))K||${write_lat}||${read_lat}|$machine  $cpucount * $cpucores  $cpu  $memory GB SSD: $model SN:$serial_number Kernel:$kernel  $fio_version DRIVER:${driver_version} `date "+%F %T"`"

w_log "
 -------------Test environment -------------------------------------
 machine: $machine   kernel:$kernel
 cpu: $cpucount * $cpucores  $cpu 
 memory: $memory GB  
 $fio_version   ssd: $model ${user_capacity}  $serial_number 功耗: ${p_status}
 -------------Performance Summary------------------------------------
 Seq Write Bandwidth:      $((${write_bw[0]} / 1000 )) MB/s($wbw_consist_percent) 
 Seq Read Bandwidth:       $((${read_bw[0]} / 1000 )) MB/s($rbw_consist_percent)  
 4K Random Write Latency:  ${write_lat[0]}us                                       
 4K Random Write IOPS:     $((${write_iops[0]} / 1000 ))K($wiops_consist_percent) 
 4K Random Read Latency:   ${read_lat[0]} us                                       
 4K Random Read IOPS:      $((${read_iops[0]} / 1000 ))K($riops_consist_percent)  
 
-----------------------mix readwrite performance----------------------
 4k Random rw 5:5 IOPS(rw):   $(( ${read_55_iops} / 1000 ))K  $(( ${write_55_iops} / 1000 ))K
 4k Random rw 7:3 IOPS(rw):   $(( ${read_73_iops} / 1000 ))K  $(( ${write_73_iops} / 1000 ))K
 4k Random rw 9:1 IOPS(rw):   $(( ${read_91_iops} / 1000 ))K  $(( ${write_91_iops} / 1000 ))K

-----------------------latency percentiles---------------------------
128k 1*128 Seq Write BW latency percentiles(us):
${write_bw[1]} ${write_bw[2]} ${write_bw[3]}

128k 1*128 Seq Read BW latency percentiles(us):
${read_bw[1]} ${read_bw[2]} ${read_bw[3]}

4K 4*64  Random Write IOPS latency percentiles(us):
${write_iops[1]} ${write_iops[2]} ${write_iops[3]}

4K 4*64 Random Read IOPS latency percentiles:(us):
${read_iops[1]} ${read_iops[2]} ${read_iops[3]}

4K 1*1 Random Write Latency:
${write_lat[1]} ${write_lat[2]} ${write_lat[3]}

4K 1*1 Random Read Latency:
${read_lat[1]} ${read_lat[2]} ${read_lat[3]}

-------------------------------trim performance----------------------
1M seq trim : ${write_trim}
4k rand trim : ${write_randtrim}

---------------------------------------------------------------------
see more: $basedir
-----------------------------------------End-------------------------"
