// Supabase Edge Function: tts
// Proxies ElevenLabs text-to-speech so the API key never reaches the client,
// and caches every generated clip in Supabase Storage (bucket "tts-cache")
// keyed by language+voice+model+text, so the same word/sentence is only ever
// synthesized once across every user and device.
//
// SECURITY NOTE. `text` is untrusted. verify_jwt is on, but the anon key that
// satisfies it ships inside the app binary — so in practice anyone can call
// this. It previously accepted a string of any length with no rate limit,
// which meant a loop of long payloads could drain the ElevenLabs balance on
// someone else's schedule, and mint an unbounded number of permanently public
// audio objects in a public bucket while doing it. Now:
//
//   * text is capped at MAX_TEXT_LEN — comfortably longer than any headword,
//     definition or example sentence the app actually sends.
//   * every synthesis (not every request — cache hits stay free) is counted
//     against a per-caller daily budget.
//   * upstream error bodies are logged, not returned.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ELEVEN_KEY = Deno.env.get("ELEVENLABS_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "tts-cache";

// Optional. When set, a caller presenting it in x-admin-token skips the daily
// per-caller budget below — and nothing else. Used by tools/warm_audio.py to
// pre-generate the example-sentence clips for the most common words, so the
// ElevenLabs spend happens once, centrally, instead of landing on whichever
// learner happens to meet a word first.
//
// FAILS CLOSED. An unset secret means no request is ever admin, rather than
// every request being admin — which is the shape this mistake usually takes.
const TTS_ADMIN_TOKEN = Deno.env.get("TTS_ADMIN_TOKEN");

// The longest thing the app ever asks for is a definition or an example
// sentence. The longest example in the shipped catalogue is comfortably under
// 300 characters; 400 leaves room without leaving room for abuse.
const MAX_TEXT_LEN = 400;

// Per caller, per day. A heavy session is ~200 synthesis calls (10 words x
// word+definition x 10 rounds), and almost all of those are cache hits that
// never reach this counter at all.
const MAX_CALLS_PER_DAY = 600;
const MAX_CHARS_PER_DAY = 60000;

// One flagship voice used consistently across English word audio and all
// five answer languages.
const VOICE_ID = "XoUkt2bf6DlvSzRmvA8X"; // "Victoria - Calm, Warm and Friendly"

// English gets eleven_flash_v2: lower latency, and — critically — it's one
// of only two ElevenLabs models that honor pronunciation dictionaries
// (phoneme-level overrides). eleven_flash_v2 is English-only, so non-English
// definition audio (es/pt/it/fr) stays on eleven_multilingual_v2.
const MODEL_ENGLISH = "eleven_flash_v2";
const MODEL_MULTILINGUAL = "eleven_multilingual_v2";

// ---------------------------------------------------------------------------
// PRONUNCIATION DICTIONARY — DISABLED PENDING REBUILD
//
// The dictionary is off by default because the shipped one silently destroyed
// audio. Measured against this exact function, same voice, same text:
//
//   "fund"       with dictionary -> 0.31s, 0% speech energy  (silent)
//                without         -> 0.91s, 50% speech
//   "endowment"  with dictionary -> 0.37s, 14% speech        (near-silent)
//                without         -> 1.10s, 63% speech
//
// A bad dictionary entry does not raise an error. ElevenLabs accepts it and
// emits nothing for that word, so a definition like "a fund given to support"
// was heard as "a ... given to support", and single words vanished entirely.
// It only ever affected English, because this is the only branch that attaches
// the dictionary — which is why the es/pt/it/fr definitions always sounded fine.
//
// Root cause is most likely the ~5,252 headwords whose phonemes came from
// espeak-ng IPA rather than CMUdict ARPAbet: two alphabets from two lineages,
// one of them not reliably accepted.
//
// Re-enable ONLY with a dictionary produced by tools/build_pronunciation_dict.py,
// which validates every entry by synthesis before it ships. Set
// USE_PRONUNCIATION_DICT=true plus the new id/version to turn it back on.
// ---------------------------------------------------------------------------
const USE_PRONUNCIATION_DICT =
  (Deno.env.get("USE_PRONUNCIATION_DICT") ?? "false").toLowerCase() === "true";
const PRONUNCIATION_DICT_ID = Deno.env.get("PRONUNCIATION_DICT_ID") ?? "";
const PRONUNCIATION_DICT_VERSION = Deno.env.get("PRONUNCIATION_DICT_VERSION") ??
  "";

// Lock this down with a comma-separated ALLOWED_ORIGINS once the web build has
// a fixed home. Native clients send no Origin at all, so this only affects
// browsers — and the real spend control is consume_budget(), not CORS.
const ALLOWED = (Deno.env.get("ALLOWED_ORIGINS") ?? "*")
  .split(",").map((s) => s.trim()).filter(Boolean);

function cors(req: Request) {
  const origin = req.headers.get("origin");
  const allow = ALLOWED.includes("*")
    ? "*"
    : (origin && ALLOWED.includes(origin) ? origin : (ALLOWED[0] ?? "null"));
  return {
    "Access-Control-Allow-Origin": allow,
    "Vary": "Origin",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
  };
}

function json(req: Request, data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors(req), "Content-Type": "application/json" },
  });
}

// Invisible characters: C0/C1 controls, soft hyphen, zero-width and bidi
// marks, line/paragraph separators, BOM. These are how an injected instruction
// hides inside an otherwise innocent-looking definition.
//
// Written as numeric comparisons rather than a regex character class on
// purpose: escape sequences in a source file get mangled by anything that
// re-encodes it in transit, and a half-mangled character class is a source of
// silent holes.
function isInvisible(c: number): boolean {
  return c < 0x20 ||
    (c >= 0x7f && c <= 0x9f) ||
    c === 0xad ||
    (c >= 0x200b && c <= 0x200f) ||
    c === 0x2028 || c === 0x2029 ||
    (c >= 0x202a && c <= 0x202e) ||
    (c >= 0x2066 && c <= 0x2069) ||
    c === 0xfeff;
}

/** Collapses anything invisible to a space, squeezes whitespace, trims. */
function stripInvisible(v: string): string {
  let out = "";
  for (const ch of v) {
    out += isInvisible(ch.codePointAt(0)!) ? " " : ch;
  }
  return out.replace(/\s+/g, " ").trim();
}

/// Constant-time string compare.
///
/// A plain `===` on a secret leaks its length and, in principle, its prefix
/// through timing. The window is small over the public internet and the cost of
/// not caring is a bypass of the only thing standing between an anonymous
/// caller and an uncapped ElevenLabs bill.
function timingSafeEqual(a: string, b: string): boolean {
  const ab = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

/// True only for the bulk-warming tool: the secret must be configured AND
/// presented. Grants exactly one privilege — skipping the daily budget.
function isAdmin(req: Request): boolean {
  if (!TTS_ADMIN_TOKEN) return false;
  const given = req.headers.get("x-admin-token");
  if (!given) return false;
  return timingSafeEqual(given, TTS_ADMIN_TOKEN);
}

/** Who to bill this to. See the note in the explain function. */
function callerBucket(req: Request): string {
  try {
    const auth = req.headers.get("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const part = token.split(".")[1];
    if (part) {
      const pad = part.length % 4 ? "=".repeat(4 - (part.length % 4)) : "";
      const payload = JSON.parse(
        atob(part.replace(/-/g, "+").replace(/_/g, "/") + pad),
      );
      if (payload?.sub && payload?.role !== "anon") return "u:" + payload.sub;
    }
  } catch { /* fall through to IP */ }
  const fwd = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim();
  return "ip:" + (fwd || "unknown");
}

// djb2 — fast, deterministic, plenty for a cache key (not security-sensitive).
function hashKey(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  }
  return h.toString(16);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors(req) });
  }
  try {
    if (!ELEVEN_KEY) return json(req, { error: "not configured" }, 500);

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return json(req, { error: "invalid JSON body" }, 400);
    }

    const rawText = body.text;
    if (typeof rawText !== "string") {
      return json(req, { error: "text is required" }, 400);
    }
    // Normalised before hashing as well as before synthesis, so "cat" and
    // "cat " share one cache entry instead of minting two objects.
    const text = stripInvisible(rawText);
    if (!text) return json(req, { error: "text is required" }, 400);
    if (text.length > MAX_TEXT_LEN) {
      return json(req, {
        error: "text too long",
        max: MAX_TEXT_LEN,
        got: text.length,
      }, 413);
    }

    const safeLang = (typeof body.lang === "string" ? body.lang : "en")
      .toString().slice(0, 5);
    const isEnglish = safeLang.toLowerCase().startsWith("en");
    const modelId = isEnglish ? MODEL_ENGLISH : MODEL_MULTILINGUAL;
    const useDict = isEnglish && USE_PRONUNCIATION_DICT &&
      PRONUNCIATION_DICT_ID && PRONUNCIATION_DICT_VERSION;

    // The dictionary is part of the cache identity: audio made with it is not
    // interchangeable with audio made without it. Without this, turning the
    // dictionary off would keep serving the silent clips it already produced.
    const dictTag = useDict
      ? `dict:${PRONUNCIATION_DICT_ID}:${PRONUNCIATION_DICT_VERSION}`
      : "nodict";
    const key = hashKey(`${safeLang}|${VOICE_ID}|${modelId}|${dictTag}|${text}`);
    const dir = safeLang;
    const fileName = `${key}.mp3`;
    const path = `${dir}/${fileName}`;

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // 1) Serve from cache if this exact text+lang+model+dict was already made.
    //    Cache hits cost nothing and are deliberately not rate limited — a
    //    learner replaying a word twenty times should never be throttled.
    const { data: listing } = await supabase.storage.from(BUCKET).list(dir, {
      search: fileName,
    });
    if (listing && listing.some((f) => f.name === fileName)) {
      const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
      return json(req, { url: pub.publicUrl, cached: true });
    }

    // 2) A miss means we are about to spend money. Check the budget first —
    //    unless this is the warming tool, which is deliberately spending it in
    //    bulk on the developer's own instruction. Logged either way, so a
    //    surprising bill has something to read.
    const admin = isAdmin(req);
    if (admin) console.log("admin warm", safeLang, text.length, "chars");
    const { data: within, error: budgetErr } = admin
        ? { data: true, error: null }
        : await supabase.rpc(
      "consume_budget",
      {
        p_bucket: callerBucket(req),
        p_fn: "tts",
        p_units: text.length,
        p_max_calls: MAX_CALLS_PER_DAY,
        p_max_units: MAX_CHARS_PER_DAY,
      },
    );
    if (budgetErr) {
      console.error("budget check failed", budgetErr);
      return json(req, { error: "synthesis unavailable" }, 500);
    }
    if (within === false) {
      return json(req, { error: "daily limit reached" }, 429);
    }

    // 3) Synthesize.
    const requestBody: Record<string, unknown> = {
      text,
      model_id: modelId,
      voice_settings: { stability: 0.75, similarity_boost: 0.75 },
    };
    if (useDict) {
      requestBody.pronunciation_dictionary_locators = [
        {
          pronunciation_dictionary_id: PRONUNCIATION_DICT_ID,
          version_id: PRONUNCIATION_DICT_VERSION,
        },
      ];
    }

    const elevenRes = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}`,
      {
        method: "POST",
        headers: {
          "xi-api-key": ELEVEN_KEY,
          "Content-Type": "application/json",
          "Accept": "audio/mpeg",
        },
        body: JSON.stringify(requestBody),
      },
    );
    if (!elevenRes.ok) {
      // The upstream body carries account and quota detail. Log it; don't hand
      // it to an anonymous caller.
      console.error("elevenlabs error", elevenRes.status, await elevenRes.text());
      return json(req, { error: "synthesis unavailable" }, 502);
    }
    const audioBytes = new Uint8Array(await elevenRes.arrayBuffer());

    // A clip this small contains no speech. Refuse to cache it: a silent object
    // in Storage is served forever and is invisible from the client, which is
    // exactly how the dictionary fault stayed hidden for so long.
    if (audioBytes.byteLength < 2048) {
      console.error("synthesis returned no audio", audioBytes.byteLength, text);
      return json(req, { error: "synthesis returned no audio" }, 502);
    }

    // 4) Cache it for next time (best-effort — still return the audio if this
    //    fails).
    await supabase.storage.from(BUCKET).upload(path, audioBytes, {
      contentType: "audio/mpeg",
      upsert: true,
    });
    const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);

    return json(req, { url: pub.publicUrl, cached: false });
  } catch (e) {
    console.error("tts failed", e);
    return json(req, { error: "synthesis unavailable" }, 500);
  }
});
