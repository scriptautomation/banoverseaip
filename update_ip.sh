#!/bin/bash
curl -s -o /tmp/cn.zone http://www.ipdeny.com/ipblocks/data/countries/cn.zone
ipset flush cn_ip
sed -i "s/^/add cn_ip /" /tmp/cn.zone
ipset restore -! < /tmp/cn.zone
rm -f /tmp/cn.zone
# 只要集合名字不改，iptables 不需要动