基于Openwrt/LEDE编译的 Newifi D1 / C-LIFE-XG1 固件

[Newifi-Lede 定制固件讨论](https://t.me/newifi_lede)

<img width="450" height="225" alt="image" src="https://github.com/user-attachments/assets/5237b494-05bd-461c-99d3-5c8c2fcf47d8" />

# Compile in Virtual Machine
if you take 8 more threads (e.g, make -j8 V=s) to compile whole project, please make sure that you have sufficient memory assigned in virtual machine.
4GB is lowest, 8GB more is perfectable that won't have unexpected failures.

# Feeds
packages/helloword have been updated 
(https://github.com/simonchen/packages) (https://github.com/simonchen/helloworld.git)

# What's New
```
主题
Argon modern theme

系统
Diskman,文件传输
Kcptun客户端，Udp2raw，FRP内网穿透客户端, SmartDNS

服务
SSR plus+, OpenClash, Passwall, Adblock,全能推送,动态DDNS, QOS Nftables, 网络唤醒, KMS服务器, uPnP, OpenVPN, , NWAN3w分流助手
Kcptun客户端，Udp2raw，FRP内网穿透客户端, SmartDNS

管控
上网时间控制, 访问控制, 网址过滤, 定时唤醒

网络存储
Samba网络共享,FTP服务器

VPN
Zerotier

网络
iPerf3, Socat, turbo ACC 网络加速, 多线多拨, NWAN3负载均衡

打印
p910nd

集成驱动
MT7621 HNAT 硬件加速
MT7621 eip93 硬件加密
USB-RNDIS 驱动

Rtw88-usb 无线网卡驱动
支持下列芯片卡：
PCIe: RTW8822BE, RTW8822CE, RTW8821CE, RTW8723DE
USB: RTW8822BU, RTW8822CU, RTW8821CU, RTW8723DU
SDIO: RTW8822BS, RTW8822CS, RTW8821CS, RTW8723DS
```

# Fix issues

- 云编译替换LEDE源码[Rtw88-usb无线网卡驱动](https://github.com/simonchen/rtw88)
- 修复Shadowsocksr已知问题，添加Chinadns-ng作为DNS防污染
- 添加新的插件包：
```
luci-app-ssr-plus (Fix the rule with gfw mode / restarting without killing kcptun)

luci-app-kcptun (Brackets with $server variable for support IPv6 address)

luci-app-udp2raw (Brackets with ${listen_addr} / ${server_addr} variables for support IPv6 address)

udp2raw (Makefile that have downgrades to stable version of 0.45.0)

kcptun (Makefile that have downgrades to stable version 20210922)

frpc (Makefile that have removed upx compression - since the compressed bin can't run well)
```
