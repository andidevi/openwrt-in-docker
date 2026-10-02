systemctl cat docker.service docker.socket containerd.service
systemctl is-enabled systemd-networkd systemd-networkd-wait-online docker containerd
systemctl show openwrt.service -p Requires,Wants,After,Before,PartOf,BindsTo
journalctl -u openwrt.service -u openwrt-netattach.service --no-pager | tail -40
systemd-analyze verify /etc/systemd/system/openwrt*.service
