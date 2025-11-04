#!/usr/bin/env node
/**
 * =========================================
 * TUIC v5 over QUIC 自动部署脚本（Node.js 版，无需 root）
 * 特性：
 *  - 支持自定义端口参数或环境变量 SERVER_PORT
 *  - 使用确认为 v1.4.5 x86_64-linux 二进制下载链接（硬编码）
 *  - 随机伪装域名
 *  - 自动生成证书
 *  - 自动下载 tuic-server
 *  - 自动生成配置文件与 TUIC 链接
 *  - 自动守护运行
 * =========================================
 */

import { execSync, spawn } from "child_process";
import fs from "fs";
import https from "https";
import crypto from "crypto";

process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

// ================== 基本配置 ==================
const MASQ_DOMAINS = [
  "www.bing.com",
];

const SERVER_TOML = "server.toml";
const CERT_PEM = "tuic-cert.pem";
const KEY_PEM = "tuic-key.pem";
const LINK_TXT = "tuic_link.txt";
const TUIC_BIN = "./tuic-server";

// ================== 工具函数 ==================
const randomPort = () => Math.floor(Math.random() * 40000) + 20000;
const randomSNI = () =>
  MASQ_DOMAINS[Math.floor(Math.random() * MASQ_DOMAINS.length)];
const randomHex = (len = 16) => crypto.randomBytes(len).toString("hex");
const uuid = () => crypto.randomUUID();

function fileExists(p) {
  return fs.existsSync(p);
}

function execSafe(cmd) {
  try {
    return execSync(cmd, { encoding: "utf8", stdio: "pipe" }).trim();
  } catch {
    return "";
  }
}

// ================== 下载文件（支持重定向） ==================
async function downloadFile(url, dest, redirectCount = 0) {
  return new Promise((resolve, reject) => {
    if (redirectCount > 5) return reject(new Error("重定向次数过多"));
    const file = fs.createWriteStream(dest);
    https
      .get(url, (res) => {
        if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
          const newUrl = res.headers.location;
          console.log(`↪️ 跳转到新地址: ${newUrl}`);
          file.close();
          try { fs.unlinkSync(dest); } catch(e){}
          return resolve(downloadFile(newUrl, dest, redirectCount + 1));
        }

        if (res.statusCode !== 200)
          return reject(new Error(`下载失败: ${res.statusCode}`));

        res.pipe(file);
        file.on("finish", () => file.close(resolve));
      })
      .on("error", reject);
  });
}

// ================== 读取端口 ==================
function readPort() {
  const argPort = process.argv[2];
  if (argPort && !isNaN(argPort)) {
    console.log(`✅ 使用命令行端口: ${argPort}`);
    return Number(argPort);
  }

  if (process.env.SERVER_PORT && !isNaN(process.env.SERVER_PORT)) {
    console.log(`✅ 使用环境变量端口: ${process.env.SERVER_PORT}`);
    return Number(process.env.SERVER_PORT);
  }

  const port = randomPort();
  console.log(`🎲 自动分配随机端口: ${port}`);
  return port;
}

// ================== 生成证书 ==================
function generateCert(domain) {
  if (fileExists(CERT_PEM) && fileExists(KEY_PEM)) {
    console.log("🔐 证书存在，跳过生成");
    return;
  }
  console.log(`🔐 生成伪装证书 (${domain})...`);
  execSafe(
    `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout ${KEY_PEM} -out ${CERT_PEM} -subj "/CN=${domain}" -days 365 -nodes`
  );
  fs.chmodSync(KEY_PEM, 0o600);
  fs.chmodSync(CERT_PEM, 0o644);
}

// ================== 检查或下载 tuic-server ==================
async function checkTuicServer() {
  if (fileExists(TUIC_BIN)) {
    console.log("✅ tuic-server 已存在");
    return;
  }
  console.log("📥 下载 tuic-server v1.4.5 (x86_64‐linux)...");
  const url = "https://github.com/Itsusinn/tuic/releases/download/v1.4.5/tuic-server-x86_64-linux";
  await downloadFile(url, TUIC_BIN);
  fs.chmodSync(TUIC_BIN, 0o755);
  console.log("✅ tuic-server 下载完成");
}

// ================== 生成配置文件 ==================
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
  console.log("⚙️ 配置文件已生成:", SERVER_TOML);
}

// ================== 获取公网IP ==================
async function getPublicIP() {
  return new Promise((resolve) => {
    https
      .get("https://api64.ipify.org", (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => resolve(data.trim() || "127.0.0.1"));
      })
      .on("error", () => resolve("127.0.0.1"));
  });
}

// ================== 生成 TUIC 链接 ==================
function generateLink(uuid, password, ip, port, domain) {
  const link = `tuic://${uuid}:${password}@${ip}:${port}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${domain}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}`;
  fs.writeFileSync(LINK_TXT, link);
  console.log("🔗 TUIC 链接已生成:");
  console.log(link);
}

// ================== 守护运行 ==================
function runLoop() {
  console.log("🚀 启动 TUIC 服务...");
  const loop = () => {
    const proc = spawn(TUIC_BIN, ["-c", SERVER_TOML], { stdio: "ignore" });
    proc.on("exit", (code) => {
      console.log(`⚠️ TUIC 异常退出 (${code})，5 秒后重启...`);
      setTimeout(loop, 5000);
    });
  };
  loop();
}

// ================== 主流程 ==================
async function main() {
  console.log("🌐 TUIC v5 over QUIC 自动部署开始");

  const port = readPort();
  const domain = randomSNI();
  const id = uuid();
  const password = randomHex(16);

  generateCert(domain);
  await checkTuicServer();
  generateConfig(id, password, port, domain);
  const ip = await getPublicIP();
  generateLink(id, password, ip, port, domain);
  runLoop();
}

main().catch((err) => console.error("❌ 发生错误：", err));

