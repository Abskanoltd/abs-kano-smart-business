import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "https://app.abskanoltd.com",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  // Supabase now injects named key dictionaries. Prefer the new keys,
  // while retaining legacy fallbacks for projects still using anon/service_role.
  const publishableKeysRaw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  const secretKeysRaw = Deno.env.get("SUPABASE_SECRET_KEYS");

  let publishableKey = "";
  let secretKey = "";

  try {
    if (publishableKeysRaw) {
      const keys = JSON.parse(publishableKeysRaw);
      publishableKey = keys.default ?? "";
    }
    if (secretKeysRaw) {
      const keys = JSON.parse(secretKeysRaw);
      secretKey = keys.default ?? "";
    }
  } catch {
    console.error("Supabase named API key environment variables are not valid JSON.");
    return json({ error: "Staff service API keys are misconfigured." }, 500);
  }

  const anonKey =
    publishableKey ||
    Deno.env.get("SUPABASE_ANON_KEY") ||
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ||
    "";

  const serviceKey =
    secretKey ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
    Deno.env.get("SUPABASE_SECRET_KEY") ||
    "";
  if (!url || !anonKey || !serviceKey) {
    console.error("Missing Supabase URL, publishable/anon key, or service secret");
    return json({ error: "Staff service is not configured on the server." }, 500);
  }

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "Sign in as the shop owner first." }, 401);

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) return json({ error: "Your login session is invalid. Sign in again." }, 401);
    const ownerId = authData.user.id;

    const body = await req.json();
    const fullName = String(body.full_name ?? "").trim();
    const email = String(body.email ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    if (fullName.length < 2) return json({ error: "Enter the staff member's full name." }, 400);
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "Enter a valid staff email address." }, 400);
    if (password.length < 8) return json({ error: "The initial password must contain at least 8 characters." }, 400);

    const { data: business, error: businessError } = await admin
      .from("businesses").select("id,business_name").eq("owner_id", ownerId).maybeSingle();
    if (businessError) throw businessError;
    if (!business) return json({ error: "Only the shop owner can create staff accounts." }, 403);

    const { data: alreadyStaff, error: staffCheckError } = await admin
      .from("business_staff").select("id").eq("business_id", business.id).eq("email", email).maybeSingle();
    if (staffCheckError) throw staffCheckError;
    if (alreadyStaff) return json({ error: "This email is already registered as staff for this shop." }, 409);

    // Find an existing Auth user, if any. Reuse is restricted to the
    // specific safe recovery case: an unconfirmed account whose stored name
    // matches the owner-entered staff name and which is not an owner or linked
    // to any business. Confirm and set the initial password server-side.
    let existingUser: any = null;

    for (let page = 1; page <= 20 && !existingUser; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 500 });
      if (error) throw error;
      existingUser = data.users.find((u) => (u.email ?? "").toLowerCase() === email) ?? null;
      if (data.users.length < 500) break;
    }

    let staffUserId = "";

    if (existingUser) {
      const storedName = String(existingUser.user_metadata?.full_name ?? "").trim().toLowerCase();
      const requestedName = fullName.trim().toLowerCase();
      const isOwner = Boolean(existingUser.app_metadata?.role === "owner" ||
        existingUser.user_metadata?.role === "owner");

      if (existingUser.email_confirmed_at || storedName !== requestedName || isOwner) {
        return json({
          error: "This email already belongs to an existing or confirmed account and cannot be reused as staff."
        }, 409);
      }

      const { data: ownerBusiness, error: ownerCheckError } = await admin
        .from("businesses").select("id").eq("owner_id", existingUser.id).maybeSingle();
      if (ownerCheckError) throw ownerCheckError;
      if (ownerBusiness) {
        return json({ error: "An owner account cannot be added as staff." }, 409);
      }

      const { data: linkedStaff, error: linkedStaffError } = await admin
        .from("business_staff").select("id").or(`user_id.eq.${existingUser.id},email.eq.${email}`).limit(1);
      if (linkedStaffError) throw linkedStaffError;
      if (linkedStaff && linkedStaff.length > 0) {
        return json({ error: "This account is already linked to a business and cannot be reassigned." }, 409);
      }

      const { data: updated, error: updateError } = await admin.auth.admin.updateUserById(
        existingUser.id,
        {
          password,
          email_confirm: true,
          user_metadata: { ...existingUser.user_metadata, full_name: fullName, role: "staff" },
        }
      );
      if (updateError) throw updateError;
      if (!updated.user) throw new Error("Supabase did not return the updated staff account.");
      staffUserId = updated.user.id;
    } else {
      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name: fullName, role: "staff" },
      });
      if (createError) throw createError;
      if (!created.user) throw new Error("Supabase did not return the new staff account.");
      staffUserId = created.user.id;
    }

    const { error: linkError } = await admin.from("business_staff").insert({
      business_id: business.id,
      user_id: staffUserId,
      email,
      full_name: fullName,
      active: true,
    });
    if (linkError) {
      await admin.auth.admin.deleteUser(staffUserId);
      throw linkError;
    }


    return json({
      ok: true,
      staff: { id: staffUserId, email, full_name: fullName, active: true },
      message: "Staff account created and activated. The staff member can sign in now.",
    });
  } catch (error) {
    console.error("create-staff-account failed:", error);
    return json({ error: error instanceof Error ? error.message : "Could not create the staff account." }, 400);
  }
});
