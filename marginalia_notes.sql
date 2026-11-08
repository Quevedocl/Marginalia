create table if not exists marginalia_notes (
  id         text primary key,
  user_id    text not null,          -- id de usuario de Spotify
  track_id   text not null,          -- id real de la canción en Spotify
  ms         integer not null,       -- instante exacto en milisegundos
  text       text not null,
  meta       jsonb,                  -- título, artista, carátula, duración
  created_at timestamptz default now()
);
create index if not exists marginalia_notes_user_track on marginalia_notes (user_id, track_id);

alter table marginalia_notes enable row level security;
create policy "notes select" on marginalia_notes for select to anon using (true);
create policy "notes insert" on marginalia_notes for insert to anon with check (true);
create policy "notes update" on marginalia_notes for update to anon using (true) with check (true);
create policy "notes delete" on marginalia_notes for delete to anon using (true);
