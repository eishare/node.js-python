#!/usr/bin/env node
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const https = require('https');
const path = require('path');

const MASQ_DOMAIN = 'www.bing.com';
const TUIC_VERSION = 'v1.4.5';

const TUIC_BIN = './tuic-server';
const TUIC_TOML = './server.toml';
const TUIC_CERT = './tuic-cert.pem';
const TUIC_KEY = './tuic-key.pem';
const TUIC_LINK = './tuic_link.txt';
const TUIC_LOG = './tuic.log';

const XRAY_BIN = './xray'; // 上传的 ELF 文件
const XRAY_CONF = './xray.json';
const REALITY_KEY_FILE = './reality_key.txt';
const VLESS_INFO = './vless_reality_info.txt';
const XRAY_LOG = './xray.log';

// ========== 工具函数 ==========
function genUUID() {
  try {
    return execSync('cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen || openssl rand -hex 16').toString().trim();
  } catch {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx';
  }
}

function randomPort() {
  return Math.floor(Math.random() * 40000) + 20000;
}

function download(url, dest, cb) {
  const file = fs.createWriteStream(dest);
  https.get(url, res => {
    res.pipe(file);
    file.on('finish', () => file.close(cb));
  }).on('error', err => cb(err));
}

function execCmd(cmd) {
  try {
    return execSync(cmd).toString().trim();
  } catch (e) {
    return '';
  }
}

// ========== TUIC 部分 ==========
let TUIC_PORT = process.env.SERVER_PORT || randomPort();
console.log('✅ TUIC 使用端口:', TUIC_PORT);

const TUIC_UUID = genUUID();
const TUIC_PASSWORD = execCmd('openssl rand -hex 16');

function checkTuic(cb) {
  if (!fs.existsSync(TUIC_BIN)) {
    console.log('📥 下载 TUIC...');
    download(`https://github.com/Itsusinn/tuic/releases/download/${TUIC_VERSION}/tuic-server-x86_64-linux`, TUIC_BIN, err => {
      if (err) return cb(err);
      fs.chmodSync(TUIC_BIN, 0o755);
      cb();
    });
  } else cb();
}

function generateTuicCert() {
  if (!fs.existsSync(TUIC_CERT) || !fs.existsSync(TUIC_KEY)) {
    execCmd(`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "${TUIC_KEY}" -out "${TUIC_CERT}" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes`);
    fs.chmodSync(TUIC_KEY, 0o600);
    fs.chmodSync(TUIC_CERT, 0o644);
  }
}

function generateTuicConfig() {
  const content = `
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "${TUIC_CERT}"
private_key = "${TUIC_KEY}"
alpn = ["h3"]
  `;
  fs.writeFileSync(TUIC_TOML, content);
}

function generateTuicLink() {
  const IP = execCmd('curl -s https://api64.ipify.org') || '127.0.0.1';
  const content = `tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${IP}`;
  fs.writeFileSync(TUIC_LINK, content);
  console.log('🔗 TUIC 链接:\n' + content);
}

function runTuic() {
  const proc = spawn(TUIC_BIN, ['-c', TUIC_TOML], { stdio: ['ignore', fs.openSync(TUIC_LOG,'a'), fs.openSync(TUIC_LOG,'a')], detached: true });
  proc.unref();
  console.log('✅ TUIC 已后台启动，日志:', TUIC_LOG);
}

// ========== VLESS Reality 部分 ==========
const VLESS_UUID = genUUID();

function checkXray() {
  if (!fs.existsSync(XRAY_BIN)) {
    console.error('❌ Xray ELF 文件不存在，请上传 ./xray');
    process.exit(1);
  }
  const fileType = execCmd(`file ${XRAY_BIN}`);
  if (!/ELF/.test(fileType)) {
    console.error('❌ Xray 不是 ELF 文件');
    process.exit(1);
  }
}

function generateRealityKeys() {
  execCmd(`${XRAY_BIN} x25519 > ${REALITY_KEY_FILE}`);
  const data = fs.readFileSync(REALITY_KEY_FILE,'utf-8');
  const priv = data.match(/Private key:\s*(.+)/i);
  const pub = data.match(/Public key:\s*(.+)/i);
  return { PRIVATE_KEY: priv ? priv[1].trim() : '', PUBLIC_KEY: pub ? pub[1].trim() : '' };
}

function generateVlessConfig(PRIVATE_KEY) {
  const conf = {
    log: { loglevel: 'warning' },
    inbounds: [{
      listen: '0.0.0.0',
      port: 443,
      protocol: 'vless',
      settings: { clients: [{id: VLESS_UUID, flow: 'xtls-rprx-vision'}], decryption: 'none' },
      streamSettings: {
        network: 'tcp',
        security: 'reality',
        realitySettings: {
          show: false,
          dest: `${MASQ_DOMAIN}:443`,
          xver: 0,
          serverNames: [MASQ_DOMAIN],
          privateKey: PRIVATE_KEY,
          shortIds: ['']
        }
      }
    }],
    outbounds: [{ protocol: 'freedom' }]
  };
  fs.writeFileSync(XRAY_CONF, JSON.stringify(conf, null, 2));
}

function generateVlessLink(PRIVATE_KEY, PUBLIC_KEY) {
  const IP = execCmd('curl -s https://api64.ipify.org') || '127.0.0.1';
  const content = `VLESS Reality 节点信息
UUID: ${VLESS_UUID}
PrivateKey: ${PRIVATE_KEY}
PublicKey: ${PUBLIC_KEY}
SNI: ${MASQ_DOMAIN}
Port: 443
Link:
vless://${VLESS_UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}#VLESS-REALITY
`;
  fs.writeFileSync(VLESS_INFO, content);
  console.log(content);
}

function runVless() {
  const proc = spawn(XRAY_BIN, ['run', '-c', XRAY_CONF], { stdio: ['ignore', fs.openSync(XRAY_LOG,'a'), fs.openSync(XRAY_LOG,'a')], detached: true });
  proc.unref();
  console.log('✅ VLESS Reality 已后台启动，日志:', XRAY_LOG);
}

// ========== 主流程 ==========
checkXray();

checkTuic(err=>{
  if(err) { console.error(err); return; }
  generateTuicCert();
  generateTuicConfig();
  generateTuicLink();

  const keys = generateRealityKeys();
  generateVlessConfig(keys.PRIVATE_KEY);
  generateVlessLink(keys.PRIVATE_KEY, keys.PUBLIC_KEY);

  runVless();
  runTuic();

  console.log('🎉 一键部署完成！');
});

