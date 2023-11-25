#!/bin/bash

# Function to check if the kernel is supported and the file system is ext4
check_kernel_and_fs() 
{
    if grep -E "CONFIG_EXT4_FS_SECURITY|CONFIG_EXT4_FS_POSIX_ACL" /boot/config-$(uname -r) | grep -q "CONFIG_EXT4_FS_POSIX_ACL=y" && grep -E "CONFIG_EXT4_FS_SECURITY|CONFIG_EXT4_FS_POSIX_ACL" /boot/config-$(uname -r) | grep -q "CONFIG_EXT4_FS_SECURITY=y" && grep -q "ext4" /proc/mounts; then
        echo "Kernel is supported, and the file system is ext4"
    else
        echo "Kernel is not supported or the file system is not ext4"
        exit 1
    fi
}

# Check if the /etc/os-release file exists
check_os_release ()
{
    if [ -e /etc/os-release ]; then
        # Source the /etc/os-release file to get the OS version information
        source /etc/os-release

        # Check if the OS version is either 20.04 or 22.04
        if [[ "$VERSION_ID" == "20.04" || "$VERSION_ID" == "22.04" ]]; then
            echo "The OS version is supported (20.04 or 22.04)."
        else
            echo "Unsupported OS version: $VERSION_ID"
            exit 1
        fi
    else
        echo "The /etc/os-release file does not exist. Unable to determine OS version."
        exit 1
    fi
}

setting_the_static_ip () 
{
  # Directory where Netplan configuration files are stored
  netplan_dir="/etc/netplan/"

  while true; do
    # Check for existing .yaml files in /etc/netplan
    existing_yaml_files=("$netplan_dir"*.yaml)

    if [ ${#existing_yaml_files[@]} -gt 0 ]; then
      echo "Existing Netplan configuration files found in $netplan_dir:"
      for ((i=0; i<${#existing_yaml_files[@]}; i++)); do
        echo "[$i] ${existing_yaml_files[i]}"
      done

      read -p "Enter the number of the configuration file you want to backup (or 'c' to continue): " config_number

      # Check if the user wants to continue without backup
      if [[ "$config_number" == "c" || "$config_number" == "C" ]]; then
        break
      fi

      # Validate the selected configuration number
      if [[ ! "$config_number" =~ ^[0-9]+$ || "$config_number" -ge ${#existing_yaml_files[@]} ]]; then
        echo "Invalid selection. Please enter a valid configuration number or 'c' to continue."
        continue
      fi

      selected_config="${existing_yaml_files[$config_number]}"

      # Backup the selected configuration file
      sudo mv "$selected_config" "$selected_config.bak"
      echo "Backup of $selected_config created as $selected_config.bak"
    fi

    # List available network adapters
    adapters=($(ip -o link show | awk -F': ' '{print $2}'))

    # Display available adapters and prompt for selection
    echo "Available network adapters:"
    for ((i=0; i<${#adapters[@]}; i++)); do
      echo "[$i] ${adapters[i]}"
    done

    read -p "Enter the number of the network adapter you want to configure (or 'q' to quit): " adapter_number

    # Check if the user wants to quit
    if [[ "$adapter_number" == "q" || "$adapter_number" == "Q" ]]; then
      break
    fi

    # Validate the selected adapter number
    if [[ ! "$adapter_number" =~ ^[0-9]+$ || "$adapter_number" -ge ${#adapters[@]} ]]; then
      echo "Invalid selection. Please enter a valid adapter number or 'q' to quit."
      continue
    fi

    selected_adapter="${adapters[$adapter_number]}"

    # Prompt for static IP address and subnet mask
    read -p "Enter the static IP address for $selected_adapter (e.g., 192.168.1.2): " static_ip
    read -p "Enter the subnet mask for $selected_adapter (e.g., 8 , 16 , 24 ): " subnet_mask

    # Prompt for multiple DNS servers
    dns_servers=()
    while true; do
      read -p "Enter a DNS server IP address for $selected_adapter (or 'done' to finish): " dns_server
      if [[ "$dns_server" == "done" ]]; then
        break
      elif [[ "$dns_server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        dns_servers+=("$dns_server")
      else
        echo "Invalid DNS server IP address. Please enter a valid IP address or 'done' to finish."
      fi
    done

    # Prompt for gateway
    read -p "Enter the gateway IP address for $selected_adapter (e.g., 192.168.1.1): " gateway_ip

    # Generate the Netplan configuration file for the selected adapter
    cat <<EOF | sudo tee "$netplan_dir/99-config-${selected_adapter}.yaml" > /dev/null
network:
  version: 2
  renderer: networkd
  ethernets:
    ${selected_adapter}:
      addresses: ["${static_ip}/${subnet_mask}"]
      gateway4: ${gateway_ip}
      nameservers:
        addresses: [$(IFS=,; echo "${dns_servers[*]}")]
EOF

    # Apply the Netplan configuration
    sudo netplan apply

    echo "Configuration applied for $selected_adapter:"
    echo "Static IP: $static_ip"
    echo "Subnet Mask: $subnet_mask"
    echo "Gateway: $gateway_ip"
    echo "DNS Servers: ${dns_servers[@]}"

    echo "Configuration complete for $selected_adapter."

    read -p "Do you want to configure another network adapter? (yes/no): " configure_another
    if [[ "$configure_another" != "yes" && "$configure_another" != "Yes" ]]; then
      break
    fi
  done

  echo "Exiting the configuration script."
}

checking_and_removing_previous_samba_installation ()
{
    # Check if Samba configuration file (smb.conf) exists
    if [ -e /etc/samba/smb.conf ]; then
        echo "Samba configuration file (smb.conf) found. Removing..."
        rm /etc/samba/smb.conf
    fi
    # Check and remove Samba database files (*.tdb and *.ldb files)
    database_dirs=$(smbd -b | egrep "LOCKDIR|STATEDIR|CACHEDIR|PRIVATE_DIR" | awk -F'=' '{print $2}' | tr -d ' ')
    for dir in $database_dirs; do
        if [ -d "$dir" ]; then
            echo "Removing Samba database files in $dir..."
            find "$dir" -type f -name '*.tdb' -exec rm {} \;
            find "$dir" -type f -name '*.ldb' -exec rm {} \;
        fi
    done
    echo "Cleanup complete."
}

setting_hostname_for_server () 
{
    # One-liner summary for the user
    echo "Please choose a hostname for your Active Directory Domain Controller (AD DC) that is less than 15 characters and does not use NT4-only terms like PDC or BDC."

    # Prompt the user for the desired hostname
    read -p "Enter a hostname for your AD DC: " new_hostname

    # Check if the hostname length is less than 15 characters
    if [ ${#new_hostname} -le 15 ]; then
        # Set the hostname
        hostnamectl set-hostname $new_hostname

        # Inform the user about the hostname change
        echo "Hostname has been set to: $new_hostname"
    else
        # Inform the user if the hostname is too long
        echo "Hostname is too long. Please choose a hostname with less than 15 characters."
    fi

    #checking hostname
    echo "Checking hostname : "
    hostname -f
}

setting_etchosts_and_etcresolv ()
{
    # Validate domain name and IP address here if needed
    read -p "Enter Your Domain Name Lowercase :- " set_domainname
    company_fqdn="$new_hostname.$set_domainname"
    echo "Your Domain Name is: $set_domainname"
    echo "Your Fully Qualified Domain Name is: $company_fqdn"

    # Backup existing hosts file
    cp /etc/hosts /etc/hosts.backup

    # Update /etc/hosts
    echo "$static_ip    $company_fqdn  $new_hostname" >> /etc/hosts

    # Disable systemd-resolved (if needed)
    systemctl disable --now systemd-resolved

    # Backup existing resolv.conf and create a new one
    cp /etc/resolv.conf /etc/resolv.conf.backup
    unlink /etc/resolv.conf
    touch /etc/resolv.conf

    # Update /etc/resolv.conf
    cat <<EOF > /etc/resolv.conf
# Samba server IP address
nameserver $static_ip
# Fallback resolver (e.g., Google DNS)
nameserver 8.8.8.8
# Main domain for Samba
search $set_domainname
EOF

    # Make resolv.conf immutable
    chattr +i /etc/resolv.conf

    echo "Hosts and resolv.conf files have been updated."
}

downloading_and_configuring_samba ()
{
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y acl attr samba samba-dsdb-modules samba-vfs-modules smbclient winbind libpam-winbind libnss-winbind libpam-krb5 krb5-config krb5-user dnsutils chrony net-tools
  # Disable Samba Services
  systemctl disable --now smbd nmbd winbind
  # Backing up kerberous and samba files
  mv /etc/krb5.conf /etc/krb5.conf.original
  mv /etc/samba/smb.conf /etc/samba/smb.conf.bak

  #Provision AD
  samba-tool domain provision --use-rfc2307 --interactive
  #Starting Services
  systemctl unmask samba-ad-dc
  systemctl enable samba-ad-dc.service
  systemctl start samba-ad-dc.service
  #coping krb5.conf
  cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
  # Restart networking for changes to take effect
  systemctl restart systemd-networkd
}

setup_timezone ()
{
  timedatectl set-timezone Asia/Karachi
  # restart chronyd service
  systemctl restart chronyd
  # verify chronyd service status
  systemctl status chronyd
}

verification_for_ad ()
{
# verify domain example.lan
host -t A $set_domainname 
# verify domain dc1.example.lan
host -t A $company_fqdn
# verify SRV record for _kerberos
host -t SRV _kerberos._udp.$set_domainname
# verify SRV record for _ldap
host -t SRV _ldap._tcp.$set_domainname
# verify SRV record for _kerberos
host -t SRV _kerberos._udp.$set_domainname
# verify SRV record for _ldap
host -t SRV _ldap._tcp.$set_domainname
}

main ()
{
  check_kernel_and_fs
  check_os_release
  setting_the_static_ip
  checking_and_removing_previous_samba_installation
  setting_hostname_for_server
  setting_etchosts_and_etcresolv
  downloading_and_configuring_samba
  setup_timezone
  verification_for_ad
  kinit administrator@$set_domainname
}

main