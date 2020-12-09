#!/bin/sh

source /etc/profile
wlog()
{
        time=`date "+%F %T"`
        echo "${time} $1"  >>main.log
}
checkexit()
{
        if [ $? -ne "0" ]
        then
                w_log "Error: $1, code=$?"
                exit 1
        fi
}
#下载sysbench

curl -s https://packagecloud.io/install/repositories/akopytov/sysbench/script.rpm.sh | sudo bash
yum -y install sysbench

wlog "清理测试表sbtest"
mysql -S /tmp/mysql3306.sock -pshannon  -e "drop database sbtest;"   2>/dev/null
wlog "创建测试表"
mysql -S /tmp/mysql3306.sock -pshannon  -e "create database sbtest;"
#导入数据
wlog "导入数据开始"
sysbench --mysql-host=localhost --mysql-port=3306  --mysql-socket=/tmp/mysql3306.sock --mysql-user=root --mysql-password=shannon --mysql-db=sbtest --oltp-tables-count=100 --oltp-table-size=20000000  --threads=32 --oltp-test-mode=complex --rand-type=uniform --rand-init=on  /usr/share/sysbench/tests/include/oltp_legacy/parallel_prepare.lua run
wlog "导入数据完成"
sleep 300
#测试
testNo=1
testMaxTimes=5
while [	${testNo} -le ${testMaxTimes} ]
do
	mode="select oltp insert delete update_index update_non_index"
	for testMode in $mode
		do
			wlog "第${testNo}次${testMode}测试开始"
			sysbench --mysql-host=localhost --mysql-port=3306  --mysql-socket=/tmp/mysql3306.sock --mysql-user=root --mysql-password=shannon --mysql-db=sbtest --oltp-tables-count=100 --oltp-table-size=20000000 --threads=32 --oltp-test-mode=complex --time=3600 --report-interval=10 --percentile=95 --rand-type=uniform --rand-init=on  /usr/share/sysbench/tests/include/oltp_legacy/${testMode}.lua run >${testNo}_${testMode}.log
			sleep 300
			wlog "第${testNo}次${testMode}测试结束"
			#clean binlog
			log_now=`mysql -S /tmp/mysql3306.sock -pshannon -e "show master status;"|grep -v '^+'|tail -1|awk '{print $1}'`
			mysql -S /tmp/mysql3306.sock -pshannon  -e "purge binary logs to '${log_now}';"
			if [ $? -eq 0 ];then
				wlog "clean MySQL binlog success!"
			fi
			sleep 60	
		done
	let testNo++
done
wlog "测试完成!"
