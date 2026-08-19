-- 20260819_lock_api_budget_and_bucket.sql
-- Applied to project fzhguqoodojugeuyosnj on 2026-08-19.
--
-- api_budget answered an anon SELECT with 200 [] rather than an error: RLS was
-- returning zero rows, which is correct, but the table was still published in
-- the REST schema. Take the grants away so it isn't part of the API surface
-- at all. The Edge Functions reach it with the service role, which is
-- unaffected by both RLS and these grants.
revoke all on table public.api_budget from anon, authenticated;

-- SEC-3, the storage half. The bucket had no size limit and no MIME
-- allowlist, so anything the function wrote became a permanently public
-- object of any size. 512 KiB is comfortably above the largest real clip
-- (a full example sentence at this voice runs well under 200 KiB).
update storage.buckets
   set file_size_limit = 524288,
       allowed_mime_types = array['audio/mpeg']
 where id = 'tts-cache';
