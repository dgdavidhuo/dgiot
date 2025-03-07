#!/bin/bash
# This file is used to install dgiot on linux systems. The operating system
# is required to use systemd to manage services at boot

export PATH=$PATH:/usr/local/bin

lanip=""
wlanip=""
serverFqdn=""
processor=1
# -----------------------Variables definition---------------------
fileserver="http://dgiot-1253666439.cos.ap-shanghai-fsi.myqcloud.com/dgiot_release/v4.4.0"
updateserver="http://dgiot-1253666439.cos.ap-shanghai-fsi.myqcloud.com/dgiot_release/update"
#https://bcrypt-generator.com/
pg_pwd=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`

parse_user=dgiot
parse_pwd=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_appid=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_master=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_readonly_master=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_file=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_client=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_javascript=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_restapi=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_dotnet=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`
parse_webhook=`openssl rand -hex 8 | md5sum | cut -f1 -d ' '`

randtime=`date +%F_%T`
script_dir=$(dirname $(readlink -f "$0"))
#install path
install_dir="/data/dgiot"
backup_dir=${install_dir}/${randtime}
mkdir ${backup_dir} -p

#service path
service_dir="/lib/systemd/system"

# Color setting
RED='\033[0;31m'
GREEN='\033[1;32m'
GREEN_DARK='\033[0;32m'
GREEN_UNDERLINE='\033[4;32m'
NC='\033[0m'

csudo=""
if command -v sudo > /dev/null; then
    csudo="sudo"
fi

prompt_force=0
update_flag=0
initd_mod=0
service_mod=2
if pidof systemd &> /dev/null; then
    service_mod=0
elif $(which service &> /dev/null); then
    service_mod=1
    service_config_dir="/etc/init.d"
    if $(which chkconfig &> /dev/null); then
         initd_mod=1
    elif $(which insserv &> /dev/null); then
        initd_mod=2
    elif $(which update-rc.d &> /dev/null); then
        initd_mod=3
    else
        service_mod=2
    fi
else
    service_mod=2
fi

# get the operating system type for using the corresponding init file
# ubuntu/debian(deb), centos/fedora(rpm), others: opensuse, redhat, ..., no verification
#osinfo=$(awk -F= '/^NAME/{print $2}' /etc/os-release)
if [[ -e /etc/os-release ]]; then
  osinfo=$(cat /etc/os-release | grep "NAME" | cut -d '"' -f2)   ||:
else
  osinfo=""
fi
echo "osinfo: ${osinfo}"
os_type=0
if echo $osinfo | grep -qwi "ubuntu" ; then
#  echo "This is ubuntu system"
  os_type=1
elif echo $osinfo | grep -qwi "debian" ; then
#  echo "This is debian system"
  os_type=1
elif echo $osinfo | grep -qwi "Kylin" ; then
#  echo "This is Kylin system"
  os_type=1
elif  echo $osinfo | grep -qwi "centos" ; then
#  echo "This is centos system"
  os_type=2
elif echo $osinfo | grep -qwi "fedora" ; then
#  echo "This is fedora system"
  os_type=2
else
  echo " osinfo: ${osinfo}"
  echo " This is an officially unverified linux system,"
  echo " if there are any problems with the installation and operation, "
  echo " please feel free to contact www.iotn2n.com for support."
  os_type=1
fi

# =============================  get input parameters =================================================
# dgiot_install.sh -v [single | cluster] -d [prod.iotn2n.com | your_domain_name] -s [dgiot_44 | dgiot_n]

# set parameters by default value
verType=single        # [single | cluster]
domain_name="prod.iotn2n.com" #[prod.iotn2n.com | your_domain_name]
dgiot="dgiot_44"   #[dgiot_44 | dgiot_n]
while getopts "h:v:d:s:" arg
do
  case $arg in
    v)
      echo "verType=$OPTARG"
      verType=$(echo $OPTARG)
      ;;
    s)
      echo "dgiot=$OPTARG"
      dgiot=$(echo $OPTARG)
      ;;
    d)
      echo "Please ensure that the certificate file has been placed in ${script_dir}"
      echo -e  "`date +%F_%T`: ${GREEN} Please ensure that the certificate file has been placed in `pwd`${NC}"
      if [ ! -f  ${script_dir}/${domain_name}.zip  ]; then
        echo -e  "`date +%F_%T`: ${RED} ${script_dir}/${domain_name}.zip cert file not exist ${NC}"
        exit 1
      fi
      domain_name=$(echo $OPTARG)
      ;;
    h)
      echo "Usage: `basename $0` -v [single | cluster] -s [dgiot_44 | dgiot_n] -d [prod.iotn2n.com | your_domain_name]"
      exit 0
      ;;
    ?) #unknow option
      echo "unkonw argument"
      exit 1
      ;;
  esac
done

## 1.3. 部署前处理
function pre_install() {
  # 网络检查pre_install
  ping -c2 baidu.com
  get_lanip
  get_wanip
  get_processor

  ## 1.4 关闭防火墙，selinux
  #systemctl stop firewalld && sudo systemctl disable firewalld
  #sed -ri s/SELINUX=enforcing/SELINUX=disabled/g /etc/selinux/config
  #setenforce 0

  ## 1.5 配置阿里云yum源
  mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.bak
  curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo

  ## 1.6 echo "isntalling tools"
  #yum -y install vim net-tools wget ntpdate
  #yum -y groupinstall "Development Tools"

  ## 1.7 时间同步
  echo "*/10 * * * * /usr/sbin/ntpdate ntp.aliyun.com > /dev/null 2>&1" >>/etc/crontab

  ## 1.8 加快ssh连接
  sed -ri s/"#UseDNS yes"/"UseDNS no"/g /etc/ssh/sshd_config
  systemctl restart sshd
}

function get_processor() {
  processor=`cat /proc/cpuinfo| grep "processor"| wc -l`
}

function get_wanip() {
  wlanip=`curl whatismyip.akamai.com`
  echo -e  "`date +%F_%T`: ${GREEN} wlanip: ${wlanip}${NC}"
}

function get_lanip() {
  lanip=$(ip address |grep inet |grep -v inet6 |grep -v 127.0.0.1 |awk '{print $2}' |awk -F "/" '{print $1}') ||:
  if [ -z "$lanip" ]; then
    lanip=$(ifconfig |grep inet |grep -v inet6 |grep -v 127.0.0.1 |awk '{print $2}' |awk -F ":" '{print $2}') ||:
  fi

  if [ -z "$lanip" ]; then
    lanip="127.0.0.1"
  fi
  echo -e  "`date +%F_%T`: ${GREEN} lanip: ${lanip}${NC}"
}

function kill_process() {
  pid=$(ps -ef | grep "$1" | grep -v "grep" | awk '{print $2}')
  if [ -n "$pid" ]; then
    ${csudo} kill -9 $pid   || :
  fi
}

function clean_services(){
  clean_service dgiot_pg_writer
  clean_service dgiot
  clean_service dgiot_parse_server
  clean_service dgiot_redis
  clean_service grafana-server
  clean_service go_fastdfs
  clean_service taosd
  clean_service dgiot_tdengine_mqtt
  clean_service prometheus
  clean_service pushgateway
  clean_service node_exporter
  clean_service postgres_exporter
}

function clean_service() {
  if systemctl is-active --quiet $1; then
        echo -e  "`date +%F_%T`: ${GREEN} $1 is running, stopping it...${NC}"
        ${csudo} systemctl stop $1 &> /dev/null || echo &> /dev/null
    fi
  ${csudo} systemctl disable $1 &> /dev/null || echo &> /dev/null
  ${csudo} rm -f ${service_dir}/$1.service
}

# $1:service  $2:Type  $3:ExecStart  $4:User  $5:Environment  $6:ExecStop
function install_service() {
  service_config="${service_dir}/$1.service"
  echo -e  "`date +%F_%T`: ${GREEN} build ${service_config}${NC}"
  ${csudo} bash -c "echo '[Unit]'                             > ${service_config}"
  ${csudo} bash -c "echo 'Description=$1 server'              >> ${service_config}"
  ${csudo} bash -c "echo 'After=network-online.target'        >> ${service_config}"
  ${csudo} bash -c "echo 'Wants=network-online.target'        >> ${service_config}"
  ${csudo} bash -c "echo                                      >> ${service_config}"
  ${csudo} bash -c "echo '[Service]'                          >> ${service_config}"
  ${csudo} bash -c "echo 'Type=$2'                            >> ${service_config}"
  ${csudo} bash -c "echo 'ExecStart=$3'                        >> ${service_config}"
  if [ ! x"$4" = x ]; then
    ${csudo} bash -c "echo 'User=$4'                          >> ${service_config}"
    ${csudo} bash -c "echo 'Group=$4'                         >> ${service_config}"
  fi
  if [ ! x"$5" = x ]; then
    ${csudo} bash -c "echo 'Environment=$5'                   >> ${service_config}"
  fi
  if [[ -$# -eq 6 ]]; then
    ${csudo} bash -c "echo 'ExecStop=$6'                       >> ${service_config}"
  fi
  ${csudo} bash -c "echo 'KillMode=mixed'                      >> ${service_config}"
  ${csudo} bash -c "echo 'KillSignal=SIGINT'                   >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutSec=300'                      >> ${service_config}"
  ${csudo} bash -c "echo 'OOMScoreAdjust=-1000'                >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutStopSec=1000000s'             >> ${service_config}"
  ${csudo} bash -c "echo 'LimitNOFILE=infinity'                >> ${service_config}"
  ${csudo} bash -c "echo 'LimitNPROC=infinity'                 >> ${service_config}"
  ${csudo} bash -c "echo 'LimitCORE=infinity'                  >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutStartSec=0'                   >> ${service_config}"
  ${csudo} bash -c "echo 'StandardOutput=null'                 >> ${service_config}"
  ${csudo} bash -c "echo 'Restart=always'                      >> ${service_config}"
  ${csudo} bash -c "echo 'StartLimitBurst=3'                   >> ${service_config}"
  ${csudo} bash -c "echo 'StartLimitInterval=60s'              >> ${service_config}"
  ${csudo} bash -c "echo                                       >> ${service_config}"
  ${csudo} bash -c "echo '[Install]'                           >> ${service_config}"
  ${csudo} bash -c "echo 'WantedBy=multi-user.target'          >> ${service_config}"

  ${csudo} systemctl daemon-reload  &> /dev/null
  ${csudo} systemctl enable $1 &> /dev/null
  ${csudo} systemctl start $1 &> /dev/null
  echo -e  "`date +%F_%T`: ${GREEN} systemctl start $1${NC}"
}

# $1:service  $2:Type  $3:ExecStart  $4:Environment $5:WorkingDirectory
function install_service1() {
  service_config="${service_dir}/$1.service"
  echo -e  "`date +%F_%T`: ${GREEN} build ${service_config}${NC}"
  ${csudo} bash -c "echo '[Unit]'                             > ${service_config}"
  ${csudo} bash -c "echo 'Description=$1 server'              >> ${service_config}"
  ${csudo} bash -c "echo 'After=network-online.target'        >> ${service_config}"
  ${csudo} bash -c "echo 'Wants=network-online.target'        >> ${service_config}"
  ${csudo} bash -c "echo                                      >> ${service_config}"
  ${csudo} bash -c "echo '[Service]'                          >> ${service_config}"
  ${csudo} bash -c "echo 'Type=$2'                            >> ${service_config}"
  ${csudo} bash -c "echo 'ExecStart=$3'                        >> ${service_config}"
   if [ ! x"$5" = x ]; then
    ${csudo} bash -c "echo 'WorkingDirectory=$5'               >> ${service_config}"
  fi
  if [ ! x"$4" = x ]; then
    ${csudo} bash -c "echo 'Environment=$4'                   >> ${service_config}"
  fi
  ${csudo} bash -c "echo 'KillMode=mixed'                      >> ${service_config}"
  ${csudo} bash -c "echo 'KillSignal=SIGINT'                   >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutSec=300'                      >> ${service_config}"
  ${csudo} bash -c "echo 'OOMScoreAdjust=-1000'                >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutStopSec=1000000s'             >> ${service_config}"
  ${csudo} bash -c "echo 'LimitNOFILE=infinity'                >> ${service_config}"
  ${csudo} bash -c "echo 'LimitNPROC=infinity'                 >> ${service_config}"
  ${csudo} bash -c "echo 'LimitCORE=infinity'                  >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutStartSec=0'                   >> ${service_config}"
  ${csudo} bash -c "echo 'StandardOutput=null'                 >> ${service_config}"
  ${csudo} bash -c "echo 'Restart=always'                      >> ${service_config}"
  ${csudo} bash -c "echo 'StartLimitBurst=3'                   >> ${service_config}"
  ${csudo} bash -c "echo 'StartLimitInterval=60s'              >> ${service_config}"
  ${csudo} bash -c "echo                                       >> ${service_config}"
  ${csudo} bash -c "echo '[Install]'                           >> ${service_config}"
  ${csudo} bash -c "echo 'WantedBy=multi-user.target'          >> ${service_config}"

  ${csudo} systemctl daemon-reload &> /dev/null
  ${csudo} systemctl enable $1 &> /dev/null
  ${csudo} systemctl start $1 &> /dev/null
  echo -e  "`date +%F_%T`: ${GREEN} systemctl start $1${NC}"
}

# $1:service  $2:Type  $3:ExecStart
function install_service2() {
  service_config="${service_dir}/$1.service"
  echo -e  "`date +%F_%T`: ${GREEN} build ${service_config}${NC}"
  ${csudo} bash -c "echo '[Unit]'                             > ${service_config}"
  ${csudo} bash -c "echo 'Description=$1 server'              >> ${service_config}"
  ${csudo} bash -c "echo 'After=network-online.target'        >> ${service_config}"
  ${csudo} bash -c "echo 'Wants=network-online.target'        >> ${service_config}"
  ${csudo} bash -c "echo                                      >> ${service_config}"
  ${csudo} bash -c "echo '[Service]'                          >> ${service_config}"
  ${csudo} bash -c "echo 'Type=$2'                            >> ${service_config}"
  ${csudo} bash -c "echo 'ExecStart=$3'                        >> ${service_config}"
  ${csudo} bash -c "echo 'KillMode=mixed'                      >> ${service_config}"
  ${csudo} bash -c "echo 'KillSignal=SIGINT'                   >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutSec=300'                      >> ${service_config}"
  ${csudo} bash -c "echo 'OOMScoreAdjust=-1000'                >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutStopSec=1000000s'             >> ${service_config}"
  ${csudo} bash -c "echo 'LimitNOFILE=infinity'                >> ${service_config}"
  ${csudo} bash -c "echo 'LimitNPROC=infinity'                 >> ${service_config}"
  ${csudo} bash -c "echo 'LimitCORE=infinity'                  >> ${service_config}"
  ${csudo} bash -c "echo 'TimeoutStartSec=0'                   >> ${service_config}"
  ${csudo} bash -c "echo 'StandardOutput=null'                 >> ${service_config}"
  ${csudo} bash -c "echo 'Restart=always'                      >> ${service_config}"
  ${csudo} bash -c "echo 'StartLimitBurst=3'                   >> ${service_config}"
  ${csudo} bash -c "echo 'StartLimitInterval=60s'              >> ${service_config}"
  ${csudo} bash -c "echo                                       >> ${service_config}"
  ${csudo} bash -c "echo '[Install]'                           >> ${service_config}"
  ${csudo} bash -c "echo 'WantedBy=multi-user.target'          >> ${service_config}"

  ${csudo} systemctl daemon-reload &> /dev/null
  ${csudo} systemctl enable $1 &> /dev/null
  ${csudo} systemctl start $1 &> /dev/null
  echo -e  "`date +%F_%T`: ${GREEN} systemctl start $1${NC}"
}
##---------------------------------------------------------------##
#2 部署档案数据库
## 2.1 部署postgres数据库
### 2.1.1 环境准备，根据自身需要，减少或者增加
function yum_install_postgres() {
  echo -e  "${GREEN} yum install postgres${NC}"
  yum install -y wget git &> /dev/null
  ${csudo} yum install -y gcc gcc-c++  epel-release &> /dev/null
  ${csudo} yum install -y llvm5.0 llvm5.0-devel &> /dev/null
  ${csudo} yum install -y clang libicu-devel perl-ExtUtils-Embed &> /dev/null
  ${csudo} yum install -y readline readline-devel &> /dev/null
  ${csudo} yum install -y zlib zlib-devel &> /dev/null
  ${csudo} yum install -y openssl openssl-devel &> /dev/null
  ${csudo} yum install -y pam-devel libxml2-devel libxslt-devel &> /dev/null
  ${csudo} yum install -y  openldap-devel systemd-devel &> /dev/null
  ${csudo} yum install -y tcl-devel python-devel &> /dev/null
}

### 2.1.2 编译安装postgres
function install_postgres() {
  echo -e "`date +%F_%T`: ${GREEN}install_postgres${NC}"
  ##下载软件
  if [ ! -f ${script_dir}/postgresql-12.0.tar.gz ]; then
      ${csudo} wget ${fileserver}/postgresql-12.0.tar.gz -O ${script_dir}/postgresql-12.0.tar.gz &> /dev/null
  fi

  ### 创建目录和用户,以及配置环境变化
  echo -e "${GREEN}create postgres user and group ${NC}"
  set +uxe
  egrep "^postgres" /etc/passwd >/dev/null
  if [ $? -eq 0 ]; then
      echo -e "${GREEN} postgres user and group exist ${NC}"
  else
      ${csudo} groupadd postgres  &> /dev/null
      ${csudo} useradd -g postgres postgres  &> /dev/null
  fi

  ###  密码设置在引号内输入自己的密码
  echo ${pg_pwd} | passwd --stdin postgres
  echo "export PATH=/usr/local/pgsql/12/bin:$PATH" >/etc/profile.d/pgsql.sh
  source /etc/profile.d/pgsql.sh

  if [ -d ${script_dir}/postgresql-12.0 ]; then
   ${csudo} rm ${script_dir}/postgresql-12.0 -rf
  fi

  tar xvf postgresql-12.0.tar.gz &> /dev/null
  cd postgresql-12.0
  set -ue
  yum_install_postgres
  echo -e  "`date +%F_%T`: ${GREEN} configure postgres${NC}"
  ./configure --prefix=/usr/local/pgsql/12 --with-pgport=7432 --enable-nls --with-python --with-tcl --with-gssapi --with-icu --with-openssl --with-pam --with-ldap --with-systemd --with-libxml --with-libxslt &> /dev/null

  echo -e  "`date +%F_%T`: ${GREEN} make install postgres${NC}"
  make install -j${processor}  &> /dev/null

  ### 添加pg_stat_statements数据库监控插件
  cd ${script_dir}/postgresql-12.0/contrib/pg_stat_statements/
  echo -e  "`date +%F_%T`: ${GREEN} make install pg_stat_statements ${NC}"
  make install -j${processor}  &> /dev/null
  sleep 5

  rm ${script_dir}/postgresql-12.0 -rf
  cd ${script_dir}
  echo -e "`date +%F_%T`: ${GREEN}build postgres sueccess${NC}"
}

function init_postgres_database(){
  ### 2.1.4.搭建主数据库
  if [ -d ${install_dir}/dgiot_pg_writer ]; then
    ${csudo} mv ${install_dir}/dgiot_pg_writer/ ${backup_dir}/
  fi

  mkdir ${install_dir}/dgiot_pg_writer/data -p
  mkdir ${install_dir}/dgiot_pg_writer/archivedir -p
  chown -R postgres:postgres ${install_dir}/dgiot_pg_writer

  echo -e "`date +%F_%T`: ${GREEN}initdb postgres${NC}"
  sudo -u postgres /usr/local/pgsql/12/bin/initdb -D ${install_dir}/dgiot_pg_writer/data/ -U postgres --locale=en_US.UTF8 -E UTF8 &> /dev/null
  ${csudo} bash -c "cp ${install_dir}/dgiot_pg_writer/data/{pg_hba.conf,pg_hba.conf.bak}"
  ${csudo} bash -c "cp ${install_dir}/dgiot_pg_writer/data/{postgresql.conf,postgresql.conf.bak}"

  ### 2.1.5 配置postgresql.conf
  postgresql_conf="${install_dir}/dgiot_pg_writer/data/postgresql.conf"
  cat > ${postgresql_conf} << "EOF"
  listen_addresses = '*'
  port = 7432
  max_connections = 100
  superuser_reserved_connections = 10
  full_page_writes = on
  wal_log_hints = off
  max_wal_senders = 50
  hot_standby = on
  log_destination = 'csvlog'
  logging_collector = off
  log_directory = 'log'
  log_filename = 'postgresql-%Y-%m-%d_%H%M%S'
  log_rotation_age = 1d
  log_rotation_size = 10MB
  log_statement = 'mod'
  log_timezone = 'PRC'
  timezone = 'PRC'
  unix_socket_directories = '/tmp'
  shared_buffers = 512MB
  temp_buffers = 16MB
  work_mem = 32MB
  effective_cache_size = 2GB
  maintenance_work_mem = 128MB
  #max_stack_depth = 2MB
  dynamic_shared_memory_type = posix
  ## PITR
  full_page_writes = on
  wal_buffers = 16MB
  wal_writer_delay = 200ms
  commit_delay = 0
  commit_siblings = 5
  wal_level = replica
  archive_mode = off
  archive_timeout = 60s
  #pg_stat_statements
  shared_preload_libraries = 'pg_stat_statements'
  pg_stat_statements.max = 1000
  pg_stat_statements.track = all
EOF
  archivedir="${install_dir}/dgiot_pg_writer/archivedir"
  echo "  archive_command = 'test ! -f ${archivedir}/%f && cp %p ${archivedir}/%f'" >>  ${postgresql_conf}
  echo -e  "`date +%F_%T`: ${GREEN} ${postgresql_conf}${NC}"
}

### 2.1.4 安装部署postgres
function deploy_postgres() {
  clean_service dgiot_pg_writer
  install_postgres
  init_postgres_database
  DATA_DIR="${install_dir}/dgiot_pg_writer/data"
  install_service dgiot_pg_writer "notify" "/usr/local/pgsql/12/bin/postgres -D ${DATA_DIR}" "postgres" "DATA_DIR=${DATA_DIR}"
  sleep 2
  psql -U postgres -c "CREATE USER  repl WITH PASSWORD '${pg_pwd}' REPLICATION;" &> /dev/null
  echo -e  "`date +%F_%T`: ${GREEN} deploy postgres success${NC}"
}

## 2.2 部署parse server
### 1.2.2 下载parse初始数据
### 2.1.3 安装postgres_service系统服务
function install_parse_server() {
  ### 备份dgiot_parse_server
  if [ -d ${install_dir}/dgiot_parse_server ]; then
     mv ${install_dir}/dgiot_parse_server/ ${backup_dir}/dgiot_parse_server
     chown -R postgres:postgres ${backup_dir}/dgiot_parse_server/
  fi

  ###下载dgiot_parse_server软件
  if [ ! -f ${install_dir}/dgiot_parse_server.tar.gz ]; then
     wget ${fileserver}/dgiot_parse_server.tar.gz -O ${script_dir}/dgiot_parse_server.tar.gz &> /dev/null
  fi

  cd ${script_dir}/
  tar xf dgiot_parse_server.tar.gz
  mv ./dgiot_parse_server ${install_dir}/dgiot_parse_server
  ### 下载dgiot_parse_server初始数据
  wget ${fileserver}/parse_4.0.sql.tar.gz -O ${install_dir}/dgiot_parse_server/parse_4.0.sql.tar.gz &> /dev/null
  cd ${install_dir}/dgiot_parse_server/
  tar xvf parse_4.0.sql.tar.gz &> /dev/null

  ###  配置dgiot_parse_server配置参数
  parseconfig=${install_dir}/dgiot_parse_server/script/.env
  ${csudo} bash -c "echo '# 基础配置'                                                      > ${parseconfig}"
  ${csudo} bash -c "echo 'SERVER_NAME = dgiot_parse_server'                                >> ${parseconfig}"
  ${csudo} bash -c "echo 'SERVER_PORT = 1337'                                              >> ${parseconfig}"
  ${csudo} bash -c "echo 'SERVER_DOMAIN = http://${wlanip}:1337'                           >> ${parseconfig}"
  ${csudo} bash -c "echo  'SERVER_PUBLIC = http://${wlanip}:1337'                          >> ${parseconfig}"
  ${csudo} bash -c "echo  'SERVER_PATH = /parse'                                           >> ${parseconfig}"
  ${csudo} bash -c "echo  'GRAPHQL_PATH = http://${wlanip}:1337/graphql'                   >> ${parseconfig}"
  ${csudo} bash -c "echo  '# 管理配置'                                                      >> ${parseconfig}"
  ${csudo} bash -c "echo  'DASHBOARD_PATH = /dashboard'                                    >> ${parseconfig}"
  ${csudo} bash -c "echo  'DASHBOARD_USER = ${parse_user}'                                 >> ${parseconfig}"
  ${csudo} bash -c "echo  'DASHBOARD_PASS = ${parse_pwd}'                                  >> ${parseconfig}"
  ${csudo} bash -c "echo  'DASHBOARD_ENCPASS = false'                                      >> ${parseconfig}"
  ${csudo} bash -c "echo  '# 数据配置'                                                     >> ${parseconfig}"
  ${csudo} bash -c "echo  'DATABASE = postgres://postgres:${pg_pwd}@127.0.0.1:7432/parse'  >> ${parseconfig}"
  ${csudo} bash -c "echo  'REDIS_SOCKET = redis://127.0.0.1:16379/0'                       >> ${parseconfig}"
  ${csudo} bash -c "echo  'REDIS_CACHE = redis://127.0.0.1:16379/1'                        >> ${parseconfig}"
  ${csudo} bash -c "echo  '# 邮箱配置'                                                      >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_FROM_ADDRESS = lsxredrain@163.com'                           >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_FROM_NAME = 系统通知'                                      >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_SENDMAIL = true'                                           >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_SMTP_HOST = smtp.163.com'                                  >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_SMTP_PORT = 465'                                           >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_SMTP_SECURE = true'                                        >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_SMTP_USER = lsxredrain'                                    >> ${parseconfig}"
  ${csudo} bash -c "echo  'EMAIL_SMTP_PASS = youpasswd'                                     >> ${parseconfig}"
  ${csudo} bash -c "echo  '# 接口配置'                                                       >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_APPID = ${parse_appid}'                                       >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_MASTER = ${parse_master}'                                     >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_READONLY_MASTER = ${parse_readonly_master}'                   >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_FILE = ${parse_file}'                                         >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_CLIENT = ${parse_client}'                                     >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_JAVASCRIPT = ${parse_javascript}'                             >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_RESTAPI = ${parse_restapi}'                                   >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_DOTNET = ${parse_dotnet}'                                     >> ${parseconfig}"
  ${csudo} bash -c "echo  'KEY_WEBHOOK = ${parse_webhook}'                                   >> ${parseconfig}"
  ${csudo} bash -c "echo  '# 会话配置'                                                       >> ${parseconfig}"
  ${csudo} bash -c "echo  'SESSION_LENGTH = 604800'                                          >> ${parseconfig}"

  cd ${script_dir}

  echo -e "`date +%F_%T`: ${GREEN} create ${parseconfig} success${NC}"
  psql -U postgres -c "ALTER USER postgres WITH PASSWORD '${pg_pwd}';"  &> /dev/null
  retval=`psql -U postgres -c "SELECT datname FROM pg_database WHERE datistemplate = false;"`
  if [[ $retval == *"parse"* ]]; then
     pg_dump -F p -f  ${backup_dir}/dgiot_parse_server/parse_4.0_backup.sql -C -E  UTF8 -h 127.0.0.1 -U postgres parse &> /dev/null
     psql -U postgres -c "DROP DATABASE parse;" &> /dev/null
  fi
  psql -U postgres -c "CREATE DATABASE parse;" &> /dev/null
  psql -U postgres -f ${install_dir}/dgiot_parse_server/parse_4.0.sql parse &> /dev/null
  echo -e "`date +%F_%T`: ${GREEN}install parse_server success${NC}"
  }

function install_dgiot_redis() {
  ### 2.2.3 部署dgiot_redis缓存服务
  cd ${install_dir}/dgiot_parse_server/script/redis/
  make -j${processor} &> /dev/null
  cd ${script_dir}
}

function deploy_parse_server() {
  clean_service dgiot_parse_server
  clean_service dgiot_redis
  install_parse_server
  install_dgiot_redis
  parsehome="${install_dir}/dgiot_parse_server"
  install_service2 "dgiot_parse_server" "simple" "${parsehome}/script/node/bin/node  ${parsehome}/server/index.js"
  install_service2 "dgiot_redis" "simple" "${parsehome}/script/redis/src/redis-server ${parsehome}/script/redis.conf"
}

#3 部署时序数据服务
##3.1 部署tdengine server
function deploy_tdengine_server() {
  ### 1.2.4 下载TDengine-server
  if [ -f ${install_dir}/taos ]; then
     clean_service "taosd"
    mv ${install_dir}/taos/ ${backup_dir}/taos/
  fi

  if [ ! -f ${script_dir}/TDengine-server-2.0.20.13.tar.gz ]; then
    wget ${fileserver}/TDengine-server-2.0.20.13.tar.gz -O ${script_dir}/TDengine-server-2.0.20.13.tar.gz &> /dev/null
  fi

  cd ${script_dir}
  if [ -f ${script_dir}/TDengine-server-2.0.20.13 ]; then
    rm -rf ${script_dir}/TDengine-server-2.0.20.13/
  fi

  tar xf TDengine-server-2.0.20.13.tar.gz
  cd ${script_dir}/TDengine-server-2.0.20.13/
  mkdir ${install_dir}/taos/log/ -p
  mkdir ${install_dir}/taos/data/ -p
  echo | /bin/sh install.sh &> /dev/null
  ldconfig
  rm ${script_dir}/TDengine-server-2.0.20.13 -rf
  ${csudo} bash -c "echo 'logDir                    ${install_dir}/taos/log/'   > /etc/taos/taos.cfg"
  ${csudo} bash -c "echo 'dataDir                   ${install_dir}/taos/data/'   >> /etc/taos/taos.cfg"
  systemctl start taosd
  install_dgiot_tdengine_mqtt
}

## 3.3 部署dgiot_tdengine_mqtt桥接服务
function install_dgiot_tdengine_mqtt() {
  ## 3.2.setup mosquitto
  ### 1.2.5 下载mosquitto
  if [ ! -f ${script_dir}/mosquitto-1.6.7.tar.gz ]; then
    wget ${fileserver}/mosquitto-1.6.7.tar.gz -O ${script_dir}/mosquitto-1.6.7.tar.gz &> /dev/null
  fi
  if [ -d ${script_dir}/mosquitto-1.6.7/ ]; then
     rm ${script_dir}/mosquitto-1.6.7/ -rf
  fi
  cd  ${script_dir}
  tar xvf mosquitto-1.6.7.tar.gz &> /dev/null
  cd  ${script_dir}/mosquitto-1.6.7
  if [ -f /usr/lib/libmosquitto.so.1 ]; then
    rm /usr/lib/libmosquitto.so.1 -rf
  fi

  make -j${processor} &> /dev/null
  make install &> /dev/null
  sudo ln -s /usr/local/lib/libmosquitto.so.1 /usr/lib/libmosquitto.so.1
  ldconfig
  cd  ${script_dir}/
  rm ${script_dir}/mosquitto-1.6.7/ -rf
  wget ${fileserver}/dgiot_tdengine_mqtt -O /usr/sbin/dgiot_tdengine_mqtt &> /dev/null
  chmod 777 /usr/sbin/dgiot_tdengine_mqtt
  install_service2 dgiot_tdengine_mqtt "simple" "/usr/sbin/dgiot_tdengine_mqtt 127.0.0.1"
}

#4 安装文件数据服务器
function install_go_fastdfs() {
  if [ ! -f ${script_dir}/go_fastdfs.tar.gz ]; then
    wget ${fileserver}/go_fastdfs.tar.gz -O ${script_dir}/go_fastdfs.tar.gz &> /dev/null
  fi

  if [ -d ${install_dir}/go_fastdfs/ ]; then
    clean_service go_fastdfs
    mv ${install_dir}/go_fastdfs  ${backup_dir}/
  fi
  cd ${script_dir}/
  tar xvf go_fastdfs.tar.gz  &> /dev/null
  cd ${script_dir}/go_fastdfs
  chmod 777 ${script_dir}/go_fastdfs/file
  mv ${script_dir}/go_fastdfs ${install_dir}
  sed -i "s!{{ip}}!${lanip}!g"  ${install_dir}/go_fastdfs/cfg.json
  sed -i "s!{{port}}!1250!g"  ${install_dir}/go_fastdfs/cfg.json
  if [ -f ${install_dir}/go_fastdfs/conf/ ]; then
    rm ${install_dir}/go_fastdfs/conf/ -rf
  fi
  mkdir ${install_dir}/go_fastdfs/conf/ -p
  cp ${install_dir}/go_fastdfs/cfg.json  ${install_dir}/go_fastdfs/conf/cfg.json
  go_fastdhome=${install_dir}/go_fastdfs
  install_service1 gofastdfs "simple" "${install_dir}/go_fastdfs/file ${go_fastdhome}" "GO_FASTDFS_DIR=${go_fastdhome}" "${go_fastdhome}"
}


function yum_install_erlang_otp {
  echo -e "`date +%F_%T`: ${GREEN}yum_install_erlang_otp${NC}"
  yum install -y make gcc gcc-c++ &> /dev/null
  yum install -y kernel-devel m4 ncurses-devel &> /dev/null
  yum install -y libstdc++-devel openssl-devel &> /dev/null
  yum install  -y unixODBC unixODBC-devel &> /dev/null
  yum install -y libtool-ltdl libtool-ltdl-devel &> /dev/null

}
#5. 部署应用服务器
# 5.1 安装erlang/otp环境
function install_erlang_otp() {
  yum_install_erlang_otp
  if [ ! -f ${script_dir}/otp_src_23.0.tar.gz ]; then
    wget ${fileserver}/otp_src_23.0.tar.gz -O ${script_dir}/otp_src_23.0.tar.gz &> /dev/null
  fi
  if [ -d ${install_dir}/otp_src_23.0/ ]; then
    rm ${script_dir}/otp_src_23.0 -rf
  fi
  cd ${script_dir}
  tar xf otp_src_23.0.tar.gz &> /dev/null

  cd ${script_dir}/otp_src_23.0/
  echo -e "`date +%F_%T`: ${GREEN}otp configure${NC}"
  ./configure &> /dev/null
  echo -e "`date +%F_%T`: ${GREEN}otp make install${NC}"
  make install &> /dev/null
  cd ${script_dir}
  rm ${script_dir}/otp_src_23.0 -rf
  echo -e "`date +%F_%T`: ${GREEN}install erlang otp success${NC}"
}

function update_dgiot() {
  if [ ! -f ${script_dir}/${dgiot}.tar.gz ]; then
    wget $fileserver/${dgiot}.tar.gz -O ${script_dir}/${dgiot}.tar.gz &> /dev/null
  fi
  cd ${script_dir}
  tar xf ${dgiot}.tar.gz
  rm   ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf -rf
  cp   ${install_dir}/dgiot/etc/plugins/dgiot_parse.conf ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf
  cp   ${install_dir}/dgiot/etc/emqx.conf ${script_dir}/dgiot/etc/emqx.conf
  if [ -d ${install_dir}/dgiot/ ]; then
    clean_service dgiot
    mv ${install_dir}/dgiot  ${backup_dir}/dgiot/
  fi
  mv ${script_dir}/dgiot  ${install_dir}/

  install_service "dgiot" "forking" "/bin/sh ${install_dir}/dgiot/bin/emqx start"  "root" "HOME=${install_dir}/dgiot/erts-11.0" "/bin/sh /data/dgiot/bin/emqx stop"
}

function install_dgiot() {
  if [ ! -f ${script_dir}/${dgiot}.tar.gz ]; then
    wget $fileserver/${dgiot}.tar.gz -O ${script_dir}/${dgiot}.tar.gz &> /dev/null
  fi
  cd ${script_dir}
  tar xf ${dgiot}.tar.gz

  #修改 dgiot_parse 连接 配置
  ${csudo} bash -c  "sed -i '/^parse.parse_server/cparse.parse_server = http://127.0.0.1:1337' ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf"
  ${csudo} bash -c  "sed -i '/^parse.parse_path/cparse.parse_path = /parse/'  ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf"
  ${csudo} bash -c  "sed -i '/^parse.parse_appid/cparse.parse_appid = ${parse_appid}' ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf"
  ${csudo} bash -c  "sed -i '/^parse.parse_master_key/cparse.parse_master_key = ${parse_master}' ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf"
  ${csudo} bash -c  "sed -i '/^parse.parse_js_key/cparse.parse_js_key = ${parse_javascript}' ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf"
  ${csudo} bash -c  "sed -i '/^parse.parse_rest_key/cparse.parse_rest_key = ${parse_restapi}' ${script_dir}/dgiot/etc/plugins/dgiot_parse.conf"

  # 修改dgiot.conf
  ${csudo} bash -c "sed -i 's!/etc/ssl/certs/domain_name!/etc/ssl/certs/${domain_name}!g' ${script_dir}/dgiot/etc/emqx.conf"

  cat > ${script_dir}/dgiot/data/loaded_plugins << "EOF"
  {emqx_management, true}.
  {emqx_dashboard, true}.
  {emqx_modules, false}.
  {emqx_recon, true}.
  {emqx_retainer, true}.
  {emqx_telemetry, true}.
  {emqx_rule_engine, true}.
  {emqx_bridge_mqtt, false}.
  {dgiot, true}.
  {dgiot_parse, true}.
  {dgiot_api, true}.
  {dgiot_bridge, true}.
  {dgiot_device, true}.
  {dgiot_tdengine, true}.
  {dgiot_task, true}.
  {dgiot_http, true}.
  {dgiot_ffmpeg, true}.
  {dgiot_grpc, true}.
  {dgiot_license, true}.
  {dgiot_topo, true}.
  {dgiot_opc, true}.
  {dgiot_meter, true}.
  {dgiot_matlab, true}.
  {dgiot_niisten, true}.
  {dgiot_modbus, true}.
  {dgiot_group, true}.
  {dgiot_ffmpeg, true}.
EOF

  if [ -d ${install_dir}/dgiot/ ]; then
    clean_service dgiot
    mv ${install_dir}/dgiot  ${backup_dir}/dgiot/
  fi
  mv ${script_dir}/dgiot  ${install_dir}/

  install_service "dgiot" "forking" "/bin/sh ${install_dir}/dgiot/bin/emqx start"  "root" "HOME=${install_dir}/dgiot/erts-11.0" "/bin/sh /data/dgiot/bin/emqx stop"

}

#6 运维监控
# 6.1 安装node_exporter-0.18.1.linux-amd64.tar.gz
function install_node_exporter() {
  if [ ! -f ${script_dir}/node_exporter-0.18.1.linux-amd64.tar.gz ]; then
    wget ${fileserver}/node_exporter-0.18.1.linux-amd64.tar.gz -O ${script_dir}/node_exporter-0.18.1.linux-amd64.tar.gz &> /dev/null
  fi

  if [ -d ${install_dir}/node_exporter-0.18.1.linux-amd64/ ]; then
    clean_service node_exporter
    mv ${install_dir}/node_exporter-0.18.1.linux-amd64/ ${backup_dir}/
  fi

  tar -zxvf node_exporter-0.18.1.linux-amd64.tar.gz
  mv ${script_dir}/node_exporter-0.18.1.linux-amd64/ ${install_dir}/
  install_service2 node_exporter "simple" "/usr/local/bin/node_exporter"
}

##6.2 install postgres exporter
function install_postgres_exporter() {
  if [ ! -f ${script_dir}/postgres_exporter-0.10.0.linux-amd64.tar.gz ]; then
    wget ${fileserver}/postgres_exporter-0.10.0.linux-amd64.tar.gz -O ${script_dir}/postgres_exporter-0.10.0.linux-amd64.tar.gz &> /dev/null
  fi

  retval=`psql -U postgres -d parse -c "SELECT * FROM pg_available_extensions;"`
  if [[ $retval == *"pg_stat_statements"* ]]; then
      echo -e "`date +%F_%T`: ${GREEN}pg_stat_statements has installed${NC}"
  else
    psql -U postgres -d parse -c "CREATE EXTENSION pg_stat_statements SCHEMA public;"
    psql -U postgres -d parse -c "CREATE USER postgres_exporter PASSWORD 'password';"
    psql -U postgres -d parse -c "ALTER USER postgres_exporter SET SEARCH_PATH TO postgres_exporter,pg_catalog;"
    psql -U postgres -d parse -c "CREATE SCHEMA postgres_exporter AUTHORIZATION postgres_exporter;"
    psql -U postgres -d parse -c "CREATE FUNCTION postgres_exporter.f_select_pg_stat_activity()
    RETURNS setof pg_catalog.pg_stat_activity
    LANGUAGE sql
    SECURITY DEFINER
    AS \$\$
    SELECT * from pg_catalog.pg_stat_activity;
    \$\$;"

    psql -U postgres -d parse -c "CREATE FUNCTION postgres_exporter.f_select_pg_stat_replication()
    RETURNS setof pg_catalog.pg_stat_replication
    LANGUAGE sql
    SECURITY DEFINER
    AS \$\$
      SELECT * from pg_catalog.pg_stat_replication;
    \$\$;"

    psql -U postgres -d parse -c "CREATE VIEW postgres_exporter.pg_stat_replication
    AS
      SELECT * FROM postgres_exporter.f_select_pg_stat_replication();"

    psql -U postgres -d parse -c "CREATE VIEW postgres_exporter.pg_stat_activity
    AS
      SELECT * FROM postgres_exporter.f_select_pg_stat_activity();"

    psql -U postgres -d parse -c "GRANT SELECT ON postgres_exporter.pg_stat_replication TO postgres_exporter;"
    psql -U postgres -d parse -c "GRANT SELECT ON postgres_exporter.pg_stat_activity TO postgres_exporter;"
  fi

  systemctl restart dgiot_pg_writer

  if [ -d ${install_dir}/postgres_exporter-0.10.0.linux-amd64/ ]; then
    clean_service postgres_exporter
    mv ${install_dir}/postgres_exporter-0.10.0.linux-amd64/ ${backup_dir}/
  fi

  tar xvf postgres_exporter-0.10.0.linux-amd64.tar.gz  &> /dev/null
  mv ${script_dir}/postgres_exporter-0.10.0.linux-amd64/ ${install_dir}/
  export  DATA_SOURCE_NAME=postgresql://postgres:postgres@127.0.0.1:7432/parse?sslmode=disable
  install_service2 postgres_exporter "simple" "${install_dir}/postgres_exporter --extend.query-path='${install_dir}/queries.yaml'"
}

##6.3 安装prometheus-2.17.1.linux-amd64.tar.gz
function install_prometheus() {
  if [ ! -f ${script_dir}/prometheus-2.17.1.linux-amd64.tar.gz ]; then
     wget $fileserver/prometheus-2.17.1.linux-amd64.tar.gz -O ${script_dir}/prometheus-2.17.1.linux-amd64.tar.gz &> /dev/null
  fi

  cd ${script_dir}
  tar -zxvf prometheus-2.17.1.linux-amd64.tar.gz &> /dev/null

  if [ -d ${install_dir}/prometheus-2.17.1.linux-amd64/ ]; then
    clean_service pushgateway
    clean_service prometheus
    mv ${install_dir}/prometheus-2.17.1.linux-amd64/  ${backup_dir}/prometheus-2.17.1.linux-amd64/
  fi

  mv ${script_dir}/prometheus-2.17.1.linux-amd64/  ${install_dir}/
  install_service2 pushgateway "simple" "${install_dir}/prometheus-2.17.1.linux-amd64/pushgateway"
  install_service2 prometheus "simple" "${install_dir}/prometheus-2.17.1.linux-amd64/prometheus \
    --config.file=${install_dir}/prometheus-2.17.1.linux-amd64/prometheus.yml \
    --storage.tsdb.path=${install_dir}/prometheus-2.17.1.linux-amd64/data"
}

function  yum_install_grafana() {
  echo -e "`date +%F_%T`: ${GREEN}yum_install_grafana${NC}"
  yum install -y libXcomposite libXdamage libXtst cups libXScrnSaver &> /dev/null
  yum install -y pango atk adwaita-cursor-theme adwaita-icon-theme &> /dev/null
  yum install -y at at-spi2-atk at-spi2-core cairo-gobject colord-libs &> /dev/null
  yum install -y dconf desktop-file-utils ed emacs-filesystem gdk-pixbuf2 &> /dev/null
  yum install -y glib-networking gnutls gsettings-desktop-schemas &> /dev/null
  yum install -y  gtk-update-icon-cache gtk3 hicolor-icon-theme jasper-libs &> /dev/null
  yum install -y json-glib libappindicator-gtk3 libdbusmenu libdbusmenu-gtk3 libepoxy &> /dev/null
  yum install -y liberation-fonts liberation-narrow-fonts liberation-sans-fonts liberation-serif-fonts &> /dev/null
  yum install -y libgusb libindicator-gtk3 libmodman libproxy libsoup libwayland-cursor libwayland-egl &> /dev/null
  yum install -y  libxkbcommon m4 mailx nettle patch psmisc redhat-lsb-core redhat-lsb-submod-security &> /dev/null
  yum install -y rest spax time trousers xdg-utils xkeyboard-config alsa-lib &> /dev/null
}
###6.3.4 安装grafana-7.1.1.tar.gz
function install_grafana() {
  ## 部署图片报表插件
  yum_install_grafana
  if [ ! -f ${script_dir}/grafana-7.1.1.tar.gz ]; then
     wget ${fileserver}/grafana-7.1.1.tar.gz -O ${script_dir}/grafana-7.1.1.tar.gz &> /dev/null
  fi

  if [ -d ${install_dir}/grafana-7.1.1/ ]; then
    clean_service grafana-server
     mv ${install_dir}/grafana-7.1.1/  ${backup_dir}/grafana-7.1.1/
  fi
  cd ${script_dir}
  tar xvf grafana-7.1.1.tar.gz &> /dev/null

  mv ${script_dir}/grafana-7.1.1/  ${install_dir}/
  grafanahome=${install_dir}/grafana-7.1.1
  ${csudo} bash -c  "sed -i '/^plugins/cplugins = ${install_dir}/grafana-7.1.1/data/plugins/'  ${install_dir}/grafana-7.1.1/conf/defaults.ini"
  install_service2 grafana-server "simple" "${grafanahome}/bin/grafana-server --config=${grafanahome}/conf/defaults.ini  --homepath=${grafanahome}"
}

function install_nginx() {
    if systemctl is-active --quiet nginx; then
        echo -e  "`date +%F_%T`: ${GREEN} nginx is running, stopping it...${NC}"
        rpm -e nginx
    fi
    ${csudo} rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm --force &> /dev/null
    ${csudo} yum install -y nginx &> /dev/null
    if [ ! -f ${script_dir}/nginx.conf ]; then
       wget $fileserver/nginx.conf -O ${script_dir}/nginx.conf &> /dev/null
    fi
    if [ ! -f ${script_dir}/${domain_name}.zip ]; then
       wget $fileserver/${domain_name}.zip -O ${script_dir}/${domain_name}.zip  &> /dev/null
    fi
    rm  /etc/nginx/nginx.conf -rf
    cp ${script_dir}/nginx.conf /etc/nginx/nginx.conf -rf
    sed -i "s!{{domain_name}}!${domain_name}!g"  /etc/nginx/nginx.conf
    sed -i "s!{{install_dir}}!${install_dir}!g"  /etc/nginx/nginx.conf
    echo -e "`date +%F_%T`: ${GREEN}${install_dir}${NC}"
    if [ -f ${script_dir}/${domain_name}.zip ]; then
      unzip -o ${domain_name}.zip -d /etc/ssl/certs/ &> /dev/null
    fi
    systemctl start nginx.service
    systemctl enable nginx.service
}
## ==============================Main program starts from here============================

set -e
#set -x
echo -e "`date +%F_%T`: ${GREEN}dgiot  $verType deploy  start${NC}"
if [ "$verType" == "single" ]; then
    # Install server and client
    if [ -x ${install_dir}/dgiot ]; then
      update_flag=1
      update_dgiot
    else
      pre_install
      clean_services
      deploy_postgres
      deploy_parse_server     # 配置数据
      install_postgres_exporter
      deploy_tdengine_server  # 时序数据
      install_go_fastdfs      # 文件数据
      install_erlang_otp
      install_dgiot
      install_prometheus
      install_grafana
      install_nginx
    fi
elif [ "$verType" == "cluster" ]; then
    # todo
    if [ -x ${install_dir}/dgiot ]; then
      update_flag=1
      update_dgiot_cluster
    else
      install_update_dgiot_cluster
    fi
else
    echo  "please input correct verType"
fi
echo -e "`date +%F_%T`: ${GREEN}dgiot  $verType deploy  end${NC}"
