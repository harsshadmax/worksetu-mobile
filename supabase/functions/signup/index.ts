// Creates an account without sending a confirmation email.
//
// The project has "Confirm email" on and the free tier caps built-in SMTP at
// two messages an hour, so a normal client signUp fails with
// over_email_send_rate_limit before any account exists. This creates the user
// server-side with the service-role key and marks the address confirmed, so
// no mail is ever sent and the dashboard setting stops mattering. The key
// lives only in the function's environment; it is never shipped to a browser.
//
// The client still signs in afterwards through the ordinary password flow, so
// sessions, refresh and RLS all behave exactly as they would otherwise.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Only these two may be self-assigned. An administrator is appointed by the
// cooperative, never claimed by whoever posts to this endpoint -- the trigger
// copies role straight out of user_metadata, so letting "admin" through here
// would hand the admin RLS policies to anyone who asked for them.
const SELF_SERVE_ROLES = new Set(["customer", "worker"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Expected a JSON body" }, 400);
  }

  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  const role = String(body.role ?? "customer");
  const name = String(body.name ?? "").trim();
  const phone = String(body.phone ?? "").trim();
  const locality = String(body.locality ?? "").trim();

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Enter a valid email address" }, 400);
  if (password.length < 8) return json({ error: "Password must be at least 8 characters" }, 400);
  if (!SELF_SERVE_ROLES.has(role)) return json({ error: "That role cannot be self-assigned" }, 400);
  if (name.length < 2) return json({ error: "Enter your full name" }, 400);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { role, name, phone, locality },
  });

  if (error) {
    // A duplicate is the one failure worth naming precisely: the person needs
    // to know to sign in instead of trying a different password.
    const already = /already/i.test(error.message);
    return json(
      { error: already ? "An account with this email already exists" : error.message },
      already ? 409 : 400,
    );
  }

  return json({ userId: data.user?.id, email: data.user?.email }, 201);
});
