# 1.Hysteria2在Nodejs或Python部署

* Node.js/Python运行环境一键极简部署Hysteria2节点

* Hysteria2版本：2.6.5 官方更新说明（原文直译）：

  修复了随着每个客户端连接而累积的服务器端内存泄漏问题

* 更新自适应端口，无需再手动设置

```
curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/hy2.sh | sed 's/\r$//' | bash
```


---------------------------------------

# 2.TUIC在Nodejs或Python部署

* Node.js/Python运行环境一键极简部署TUIC节点

* 更新自适应端口，无需再手动设置

* TUIC版本：1.5.3 官方更新说明（原文直译）：
  
  更积极的max_concurrent_streams策略
  使用 json5 作为反序列化配置方法

```
curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash
```
