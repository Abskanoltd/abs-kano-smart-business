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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SECRET_KEY") ?? "";
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

    // Reuse a previously-created, unconfirmed staff signup only when it is not
    // an owner account and is not already assigned to another shop.
    let existingUser: any = null;
    for (let page = 1; page <= 20 && !existingUser; page++) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 500 });
      if (error) throw error;
      existingUser = data.users.find((u) => (u.email ?? "").toLowerCase() === email) ?? null;
      if (data.users.length < 500) break;
    }

    let staffUserId: string;
    let createdNewUser = false;
    if (existingUser) {
      if (existingUser.id === ownerId) return json({ error: "You cannot add the owner's own email as staff." }, 409);
      const { data: ownedBusiness, error: ownerCheckError } = await admin
        .from("businesses").select("id").eq("owner_id", existingUser.id).maybeSingle();
      if (ownerCheckError) throw ownerCheckError;
      if (ownedBusiness || existingUser.user_metadata?.business_name || existingUser.user_metadata?.role === "owner") return json({ error: "This email already belongs to a business owner account. Use a different staff email." }, 409);

      const { data: assignedStaff, error: assignedError } = await admin
        .from("business_staff").select("id").eq("user_id", existingUser.id).maybeSingle();
      if (assignedError) throw assignedError;
      if (assignedStaff) return json({ error: "This account is already assigned as staff. Use its existing shop login." }, 409);
      staffUserId = existingUser.id;
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
      createdNewUser = true;
    }

    const { error: linkError } = await admin.from("business_staff").insert({
      business_id: business.id,
      user_id: staffUserId,
      email,
      full_name: fullName,
      active: true,
    });
    if (linkError) {
      if (createdNewUser) await admin.auth.admin.deleteUser(staffUserId);
      throw linkError;
    }

    if (!createdNewUser) {
      const { error: updateError } = await admin.auth.admin.updateUserById(staffUserId, {
        password,
        email_confirm: true,
        user_metadata: { ...(existingUser.user_metadata ?? {}), full_name: fullName, role: "staff" },
      });
      if (updateError) {
        await admin.from("business_staff").delete().eq("user_id", staffUserId).eq("business_id", business.id);
        throw updateError;
      }
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
