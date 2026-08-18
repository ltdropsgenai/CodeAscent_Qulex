// Supabase Edge Function: tts
// Proxies ElevenLabs text-to-speech so the API key never reaches the client,
// and caches every generated clip in Supabase Storage (bucket "tts-cache")
// keyed by language+voice+model+text, so the same word/sentence is only ever
// synthesized once across every user and device.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ELEVEN_KEY = Deno.env.get("ELEVENLABS_API_KEY");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "tts-cache";

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
const PRONUNCIATION_DICT_VERSION = Deno.env.get("PRONUNCIATION_DICT_VERSION") ?? "";

function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  };
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
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors() });
  try {
    if (!ELEVEN_KEY) {
      return new Response(JSON.stringify({ error: "ELEVENLABS_API_KEY not configured" }), {
        status: 500,
        headers: { ...cors(), "Content-Type": "application/json" },
      });
    }
    const { text, lang } = await req.json();
    if (!text || typeof text !== "string") {
      return new Response(JSON.stringify({ error: "text is required" }), {
        status: 400,
        headers: { ...cors(), "Content-Type": "application/json" },
      });
    }
    const safeLang = (lang || "en").toString().slice(0, 5);
    const isEnglish = safeLang.toLowerCase().startsWith("en");
    const modelId = isEnglish ? MODEL_ENGLISH : MODEL_MULTILINGUAL;
    const useDict =
      isEnglish && USE_PRONUNCIATION_DICT && PRONUNCIATION_DICT_ID && PRONUNCIATION_DICT_VERSION;

    // The dictionary is part of the cache identity: audio made with it is not
    // interchangeable with audio made without it. Without this, turning the
    // dictionary off would keep serving the silent clips it already produced.
    const dictTag = useDict ? `dict:${PRONUNCIATION_DICT_ID}:${PRONUNCIATION_DICT_VERSION}` : "nodict";
    const key = hashKey(`${safeLang}|${VOICE_ID}|${modelId}|${dictTag}|${text}`);
    const dir = safeLang;
    const fileName = `${key}.mp3`;
    const path = `${dir}/${fileName}`;

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // 1) Serve from cache if this exact text+lang+model+dict was already made.
    const { data: listing } = await supabase.storage.from(BUCKET).list(dir, { search: fileName });
    if (listing && listing.some((f) => f.name === fileName)) {
      const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);
      return new Response(JSON.stringify({ url: pub.publicUrl, cached: true }), {
        headers: { ...cors(), "Content-Type": "application/json" },
      });
    }

    // 2) Not cached — synthesize via ElevenLabs.
    const requestBody: Record<string, unknown> = {
      text,
      model_id: modelId,
      voice_settings: { stability: 0.75, similarity_boost: 0.75 },
    };
    if (useDict) {
      requestBody.pronunciation_dictionary_locators = [
        { pronunciation_dictionary_id: PRONUNCIATION_DICT_ID, version_id: PRONUNCIATION_DICT_VERSION },
      ];
    }

    const elevenRes = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}`, {
      method: "POST",
      headers: {
        "xi-api-key": ELEVEN_KEY,
        "Content-Type": "application/json",
        "Accept": "audio/mpeg",
      },
      body: JSON.stringify(requestBody),
    });
    if (!elevenRes.ok) {
      const detail = await elevenRes.text();
      return new Response(JSON.stringify({ error: "ElevenLabs error", detail }), {
        status: 502,
        headers: { ...cors(), "Content-Type": "application/json" },
      });
    }
    const audioBytes = new Uint8Array(await elevenRes.arrayBuffer());

    // A clip this small contains no speech. Refuse to cache it: a silent object
    // in Storage is served forever and is invisible from the client, which is
    // exactly how the dictionary fault stayed hidden for so long.
    if (audioBytes.byteLength < 2048) {
      return new Response(
        JSON.stringify({
          error: "synthesis returned no audio",
          bytes: audioBytes.byteLength,
          text,
        }),
        { status: 502, headers: { ...cors(), "Content-Type": "application/json" } },
      );
    }

    // 3) Cache it for next time (best-effort — still return the audio if this fails).
    await supabase.storage.from(BUCKET).upload(path, audioBytes, {
      contentType: "audio/mpeg",
      upsert: true,
    });
    const { data: pub } = supabase.storage.from(BUCKET).getPublicUrl(path);

    return new Response(JSON.stringify({ url: pub.publicUrl, cached: false }), {
      headers: { ...cors(), "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { ...cors(), "Content-Type": "application/json" },
    });
  }
});
