#!/usr/bin/env bash

# Warn users who aren't on oneiric, but allow them to override check and attempt
# installation with ``FORCE=yes ./stack``
DISTRO=$(lsb_release -c -s)

if [[ ! ${DISTRO} =~ (oneiric) ]]; then
    echo "WARNING: this script has only been tested on oneiric"
    if [[ "$FORCE" != "yes" ]]; then
        echo "If you wish to run this script anyway run with FORCE=yes"
        exit 1
    fi
fi

# Keep track of the current devstack directory.
TOP_DIR=$(cd $(dirname "$0") && pwd)

# stack.sh keeps the list of **apt** and **pip** dependencies in external
# files, along with config templates and other useful files.  You can find these
# in the ``files`` directory (next to this script).  We will reference this
# directory using the ``FILES`` variable in this script.
FILES=$TOP_DIR/files
if [ ! -d $FILES ]; then
    echo "ERROR: missing devstack/files - did you grab more than just stack.sh?"
    exit 1
fi



# Settings
# ========

# This script is customizable through setting environment variables.  If you
# want to override a setting you can either::
#
#     export MYSQL_PASSWORD=anothersecret
#     ./stack.sh
#
# You can also pass options on a single line ``MYSQL_PASSWORD=simple ./stack.sh``
#
# Additionally, you can put any local variables into a ``localrc`` file, like::
#
#     MYSQL_PASSWORD=anothersecret
#     MYSQL_USER=hellaroot
#
# We try to have sensible defaults, so you should be able to run ``./stack.sh``
# in most cases.
#
# We source our settings from ``stackrc``.  This file is distributed with devstack
# and contains locations for what repositories to use.  If you want to use other
# repositories and branches, you can add your own settings with another file called
# ``localrc``
#
# If ``localrc`` exists, then ``stackrc`` will load those settings.  This is
# useful for changing a branch or repository to test other versions.  Also you
# can store your other settings like **MYSQL_PASSWORD** or **ADMIN_PASSWORD** instead
# of letting devstack generate random ones for you.
source ./stackrc

# Destination path for installation ``DEST``
DEST=${DEST:-/opt/stack}

# Configure services to syslog instead of writing to individual log files
SYSLOG=${SYSLOG:-False}

# apt-get wrapper to just get arguments set correctly
function apt_get() {
    local sudo="sudo"
    [ "$(id -u)" = "0" ] && sudo="env"
    $sudo DEBIAN_FRONTEND=noninteractive apt-get \
        --option "Dpkg::Options::=--force-confold" --assume-yes "$@"
}


# OpenStack is designed to be run as a regular user (Horizon will fail to run
# as root, since apache refused to startup serve content from root user).  If
# stack.sh is run as root, it automatically creates a stack user with
# sudo privileges and runs as that user.

if [[ $EUID -eq 0 ]]; then
    ROOTSLEEP=${ROOTSLEEP:-10}
    echo "You are running this script as root."
    echo "In $ROOTSLEEP seconds, we will create a user 'stack' and run as that user"
    sleep $ROOTSLEEP

    # since this script runs as a normal user, we need to give that user
    # ability to run sudo
    dpkg -l sudo || apt_get update && apt_get install sudo

    if ! getent passwd stack >/dev/null; then
        echo "Creating a user called stack"
        useradd -U -G sudo -s /bin/bash -d $DEST -m stack
    fi

    echo "Giving stack user passwordless sudo priviledges"
    # some uec images sudoers does not have a '#includedir'. add one.
    grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" >> /etc/sudoers
    ( umask 226 && echo "stack ALL=(ALL) NOPASSWD:ALL" \
        > /etc/sudoers.d/50_stack_sh )

    echo "Copying files to stack user"
    STACK_DIR="$DEST/${PWD##*/}"
    cp -r -f "$PWD" "$STACK_DIR"
    chown -R stack "$STACK_DIR"
    if [[ "$SHELL_AFTER_RUN" != "no" ]]; then
        exec su -c "set -e; cd $STACK_DIR; bash stack.sh; bash" stack
    else
        exec su -c "set -e; cd $STACK_DIR; bash stack.sh" stack
    fi
    exit 1
else
    # Our user needs passwordless priviledges for certain commands which nova
    # uses internally.
    # Natty uec images sudoers does not have a '#includedir'. add one.
    sudo grep -q "^#includedir.*/etc/sudoers.d" /etc/sudoers ||
        echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers
    TEMPFILE=`mktemp`
    cat $FILES/sudo/nova > $TEMPFILE
    sed -e "s,%USER%,$USER,g" -i $TEMPFILE
    chmod 0440 $TEMPFILE
    sudo chown root:root $TEMPFILE
    sudo mv $TEMPFILE /etc/sudoers.d/stack_sh_nova
fi

# Set the destination directories for openstack projects
NOVA_DIR=$DEST/nova
GLANCE_DIR=$DEST/glance
NOVACLIENT_DIR=$DEST/python-novaclient

# Default Quantum Plugin
Q_PLUGIN=${Q_PLUGIN:-openvswitch}

# Specify which services to launch.  These generally correspond to screen tabs
ENABLED_SERVICES=${ENABLED_SERVICES:-g-api,g-reg,n-api,n-cpu,n-net,n-sch,mysql,rabbit}

# Name of the lvm volume group to use/create for iscsi volumes
VOLUME_GROUP=${VOLUME_GROUP:-nova-volumes}

# Nova hypervisor configuration.  We default to libvirt whth  **kvm** but will
# drop back to **qemu** if we are unable to load the kvm module.  Stack.sh can
# also install an **LXC** based system.
VIRT_DRIVER=${VIRT_DRIVER:-libvirt}
LIBVIRT_TYPE=${LIBVIRT_TYPE:-kvm}

# nova supports pluggable schedulers.  ``SimpleScheduler`` should work in most
# cases unless you are working on multi-zone mode.
SCHEDULER=${SCHEDULER:-nova.scheduler.simple.SimpleScheduler}

# Use the eth0 IP unless an explicit is set by ``HOST_IP`` environment variable
if [ ! -n "$HOST_IP" ]; then
    HOST_IP=`LC_ALL=C /sbin/ifconfig eth0 | grep -m 1 'inet addr:'| cut -d: -f2 | awk '{print $1}'`
    if [ "$HOST_IP" = "" ]; then
        echo "Could not determine host ip address."
        echo "If this is not your first run of stack.sh, it is "
        echo "possible that nova moved your eth0 ip address to the FLAT_NETWORK_BRIDGE."
        echo "Please specify your HOST_IP in your localrc."
        exit 1
    fi
fi

# Service startup timeout
SERVICE_TIMEOUT=${SERVICE_TIMEOUT:-60}

# Generic helper to configure passwords
function read_password {
    set +o xtrace
    var=$1; msg=$2
    pw=${!var}

    localrc=$TOP_DIR/localrc

    # If the password is not defined yet, proceed to prompt user for a password.
    if [ ! $pw ]; then
        # If there is no localrc file, create one
        if [ ! -e $localrc ]; then
            touch $localrc
        fi

        # Presumably if we got this far it can only be that our localrc is missing
        # the required password.  Prompt user for a password and write to localrc.
        echo ''
        echo '################################################################################'
        echo $msg
        echo '################################################################################'
        echo "This value will be written to your localrc file so you don't have to enter it again."
        echo "It is probably best to avoid spaces and weird characters."
        echo "If you leave this blank, a random default value will be used."
        echo "Enter a password now:"
        read -e $var
        pw=${!var}
        if [ ! $pw ]; then
            pw=`openssl rand -hex 10`
        fi
        eval "$var=$pw"
        echo "$var=$pw" >> $localrc
    fi
    set -o xtrace
}


# Nova Network Configuration
# --------------------------

# FIXME: more documentation about why these are important flags.  Also
# we should make sure we use the same variable names as the flag names.

PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-eth0}
FIXED_RANGE=${FIXED_RANGE:-10.0.0.0/24}
FIXED_NETWORK_SIZE=${FIXED_NETWORK_SIZE:-256}
FLOATING_RANGE=${FLOATING_RANGE:-172.24.4.224/28}
NET_MAN=${NET_MAN:-FlatDHCPManager}
EC2_DMZ_HOST=${EC2_DMZ_HOST:-$HOST_IP}
FLAT_NETWORK_BRIDGE=${FLAT_NETWORK_BRIDGE:-br100}
VLAN_INTERFACE=${VLAN_INTERFACE:-$PUBLIC_INTERFACE}

# Multi-host is a mode where each compute node runs its own network node.  This
# allows network operations and routing for a VM to occur on the server that is
# running the VM - removing a SPOF and bandwidth bottleneck.
MULTI_HOST=${MULTI_HOST:-False}

# If you are using FlatDHCP on multiple hosts, set the ``FLAT_INTERFACE``
# variable but make sure that the interface doesn't already have an
# ip or you risk breaking things.
#
# **DHCP Warning**:  If your flat interface device uses DHCP, there will be a
# hiccup while the network is moved from the flat interface to the flat network
# bridge.  This will happen when you launch your first instance.  Upon launch
# you will lose all connectivity to the node, and the vm launch will probably
# fail.
#
# If you are running on a single node and don't need to access the VMs from
# devices other than that node, you can set the flat interface to the same
# value as ``FLAT_NETWORK_BRIDGE``.  This will stop the network hiccup from
# occurring.
FLAT_INTERFACE=${FLAT_INTERFACE:-eth0}

## FIXME(ja): should/can we check that FLAT_INTERFACE is sane?

# Using Quantum networking:
#
# Make sure that q-svc is enabled in ENABLED_SERVICES.  If it is the network
# manager will be set to the QuantumManager.
#
# If you're planning to use the Quantum openvswitch plugin, set Q_PLUGIN to
# "openvswitch" and make sure the q-agt service is enabled in
# ENABLED_SERVICES.
#
# With Quantum networking the NET_MAN variable is ignored.


# MySQL & RabbitMQ
# ----------------

# We configure Nova, Horizon, Glance and Keystone to use MySQL as their
# database server.  While they share a single server, each has their own
# database and tables.

# By default this script will install and configure MySQL.  If you want to
# use an existing server, you can pass in the user/password/host parameters.
# You will need to send the same ``MYSQL_PASSWORD`` to every host if you are doing
# a multi-node devstack installation.
MYSQL_HOST=${MYSQL_HOST:-localhost}
MYSQL_USER=${MYSQL_USER:-root}
read_password MYSQL_PASSWORD "ENTER A PASSWORD TO USE FOR MYSQL."

# don't specify /db in this string, so we can use it for multiple services
BASE_SQL_CONN=${BASE_SQL_CONN:-mysql://$MYSQL_USER:$MYSQL_PASSWORD@$MYSQL_HOST}

# Rabbit connection info
RABBIT_HOST=${RABBIT_HOST:-localhost}
read_password RABBIT_PASSWORD "ENTER A PASSWORD TO USE FOR RABBIT."

# Glance connection info.  Note the port must be specified.
GLANCE_HOSTPORT=${GLANCE_HOSTPORT:-$HOST_IP:9292}

# Service Token - Openstack components need to have an admin token
# to validate user tokens.
read_password SERVICE_TOKEN "ENTER A SERVICE_TOKEN TO USE FOR THE SERVICE ADMIN TOKEN."

LOGFILE=${LOGFILE:-"$PWD/stack.sh.$$.log"}
(
# So that errors don't compound we exit on any errors so you see only the
# first error that occurred.
trap failed ERR
failed() {
    local r=$?
    set +o xtrace
    [ -n "$LOGFILE" ] && echo "${0##*/} failed: full log in $LOGFILE"
    exit $r
}

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following along as the install occurs.
set -o xtrace

# create the destination directory and ensure it is writable by the user
sudo mkdir -p $DEST
if [ ! -w $DEST ]; then
    sudo chown `whoami` $DEST
fi

# Install Packages
# ================
#
# Openstack uses a fair number of other projects.

# - We are going to install packages only for the services needed.
# - We are parsing the packages files and detecting metadatas.
#  - If there is a NOPRIME as comment mean we are not doing the install
#    just yet.
#  - If we have the meta-keyword distro:DISTRO or
#    distro:DISTRO1,DISTRO2 it will be installed only for those
#    distros (case insensitive).
function get_packages() {
    local file_to_parse="general"
    local service

    for service in ${ENABLED_SERVICES//,/ }; do
        # Allow individual services to specify dependencies
        if [[ -e $FILES/apts/${service} ]]; then
            file_to_parse="${file_to_parse} $service"
        fi
        if [[ $service == n-* ]]; then
            if [[ ! $file_to_parse =~ nova ]]; then
                file_to_parse="${file_to_parse} nova"
            fi
        elif [[ $service == g-* ]]; then
            if [[ ! $file_to_parse =~ glance ]]; then
                file_to_parse="${file_to_parse} glance"
            fi
        fi
    done

    for file in ${file_to_parse}; do
        local fname=${FILES}/apts/${file}
        local OIFS line package distros distro
        [[ -e $fname ]] || { echo "missing: $fname"; exit 1 ;}

        OIFS=$IFS
        IFS=$'\n'
        for line in $(<${fname}); do
            if [[ $line =~ "NOPRIME" ]]; then
                continue
            fi

            if [[ $line =~ (.*)#.*dist:([^ ]*) ]]; then # We are using BASH regexp matching feature.
                        package=${BASH_REMATCH[1]}
                        distros=${BASH_REMATCH[2]}
                        for distro in ${distros//,/ }; do  #In bash ${VAR,,} will lowecase VAR
                            [[ ${distro,,} == ${DISTRO,,} ]] && echo $package
                        done
                        continue
            fi

            echo ${line%#*}
        done
        IFS=$OIFS
    done
}

# install apt requirements
apt_get update
apt_get install $(get_packages)

# git clone only if directory doesn't exist already.  Since ``DEST`` might not
# be owned by the installation user, we create the directory and change the
# ownership to the proper user.
function git_clone {

    GIT_REMOTE=$1
    GIT_DEST=$2
    GIT_BRANCH=$3

    if echo $GIT_BRANCH | egrep -q "^refs"; then
        # If our branch name is a gerrit style refs/changes/...
        if [ ! -d $GIT_DEST ]; then
            git clone $GIT_REMOTE $GIT_DEST
        fi
        cd $GIT_DEST
        git fetch $GIT_REMOTE $GIT_BRANCH && git checkout FETCH_HEAD
    else
        # do a full clone only if the directory doesn't exist
        if [ ! -d $GIT_DEST ]; then
            git clone $GIT_REMOTE $GIT_DEST
            cd $GIT_DEST
            # This checkout syntax works for both branches and tags
            git checkout $GIT_BRANCH
        elif [[ "$RECLONE" == "yes" ]]; then
            # if it does exist then simulate what clone does if asked to RECLONE
            cd $GIT_DEST
            # set the url to pull from and fetch
            git remote set-url origin $GIT_REMOTE
            git fetch origin
            # remove the existing ignored files (like pyc) as they cause breakage
            # (due to the py files having older timestamps than our pyc, so python
            # thinks the pyc files are correct using them)
            find $GIT_DEST -name '*.pyc' -delete
            git checkout -f origin/$GIT_BRANCH
            # a local branch might not exist
            git branch -D $GIT_BRANCH || true
            git checkout -b $GIT_BRANCH
        fi
    fi
}

# compute service
git_clone $NOVA_REPO $NOVA_DIR $NOVA_BRANCH
# python client library to nova that horizon (and others) use
git_clone $NOVACLIENT_REPO $NOVACLIENT_DIR $NOVACLIENT_BRANCH

if [[ "$ENABLED_SERVICES" =~ "g-api" ||
      "$ENABLED_SERVICES" =~ "n-api" ]]; then
    # image catalog service
    git_clone $GLANCE_REPO $GLANCE_DIR $GLANCE_BRANCH
fi

# Initialization
# ==============


# setup our checkouts so they are installed into python path
# allowing ``import nova`` or ``import glance.client``
if [[ "$ENABLED_SERVICES" =~ "g-api" ||
      "$ENABLED_SERVICES" =~ "n-api" ]]; then
    cd $GLANCE_DIR; sudo python setup.py develop
fi
cd $NOVACLIENT_DIR; sudo python setup.py develop
cd $NOVA_DIR; sudo python setup.py develop

# Add a useful screenrc.  This isn't required to run openstack but is we do
# it since we are going to run the services in screen for simple
cp $FILES/screenrc ~/.screenrc

# Rabbit
# ---------

if [[ "$ENABLED_SERVICES" =~ "rabbit" ]]; then
    # Install and start rabbitmq-server
    # the temp file is necessary due to LP: #878600
    tfile=$(mktemp)
    apt_get install rabbitmq-server > "$tfile" 2>&1
    cat "$tfile"
    rm -f "$tfile"
    # change the rabbit password since the default is "guest"
    sudo rabbitmqctl change_password guest $RABBIT_PASSWORD
fi

# Mysql
# ---------

if [[ "$ENABLED_SERVICES" =~ "mysql" ]]; then

    # Seed configuration with mysql password so that apt-get install doesn't
    # prompt us for a password upon install.
    cat <<MYSQL_PRESEED | sudo debconf-set-selections
mysql-server-5.1 mysql-server/root_password password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/root_password_again password $MYSQL_PASSWORD
mysql-server-5.1 mysql-server/start_on_boot boolean true
MYSQL_PRESEED

    # while ``.my.cnf`` is not needed for openstack to function, it is useful
    # as it allows you to access the mysql databases via ``mysql nova`` instead
    # of having to specify the username/password each time.
    if [[ ! -e $HOME/.my.cnf ]]; then
        cat <<EOF >$HOME/.my.cnf
[client]
user=$MYSQL_USER
password=$MYSQL_PASSWORD
host=$MYSQL_HOST
EOF
        chmod 0600 $HOME/.my.cnf
    fi

    # Install and start mysql-server
    apt_get install mysql-server
    # Update the DB to give user ‘$MYSQL_USER’@’%’ full control of the all databases:
    sudo mysql -uroot -p$MYSQL_PASSWORD -h127.0.0.1 -e "GRANT ALL PRIVILEGES ON *.* TO '$MYSQL_USER'@'%' identified by '$MYSQL_PASSWORD';"

    # Edit /etc/mysql/my.cnf to change ‘bind-address’ from localhost (127.0.0.1) to any (0.0.0.0) and restart the mysql service:
    sudo sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf
    sudo service mysql restart
fi


# Glance
# ------

if [[ "$ENABLED_SERVICES" =~ "g-reg" ]]; then
    GLANCE_IMAGE_DIR=$DEST/glance/images
    # Delete existing images
    rm -rf $GLANCE_IMAGE_DIR

    # Use local glance directories
    mkdir -p $GLANCE_IMAGE_DIR

    # (re)create glance database
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS glance;'
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE glance;'

    # Copy over our glance configurations and update them
    GLANCE_CONF=$GLANCE_DIR/etc/glance-registry.conf
    cp $FILES/glance-registry.conf $GLANCE_CONF
    sudo sed -e "s,%SQL_CONN%,$BASE_SQL_CONN/glance,g" -i $GLANCE_CONF
    sudo sed -e "s,%SERVICE_TOKEN%,$SERVICE_TOKEN,g" -i $GLANCE_CONF
    sudo sed -e "s,%DEST%,$DEST,g" -i $GLANCE_CONF
    sudo sed -e "s,%SYSLOG%,$SYSLOG,g" -i $GLANCE_CONF

    GLANCE_API_CONF=$GLANCE_DIR/etc/glance-api.conf
    cp $FILES/glance-api.conf $GLANCE_API_CONF
    sudo sed -e "s,%DEST%,$DEST,g" -i $GLANCE_API_CONF
    sudo sed -e "s,%SERVICE_TOKEN%,$SERVICE_TOKEN,g" -i $GLANCE_API_CONF
    sudo sed -e "s,%SYSLOG%,$SYSLOG,g" -i $GLANCE_API_CONF
fi

# Nova
# ----

if [[ "$ENABLED_SERVICES" =~ "n-api" ]]; then
    # We are going to use a sample http middleware configuration based on the
    # one from the keystone project to launch nova.  This paste config adds
    # the configuration required for nova to validate keystone tokens. We add
    # our own service token to the configuration.
    cp $FILES/nova-api-paste.ini $NOVA_DIR/bin
    sed -e "s,%SERVICE_TOKEN%,$SERVICE_TOKEN,g" -i $NOVA_DIR/bin/nova-api-paste.ini
fi

if [[ "$ENABLED_SERVICES" =~ "n-cpu" ]]; then

    # Virtualization Configuration
    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    # attempt to load modules: network block device - used to manage qcow images
    sudo modprobe nbd || true

    # Check for kvm (hardware based virtualization).  If unable to initialize
    # kvm, we drop back to the slower emulation mode (qemu).  Note: many systems
    # come with hardware virtualization disabled in BIOS.
    if [[ "$LIBVIRT_TYPE" == "kvm" ]]; then
        apt_get install libvirt-bin
        sudo modprobe kvm || true
        if [ ! -e /dev/kvm ]; then
            echo "WARNING: Switching to QEMU"
            LIBVIRT_TYPE=qemu
        fi
    fi

    # Install and configure **LXC** if specified.  LXC is another approach to
    # splitting a system into many smaller parts.  LXC uses cgroups and chroot
    # to simulate multiple systems.
    if [[ "$LIBVIRT_TYPE" == "lxc" ]]; then
        apt_get install lxc
        # lxc uses cgroups (a kernel interface via virtual filesystem) configured
        # and mounted to ``/cgroup``
        sudo mkdir -p /cgroup
        if ! grep -q cgroup /etc/fstab; then
            echo none /cgroup cgroup cpuacct,memory,devices,cpu,freezer,blkio 0 0 | sudo tee -a /etc/fstab
        fi
        if ! mount -n | grep -q cgroup; then
            sudo mount /cgroup
        fi
    fi

    # The user that nova runs as needs to be member of libvirtd group otherwise
    # nova-compute will be unable to use libvirt.
    sudo usermod -a -G libvirtd `whoami`
    # libvirt detects various settings on startup, as we potentially changed
    # the system configuration (modules, filesystems), we need to restart
    # libvirt to detect those changes.
    sudo /etc/init.d/libvirt-bin restart


    # Instance Storage
    # ~~~~~~~~~~~~~~~~

    # Nova stores each instance in its own directory.
    mkdir -p $NOVA_DIR/instances

    # You can specify a different disk to be mounted and used for backing the
    # virtual machines.  If there is a partition labeled nova-instances we
    # mount it (ext filesystems can be labeled via e2label).
    if [ -L /dev/disk/by-label/nova-instances ]; then
        if ! mount -n | grep -q $NOVA_DIR/instances; then
            sudo mount -L nova-instances $NOVA_DIR/instances
            sudo chown -R `whoami` $NOVA_DIR/instances
        fi
    fi

    # Clean out the instances directory.
    sudo rm -rf $NOVA_DIR/instances/*
fi

if [[ "$ENABLED_SERVICES" =~ "n-net" ]]; then
    # delete traces of nova networks from prior runs
    sudo killall dnsmasq || true
    rm -rf $NOVA_DIR/networks
    mkdir -p $NOVA_DIR/networks
fi

# Volume Service
# --------------

if [[ "$ENABLED_SERVICES" =~ "n-vol" ]]; then
    #
    # Configure a default volume group called 'nova-volumes' for the nova-volume
    # service if it does not yet exist.  If you don't wish to use a file backed
    # volume group, create your own volume group called 'nova-volumes' before
    # invoking stack.sh.
    #
    # By default, the backing file is 2G in size, and is stored in /opt/stack.

    apt_get install iscsitarget-dkms iscsitarget

    if ! sudo vgdisplay | grep -q $VOLUME_GROUP; then
        VOLUME_BACKING_FILE=${VOLUME_BACKING_FILE:-$DEST/nova-volumes-backing-file}
        VOLUME_BACKING_FILE_SIZE=${VOLUME_BACKING_FILE_SIZE:-2052M}
        truncate -s $VOLUME_BACKING_FILE_SIZE $VOLUME_BACKING_FILE
        DEV=`sudo losetup -f --show $VOLUME_BACKING_FILE`
        sudo vgcreate $VOLUME_GROUP $DEV
    fi

    # Configure iscsitarget
    sudo sed 's/ISCSITARGET_ENABLE=false/ISCSITARGET_ENABLE=true/' -i /etc/default/iscsitarget
    sudo /etc/init.d/iscsitarget restart
fi

function add_nova_flag {
    echo "$1" >> $NOVA_DIR/bin/nova.conf
}

# (re)create nova.conf
rm -f $NOVA_DIR/bin/nova.conf
add_nova_flag "--verbose"
add_nova_flag "--allow_admin_api"
add_nova_flag "--scheduler_driver=$SCHEDULER"
add_nova_flag "--dhcpbridge_flagfile=$NOVA_DIR/bin/nova.conf"
add_nova_flag "--fixed_range=$FIXED_RANGE"
add_nova_flag "--network_manager=nova.network.manager.$NET_MAN"
if [[ "$ENABLED_SERVICES" =~ "n-vol" ]]; then
    add_nova_flag "--volume_group=$VOLUME_GROUP"
fi
add_nova_flag "--my_ip=$HOST_IP"
add_nova_flag "--public_interface=$PUBLIC_INTERFACE"
add_nova_flag "--vlan_interface=$VLAN_INTERFACE"
add_nova_flag "--sql_connection=$BASE_SQL_CONN/nova"
add_nova_flag "--libvirt_type=$LIBVIRT_TYPE"
add_nova_flag "--api_paste_config=$NOVA_DIR/bin/nova-api-paste.ini"
add_nova_flag "--image_service=nova.image.glance.GlanceImageService"
add_nova_flag "--ec2_dmz_host=$EC2_DMZ_HOST"
add_nova_flag "--rabbit_host=$RABBIT_HOST"
add_nova_flag "--rabbit_password=$RABBIT_PASSWORD"
add_nova_flag "--glance_api_servers=$GLANCE_HOSTPORT"
add_nova_flag "--force_dhcp_release"
if [ -n "$INSTANCES_PATH" ]; then
    add_nova_flag "--instances_path=$INSTANCES_PATH"
fi
if [ "$MULTI_HOST" != "False" ]; then
    add_nova_flag "--multi_host"
    add_nova_flag "--send_arp_for_ha"
fi
if [ "$SYSLOG" != "False" ]; then
    add_nova_flag "--use_syslog"
fi

# You can define extra nova conf flags by defining the array EXTRA_FLAGS,
# For Example: EXTRA_FLAGS=(--foo --bar=2)
for I in "${EXTRA_FLAGS[@]}"; do
    add_nova_flag $I
done

add_nova_flag "--flat_network_bridge=$FLAT_NETWORK_BRIDGE"
if [ -n "$FLAT_INTERFACE" ]; then
    add_nova_flag "--flat_interface=$FLAT_INTERFACE"
fi

# Nova Database
# ~~~~~~~~~~~~~

# All nova components talk to a central database.  We will need to do this step
# only once for an entire cluster.

if [[ "$ENABLED_SERVICES" =~ "mysql" ]]; then
    # (re)create nova database
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS nova;'
    mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE nova;'

    # (re)create nova database
    $NOVA_DIR/bin/nova-manage db sync
fi



# Launch Services
# ===============

# nova api crashes if we start it with a regular screen command,
# so send the start command by forcing text into the window.
# Only run the services specified in ``ENABLED_SERVICES``

# our screen helper to launch a service in a hidden named screen
function screen_it {
    NL=`echo -ne '\015'`
    if [[ "$ENABLED_SERVICES" =~ "$1" ]]; then
        if [[ "$USE_TMUX" =~ "yes" ]]; then
            tmux new-window -t stack -a -n "$1" "bash"
            tmux send-keys "$2" C-M
        else
            screen -S stack -X screen -t $1
            # sleep to allow bash to be ready to be send the command - we are
            # creating a new window in screen and then sends characters, so if
            # bash isn't running by the time we send the command, nothing happens
            sleep 1
            screen -S stack -p $1 -X stuff "$2$NL"
        fi
    fi
}

# create a new named screen to run processes in
screen -d -m -S stack -t stack
sleep 1

# launch the glance registry service
if [[ "$ENABLED_SERVICES" =~ "g-reg" ]]; then
    screen_it g-reg "cd $GLANCE_DIR; bin/glance-registry --config-file=etc/glance-registry.conf"
fi

# launch the glance api and wait for it to answer before continuing
if [[ "$ENABLED_SERVICES" =~ "g-api" ]]; then
    screen_it g-api "cd $GLANCE_DIR; bin/glance-api --config-file=etc/glance-api.conf"
    echo "Waiting for g-api ($GLANCE_HOSTPORT) to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! wget -q -O- http://$GLANCE_HOSTPORT; do sleep 1; done"; then
      echo "g-api did not start"
      exit 1
    fi
fi

# launch the nova-api and wait for it to answer before continuing
if [[ "$ENABLED_SERVICES" =~ "n-api" ]]; then
    screen_it n-api "cd $NOVA_DIR && $NOVA_DIR/bin/nova-api"
    echo "Waiting for nova-api to start..."
    if ! timeout $SERVICE_TIMEOUT sh -c "while ! wget -q -O- http://127.0.0.1:8774; do sleep 1; done"; then
      echo "nova-api did not start"
      exit 1
    fi
fi

# If we're using Quantum (i.e. q-svc is enabled), network creation has to
# happen after we've started the Quantum service.
if [[ "$ENABLED_SERVICES" =~ "mysql" ]]; then
    # create a small network
    $NOVA_DIR/bin/nova-manage network create private $FIXED_RANGE 1 $FIXED_NETWORK_SIZE

    # create some floating ips
    $NOVA_DIR/bin/nova-manage floating create $FLOATING_RANGE
fi

# Launching nova-compute should be as simple as running ``nova-compute`` but
# have to do a little more than that in our script.  Since we add the group
# ``libvirtd`` to our user in this script, when nova-compute is run it is
# within the context of our original shell (so our groups won't be updated).
# Use 'sg' to execute nova-compute as a member of the libvirtd group.
screen_it n-cpu "cd $NOVA_DIR && sg libvirtd $NOVA_DIR/bin/nova-compute"
screen_it n-vol "cd $NOVA_DIR && $NOVA_DIR/bin/nova-volume"
screen_it n-net "cd $NOVA_DIR && $NOVA_DIR/bin/nova-network"
screen_it n-sch "cd $NOVA_DIR && $NOVA_DIR/bin/nova-scheduler"

# Install Images
# ==============

# Upload an image to glance.
#
# The default image is a small ***TTY*** testing image, which lets you login
# the username/password of root/password.
#
# TTY also uses cloud-init, supporting login via keypair and sending scripts as
# userdata.  See https://help.ubuntu.com/community/CloudInit for more on cloud-init
#
# Override ``IMAGE_URLS`` with a comma-separated list of uec images.
#
#  * **natty**: http://uec-images.ubuntu.com/natty/current/natty-server-cloudimg-amd64.tar.gz
#  * **oneiric**: http://uec-images.ubuntu.com/oneiric/current/oneiric-server-cloudimg-amd64.tar.gz

if [[ "$ENABLED_SERVICES" =~ "g-reg" ]]; then
    # Create a directory for the downloaded image tarballs.
    mkdir -p $FILES/images

    # Option to upload legacy ami-tty, which works with xenserver
    if [ $UPLOAD_LEGACY_TTY ]; then
        if [ ! -f $FILES/tty.tgz ]; then
            wget -c http://images.ansolabs.com/tty.tgz -O $FILES/tty.tgz
        fi

        tar -zxf $FILES/tty.tgz -C $FILES/images
        RVAL=`glance add -A $SERVICE_TOKEN name="tty-kernel" is_public=true container_format=aki disk_format=aki < $FILES/images/aki-tty/image`
        KERNEL_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        RVAL=`glance add -A $SERVICE_TOKEN name="tty-ramdisk" is_public=true container_format=ari disk_format=ari < $FILES/images/ari-tty/image`
        RAMDISK_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        glance add -A $SERVICE_TOKEN name="tty" is_public=true container_format=ami disk_format=ami kernel_id=$KERNEL_ID ramdisk_id=$RAMDISK_ID < $FILES/images/ami-tty/image
    fi

    for image_url in ${IMAGE_URLS//,/ }; do
        # Downloads the image (uec ami+aki style), then extracts it.
        IMAGE_FNAME=`basename "$image_url"`
        IMAGE_NAME=`basename "$IMAGE_FNAME" .tar.gz`
        if [ ! -f $FILES/$IMAGE_FNAME ]; then
            wget -c $image_url -O $FILES/$IMAGE_FNAME
        fi

        # Extract ami and aki files
        tar -zxf $FILES/$IMAGE_FNAME -C $FILES/images

        # Use glance client to add the kernel the root filesystem.
        # We parse the results of the first upload to get the glance ID of the
        # kernel for use when uploading the root filesystem.
        RVAL=`glance add -A $SERVICE_TOKEN name="$IMAGE_NAME-kernel" is_public=true container_format=aki disk_format=aki < $FILES/images/$IMAGE_NAME-vmlinuz*`
        KERNEL_ID=`echo $RVAL | cut -d":" -f2 | tr -d " "`
        glance add -A $SERVICE_TOKEN name="$IMAGE_NAME" is_public=true container_format=ami disk_format=ami kernel_id=$KERNEL_ID < $FILES/images/$IMAGE_NAME.img
    done
fi

# Fin
# ===


) 2>&1 | tee "${LOGFILE}"

# Check that the left side of the above pipe succeeded
for ret in "${PIPESTATUS[@]}"; do [ $ret -eq 0 ] || exit $ret; done

(
# Using the cloud
# ===============

echo ""
echo ""
echo ""

# indicate how long this took to run (bash maintained variable 'SECONDS')
echo "stack.sh completed in $SECONDS seconds."

) | tee -a "$LOGFILE"
