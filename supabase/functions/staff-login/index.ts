// Deploy with verify_jwt = false. Uses server-side secrets only.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
const encoder = new TextEncoder();
const sha256 = async (value: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(value)))).map(x => x.toString(16).padStart(2, '0')).join('');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  try {
    const { username, password } = await req.json();
    if (typeof username !== 'string' || !/^[a-z][a-z0-9_]{2,29}$/.test(username) || typeof password !== 'string' || password.length < 8 || password.length > 256) return json({ error: 'بيانات الدخول غير صحيحة' }, 401);
    const url = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const server = createClient(url, serviceKey, { auth: { persistSession: false } });
    // Fingerprint is hashed; only trusted proxy headers should be used for production IP rate limiting.
    const ip = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? 'unknown';
    const fingerprint = await sha256(`${username}:${ip}`);
    const { data: allowed, error: rateError } = await server.rpc('check_staff_login_rate', { p_fingerprint: fingerprint });
    if (rateError || allowed !== true) return json({ error: 'محاولات كثيرة. حاول لاحقًا' }, 429);
    const { data: staff, error: lookupError } = await server.from('staff_profiles').select('user_id,is_active').eq('username', username).maybeSingle();
    if (lookupError || !staff?.is_active) return json({ error: 'بيانات الدخول غير صحيحة' }, 401);
    const { data: userData, error: userError } = await server.auth.admin.getUserById(staff.user_id);
    if (userError || !userData.user?.email) return json({ error: 'بيانات الدخول غير صحيحة' }, 401);
    const auth = createClient(url, anonKey, { auth: { persistSession: false } });
    const { data, error } = await auth.auth.signInWithPassword({ email: userData.user.email, password });
    if (error || !data.session) return json({ error: 'بيانات الدخول غير صحيحة' }, 401);
    return json({ access_token: data.session.access_token, refresh_token: data.session.refresh_token, expires_in: data.session.expires_in });
  } catch { return json({ error: 'تعذر إتمام تسجيل الدخول' }, 400); }
});
