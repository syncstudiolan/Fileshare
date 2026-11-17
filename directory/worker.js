// File Share account directory. Hosted ONE TIME by the app operator, not
// inside an individual user's Worker. Stores ONLY bound email -> Worker URL.
// Passwords are never written to the directory database or logged. On login,
// credentials are forwarded over HTTPS to the user's own Worker for verification.
// Email ownership is not verified: prevent cloud rebinding and reject arbitrary URL redirects.
const encoder = new TextEncoder();
const json = (obj, status = 200) => Response.json(obj, {
  status,
  headers: {
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'strict-transport-security': 'max-age=31536000; includeSubDomains',
    'referrer-policy': 'no-referrer',
  },
});
const fail = (code, status = 400) => json({ok: false, error: code}, status);
const normalizedEmail = raw => typeof raw === 'string' ?
  raw.trim().toLowerCase() : '';
const isEmail = email => email.length <= 254 &&
  /^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]+$/.test(email);

function personalWorker(raw) {
  if (typeof raw !== 'string' || raw.length > 250) return null;
  let uri;
  try { uri = new URL(raw); } catch (_) { return null; }
  // Only exact Cloudflare workers.dev hostnames. No arbitrary URL/SSRF.
  if (uri.protocol !== 'https:' || uri.port || uri.username ||
      uri.password || uri.search || uri.hash ||
      (uri.pathname !== '/' && uri.pathname !== '') ||
      !/^[a-z0-9-]+\.[a-z0-9-]+\.workers\.dev$/.test(uri.hostname)) {
    return null;
  }
  return uri.origin;
}

async function readJson(request) {
  if (Number(request.headers.get('content-length') || 0) > 4096) return null;
  const raw = await request.text();
  if (raw.length > 4096) return null;
  try { return JSON.parse(raw); } catch (_) { return null; }
}
const bytesToHex = bytes => [...new Uint8Array(bytes)]
  .map(byte => byte.toString(16).padStart(2, '0')).join('');
function hexToBytes(hex) {
  if (!/^[a-f0-9]{64}$/.test(hex)) return null;
  return Uint8Array.from(hex.match(/../g), x => parseInt(x, 16));
}
async function sha256(text) {
  return bytesToHex(await crypto.subtle.digest('SHA-256',encoder.encode(text)));
}
async function throttle(env, kind, request, email, max, windowMs) {
  const ip = request.headers.get('cf-connecting-ip') || 'unavailable';
  const key = await sha256(env.DIRECTORY_RATE_SECRET + ':' + kind + ':' +
    ip + ':' + email);
  const now = Date.now();
  const current = await env.DB.prepare(
    'SELECT count, starts_at FROM limits WHERE id=?'
  ).bind(key).first();
  if (current && current.starts_at > now - windowMs &&
      current.count >= max) return false;
  await env.DB.prepare(
    'INSERT INTO limits(id,count,starts_at) VALUES(?,1,?) ' +
    'ON CONFLICT(id) DO UPDATE SET ' +
    'count=CASE WHEN starts_at<? THEN 1 ELSE count+1 END, ' +
    'starts_at=CASE WHEN starts_at<? THEN excluded.starts_at ELSE starts_at END'
  ).bind(key, now, now-windowMs, now-windowMs).run();
  return true;
}

// Service binding avoids unsupported same-account workers.dev -> workers.dev
// subrequests. For customers on OTHER Cloudflare accounts use public HTTPS.
// The local binding is only used for the one exact operator-owned hostname.
function personalFetch(env, worker, route, options) {
  const url = worker + route;
  const local = env.LOCAL_PERSONAL_WORKER;
  if (local && env.LOCAL_PERSONAL_URL === worker) {
    return local.fetch(new Request(url, options));
  }
  return fetch(url, options);
}

async function verifyPersonalSession(worker, email, session, env) {
  if (typeof session !== 'string' || session.length < 24 ||
      session.length > 1800) return false;
  try {
    const response = await personalFetch(env, worker, '/v1/auth/me', {
      headers: {'authorization': 'Bearer ' + session, 'accept':'application/json'},
      signal: AbortSignal.timeout(10000),
      redirect: 'error',
    });
    if (!response.ok) return false;
    const result = await response.json();
    return result?.ok === true && result.email === email;
  } catch (_) { return false; }
}

// No email delivery or OTP service. A verified personal Worker session is
// required to link an address. This is account binding, NOT proof that the
// mailbox belongs to that person. First successful binding is immutable.
async function claim(request, env) {
  const body = await readJson(request);
  const email = normalizedEmail(body?.email);
  const worker = personalWorker(body?.workerUrl);
  if (!isEmail(email) || !worker) return fail('Invalid account details',400);
  if (!await throttle(env,'claim',request,email,6,15*60*1000))
    return fail('Please retry later',429);
  if (!await verifyPersonalSession(worker,email,body?.personalSession,env))
    return fail('Personal Worker session required',403);

  const existing = await env.DB.prepare(
    'SELECT worker_url FROM accounts WHERE email=?').bind(email).first();
  if (existing) {
    // An existing email can never be rebound to a different cloud account.
    if (existing.worker_url !== worker)
      return fail('This account is already bound to another cloud',409);
    return json({ok:true,linked:true,alreadyLinked:true});
  }
  const result = await env.DB.prepare(
    'INSERT OR IGNORE INTO accounts(email,worker_url,linked_at) VALUES(?,?,?)'
  ).bind(email,worker,Date.now()).run();
  if (result.meta?.changes !== 1) {
    const current = await env.DB.prepare(
      'SELECT worker_url FROM accounts WHERE email=?').bind(email).first();
    return current?.worker_url === worker ?
      json({ok:true,linked:true,alreadyLinked:true}) :
      fail('This account is already bound to another cloud',409);
  }
  return json({ok:true,linked:true});
}

// Discovery only: the Directory never handles passwords for new clients.
// The mobile/desktop app authenticates directly against this immutable URL.
async function resolveAccount(request,env) {
  const body=await readJson(request);
  const email=normalizedEmail(body?.email);
  if(!isEmail(email))return fail('Enter a valid email address',400);
  if(!await throttle(env,'resolve',request,email,8,15*60*1000))
    return fail('Too many attempts; retry later',429);
  const account=await env.DB.prepare(
    'SELECT worker_url FROM accounts WHERE email=?').bind(email).first();
  const worker=personalWorker(account?.worker_url);
  if(!worker)return fail('Email address is not registered',404);
  return json({ok:true,email,workerUrl:worker});
}

async function signIn(request,env) {
  const body=await readJson(request);
  const email=normalizedEmail(body?.email), password=body?.password;
  if(!isEmail(email)||typeof password!=='string'||
      password.length<10||password.length>1024)
    return fail('Incorrect email or password',401);
  if(!await throttle(env,'login',request,email,8,15*60*1000))
    return fail('Too many attempts; retry later',429);
  const account=await env.DB.prepare(
    'SELECT worker_url FROM accounts WHERE email=?'
  ).bind(email).first();
  const worker=personalWorker(account?.worker_url);
  if(!worker)return fail('Email address is not registered',404);
  // Password is forwarded ONLY to this verified personal Worker over TLS,
  // NEVER placed in the directory database or written to a log.
  let response;
  try {
    response=await personalFetch(env,worker,'/v1/auth/login',{
      method:'POST',
      headers:{'content-type':'application/json','accept':'application/json'},
      body:JSON.stringify({email,password}),
      signal:AbortSignal.timeout(20000),redirect:'error',
    });
  } catch (_) { return fail('Personal cloud unavailable',503); }
  if(!response.ok)return fail('Incorrect email or password',401);
  let result;
  try {result=await response.json();}catch(_){return fail('Personal cloud unavailable',503);}
  if(result?.ok!==true || result.email!==email ||
      typeof result.session!=='string' || result.session.length<24 ||
      !Number.isFinite(result.expiresAt) || result.expiresAt<=Date.now())
    return fail('Invalid personal cloud response',502);
  return json({ok:true,email,workerUrl:worker,
    session:result.session,expiresAt:result.expiresAt});
}

export default {
  async fetch(request,env){
    try {
      if(!env.DB || !env.DIRECTORY_RATE_SECRET || env.DIRECTORY_RATE_SECRET.length<32)
        return fail('Directory not configured',503);
      const url=new URL(request.url);
      const origin=request.headers.get('origin');
      if(origin && origin!==url.origin &&
         origin!==env.ALLOWED_ORIGIN) return fail('Origin blocked',403);
      if(url.pathname==='/health' && request.method==='GET') {
        await env.DB.prepare('SELECT 1').first();
        return json({ok:true,service:'fileshare-directory',database:true});
      }
      if(request.method!=='POST')return fail('Not found',404);
      if(request.headers.get('content-type')?.split(';')[0].trim()!=='application/json')
        return fail('JSON required',415);
      if(url.pathname==='/v1/directory/claim')return claim(request,env);
      // OTP endpoint intentionally removed; an app cannot prove mailbox ownership itself.
      if(url.pathname==='/v1/directory/resolve')return resolveAccount(request,env);
      if(url.pathname==='/v1/directory/login')return signIn(request,env);
      return fail('Not found',404);
    }catch(_){return fail('Request could not be completed',500);}
  },
  async scheduled(_,env){
    await env.DB.prepare('DELETE FROM limits WHERE starts_at<?')
      .bind(Date.now()-24*60*60*1000).run();
  },
};
