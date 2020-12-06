#!/bin/bash

#3306 
port=3306
#osb
datadir=data
ip_last=$(/usr/sbin/ip addr show|awk -F'[./]' '/inet / && !/127.0.0.1/{print $4}')
 
#yum -y update
yum -y install gcc gcc-c++ openssl openssl-devel zlib zlib-devel libaio wget lsof vim-enhanced sysstat ntpdate
sed -i '/SELINUX/s/enforcing/disabled/' /etc/selinux/config
setenforce 0
 
#ntpdate 0.pool.ntp.org
#timedatectl set-timezone "Asia/Shanghai"
groupadd  mysql
useradd -d /usr/local/mysql -s /sbin/nologin -g mysql -M -n mysql
tar -zxf /opt/mysql-5.7.32-linux-glibc2.12-x86_64.tar.gz -C /opt/
mkdir -p /${datadir}/mysql${port}/{data,logs,tmp}
 
ln -s /opt/mysql-5.7.32-linux-glibc2.12-x86_64 /usr/local/mysql
chown mysql.mysql /opt/mysql /usr/local/mysql /${datadir} -R
echo 'PATH=$PATH:/usr/local/mysql/bin' >> /etc/profile
source /etc/profile
rm -rf /${datadir}/mysql${port} 2>/dev/null

mkdir -p /${datadir}/mysql${port}/{data,logs,tmp}
chown mysql.mysql /usr/local/mysql /${datadir} -R
cat > /etc/my.cnf << EOF
#my.cnf
[client]
port = ${port}
socket = /tmp/mysql${port}.sock
 
[mysql]
prompt="\u@\h [\d]>" 
 
[mysqld]
user = mysql
basedir = /usr/local/mysql
datadir = /${datadir}/mysql${port}/data
port = ${port}
socket = /tmp/mysql${port}.sock
event_scheduler = 0
explicit-defaults-for-timestamp=on
tmpdir = /${datadir}/mysql${port}/tmp

#timeout
interactive_timeout = 300
wait_timeout = 300
 
#character set
character-set-server = utf8
 
open_files_limit = 65535
max_connections = 100
max_connect_errors = 100000

#logs
log-output=file
slow_query_log = 1
slow_query_log_file = slow.log
log-error = error.log
log_error_verbosity=3
pid-file = mysql.pid
long_query_time = 1
#log-slow-admin-statements = 1
#log-queries-not-using-indexes = 1
log-slow-slave-statements = 1
 
#binlog
binlog_format = row
server-id = 23306
log-bin = /${datadir}/mysql${port}/logs/mysql-bin
binlog_cache_size = 20M
max_binlog_size = 256M
max_binlog_cache_size = 100M
sync_binlog = 0
expire_logs_days = 10
#procedure 
log_bin_trust_function_creators=1
 
#
gtid-mode=on
binlog_gtid_simple_recovery = 1
enforce_gtid_consistency = 1
log_slave_updates
 
#relay log
skip_slave_start = 1
max_relay_log_size = 128M
relay_log_purge = 1
relay_log_recovery = 1
relay-log=relay-bin
relay-log-index=relay-bin.index
#slave-skip-errors=1032,1053,1062
#skip-grant-tables
 
#buffers & cache
table_open_cache = 2048
table_definition_cache = 2048
table_open_cache = 2048
max_heap_table_size = 96M
sort_buffer_size = 128K
join_buffer_size = 128K
thread_cache_size = 200
query_cache_size = 0
query_cache_type = 0
query_cache_limit = 256K
query_cache_min_res_unit = 512
thread_stack = 192K
tmp_table_size = 96M
key_buffer_size = 8M
read_buffer_size = 2M
read_rnd_buffer_size = 16M
bulk_insert_buffer_size = 32M
 
#myisam
myisam_sort_buffer_size = 128M
myisam_max_sort_file_size = 10G
myisam_repair_threads = 1
 
#innodb
innodb_buffer_pool_size = 40G
innodb_buffer_pool_instances = 1
innodb_data_file_path = ibdata1:2048M:autoextend
innodb_flush_log_at_trx_commit = 2
innodb_log_buffer_size = 8M
innodb_log_file_size = 2048M
innodb_log_files_in_group = 3
innodb_max_dirty_pages_pct = 70
innodb_file_per_table = 1
innodb_rollback_on_timeout
innodb_status_file = 1
innodb_io_capacity = 20000
transaction_isolation = READ-COMMITTED
innodb_flush_method = O_DIRECT
innodb_read_io_threads = 8
innodb_write_io_threads = 8
EOF
 
cd /usr/local/mysql/
set -e 
./bin/mysqld --initialize
cp support-files/mysql.server /etc/init.d/mysqld
cp /etc/my.cnf /${datadir}/mysql${port}/${port}.cnf
/usr/local/mysql/bin/mysqld --defaults-file=/${datadir}/mysql${port}/${port}.cnf &
sleep 10
pass=`grep -i pass /${datadir}/mysql${port}/data/error.log|awk '{print $NF}'`
mysql -S /tmp/mysql${port}.sock -uroot --connect-expired-password -p${pass} -e "alter user user() identified by \"shannon\";"
mysql -S /tmp/mysql${port}.sock -uroot -pshannon -e "create database sbtest;"
