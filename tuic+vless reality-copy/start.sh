#!/bin/bash
# 启动 Xray 后台
./xray run -c ./xray.json &

# TUIC 前台执行，面板主进程
exec ./tuic-server -c ./server.toml

