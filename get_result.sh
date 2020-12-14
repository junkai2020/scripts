#!/bin/sh

test_result=test_result
echo "测试轮数 测试项目 TPS QPS MinLat AvgLat MaxLat 95%Lat" >${test_result}
test_no=5
while [	${test_no} -gt 0 ]
do
	mode="select oltp insert delete update_index update_non_index"
	for test_mode in $mode
		do
			test_file=${test_no}_${test_mode}.log
			#tps
			tps=`grep transactions: ${test_file}|awk -F "(" '{print $2}'|awk '{print $1}'`
			#qps
			qps=`grep queries: ${test_file}|awk -F "(" '{print $2}'|awk '{print $1}'`
			#latency
			latency=(`grep -A4 "Latency (ms):" ${test_file}|grep -v Latency|awk '{print $NF}'|tr  '\n' ' '`)
			echo "${test_no} ${test_mode} ${tps} $qps ${latency[0]} ${latency[1]} ${latency[2]} ${latency[3]}" >>${test_result}	
		done
	let test_no--
done
