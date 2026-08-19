// Supabase Edge Function: dict-setup
//
// Admin utility for the Qulex pronunciation dictionary in ElevenLabs, using
// the same ELEVENLABS_API_KEY secret the `tts` function already uses (so it
// is guaranteed to hit the correct production ElevenLabs account). Not part
// of the normal request path.
//
// SECURITY NOTE. This used to read:
//
//     const ADMIN_TOKEN = Deno.env.get("DICT_ADMIN_TOKEN") ?? "qbit-dict-setup-2026";
//
// DICT_ADMIN_TOKEN was never set, so that literal WAS the live credential —
// sitting in the deployed source and in git history, guarding create, delete
// and add_rules against the production ElevenLabs account. A verified probe
// with that value passed the gate and reached ElevenLabs; only the API key's
// own missing `user_read` scope stopped it going further, which is luck, not
// design.
//
// It now fails closed. With no DICT_ADMIN_TOKEN set, every request is refused,
// including one that guesses the old value. Set a real secret before use:
//
//     supabase secrets set DICT_ADMIN_TOKEN="$(openssl rand -hex 32)"
//
// Treat "qbit-dict-setup-2026" as burned — never reuse it.
const ELEVEN_KEY = Deno.env.get("ELEVENLABS_API_KEY");
const ADMIN_TOKEN = Deno.env.get("DICT_ADMIN_TOKEN") ?? "";

function cors() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-admin-token",
  };
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...cors(), "Content-Type": "application/json" },
  });
}

/** Constant-time compare, so the gate can't be probed a character at a time. */
function tokenMatches(supplied: string | null): boolean {
  // No secret configured => no access. This is the fail-closed default: an
  // admin surface that is unreachable is strictly better than one guarded by
  // a value anybody can read.
  if (!ADMIN_TOKEN) return false;
  if (!supplied) return false;
  const a = new TextEncoder().encode(supplied);
  const b = new TextEncoder().encode(ADMIN_TOKEN);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors() });
  try {
    if (!tokenMatches(req.headers.get("x-admin-token"))) {
      if (!ADMIN_TOKEN) {
        console.warn("dict-setup called but DICT_ADMIN_TOKEN is not set");
      }
      return json({ error: "forbidden" }, 403);
    }
    if (!ELEVEN_KEY) return json({ error: "not configured" }, 500);

    const body = await req.json();
    const action = body.action;

    if (action === "usage") {
      const res = await fetch(
        "https://api.elevenlabs.io/v1/user/subscription",
        { headers: { "xi-api-key": ELEVEN_KEY } },
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "elevenlabs error", detail: data }, 502);
      return json({
        tier: data.tier,
        character_count: data.character_count,
        character_limit: data.character_limit,
        characters_remaining: (data.character_limit ?? 0) -
          (data.character_count ?? 0),
        next_character_count_reset_unix: data.next_character_count_reset_unix,
        status: data.status,
      });
    }

    if (action === "list") {
      const res = await fetch(
        "https://api.elevenlabs.io/v1/pronunciation-dictionaries",
        { headers: { "xi-api-key": ELEVEN_KEY } },
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "elevenlabs error", detail: data }, 502);
      return json(data);
    }

    if (action === "create") {
      const res = await fetch(
        "https://api.elevenlabs.io/v1/pronunciation-dictionaries/add-from-rules",
        {
          method: "POST",
          headers: {
            "xi-api-key": ELEVEN_KEY,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            name: body.name ?? "qulex-headwords",
            description: body.description ??
              "Qulex vocabulary headword pronunciations",
            rules: body.rules ?? [],
          }),
        },
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "elevenlabs error", detail: data }, 502);
      return json(data);
    }

    if (action === "get") {
      const { dictionary_id } = body;
      if (!dictionary_id) return json({ error: "dictionary_id required" }, 400);
      const res = await fetch(
        `https://api.elevenlabs.io/v1/pronunciation-dictionaries/${dictionary_id}`,
        { headers: { "xi-api-key": ELEVEN_KEY } },
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "elevenlabs error", detail: data }, 502);
      return json(data);
    }

    if (action === "delete") {
      const { dictionary_id } = body;
      if (!dictionary_id) return json({ error: "dictionary_id required" }, 400);
      const res = await fetch(
        `https://api.elevenlabs.io/v1/pronunciation-dictionaries/${dictionary_id}`,
        { method: "DELETE", headers: { "xi-api-key": ELEVEN_KEY } },
      );
      if (!res.ok) {
        const detail = await res.text();
        return json({ error: "elevenlabs error", detail }, 502);
      }
      return json({ deleted: dictionary_id });
    }

    // Remove one or more graphemes from the live dictionary, returning a new
    // version_id. This is the maintenance path for a bad entry.
    //
    // It exists because of "sacred": the dictionary said S EY1 K R AH0 D,
    // which is CMUdict-correct, and ElevenLabs still rendered it with an extra
    // syllable, while the plain no-dictionary reading was right. Nothing in
    // the validation pipeline could have caught that — its oracle was a Scribe
    // transcript, and both readings transcribe back to "sacred" — so bad
    // entries surface one user report at a time, and each needs to be pullable
    // without rebuilding all 11,173.
    //
    // Removing beats a Word.say override: `say` only rewrites the HEADWORD,
    // and "sacred" also appears inside 28 other entries' definitions and
    // examples, where the dictionary would still apply.
    if (action === "remove_rules") {
      const { dictionary_id, rule_strings } = body;
      if (!dictionary_id) return json({ error: "dictionary_id required" }, 400);
      if (!Array.isArray(rule_strings) || rule_strings.length === 0) {
        return json({ error: "rule_strings must be a non-empty array" }, 400);
      }
      const res = await fetch(
        `https://api.elevenlabs.io/v1/pronunciation-dictionaries/${dictionary_id}/remove-rules`,
        {
          method: "POST",
          headers: {
            "xi-api-key": ELEVEN_KEY,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ rule_strings }),
        },
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "elevenlabs error", detail: data }, 502);
      // The caller MUST now point PRONUNCIATION_DICT_VERSION at this id, or
      // the removal has no effect on what the app actually plays.
      return json({
        removed: rule_strings,
        new_version_id: data.version_id ?? data.id ?? null,
        next_step:
          "set PRONUNCIATION_DICT_VERSION to new_version_id, or nothing changes",
        raw: data,
      });
    }

    if (action === "add_rules") {
      const { dictionary_id, rules } = body;
      if (!dictionary_id) return json({ error: "dictionary_id required" }, 400);
      const res = await fetch(
        `https://api.elevenlabs.io/v1/pronunciation-dictionaries/${dictionary_id}/add-rules`,
        {
          method: "POST",
          headers: {
            "xi-api-key": ELEVEN_KEY,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ rules }),
        },
      );
      const data = await res.json();
      if (!res.ok) return json({ error: "elevenlabs error", detail: data }, 502);
      return json(data);
    }

    return json({ error: "unknown action" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
