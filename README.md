# 1.Hysteria2在Nodejs/Python一键脚本极简部署

* 更新自适应端口，无需再手动设置

* Hysteria2版本：2.6.5 官方更新说明（原文直译）：

  修复了随着每个客户端连接而累积的服务器端内存泄漏问题

```
curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/hy2.sh | sed 's/\r$//' | bash
```


---------------------------------------

# 2.TUIC在Nodejs/Python一键脚本极简部署

* 更新自适应端口，无需再手动设置

* TUIC版本：1.4.5 官方更新说明（原文直译）：

  🐛 错误修复
     （服务器）发送 FIN 以作废stream reset by peer

   ⚙️ 杂项任务
      将日志更改为跟踪

```
curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash
```

# 3.tuic-copy说明：

*TUIC在Nodejs/Python文件复制部署（适用无法执行bash命令的场景）

* 自适应端口，无需手动编辑文件，复制node.js+package.json文件即可
* TUIC版本：1.4.5
* hy2由于较高QoS阻断率，暂停更新
