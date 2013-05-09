#!/bin/sh
# Copyright (c) Zygmunt Krynicki 2013

# Try to identify the system
case $(lsb_release --short --id) in
    Ubuntu)
        base_os_list="ubuntu-$(lsb_release --short --codename) ubuntu debian dpkg"
        ;;
    Debian)
        base_os_list="debian-$(lsb_release --short --codename) debian dpkg"
        ;;
    "elementary OS")
        base_os_list="elementary-$(lsb_release --short --codename) elementary ubuntu-$(lsb_release --short --upstream --codename) ubuntu debian dpkg"
        ;;
    *)
        echo "Unsupported system"
        exit 1
esac

# Default configuration
enroll_packages=""
enroll_nas=""
enroll_nas_opts="defaults"
enroll_ssh_import_id_user=""

# Load configuration
test -r ./enroll.conf && . ./enroll.conf
test -r ./enroll-$(hostname).conf && . ./enroll-$(hostname).conf

# Install a named package
_install_dpkg() {
    dpkg-query --status $1 2>/dev/null | grep --quiet --fixed-strings 'Status: install ok installed' || (
        echo "[enroll] installing package: $1"
        apt-get install --quiet=2 --yes "$1"
    )
}

# Pick and install first matching package, argument list is a sequence of pairs
# $os_name:$pkg_name where $os_name matches any of the words in $base_os_list
install_supported() {
    for designator in $@; do
        os_name=$(echo $designator | cut -d : -f 1)
        pkg_name=$(echo $designator | cut -d : -f 2)
        for supported_os_name in $base_os_list; do
            if [ $supported_os_name = $os_name ]; then
                _install_dpkg $pkg_name
                return 0
            fi
        done
    done
    return 1
}


root_install_packages() {
    # Install requested packages
    for pkg in $enroll_packages; do
        install_supported $pkg
    done
    if [ "$DISPLAY" != "" ]; then
        for pkg in $enroll_packages_gui; do
            install_supported $pkg
        done
    fi
}


root_update_hosts() {
    # Update /etc/hosts
    new_hosts=$(mktemp)
    cp /etc/hosts $new_hosts
    for host_ip in $enroll_hosts; do
        host=$(echo $host_ip | cut -d : -f 1)
        # Don't add entry for the particular host not to collide with 127.0.1.1
        if [ "$(hostname)" = "$host" ]; then
            continue
        fi
        ip=192.168.0.$(echo $host_ip | cut -d : -f 2)
        if grep --quiet --fixed-strings "$ip $host" $new_hosts; then
            : # nothing to do
        elif grep --quiet --extended-regexp "^[0-9]+(\.[0-9]+){3} $host\$" $new_hosts; then
            sed -i -e "s/^[0-9]+(\.[0-9]+){3} $host\$/$ip $host/" $new_hosts
        else
            echo "$ip $host" >> $new_hosts
        fi
    done
    # Diff, just in case
    hosts_patch=$(mktemp --suffix=.patch)
    diff -u /etc/hosts $new_hosts > $hosts_patch
    if [ -s $hosts_patch ]; then
        patch --quiet /etc/hosts $hosts_patch
        echo "[enroll] Updated /etc/hosts with the following patch:"
        cat $hosts_patch
    fi
    rm $hosts_patch
    rm $new_hosts
}


root_connect_to_nas() {
    install_supported debian:nfs-common
    new_fstab=$(mktemp)
    marker='# ENROLL'
    cat /etc/fstab | grep --invert-match --fixed-strings "$marker" > $new_fstab
    for share in $( ( for share in $enroll_nas; do echo $share; done ) | sort); do
        # share is a $vol/$mnt pair
        mount_origin="silverbox:/mnt/$share"
        mount_name=$(echo $share | cut -d / -f 2)
        mount_point=/nas/$mount_name
        mount_fs=nfs
        mount_opts="$enroll_nas_opts"
        # Create and populate /nas
        test -d $mount_point || (
            echo "[enroll] creating nas mount point: $mount_point"
            mkdir -p "$mount_point"
        )
        entry="$mount_origin $mount_point $mount_fs $mount_opts 0 0 $marker"
        echo "$entry" >> $new_fstab
    done
    # Diff, just in case
    fstab_patch=$(mktemp --suffix=.patch)
    diff -u /etc/fstab $new_fstab > $fstab_patch
    if [ -s $fstab_patch ]; then
        patch --quiet /etc/fstab $fstab_patch
        echo "[enroll] Updated /etc/fstab with the following patch:"
        cat $fstab_patch
    fi
    rm $fstab_patch
    rm $new_fstab
}


user_install_dotfiles() {
    # Get personalized dotfiles
    if [ ! -d ~/.dotfiles ] && [ "x$enroll_dotfiles" != "x" ]; then
        echo "[enroll] setting up ~/.dotfiles from $enroll_dotfiles"
        install_supported ubuntu-lucid:git-core debian:git
        git clone "$enroll_dotfiles" ~/.dotfiles && (
        cd ~/.dotfiles && ./install-dot-files.sh
        )
    fi
}

user_ssh_import_id() {
    if [ "x$enroll_ssh_import_id_user" != "x" ]; then
        install_supported ubuntu:ssh-import-id && (
            ssh-import-id "$enroll_ssh_import_id_user"
        ) || (
            echo "[enroll] ssh-import-id is not supported here"
        )
    fi
}

# Check if this is the --root , --user or normal startup
case "$1" in
    --root)
        root_install_packages
        root_update_hosts
        root_connect_to_nas
        ;;
    --user)
        user_install_dotfiles
        user_ssh_import_id
        ;;
    '')
        # Say hi
        echo "[enroll] hostname: $(hostname)"
        echo "[enroll] OS name list: $base_os_list"
        # Rerun root and user parts
        sudo /bin/sh "$0" --root && /bin/sh "$0" --user
esac
