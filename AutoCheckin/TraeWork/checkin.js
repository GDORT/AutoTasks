const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function appendLog(line) {
  try {
    const logFile = path.join(__dirname, '..', 'checkin.log');
    // 固定 yyyy-MM-dd HH:mm:ss，与 trae_task.ps1「当天已签」守卫的搜索格式一致。
    // 原用 toLocaleString('zh-CN') 会写成 2026/10/1，守卫按 2026-10-01 搜索永远匹配不到，
    // 导致同一天被重复执行签到（接口幂等，无资损，但浪费一次调用）。
    const d = new Date();
    const p = n => String(n).padStart(2, '0');
    const ts = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
               `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
    fs.appendFileSync(logFile, `${ts}  [TRAE]  ${line}\n`, 'utf8');
  } catch (e) {}
}

const HP = 16, q8_AES128 = 16, WP = HP, rh = 64, Rv = 32, VP = 64, Em = 6;
const ure = Uint8Array.from([82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37]);
const dre = Uint8Array.from([31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125]);

async function sha512(data) {
  const h = await crypto.subtle.digest('SHA-512', data);
  return new Uint8Array(h);
}
function xorArrays(a, b, n) {
  const r = new Uint8Array(n);
  for (let i = 0; i < n; i++) r[i] = a[i] ^ b[i];
  return r;
}

async function decrypt(b64) {
  const t = new Uint8Array(Buffer.from(b64, 'base64'));
  const key = t.slice(Em, Em + Rv);
  const sha = await sha512(key);
  const xor = xorArrays(ure, dre, VP);
  const comb = new Uint8Array(rh + VP);
  comb.set(sha, 0);
  comb.set(xor, rh);
  const hash = await sha512(comb);
  const aesKey = hash.slice(0, q8_AES128);
  const iv = hash.slice(q8_AES128, q8_AES128 + WP);
  const ct = t.slice(Rv + Em);
  const ck = await crypto.subtle.importKey('raw', aesKey, { name: 'AES-CBC' }, false, ['decrypt']);
  const dec = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-CBC', iv }, ck, ct));
  return new TextDecoder().decode(dec.slice(rh));
}

async function main() {
  const appData = process.env.APPDATA;
  const storagePath = `${appData}\\TRAE SOLO CN\\User\\globalStorage\\storage.json`;
  const storage = JSON.parse(fs.readFileSync(storagePath, 'utf8'));
  const enc = storage['iCubeAuthInfo://icube.cloudide'];
  if (!enc) { return 'ERROR: No auth data found'; }
  const auth = JSON.parse(await decrypt(enc));
  if (!auth.token) { return 'ERROR: No token in auth data'; }

  // 已验证成功方案（实测 code:0）：真实设备ID来自 icube-dc 键 + req_source:1
  const dcKey = Object.keys(storage).find(k => k.includes('icube-dc'));
  const realDeviceId = dcKey ? dcKey.split(':').pop() : (storage['telemetry.devDeviceId'] || '');
  const headers = {
    'Authorization': `Cloud-IDE-JWT ${auth.token}`,
    'Content-Type': 'application/json',
    'X-Device-Id': realDeviceId,
    'X-User-Id': auth.userId || '',
  };
  if (auth.userRegion?.region) headers['X-User-Region'] = auth.userRegion.region;

  const STATUS = 'https://api.trae.cn/trae/api/v2/ug/checkin_credits/status';
  const CLAIM = 'https://api.trae.cn/trae/api/v2/ug/checkin_credits/claim';

  // 1) 查状态（可选，仅提示）
  let status;
  try {
    const r = await fetch(STATUS, { method: 'POST', headers, body: JSON.stringify({ req_source: 1 }) });
    status = await r.json();
  } catch (e) { return `Error(status): ${e.message}`; }

  // 2) 领取（成功判据=claim.code===0）
  for (let attempt = 1; attempt <= 3; attempt++) {
    let claim;
    try {
      const r = await fetch(CLAIM, { method: 'POST', headers, body: JSON.stringify({ req_source: 1 }) });
      claim = await r.json();
    } catch (e) { return `Error(claim): ${e.message}`; }
    if (claim.code === 0) return `[OK] Check-in successful! Credits: ${claim.data?.credits || status?.credits || 200}`;
    if (attempt === 3) {
      return `[RETRY] Given up after 3 tries, code=${claim.code} msg=${claim.message}`;
    }
    const wait = 5000 + Math.floor(Math.random() * 5000);
    await new Promise(res => setTimeout(res, wait));
  }
}

main()
  .then(msg => { console.log(msg); appendLog(msg); })
  .catch(e => console.log('Fatal:', e.message));