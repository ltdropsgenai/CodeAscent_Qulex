-- 20260819_harden_entitlements_budget_and_explanations.sql
-- Applied to project fzhguqoodojugeuyosnj on 2026-08-19.
--
-- SEC-4: entitlements become read-only to clients.
--
-- The old policy was:
--     entitlements_own  ALL  qual/with_check: auth.uid() = user_id
-- ALL includes INSERT and UPDATE, and nothing constrained is_pro, so any
-- signed-in user could grant themselves Pro with one REST call using the anon
-- key that ships in the app binary. The client no longer writes this table at
-- all (see SyncService); a store webhook holding the service role will.
drop policy if exists entitlements_own on public.entitlements;

create policy entitlements_read_own
  on public.entitlements
  for select
  using (auth.uid() = user_id);

-- No insert/update/delete policy on purpose. RLS denies by default, and the
-- service role bypasses RLS, so only server-side code can grant an entitlement.

-- SEC-6: a trigger function should not be callable as an RPC.
revoke execute on function public.handle_new_user() from anon, authenticated, public;
alter function public.touch_updated_at() set search_path = '';
alter function public.handle_new_user() set search_path = '';

-- SEC-1: make a poisoned explanation reachable only by whoever poisoned it.
--
-- word_explanations was keyed (word_id, lang), and word/definition arrive from
-- the client, so a crafted definition under a real word_id overwrote what every
-- other learner sees. Keying on a hash of the content the explanation was
-- generated FROM means honest clients (all sending the same bundled catalogue
-- text) still share one row, while anything else lands in its own.
alter table public.word_explanations
  add column if not exists content_hash text not null default '';

alter table public.word_explanations
  drop constraint if exists word_explanations_pkey;

alter table public.word_explanations
  add constraint word_explanations_pkey
  primary key (word_id, lang, content_hash);

comment on column public.word_explanations.content_hash is
  'sha-256 (first 16 hex) of word || NUL || definition. Part of the primary key '
  'so client-supplied text can only ever poison its own cache entry.';

-- SEC-3: a daily budget for the billable Edge Functions.
--
-- tts had no length cap and no rate limit, so anyone holding the public anon
-- key could bill unlimited ElevenLabs synthesis. explain had the same shape
-- against the Anthropic key.
create table if not exists public.api_budget (
  bucket      text        not null,   -- 'u:<uid>' when signed in, else 'ip:<addr>'
  day         date        not null default current_date,
  fn          text        not null,   -- 'tts' | 'explain'
  calls       integer     not null default 0,
  units       integer     not null default 0,  -- characters submitted
  updated_at  timestamptz not null default now(),
  primary key (bucket, day, fn)
);

alter table public.api_budget enable row level security;
-- Deliberately no policies: clients must never read or write this. The Edge
-- Functions reach it with the service role, which bypasses RLS.

comment on table public.api_budget is
  'Per-caller daily usage of the billable Edge Functions. Service-role only.';

-- Atomically count a call and report whether it is still within budget.
-- Returns false once either ceiling is crossed; the caller then refuses.
create or replace function public.consume_budget(
  p_bucket    text,
  p_fn        text,
  p_units     integer,
  p_max_calls integer,
  p_max_units integer
) returns boolean
language plpgsql
as $$
declare
  v_calls integer;
  v_units integer;
begin
  insert into public.api_budget as b (bucket, day, fn, calls, units)
  values (p_bucket, current_date, p_fn, 1, greatest(p_units, 0))
  on conflict (bucket, day, fn) do update
    set calls = b.calls + 1,
        units = b.units + greatest(p_units, 0),
        updated_at = now()
  returning b.calls, b.units into v_calls, v_units;

  return v_calls <= p_max_calls and v_units <= p_max_units;
end;
$$;

revoke execute on function
  public.consume_budget(text, text, integer, integer, integer)
  from anon, authenticated, public;

create index if not exists api_budget_day_idx on public.api_budget (day);
