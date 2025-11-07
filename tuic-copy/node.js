#!/usr/bin/env node
/**
 * =========================================
 * TUIC v5 over QUIC 自动部署脚本（Node.js 版）
 * 定时重启：每天北京时间 00:00（24:00）
 * 
 * 【UUID 已手动设置！请修改下方双引号内的值】
 * 
 *    const UUID = "43622c18-0b6d-48c8-ba22-56b23b2fe2b2";
 * 
 *    示例：const UUID = "fdeeda45-0a8e-4570-bcc6-d68c995f5830";
 * 
 *    每次部署前请务必修改此值！
 * =========================================
 */
import { execSync, spawn } from "child_process";
import fs from "fs";
import https from "https";
import crypto from "crypto";

// ================== 【手动设置 UUID】==================
// 请将下方双引号内的值替换为您的 UUID
const UUID = "fdeeda45-0a8e-4570-bcc6-d68c995f5830";  // 修改这里！

// 格式校验（防止错误）
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(UUID)) {
  console.error("\nUUID 格式错误！");
  console.error("正确格式示例: fdeeda45-0a8e-4570-bcc6-d68c995f5830");
  console.error("当前值: " + UUID);
  process.exit(1);
}
console.log(`使用手动设置的 UUID: ${UUID}`);

// ================== 内置定时器（北京时间 00:00 重启）==================
function scheduleBeijingTimeMidnight(callback) {
  const now = new Date();
  const beijingNow = new Date(now.toLocaleString("en-US", { timeZone: "Asia/Shanghai" }));
  
  let target = new Date(beijingNow);
  target.setHours(0, 0, 0, 0);

  if (beijingNow.getTime() >= target.getTime()) {
    target.setDate(target.getDate() + 1);
  }

  const delay = target.getTime() - beijingNow.getTime();
  console.log(`[Timer] 下次重启：${target.toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })} (北京时间 00:00)`);

  setTimeout(() => {
    console.log(`[Timer] 北京时间 00:00 重启触发于 ${new Date().toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}`);
    callback();
    scheduleBeijingTimeMidnight(callback);
  }, delay);
}

// ================== 基本配置 ==================
const MASQ_DOMAINS = ["www.bing.com"];
const SERVER_TOML = "server.toml";
const CERT_PEM = "tuic-cert.pem";
const KEY_PEM = "tuic-key.pem";
const LINK_TXT = "tuic_link.txt";
const TUIC_BIN = "./tuic-server";

// ================== 工具函数 ==================
const randomPort = () => Math.floor(Math.random() * 40000) + 20000;
const randomSNI = () => MASQ_DOMAINS[Math.floor(Math.random() * MASQ_DOMAINS.length)];
const randomHex = (len = 16) => crypto.randomBytes(len).toString("hex");
function fileExists(p) { return fs.existsSync(p); }
function execSafe(cmd) {
  try { return execSync(cmd, { encoding: "utf8", stdio: "pipe" }).trim(); }
  catch { return ""; }
}

// ================== 准确获取公网 IP ==================
async function getPublicIP() {
  const sources = [
    "https://api.ipify.org",
    "https://ifconfig.me",
    "https://icanhazip.com",
    "https://ipinfo.io/ip"
  ];
  for (const url of sources) {
    try {
      const ip = await new Promise((resolve, reject) => {
        const req = https.get(url, { timeout: 3000 }, (res) => {
          let data = "";
          res.on("data", chunk => data += chunk);
          res.on("end", () => resolve(data.trim()));
        });
        req.on("error", reject);
        req.setTimeout(3000, () => req.destroy());
      });
      if (ip && !/^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|169\.254\.)/.test(ip)) {
        console.log(`公网 IP: ${ip}`);
        return ip;
      }
    } catch (e) {}
  }
  console.log("警告：无法获取公网 IP，使用 127.0.0.1");
  return "127.0.0.1";
}

// ================== 下载文件 ==================
async function downloadFile(url, dest, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    if (redirectCount > 5) return reject(new Error("重定向次数过多"));
    const file = fs.createWriteStream(dest);
    https.get(url, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
        const newUrl = res.headers.location;
        console.log(`Redirecting to: ${newUrl}`);
        file.close();
        try { fs.unlinkSync(dest); } catch {}
        return resolve(downloadFile(newUrl, dest, redirectCount + 1));
      }
      if (res.statusCode !== 200) return reject(new Error(`下载失败: ${res.statusCode}`));
      res.pipe(file);
      file.on("finish", () => file.close(resolve));
    }).on("error", reject);
  });
}

// ================== 读取端口（仅随机或环境变量）=================
function readPort() {
  if (process.env.SERVER_PORT && !isNaN(process.env.SERVER_PORT)) {
    console.log(`Using env port: ${process.env.SERVER_PORT}`);
    return Number(process.env.SERVER_PORT);
  }
  const port = randomPort();
  console.log(`Random port: ${port}`);
  return port;
}

// ================== 生成证书 ==================
function generateCert(domain) {
  if (fileExists(CERT_PEM) && fileExists(KEY_PEM)) {
    console.log("Certificate exists");
    return;
  }
  console.log(`Generating cert for ${domain}...`);
  execSafe(
    `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 ` +
    `-keyout ${KEY_PEM} -out ${CERT_PEM} -subj "/CN=${domain}" -days 365 -nodes`
  );
  fs.chmodSync(KEY_PEM, 0o600);
  fs.chmodSync(CERT_PEM, 0o644);
}

// ================== 下载 tuic-server ==================
async function checkTuicServer() {
  if (fileExists(TUIC_BIN)) {
    console.log("tuic-server exists");
    return;
  }
  console.log("Downloading tuic-server v1.4.5...");
  const url = "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux";
  await downloadFile(url, TUIC_BIN);
  fs.chmodSync(TUIC_BIN, 0o755);
  console.log("tuic-server downloaded");
}

// ================== 生成配置 ==================
function generateConfig(uuid, password, port, domain) {
  const secret = randomHex(16);
  const mtu = 1200 + Math.floor(Math.random() * 200);
  const toml = `
log_level = "warn"
server = "0.0.0.0:${port}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192
[users]
${uuid} = "${password}"
[tls]
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]
[restful]
addr = "127.0.0.1:${port}"
secret = "${secret}"
maximum_clients_per_user = 999999999
[quic]
initial_mtu = ${mtu}
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"
[quic.congestion_control]
controller = "bbr"
initial_window = 6291456
`;
  fs.writeFileSync(SERVER_TOML, toml.trim() + "\n");
  console.log("Config generated:", SERVER_TOML);
}

// ================== 生成链接 ==================
function generateLink(uuid, password, ip, port, domain) {
  const link = `tuic://${uuid}:${password}@${ip}:${port}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${domain}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}`;
  fs.writeFileSync(LINK_TXT, link);
  console.log("TUIC Link:");
  console.log(link);
}

// ================== 守护运行 ==================
function runLoop() {
  console.log("Starting TUIC service...");
  const loop = () => {
    const proc = spawn(TUIC_BIN, ["-c", SERVER_TOML], { stdio: "ignore" });
    proc.on("exit", (code) => {
      console.log(`TUIC exited (${code}), restarting in 5s...`);
      setTimeout(loop, 5000);
    });
  };
  loop();
}

// ================== 主流程 ==================
async function main() {
  console.log("TUIC v5 over QUIC 自动部署开始");

  // 1. 启动定时重启
  scheduleBeijingTimeMidnight(() => {
    process.exit(0);
  });

  // 2. 部署逻辑
  const port = readPort();
  const domain = randomSNI();
  const password = randomHex(16);

  generateCert(domain);
  await checkTuicServer();
  generateConfig(UUID, password, port, domain);
  const ip = await getPublicIP();
  generateLink(UUID, password, ip, port, domain);
  runLoop();
}

main().catch((err) => console.error("Error:", err));
