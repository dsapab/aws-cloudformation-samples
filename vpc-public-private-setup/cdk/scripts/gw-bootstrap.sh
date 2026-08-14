#!/bin/bash -xe

# Fail the stack fast (don't wait for the CreationPolicy timeout) if
# any command below errors.
trap '/opt/aws/bin/cfn-signal -e 1 --stack ${AWS::StackId} --resource CustomGwASG --region ${AWS::Region}' ERR

# --- Identity (IMDSv2) ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/meta-data/instance-id)

# --- Prerequisites ---
# Amazon Linux 2023 ships nftables, not the iptables command, so the
# MASQUERADE rule below needs the iptables package (nft-backed).
dnf install -y iptables

# --- Act as a router ---
# 1. Enable IPv4 forwarding (persisted so it survives reboots).
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-custom-gw.conf
sysctl -p /etc/sysctl.d/99-custom-gw.conf

# 2. Disable this instance's source/dest check so it can forward
#    packets not addressed to itself.
aws ec2 modify-instance-attribute --region ${AWS::Region} \
  --instance-id "$IID" --no-source-dest-check

# 3. Point the private route table's default route at this instance.
#    ReplaceRoute updates the (possibly blackholed) route left by a
#    previous instance; CreateRoute handles the very first boot.
aws ec2 replace-route --region ${AWS::Region} \
  --route-table-id ${PrivateRouteTable} \
  --destination-cidr-block 0.0.0.0/0 --instance-id "$IID" 2>/dev/null \
|| aws ec2 create-route --region ${AWS::Region} \
  --route-table-id ${PrivateRouteTable} \
  --destination-cidr-block 0.0.0.0/0 --instance-id "$IID"

# 4. NAT (masquerade) private-subnet traffic out the primary
#    interface. This gives working egress immediately, before any
#    VPN is wired. Rules are re-applied on each boot (ephemeral box).
PRIMARY_IF=$(ip route show default | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -s 10.0.0.0/16 -o "$PRIMARY_IF" -j MASQUERADE

# --- VPN client files ---
# Pull whatever is in the stack-created bucket into /etc/vpn. The
# bucket starts empty (files are uploaded later), so this is a no-op
# until then. Best-effort so an empty bucket never blocks boot.
mkdir -p /etc/vpn
aws s3 cp --recursive "s3://${CustomGwVpnBucket}/" /etc/vpn/ || true

############################################################
# TODO: VPN connect (left as a scaffold hook).
#   - Install the VPN client (e.g. `dnf install -y vpnc`).
#   - Connect the tunnel using the files in /etc/vpn.
#   - Re-point the MASQUERADE above from "$PRIMARY_IF" to tun0 so
#     private egress leaves via the VPN instead of the public subnet.
#   - Extend the watchdog probe below to also require the tunnel up
#     (`ip link show tun0`).
############################################################

# --- Health watchdog ---
# A booted instance whose route or egress is broken would otherwise
# sit in service black-holing traffic. This timer marks the instance
# unhealthy so the ASG replaces it.
cat > /usr/local/sbin/gw-healthcheck.sh <<'GWHC'
#!/bin/bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/meta-data/instance-id)
OK=1
# The private default route must still target THIS instance.
TARGET=$(aws ec2 describe-route-tables --region ${AWS::Region} \
  --route-table-ids ${PrivateRouteTable} \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].InstanceId | [0]" \
  --output text 2>/dev/null)
[ "$TARGET" = "$IID" ] || OK=0
# General egress must work (once VPN is wired, also require tun0 up).
curl -s --max-time 5 https://checkip.amazonaws.com >/dev/null 2>&1 || OK=0
if [ "$OK" -ne 1 ]; then
  aws autoscaling set-instance-health --region ${AWS::Region} \
    --instance-id "$IID" --health-status Unhealthy
fi
GWHC
chmod 0755 /usr/local/sbin/gw-healthcheck.sh

cat > /etc/systemd/system/gw-healthcheck.service <<'UNIT'
[Unit]
Description=Custom gateway route/egress health watchdog
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gw-healthcheck.sh
UNIT

cat > /etc/systemd/system/gw-healthcheck.timer <<'UNIT'
[Unit]
Description=Run the custom gateway health watchdog periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now gw-healthcheck.timer

# Signal success to the CreationPolicy.
/opt/aws/bin/cfn-signal -e 0 --stack ${AWS::StackId} --resource CustomGwASG --region ${AWS::Region}
