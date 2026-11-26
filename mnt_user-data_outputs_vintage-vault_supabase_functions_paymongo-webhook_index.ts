import { createClient } from "npm:@supabase/supabase-js@2";

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const same = (a: string, b: string) =>
  a.length === b.length && [...a].reduce((r, c, i) => r | (c.charCodeAt(0) ^ b.charCodeAt(i)), 0) === 0;

Deno.serve(async (req) => {
  const raw = await req.text();   // signature covers the exact raw body
  const h = Object.fromEntries(
    (req.headers.get("paymongo-signature") ?? "").split(",").map((p) => p.split("=") as [string, string]),
  );
  let ev: any;
  try { ev = JSON.parse(raw); } catch { return new Response("bad json", { status: 400 }); }

  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(Deno.env.get("PAYMONGO_WEBHOOK_SECRET")!),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mine = hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${h.t}.${raw}`)));
  const theirs = ev?.data?.attributes?.livemode ? h.li : h.te;   // live and test events use different fields
  if (!h.t || !theirs || !same(mine, theirs) || Math.abs(Date.now() / 1000 - +h.t) > 300) {
    return new Response("invalid signature", { status: 401 });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const type = ev.data.attributes.type as string;
  const { error: dup } = await db.from("webhook_events").insert({ id: ev.data.id, type });
  if (dup?.code === "23505") return new Response("duplicate", { status: 200 });   // already processed

  if (type === "checkout_session.payment.paid") {
    const s = ev.data.attributes.data;
    const { error } = await db.rpc("mark_paid", {
      p_session: s.id, p_payment: s.attributes?.payments?.[0]?.id ?? null,
    });
    if (error) {   // let PayMongo retry
      await db.from("webhook_events").delete().eq("id", ev.data.id);
      return new Response("retry", { status: 500 });
    }
  }
  return new Response("ok", { status: 200 });
});
