// File Share — personal Cloudflare Worker (ES module).
// Bindings: DB (D1), FILES (private R2), ASSETS (static guest page).
// Secret: OWNER_TOKEN (set with Cloudflare secret storage; NEVER commit it).
// No account-token management, no global tokens, no paid dependency.
const GUEST_HTML = ''; // Embedded by first-time setup.
const MB = 1024 * 1024;
const QUOTA = 200 * MB;
const CHUNK = 6 * MB; // R2 multipart parts: all non-final parts >=5 MiB.
const DAY = 24 * 3600 * 1000;

const json = (data, status = 200, headers = {}) => new Response(
  JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      ...headers,
    },
  },
);

const fail = (message, status = 400) => json({ok: false, error: message}, status);
const nextMidnightIST = (now) =>
  (Math.floor((now + 19800000) / DAY) + 1) * DAY - 19800000;
const id = () => crypto.randomUUID();
const safeName = (name) => String(name).replace(/[\\/\x00-\x1f]/g, '_').slice(-180);
const guestCookie = (request) =>
  request.headers.get('cookie')?.match(/(?:^|;\s*)fs_guest=([a-zA-Z0-9-]{36})/)?.[1] ?? null;

async function owner(request, env) {
  const credential = request.headers.get('authorization');
  if (!env.OWNER_TOKEN || !credential?.startsWith('Bearer ')) return false;
  const token = credential.slice(7);
  return token === env.OWNER_TOKEN || !!(await readSession(token, env));
}

function originAllowed(request) {
  const origin = request.headers.get('origin');
  return !origin || origin === new URL(request.url).origin;
}

async function digest(value) {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, '0')).join('');
}

async function guest(request, env) {
  const cookie = guestCookie(request);
  if (!cookie) return null;
  // Browser cookie identifies one guest; IP hash is separately recorded for
  // abuse mitigation. Hardware IDs/IMEI are not exposed to browsers.
  return {
    key: await digest(env.OWNER_TOKEN + ':' + cookie),
    ipHash: await digest(env.OWNER_TOKEN + ':' +
      (request.headers.get('cf-connecting-ip') || 'unknown')),
  };
}

async function uploadAccess(request, env, session, fileId) {
  const who = await guest(request, env);
  if (!who) return null;
  const f = await env.DB.prepare(
    'SELECT f.* FROM uploads f JOIN guest_sessions s ON s.id=f.session_id ' +
    'WHERE f.id=? AND f.session_id=? AND s.guest_key=? AND f.expires_at>?'
  ).bind(fileId, session, who.key, Date.now()).first();
  return f;
}

async function qrActive(env, token) {
  if (!token || token.length > 150) return false;
  const row = await env.DB.prepare(
    'SELECT token FROM qr_codes WHERE token=? AND active=1'
  ).bind(token).first();
  return !!row;
}

async function createSession(request, env) {
  const who = await guest(request, env);
  if (!who) return fail('Open the QR link first to start your session', 401);
  const body = await request.json().catch(() => null);
  const files = body?.files;
  if (!Array.isArray(files) || files.length < 1 || files.length > 500 ||
      typeof body.qr !== 'string' || !await qrActive(env, body.qr)) {
    return fail('Invalid QR or file selection');
  }
  let total = 0;
  for (const f of files) {
    if (typeof f.name !== 'string' || !f.name || f.name.length > 500 ||
        !Number.isSafeInteger(f.size) || f.size < 0 || f.size > QUOTA) {
      return fail('Invalid file name or size');
    }
    total += f.size;
  }
  if (total > QUOTA) return fail('Maximum 200 MB per guest', 413);

  const now = Date.now();
  const session = id();
  const expires = nextMidnightIST(now);
  const statements = [
    // A single conditional INSERT enforces the four-session and 200-MB
    // rolling window atomically. Failed condition breaks FK child inserts.
    env.DB.prepare(
      'INSERT INTO guest_sessions(id,qr,guest_key,ip_hash,created_at,reserved_bytes,expires_at) ' +
      'SELECT ?,?,?,?,?,?,? WHERE ' +
      '(SELECT COUNT(*) FROM guest_sessions WHERE qr=? AND guest_key=? AND created_at>=?) < 4 ' +
      'AND (SELECT COALESCE(SUM(reserved_bytes),0) FROM guest_sessions ' +
      'WHERE qr=? AND guest_key=? AND created_at>=?) + ? <= ?'
    ).bind(session, body.qr, who.key, who.ipHash, now, total, expires,
      body.qr, who.key, now - DAY, body.qr, who.key, now - DAY, total, QUOTA),
  ];
  const returned = files.map((f, i) => ({
    id: id(),
    name: safeName(f.name),
    size: f.size,
    index: i,
  }));
  for (const f of returned) {
    const key = 'uploads/' + session + '/' + f.id;
    statements.push(env.DB.prepare(
      'INSERT INTO uploads(id,session_id,file_index,name,size,object_key,created_at,expires_at) ' +
      'VALUES (?,?,?,?,?,?,?,?)'
    ).bind(f.id, session, f.index, f.name, f.size, key, now, expires));
  }
  try {
    await env.DB.batch(statements);
  } catch (e) {
    return fail('Guest limit reached or session could not be created', 429);
  }
  return json({ok: true, session, expiresAt: expires,
    files: returned, chunkSize: CHUNK});
}

async function smallUpload(request, env, session, fileId) {
  const f = await uploadAccess(request, env, session, fileId);
  if (!f) return fail('Upload session not found', 404);
  if (f.completed) return json({ok: true, duplicate: true});
  if (f.size > CHUNK) return fail('Large files require multipart upload');
  const reported = Number(request.headers.get('content-length'));
  if (!Number.isSafeInteger(reported) || reported !== f.size) {
    return fail('File size does not match selection', 413);
  }
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength !== f.size) return fail('Incomplete file body', 400);
  await env.FILES.put(f.object_key, bytes, {
    httpMetadata: {contentType: 'application/octet-stream'},
  });
  await env.DB.prepare('UPDATE uploads SET completed=1 WHERE id=?')
    .bind(f.id).run();
  return json({ok: true});
}

async function beginLarge(request, env, session, fileId) {
  const f = await uploadAccess(request, env, session, fileId);
  if (!f) return fail('Upload session not found', 404);
  if (f.size <= CHUNK) return fail('Use the small-file endpoint');
  if (f.completed) return json({ok: true, completed: true});
  if (f.upload_id) return json({ok: true, uploadId: f.upload_id, chunkSize: CHUNK});
  const upload = await env.FILES.createMultipartUpload(f.object_key, {
    httpMetadata: {contentType: 'application/octet-stream'},
  });
  // If two simultaneous start calls occur, only one upload ID wins.
  const result = await env.DB.prepare(
    'UPDATE uploads SET upload_id=? WHERE id=? AND upload_id IS NULL'
  ).bind(upload.uploadId, f.id).run();
  if (!result.meta.changes) {
    await upload.abort().catch(() => {});
    const current = await uploadAccess(request, env, session, fileId);
    return json({ok: true, uploadId: current.upload_id, chunkSize: CHUNK});
  }
  return json({ok: true, uploadId: upload.uploadId, chunkSize: CHUNK});
}

async function putPart(request, env, session, fileId, partString) {
  const f = await uploadAccess(request, env, session, fileId);
  if (!f || !f.upload_id || f.completed) return fail('Multipart upload not active', 404);
  const part = Number(partString);
  const count = Math.ceil(f.size / CHUNK);
  if (!Number.isInteger(part) || part < 1 || part > count) {
    return fail('Invalid chunk number');
  }
  const expected = part === count ? f.size - CHUNK * (count - 1) : CHUNK;
  const length = Number(request.headers.get('content-length'));
  if (length !== expected || length > CHUNK) return fail('Chunk size mismatch', 413);
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength !== expected) return fail('Incomplete chunk');
  const multipart = env.FILES.resumeMultipartUpload(f.object_key, f.upload_id);
  const saved = await multipart.uploadPart(part, bytes);
  await env.DB.prepare(
    'INSERT INTO upload_parts(file_id,part_number,etag) VALUES(?,?,?) ' +
    'ON CONFLICT(file_id,part_number) DO UPDATE SET etag=excluded.etag'
  ).bind(f.id, part, saved.etag).run();
  return json({ok: true, part});
}

async function completeLarge(request, env, session, fileId) {
  const f = await uploadAccess(request, env, session, fileId);
  if (!f || !f.upload_id) return fail('Multipart upload not found', 404);
  if (f.completed) return json({ok: true, duplicate: true});
  const parts = await env.DB.prepare(
    'SELECT part_number,etag FROM upload_parts WHERE file_id=? ORDER BY part_number'
  ).bind(f.id).all();
  const count = Math.ceil(f.size / CHUNK);
  if (parts.results.length !== count ||
      parts.results.some((p, i) => p.part_number !== i + 1)) {
    return fail('Some chunks are still missing', 409);
  }
  const multipart = env.FILES.resumeMultipartUpload(f.object_key, f.upload_id);
  try {
    await multipart.complete(parts.results.map((p) =>
      ({partNumber: p.part_number, etag: p.etag})));
  } catch (e) {
    // If a previous completion succeeded but the D1 write failed, reconcile.
    if (!await env.FILES.head(f.object_key)) throw e;
  }
  await env.DB.prepare('UPDATE uploads SET completed=1 WHERE id=?')
    .bind(f.id).run();
  return json({ok: true});
}

async function finish(request, env, session) {
  const who = await guest(request, env);
  if (!who) return fail('Guest session not found', 401);
  const s = await env.DB.prepare(
    'SELECT id,expires_at FROM guest_sessions WHERE id=? AND guest_key=?'
  ).bind(session, who.key).first();
  if (!s || s.expires_at <= Date.now()) return fail('Guest session expired', 410);
  const row = await env.DB.prepare(
    'SELECT COUNT(*) AS pending FROM uploads WHERE session_id=? AND completed=0'
  ).bind(session).first();
  if (row.pending) return fail('Some uploads have not finished', 409);
  await env.DB.prepare('UPDATE guest_sessions SET completed=1 WHERE id=?')
    .bind(session).run();
  return json({ok: true});
}


const AUTH_PERIOD = 24 * 60 * 60 * 1000;
const enc = new TextEncoder(), dec = new TextDecoder();
const b64url = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes)))
  .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/g,'');
const from64 = value => Uint8Array.from(atob(value.replace(/-/g,'+')
  .replace(/_/g,'/').padEnd(Math.ceil(value.length/4)*4,'=')),c=>c.charCodeAt(0));
// Keep password verification feasible on the Workers Free CPU budget.
// OWNER_TOKEN is a server-side pepper: a copied D1 hash alone is insufficient
// for offline guessing. Retain per-account random salt and login throttles.
async function derivePassword(password,salt,env){
  const key=await crypto.subtle.importKey('raw',
    enc.encode(password+'\\u0000'+env.OWNER_TOKEN),'PBKDF2',false,['deriveBits']);
  return b64url(await crypto.subtle.deriveBits(
    {name:'PBKDF2',salt,iterations:12000,hash:'SHA-256'},key,256));
}
const hmacKey=env=>crypto.subtle.importKey('raw',enc.encode(env.OWNER_TOKEN),
  {name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
async function makeSession(email,env){
  const exp=Date.now()+AUTH_PERIOD;
  const payload=b64url(enc.encode(JSON.stringify({v:1,email,exp})));
  const mac=await crypto.subtle.sign('HMAC',await hmacKey(env),
    enc.encode('fileshare.session.'+payload));
  return {token:payload+'.'+b64url(mac),exp};
}
async function readSession(token,env){
  try{
    if(typeof token!=='string'||token.length>1600)return null;
    const parts=token.split('.');if(parts.length!==2)return null;
    const ok=await crypto.subtle.verify('HMAC',await hmacKey(env),
      from64(parts[1]),enc.encode('fileshare.session.'+parts[0]));
    if(!ok)return null;
    const data=JSON.parse(dec.decode(from64(parts[0])));
    return data.v===1 && typeof data.email==='string' &&
      Number.isFinite(data.exp) && data.exp>Date.now() ? data:null;
  }catch(_){return null;}
}
async function authApi(request,env,url){
  if(url.pathname==='/v1/auth/me'&&request.method==='GET'){
    const token=request.headers.get('authorization')?.replace(/^Bearer /,'');
    const session=await readSession(token,env);
    return session?json({ok:true,email:session.email,expiresAt:session.exp}):
      fail('Session expired: please log in again',401);
  }
  if(request.method!=='POST' ||
     !['/v1/auth/register','/v1/auth/login'].includes(url.pathname)){
    return fail('Unsupported auth request',405);
  }
  const input=await request.json().catch(()=>null);
  const email=String(input?.email??'').trim().toLowerCase(),password=input?.password;
  if(!/^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]+$/.test(email)||
     typeof password!=='string'||password.length<10||password.length>1024){
    return fail('Valid email and password with at least 10 characters required');
  }
  if(url.pathname==='/v1/auth/register'){
    if(request.headers.get('authorization')!=='Bearer '+env.OWNER_TOKEN)
      return fail('Owner setup secret required for first registration',403);
    if(await env.DB.prepare('SELECT email FROM accounts LIMIT 1').first())
      return fail('Owner account already registered',409);
    const salt=crypto.getRandomValues(new Uint8Array(16));
    const result=await env.DB.prepare(
      'INSERT OR IGNORE INTO accounts(singleton,email,salt,hash,created_at) VALUES(1,?,?,?,?)'
    ).bind(email,b64url(salt),await derivePassword(password,salt,env),Date.now()).run();
    if(result.meta?.changes!==1)return fail('Account already exists',409);
    const session=await makeSession(email,env);
    return json({ok:true,email,session:session.token,expiresAt:session.exp},201);
  }
  const ip=request.headers.get('cf-connecting-ip')||'unknown';
  const key=await digest(env.OWNER_TOKEN+':'+ip+':'+email),now=Date.now();
  await env.DB.prepare('DELETE FROM auth_attempts WHERE changed_at<?')
    .bind(now-15*60*1000).run();
  const attempts=await env.DB.prepare('SELECT failures FROM auth_attempts WHERE id=?')
    .bind(key).first();
  if((attempts?.failures??0)>=8)return fail('Too many attempts; retry later',429);
  const account=await env.DB.prepare('SELECT salt,hash FROM accounts WHERE email=?')
    .bind(email).first();
  const computed=await derivePassword(password,
    account?from64(account.salt):new Uint8Array(16),env);
  if(!account||account.hash!==computed){
    await env.DB.prepare(
      'INSERT INTO auth_attempts(id,failures,changed_at) VALUES(?,1,?) '+
      'ON CONFLICT(id) DO UPDATE SET failures=failures+1,changed_at=excluded.changed_at'
    ).bind(key,now).run();
    return fail('Incorrect email or password',401);
  }
  await env.DB.prepare('DELETE FROM auth_attempts WHERE id=?').bind(key).run();
  const session=await makeSession(email,env);
  return json({ok:true,email,session:session.token,expiresAt:session.exp});
}

async function ownerApi(request, env, url) {
  if (!await owner(request, env)) return fail('Owner authentication required', 401);
  if (url.pathname === '/v1/owner/self-test' && request.method === 'POST') {
    // The only R2 probe is triggered by an explicit one-time setup action.
    // It leaves no object in the bucket.
    const key = 'setup-self-test/' + id();
    const data = 'file-share-storage-test';
    try {
      await env.FILES.put(key, data);
      const item = await env.FILES.get(key);
      if (!item || await item.text() !== data) {
        return fail('R2 round-trip verification failed', 503);
      }
      await env.DB.prepare('SELECT 1').first();
      return json({ok: true, d1: true, r2: true});
    } finally {
      await env.FILES.delete(key).catch(() => {});
    }
  }
  if (url.pathname === '/v1/owner/qr' && request.method === 'GET') {
    const code = await env.DB.prepare(
      'SELECT token,created_at FROM qr_codes WHERE active=1 ORDER BY created_at DESC LIMIT 1'
    ).first();
    return json({ok: true, qr: code || null});
  }
  if (url.pathname === '/v1/owner/qr' && request.method === 'POST') {
    let code = await env.DB.prepare(
      'SELECT token FROM qr_codes WHERE active=1 LIMIT 1'
    ).first();
    if (!code) {
      const token = id() + id();
      await env.DB.prepare(
        'INSERT INTO qr_codes(token,active,created_at) VALUES(?,1,?)'
      ).bind(token, Date.now()).run();
      code = {token};
    }
    return json({ok: true, qr: code.token,
      url: new URL('/q/' + code.token, request.url).href});
  }
  if (url.pathname === '/v1/owner/qr' && request.method === 'DELETE') {
    await env.DB.prepare('UPDATE qr_codes SET active=0 WHERE active=1').run();
    return json({ok: true});
  }
  if (url.pathname === '/v1/owner/qr/regenerate' && request.method === 'POST') {
    await env.DB.prepare('UPDATE qr_codes SET active=0 WHERE active=1').run();
    const token = id() + id();
    await env.DB.prepare(
      'INSERT INTO qr_codes(token,active,created_at) VALUES(?,1,?)'
    ).bind(token, Date.now()).run();
    return json({ok: true, qr: token,
      url: new URL('/q/' + token, request.url).href});
  }
  if (url.pathname === '/v1/owner/files' && request.method === 'GET') {
    const offset = Math.max(0, Math.min(100000, Number(url.searchParams.get('offset')) || 0));
    const rows = await env.DB.prepare(
      'SELECT id,name,size,session_id,created_at FROM uploads ' +
      'WHERE completed=1 AND expires_at>? ORDER BY created_at DESC LIMIT 100 OFFSET ?'
    ).bind(Date.now(), offset).all();
    return json({ok: true, files: rows.results, nextOffset: offset + rows.results.length});
  }
  const fileMatch = url.pathname.match(/^\/v1\/owner\/file\/([a-zA-Z0-9-]+)$/);
  if (fileMatch && request.method === 'GET') {
    const item = await env.DB.prepare(
      'SELECT name,object_key,expires_at FROM uploads ' +
      'WHERE id=? AND completed=1'
    ).bind(fileMatch[1]).first();
    if (!item || item.expires_at <= Date.now()) return fail('File expired', 410);
    const object = await env.FILES.get(item.object_key);
    if (!object?.body) return fail('File missing', 404);
    const clean = safeName(item.name).replace(/["\\]/g, '_');
    return new Response(object.body, {
      headers: {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="' + clean + '"',
        'cache-control': 'private, no-store',
        'x-content-type-options': 'nosniff',
      },
    });
  }
  if (fileMatch && request.method === 'DELETE') {
    const item = await env.DB.prepare(
      'SELECT object_key FROM uploads WHERE id=?'
    ).bind(fileMatch[1]).first();
    if (!item) return json({ok: true});
    await env.FILES.delete(item.object_key);
    await env.DB.prepare('DELETE FROM uploads WHERE id=?').bind(fileMatch[1]).run();
    return json({ok: true});
  }
  return fail('Not found', 404);
}

async function cleanup(env) {
  const now = Date.now();
  // A single short DB query is needed by the scheduled trigger. No R2 delete
  // request is issued if the table has no expired files.
  // Process multiple batches in the same midnight job (for example 2,000
  // one-MB files). Cap work per run; the +2h/+4h schedules retry leftovers.
  for (let batch = 0; batch < 20; batch++) {
    const rows = await env.DB.prepare(
      'SELECT id,object_key,upload_id FROM uploads ' +
      'WHERE expires_at<=? LIMIT 500'
    ).bind(now).all();
    if (!rows.results.length) break; // no R2 delete call on empty inbox
    for (const item of rows.results) {
      if (item.upload_id) {
        await env.FILES.resumeMultipartUpload(item.object_key, item.upload_id)
          .abort().catch(() => {});
      }
    }
    await env.FILES.delete(rows.results.map((item) => item.object_key));
    const statements = rows.results.map((item) =>
      env.DB.prepare('DELETE FROM uploads WHERE id=?').bind(item.id));
    await env.DB.batch(statements);
  }
  // Keep guest usage data for rolling 24h even after midnight file cleanup.
  await env.DB.prepare('DELETE FROM guest_sessions WHERE created_at<? ' +
    'AND NOT EXISTS (SELECT 1 FROM uploads WHERE uploads.session_id=guest_sessions.id)')
    .bind(now - DAY).run();
}

export default {
  async fetch(request, env) {
    try {
      if (!env.DB || !env.FILES || !env.OWNER_TOKEN) {
        return fail('Worker is not configured: missing bindings or secret', 503);
      }
      const url = new URL(request.url);
      if (!originAllowed(request) && request.method !== 'GET') {
        return fail('Cross-origin request refused', 403);
      }
      if (url.pathname.startsWith('/v1/auth/')) return authApi(request, env, url);
      if (url.pathname.startsWith('/v1/owner/')) {
        return ownerApi(request, env, url);
      }
      const qrPage = url.pathname.match(/^\/q\/([a-zA-Z0-9-]+)$/);
      if (qrPage && request.method === 'GET') {
        if (!await qrActive(env, qrPage[1])) return fail('QR revoked or missing', 404);
        const response = env.ASSETS
          ? await env.ASSETS.fetch(new Request(new URL('/guest.html', request.url)))
          : new Response(GUEST_HTML,{headers:{
              'content-type':'text/html; charset=utf-8',
              'x-content-type-options':'nosniff',
              'content-security-policy':
                "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'"
            }});
        const headers = new Headers(response.headers);
        headers.set('cache-control', 'no-store');
        headers.set('x-content-type-options', 'nosniff');
        if (!guestCookie(request)) {
          headers.append('set-cookie',
            'fs_guest=' + id() + '; Path=/; Max-Age=31536000; SameSite=Lax; Secure; HttpOnly');
        }
        return new Response(response.body, {status: response.status, headers});
      }
      if (url.pathname === '/v1/guest/session' && request.method === 'POST') {
        return createSession(request, env);
      }
      const upload = url.pathname.match(
        /^\/v1\/guest\/file\/([a-zA-Z0-9-]+)\/([a-zA-Z0-9-]+)(?:\/(start|complete|part\/[0-9]+))?$/);
      if (upload) {
        const session = upload[1];
        const fileId = upload[2];
        const mode = upload[3];
        if (!mode && request.method === 'PUT') {
          return smallUpload(request, env, session, fileId);
        }
        if (mode === 'start' && request.method === 'POST') {
          return beginLarge(request, env, session, fileId);
        }
        if (mode?.startsWith('part/') && request.method === 'PUT') {
          return putPart(request, env, session, fileId, mode.slice(5));
        }
        if (mode === 'complete' && request.method === 'POST') {
          return completeLarge(request, env, session, fileId);
        }
      }
      const finished = url.pathname.match(/^\/v1\/guest\/finish\/([a-zA-Z0-9-]+)$/);
      if (finished && request.method === 'POST') {
        return finish(request, env, finished[1]);
      }
      if (url.pathname === '/health' && request.method === 'GET') {
        return json({ok: true, service: 'file-share', configured: true});
      }
      return fail('Not found', 404);
    } catch (e) {
      return fail('Request could not be completed', 500);
    }
  },

  async scheduled(event, env) {
    // At 00:00 IST; additionally at +2h and +4h to retry failures.
    // When no files exist, this causes no R2 read or delete.
    await cleanup(env);
  },
};
