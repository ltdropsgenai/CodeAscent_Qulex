-- Storage bucket for the over-the-air word catalogue.
--
-- Public read on purpose: the payload is the same word list already compiled
-- into every installed binary, so it is not a secret, and serving it off the
-- CDN means a content push costs no Edge Function invocations and no auth
-- round-trip on a device that may be on a bad connection.
--
-- Integrity, not confidentiality, is what matters here, and it is enforced on
-- the client: manifest.json carries the SHA-256 of the decompressed catalogue
-- and CatalogueOta refuses anything that does not match.
--
-- 100MB ceiling against today's ~25MB catalogue (~6.3MB gzipped), leaving room
-- to grow without leaving room for an accident.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'catalogue',
  'catalogue',
  true,
  104857600,
  array['application/json', 'application/gzip', 'application/octet-stream']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Reads only. There is deliberately no INSERT/UPDATE/DELETE policy: writes
-- happen exclusively through the catalogue-admin Edge Function, which holds
-- the service-role key and bypasses RLS. Anything else that can reach this
-- bucket can only read it.
drop policy if exists "catalogue public read" on storage.objects;
create policy "catalogue public read"
  on storage.objects for select
  using (bucket_id = 'catalogue');
