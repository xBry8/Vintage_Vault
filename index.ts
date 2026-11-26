import { createClient } from "npm:@supabase/supabase-js@2";

const H = {
  "Access-Control-Allow-Origin": Deno.env.get("SITE_URL")!,
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Content-Type": "application/json",
};
const reply = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: H });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: H });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: { user } } = await db.auth.getUser((req.headers.get("Authorization") ?? "").replace("Bearer ", ""));
  if (!user) return reply({ error: "Log in to place an order." }, 401);

  const b = await req.json().catch(() => null);
  const ids: string[] = [...new Set<string>(Array.isArray(b?.ids) ? b.ids : [])];
  const valid = ids.length >= 1 && ids.length <= 20 && ids.every((i) => /^[0-9a-f-]{36}$/i.test(i)) &&
    typeof b?.name === "string" && b.name.trim().length >= 2 &&
    /^09\d{9}$/.test(b?.phone ?? "") && typeof b?.address === "string" && b.address.trim().length >= 8;
  if (!valid) return reply({ error: "Check your name, mobile number, address and cart." }, 400);

  // Prices come from the database, never from the browser.
  const { data: o, error } = await db.rpc("place_order", {
    p_user: user.id, p_ids: ids, p_name: b.name.trim(), p_phone: b.phone, p_address: b.address.trim(),
  }).single();
  if (error || !o) {
    const taken = error?.message.includes("item_unavailable");
    return reply({ error: taken ? "One of your pieces was just taken." : "Could not place the order." }, taken ? 409 : 500);
  }

  const { data: items } = await db.from("order_items").select("price_php, products(name)").eq("order_id", o.o_id);
  const site = Deno.env.get("SITE_URL")!;
  const pm = await fetch("https://api.paymongo.com/v1/checkout_sessions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Basic " + btoa(Deno.env.get("PAYMONGO_SECRET_KEY")! + ":"),
    },
    body: JSON.stringify({ data: { attributes: {
      payment_method_types: ["gcash"],
      line_items: (items ?? []).map((i: any) => ({
        name: i.products.name, quantity: 1, amount: i.price_php * 100, currency: "PHP",
      })),
      reference_number: o.o_no,
      description: `Vintage Vault ${o.o_no}`,
      metadata: { order_id: o.o_id },
      success_url: `${site}/?order=${o.o_no}&paid=1`,
      cancel_url: `${site}/?order=${o.o_no}&cancelled=1`,
    } } }),
  });
  const out = await pm.json().catch(() => null);
  if (!pm.ok || !out?.data?.id) {   // could not start payment: put the pieces back on sale
    await db.from("orders").update({ status: "cancelled", payment_status: "failed" }).eq("id", o.o_id);
    await db.from("products").update({ status: "available" }).in("id", ids).eq("status", "reserved");
    return reply({ error: "Payment service is unavailable. Please try again." }, 502);
  }
  await db.from("orders").update({ paymongo_session_id: out.data.id }).eq("id", o.o_id);
  return reply({ order_no: o.o_no, checkout_url: out.data.attributes.checkout_url });
});
