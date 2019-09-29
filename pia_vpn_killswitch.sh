#!/bin/bash

VPN_LOCATION="US West"
VPN_AUTH_USER_PASS_FILE='/root/.vpn_auth.txt'
OVPN_FOLDER="./ovpn/"
OVPN_FILE=""
VPN_IP=""

function create_vpn_auth_file_if_it_doesnt_exist() {
  if [ ! -f $VPN_AUTH_USER_PASS_FILE ]; then
    echo "VPN password file ($VPN_AUTH_USER_PASS_FILE) does not exist. Creating password file.";
    read -p 'VPN Username: ' uservar
    stty -echo # disable showing user input to terminal
    read -p 'VPN Password: ' passvar
    stty echo # reenable
    echo ""
    echo $uservar > $VPN_AUTH_USER_PASS_FILE && echo $passvar >> $VPN_AUTH_USER_PASS_FILE
    echo "VPN password file ($VPN_AUTH_USER_PASS_FILE) created.";
  else
    echo "Using VPN password file ($VPN_AUTH_USER_PASS_FILE)."
  fi
}

function list_vpn_regions() {
  download_ovpn_files_only_if_required
  for entry in "$OVPN_FOLDER"*.ovpn
  do
    filename=$(basename -- "$entry")
    echo "${filename%.*}"
  done
}

function download_ovpn_files_only_if_required() {
  if [ ! -d $OVPN_FOLDER ]; then
    download_ovpn_files
  fi
}

function download_ovpn_files() {
  echo "Downloading OVPN files"

  # delete all existing ovpn files
  if [ -d $OVPN_FOLDER ]; then
    echo "Deleting OVPN folder $OVPN_FOLDER"
    rm -rf $OVPN_FOLDER
  fi

  mkdir $OVPN_FOLDER
  
  # download latest ovpn files
  wget https://www.privateinternetaccess.com/openvpn/openvpn.zip -P $OVPN_FOLDER

  echo "Unzipping OVPN files to $OVPN_FOLDER"
  unzip -q ovpn/openvpn.zip -d $OVPN_FOLDER
}

function reset_all_settings() {
  echo "Clearing iptables rules"

  # flush (clear) nat tables
  sudo iptables -t nat -F
  sudo ip6tables -t nat -F

  # flush (clear) mangle tables
  sudo iptables -t mangle -F
  sudo ip6tables -t mangle -F

  # flush (clear) all chains
  sudo iptables -F
  sudo ip6tables -F

  # flush (clear) all non-default chains
  sudo iptables -X
  sudo ip6tables -X

  # set default to accept
  sudo iptables -P INPUT ACCEPT
  sudo iptables -P OUTPUT ACCEPT
  sudo iptables -P FORWARD ACCEPT

  local resolvconf="/etc/resolv.conf"
  echo "Updating $resolvconf file to google DNS server"
  echo 'nameserver 8.8.8.8' > $resolvconf
  echo 'nameserver 4.4.4.4' >> $resolvconf
}

function configure_ovpn_file() {
  local original_ovpn_file="${OVPN_FOLDER}${VPN_LOCATION}.ovpn"
  echo "Original OVPN file: $original_ovpn_file"
  
  OVPN_FILE="${original_ovpn_file}.modified"
  cp "$original_ovpn_file" "$OVPN_FILE"
  echo "Modified OVPN file: $OVPN_FILE"

  # get the dns name for the vpn location
  vpn_location_url=$(grep 'remote ' "$OVPN_FILE" | awk {'print $2'})
  echo "VPN DNS name: $vpn_location_url"

  # get the first ip address for that dns 
  VPN_IP=$(dig +short "$vpn_location_url" | awk {'print; exit;'})
  echo "VPN ip address: $VPN_IP"

  echo "Updating $OVPN_FILE file to replace DNS name with ip address"
  sed -i "s/remote $vpn_location_url/remote $VPN_IP/g" "$OVPN_FILE"  
}

function configure_iptables_rules() {
  echo "Configuring iptables rules for $VPN_LOCATION ($VPN_IP)"

  # allow in from VPN server
  sudo iptables -A INPUT -s $VPN_IP -j ACCEPT

  # allow traffic out from VPN server
  sudo iptables -A OUTPUT -d $VPN_IP -j ACCEPT

  echo "Configuring iptables input rules"

  # allow in on all private network address ranges
  sudo iptables -A INPUT -s 10.0.0.0/8 -d 10.0.0.0/8 -j ACCEPT
  sudo iptables -A INPUT -s 192.168.0.0/16 -d 192.168.0.0/16 -j ACCEPT
  sudo iptables -A INPUT -s 172.16.0.0/12 -d 172.16.0.0/12 -j ACCEPT

  # allow in from loopback and tun+ interface
  sudo iptables -A INPUT -i lo -j ACCEPT
  sudo iptables -A INPUT -i tun+ -j ACCEPT

  # create new chain that will log all packets to be dropped at a max rate of 10/min
  sudo iptables -N INPUT_LOG_THEN_DROP
  sudo iptables -A INPUT -j INPUT_LOG_THEN_DROP
  sudo iptables -A INPUT_LOG_THEN_DROP -m limit --limit 10/min -j LOG --log-prefix "[iptables DROP INPUT]: " --log-level 7
  sudo iptables -A INPUT_LOG_THEN_DROP -j DROP

  echo "Configuring iptables output rules"

  # allow out on all private network address ranges
  sudo iptables -A OUTPUT -s 10.0.0.0/8 -d 10.0.0.0/8 -j ACCEPT
  sudo iptables -A OUTPUT -s 192.168.0.0/16 -d 192.168.0.0/16 -j ACCEPT
  sudo iptables -A OUTPUT -s 172.16.0.0/12 -d 172.16.0.0/12 -j ACCEPT

  # allow out through loopback and tun+ interface
  sudo iptables -A OUTPUT -o lo -j ACCEPT
  sudo iptables -A OUTPUT -o tun+ -j ACCEPT

  # create new chain that will log all packets to be dropped at a max rate of 10/min
  sudo iptables -N OUTPUT_LOG_THEN_DROP
  sudo iptables -A OUTPUT -j OUTPUT_LOG_THEN_DROP
  sudo iptables -A OUTPUT_LOG_THEN_DROP -m limit --limit 10/min -j LOG --log-prefix "[iptables DROP OUTPUT]: " --log-level 7
  sudo iptables -A OUTPUT_LOG_THEN_DROP -j DROP

  echo "Configuring remaining iptables rules"

  # log forwarding packets then drop
  sudo iptables -N FORWARD_LOG_THEN_DROP
  sudo iptables -A FORWARD -j FORWARD_LOG_THEN_DROP
  sudo iptables -A FORWARD_LOG_THEN_DROP -m limit --limit 10/min -j LOG --log-prefix "[iptables DROP FORWARD]: " --log-level 7
  sudo iptables -A FORWARD_LOG_THEN_DROP -j DROP

  # set default on chains to drop
  sudo iptables -P OUTPUT DROP
  sudo iptables -P INPUT DROP
  sudo iptables -P FORWARD DROP

  # block all ipv6 packets
  sudo ip6tables -A OUTPUT -j DROP
  sudo ip6tables -A INPUT -j DROP
  sudo ip6tables -A FORWARD -j DROP
}

function configure_dns_resolv_conf_to_pia_dns() {
  local resolvconf="/etc/resolv.conf"
  echo "Updating $resolvconf file to PIA DNS server"
  echo 'nameserver 209.222.18.222' > $resolvconf
  echo 'nameserver 209.222.18.218' >> $resolvconf
}

function start_vpn() {
  reset_all_settings
  create_vpn_auth_file_if_it_doesnt_exist
  download_ovpn_files_only_if_required
  configure_ovpn_file
  configure_dns_resolv_conf_to_pia_dns
  configure_iptables_rules
  display_iptables
  echo "Starting openvpn (OVPN: $OVPN_FILE Auth:$VPN_AUTH_USER_PASS_FILE)"
  sudo openvpn --config "$OVPN_FILE" --auth-user-pass "$VPN_AUTH_USER_PASS_FILE"
}

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
function ctrl_c() {
  echo "CTRL+C trapped"
  reset_all_settings
}

function display_iptables() {
  echo "Displaying curret iptables"
  sudo iptables -vnL
}

function display_usage() {
  echo "Usage:"
  echo "    ./pia_vpn_killswitch.sh                Start the VPN."
  echo "    ./pia_vpn_killswitch.sh -s [LOCATION]  Start the VPN connecting to a specific region."
  echo "    ./pia_vpn_killswitch.sh -l             List all VPN regions."
  echo "    ./pia_vpn_killswitch.sh -h             Display this help message."
  echo "    ./pia_vpn_killswitch.sh -i             Display current iptables."
  echo "    ./pia_vpn_killswitch.sh -r             Restore system to original settings (iptables and dns)."
  echo "    ./pia_vpn_killswitch.sh -d             Download latest OVPN files."
}

while getopts "s:lhird" opt; do
  case ${opt} in
  s )
    echo "Setting VPN location to $OPTARG"
    VPN_LOCATION=$OPTARG
    start_vpn
    ;;
  l )
    list_vpn_regions
    ;;
  h )
    display_usage
    exit 0
    ;;
  i )
    display_iptables
    ;;
  r )
    reset_all_settings
    ;;
  d )
    download_ovpn_files
    ;;
  \? )
    echo "Invalid Option: -$OPTARG" 1>&2
    display_usage
    exit 1
    ;;
  esac
done

# if $OPTIND is still 1 then no options were processed so run default which is to start the vpn
if (( $OPTIND == 1 )); then
  start_vpn
fi

