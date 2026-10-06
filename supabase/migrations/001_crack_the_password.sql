-- Apply in the Supabase SQL editor. Client writes use authenticated RPCs only.
create extension if not exists pgcrypto with schema extensions;
create extension if not exists unaccent with schema extensions;

create table public.games (
 id uuid primary key default gen_random_uuid(), code text not null unique check(code ~ '^[A-Z0-9]{5}$'),
 title text not null, status text not null default 'lobby' check(status in('lobby','running','paused','finished')),
 current_round int not null default 1, settings jsonb not null default '{"cooldown_seconds":3,"max_attempts":40,"accent_insensitive":true,"late_join":true,"lock_room":false}',
 created_at timestamptz not null default now()
);
create table public.rounds (
 id uuid primary key default gen_random_uuid(), game_id uuid not null references public.games on delete cascade,
 round_number int not null check(round_number between 1 and 10), prompt text not null default '' check(char_length(prompt)<=180), revealed_hints int not null default 0 check(revealed_hints between 0 and 5),
 time_limit_seconds int check(time_limit_seconds is null or time_limit_seconds between 1 and 86400), status text not null default 'queued', started_at timestamptz, ended_at timestamptz, paused_at timestamptz,
 unique(game_id,round_number)
);
-- Private tables are deliberately excluded from Realtime and direct client grants.
create table public.round_answers (
 round_id uuid primary key references public.rounds on delete cascade, answer_hash bytea not null, answer_salt bytea not null,
 accepted_answers_hash bytea[] not null default '{}', accepted_answers_salt bytea[] not null default '{}'
);
create table public.round_hints(round_id uuid primary key references public.rounds on delete cascade,hints jsonb not null default '[]');
create table public.game_host_secrets(game_id uuid primary key references public.games on delete cascade,token_hash bytea not null);
create table public.players (
 id uuid primary key default gen_random_uuid(), game_id uuid not null references public.games on delete cascade,
 name text not null, character text not null, color text not null default '#b9f93c', joined_at timestamptz not null default clock_timestamp(), unique(game_id,name)
);
create table public.player_secrets(player_id uuid primary key references public.players on delete cascade,token_hash bytea not null);
create table public.attempts (
 id bigint generated always as identity primary key, round_id uuid not null references public.rounds on delete cascade,
 player_id uuid not null references public.players on delete cascade, created_at timestamptz not null default clock_timestamp(), is_correct boolean not null
);
create table public.solves (
 id bigint generated always as identity primary key, round_id uuid not null references public.rounds on delete cascade,
 player_id uuid not null references public.players on delete cascade, solved_at timestamptz not null,
 elapsed_ms bigint not null, attempts_count int not null, points int not null, unique(round_id,player_id)
);
create index rounds_game_round_idx on public.rounds(game_id,round_number);
create index players_game_joined_idx on public.players(game_id,joined_at);
create unique index players_game_name_ci_idx on public.players(game_id,lower(name));
create index attempts_round_player_idx on public.attempts(round_id,player_id);
create index solves_round_rank_idx on public.solves(round_id,solved_at,attempts_count);

do $$ declare t text; begin
 foreach t in array array['games','rounds','round_answers','round_hints','game_host_secrets','players','player_secrets','attempts','solves'] loop
  execute format('alter table public.%I enable row level security',t);
 end loop;
end $$;
create policy games_read on public.games for select to anon,authenticated using(true);
create policy rounds_read on public.rounds for select to anon,authenticated using(true);
create policy players_read on public.players for select to anon,authenticated using(true);
create policy solves_read on public.solves for select to anon,authenticated using(true);
revoke all on public.games,public.rounds,public.round_answers,public.round_hints,public.game_host_secrets,public.players,public.player_secrets,public.attempts,public.solves from anon,authenticated;
grant select on public.games,public.rounds,public.players,public.solves to anon,authenticated;

create or replace function public._norm(v text, ignore_accents boolean) returns text
language sql immutable security definer set search_path=pg_catalog,extensions as $$
 select case when ignore_accents then lower(extensions.unaccent('extensions.unaccent',btrim(coalesce(v,'')))) else lower(btrim(coalesce(v,''))) end
$$;
revoke all on function public._norm(text,boolean) from public,anon,authenticated;
-- Edit this formula in one place to adjust the score schedule.
create or replace function public._points(rank_no int) returns int language sql immutable security definer set search_path=pg_catalog as $$
 select case when rank_no<=3 then 110-rank_no*10 else greatest(10,80-(rank_no-3)*5) end
$$;
revoke all on function public._points(int) from public,anon,authenticated;

create or replace function public.create_game(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare g public.games; rd jsonb; code_value text; host_token text; rid uuid; salt_value bytea; alt text; alt_hashes bytea[]; alt_salts bytea[]; accent_mode boolean; round_i int:=0;
begin
 if jsonb_typeof(p_payload->'rounds')<>'array' or jsonb_array_length(p_payload->'rounds') not between 1 and 10 then raise exception 'Configure de 1 a 10 rodadas.';end if;
 host_token:=encode(gen_random_bytes(32),'hex');
 loop code_value:=upper(substr(encode(gen_random_bytes(4),'hex'),1,5));exit when not exists(select 1 from public.games where code=code_value);end loop;
 insert into public.games(code,title,settings) values(code_value,coalesce(nullif(btrim(p_payload->>'title'),''),'Crack the Password'),coalesce(p_payload->'settings','{}')) returning * into g;
 insert into public.game_host_secrets values(g.id,digest(host_token,'sha256'));
 accent_mode:=coalesce((g.settings->>'accent_insensitive')::boolean,true);
 for rd in select value from jsonb_array_elements(p_payload->'rounds') loop
  round_i:=round_i+1;
  if coalesce((rd->>'round_number')::int,0)<>round_i then raise exception 'As rodadas devem ser numeradas em sequência.';end if;
  if length(btrim(coalesce(rd->>'answer','')))=0 then raise exception 'A senha não pode ficar vazia.';end if;
  if char_length(rd->>'answer')>80 or char_length(coalesce(rd->>'prompt',''))>180 then raise exception 'A senha deve ter até 80 caracteres e a pergunta até 180.';end if;
  if jsonb_typeof(coalesce(rd->'hints','[]'))<>'array' or jsonb_array_length(coalesce(rd->'hints','[]'))>5 then raise exception 'Cada rodada aceita no máximo cinco dicas.';end if;
  if jsonb_typeof(coalesce(rd->'accepted_answers','[]'))<>'array' or jsonb_array_length(coalesce(rd->'accepted_answers','[]'))>20 then raise exception 'Cada rodada aceita no máximo vinte respostas alternativas.';end if;
  insert into public.rounds(game_id,round_number,prompt,time_limit_seconds)
  values(g.id,(rd->>'round_number')::int,coalesce(rd->>'prompt',''),nullif(rd->>'time_limit_seconds','')::int) returning id into rid;
  insert into public.round_hints(round_id,hints) values(rid,coalesce(rd->'hints','[]'));
  salt_value:=gen_random_bytes(32);alt_hashes:='{}';alt_salts:='{}';
  for alt in select jsonb_array_elements_text(coalesce(rd->'accepted_answers','[]')) loop
   salt_value:=gen_random_bytes(32);alt_salts:=array_append(alt_salts,salt_value);alt_hashes:=array_append(alt_hashes,digest(convert_to(public._norm(alt,accent_mode),'UTF8')||salt_value,'sha256'));
  end loop;
  salt_value:=gen_random_bytes(32);
  insert into public.round_answers values(rid,digest(convert_to(public._norm(rd->>'answer',accent_mode),'UTF8')||salt_value,'sha256'),salt_value,alt_hashes,alt_salts);
 end loop;
 return jsonb_build_object('game_id',g.id,'code',g.code,'host_token',host_token);
end $$;

create or replace function public.join_game(p_code text,p_name text,p_character text,p_color text default '#b9f93c') returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare g public.games; pid uuid; token_value text; n text:=btrim(coalesce(p_name,''));
begin
 select * into g from public.games where code=upper(btrim(p_code));if not found then raise exception 'Código de sala não encontrado.';end if;
 if coalesce((g.settings->>'lock_room')::boolean,false) then raise exception 'A sala está trancada.';end if;
 if g.status in('running','paused') and not coalesce((g.settings->>'late_join')::boolean,true) then raise exception 'A sala não aceita entradas durante a partida.';end if;
 if char_length(n) not between 1 and 20 or n~'[[:cntrl:]<>]' then raise exception 'Use um nome de 1 a 20 caracteres.';end if;
 if lower(n) in('fuck','shit','bitch','asshole','puta','puto','merda','caralho','cacete') then raise exception 'Escolha outro nome para aparecer na sala.';end if;
 if p_character not in('sun','wind','leaf','battery','drop','solar','bulb','earth','recycle','bike','plug','sprout') then raise exception 'Personagem inválido.';end if;
 if coalesce(p_color,'') !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Cor inválida.';end if;
 if exists(select 1 from public.players where game_id=g.id and lower(name)=lower(n)) then raise exception 'Nome em uso. Escolha outro.';end if;
 token_value:=encode(gen_random_bytes(32),'hex');insert into public.players(game_id,name,character,color) values(g.id,n,p_character,p_color) returning id into pid;
 insert into public.player_secrets values(pid,digest(token_value,'sha256'));return jsonb_build_object('player_id',pid,'player_token',token_value);
end $$;

create or replace function public.get_game_state(p_code text,p_host_token text default null,p_player_id uuid default null,p_player_token text default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare g public.games;r public.rounds; player_rows jsonb; board_rows jsonb; attempts_total int:=0; solved_total int:=0; private_hints jsonb:='[]'; visible_hints jsonb:='[]'; is_host boolean:=false;
begin
 select * into g from public.games where code=upper(btrim(p_code));if not found then raise exception 'Sala não encontrada.';end if;
 if p_host_token is not null then
  if not exists(select 1 from public.game_host_secrets where game_id=g.id and token_hash=digest(p_host_token,'sha256')) then raise exception 'Chave de anfitrião inválida.';end if;
  is_host:=true;
 elsif p_player_id is not null then
  if not exists(select 1 from public.players p join public.player_secrets s on s.player_id=p.id where p.id=p_player_id and p.game_id=g.id and s.token_hash=digest(coalesce(p_player_token,''),'sha256')) then raise exception 'Sessão de participante inválida.';end if;
 else raise exception 'Sessão inválida.';end if;
 select * into r from public.rounds where game_id=g.id and round_number=g.current_round;
 if r.id is not null then
  select h.hints into private_hints from public.round_hints h where h.round_id=r.id;
  if is_host then visible_hints:=coalesce(private_hints,'[]');else select coalesce(jsonb_agg(x.value order by x.ordinality),'[]') into visible_hints from jsonb_array_elements(coalesce(private_hints,'[]')) with ordinality x(value,ordinality) where x.ordinality<=r.revealed_hints;end if;
  select count(*) into attempts_total from public.attempts where round_id=r.id;
  select count(*) into solved_total from public.solves where round_id=r.id;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'character',p.character,'color',p.color,'joined_at',p.joined_at,'solved',s.player_id is not null,'rank',s.rank_no,'elapsed_ms',s.elapsed_ms,'attempts_count',coalesce(s.attempts_count,(select count(*) from public.attempts at where at.round_id=r.id and at.player_id=p.id)),'points',s.points,'total_points',coalesce((select sum(so.points) from public.solves so join public.rounds rr on rr.id=so.round_id where rr.game_id=g.id and so.player_id=p.id),0)) order by p.joined_at),'[]') into player_rows
 from public.players p left join lateral(select so.*,row_number() over(order by so.solved_at,so.attempts_count,p2.joined_at) rank_no from public.solves so join public.players p2 on p2.id=so.player_id where so.round_id=r.id) s on s.player_id=p.id where p.game_id=g.id;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.solved desc,x.rank nulls last,x.joined_at),'[]') into board_rows from (
  select p.id,p.name,p.character,p.color,p.joined_at,(s.player_id is not null) solved,s.rank_no rank,s.elapsed_ms,s.attempts_count,s.points,coalesce((select sum(so.points) from public.solves so join public.rounds rr on rr.id=so.round_id where rr.game_id=g.id and so.player_id=p.id),0) total_points
  from public.players p left join lateral(select so.player_id,so.elapsed_ms,so.attempts_count,so.points,row_number() over(order by so.solved_at,so.attempts_count,p2.joined_at) rank_no from public.solves so join public.players p2 on p2.id=so.player_id where so.round_id=r.id) s on s.player_id=p.id where p.game_id=g.id
 ) x;
 return jsonb_build_object('game',jsonb_build_object('id',g.id,'code',g.code,'title',g.title,'status',g.status,'current_round',g.current_round,'settings',g.settings),'round',case when r.id is null then null else jsonb_build_object('round_number',r.round_number,'prompt',r.prompt,'hints',coalesce(visible_hints,'[]'),'revealed_hints',r.revealed_hints,'status',r.status,'started_at',r.started_at,'ended_at',r.ended_at,'time_limit_seconds',r.time_limit_seconds) end,'players',player_rows,'leaderboard',board_rows,'attempts_total',attempts_total,'solved_count',solved_total);
end $$;

create or replace function public.submit_guess(p_code text,p_player_id uuid,p_player_token text,p_guess text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare g public.games;r public.rounds;a public.round_answers; count_try int; last_try timestamptz; now_server timestamptz:=clock_timestamp(); norm_guess text; correct_answer boolean:=false; i int; rank_value int; elapsed bigint; cd int; max_try int;
begin
 select * into g from public.games where code=upper(btrim(p_code));if not found then raise exception 'Sala não encontrada.';end if;
 if not exists(select 1 from public.players p join public.player_secrets s on s.player_id=p.id where p.id=p_player_id and p.game_id=g.id and s.token_hash=digest(coalesce(p_player_token,''),'sha256')) then raise exception 'Sessão de participante inválida.';end if;
 if g.status<>'running' then raise exception 'A rodada não está recebendo respostas.';end if;
 select * into r from public.rounds where game_id=g.id and round_number=g.current_round for update;
 if r.status<>'running' or r.started_at is null or (r.time_limit_seconds is not null and now_server>r.started_at+make_interval(secs=>r.time_limit_seconds)) then raise exception 'O tempo da rodada terminou.';end if;
 if p_guess is null or length(btrim(p_guess))=0 then raise exception 'A tentativa não pode ficar vazia.';end if;
 if length(p_guess)>100 then raise exception 'A tentativa é muito longa.';end if;
 if exists(select 1 from public.solves where round_id=r.id and player_id=p_player_id) then return jsonb_build_object('correct',true,'rank',(select count(*) from public.solves where round_id=r.id),'message','Você já decifrou esta senha.');end if;
 cd:=greatest(0,least(60,coalesce((g.settings->>'cooldown_seconds')::int,3)));max_try:=greatest(1,least(200,coalesce((g.settings->>'max_attempts')::int,40)));
 select count(*),max(created_at) into count_try,last_try from public.attempts where round_id=r.id and player_id=p_player_id;
 if count_try>=max_try then raise exception 'Você atingiu o limite de tentativas.';end if;
 if last_try is not null and now_server<last_try+make_interval(secs=>cd) then raise exception 'Aguarde antes da próxima tentativa.';end if;
 select * into a from public.round_answers where round_id=r.id;norm_guess:=public._norm(p_guess,coalesce((g.settings->>'accent_insensitive')::boolean,true));
 correct_answer:=digest(convert_to(norm_guess,'UTF8')||a.answer_salt,'sha256')=a.answer_hash;
 if not correct_answer then for i in 1..coalesce(array_length(a.accepted_answers_hash,1),0) loop if digest(convert_to(norm_guess,'UTF8')||a.accepted_answers_salt[i],'sha256')=a.accepted_answers_hash[i] then correct_answer:=true;exit;end if;end loop;end if;
 insert into public.attempts(round_id,player_id,created_at,is_correct) values(r.id,p_player_id,now_server,correct_answer);
 if not correct_answer then return jsonb_build_object('correct',false,'message','Ainda não! Reveja as pistas e tente de novo.');end if;
 elapsed:=greatest(0,(extract(epoch from(now_server-r.started_at))*1000)::bigint);select count(*)+1 into rank_value from public.solves where round_id=r.id;
 insert into public.solves(round_id,player_id,solved_at,elapsed_ms,attempts_count,points) values(r.id,p_player_id,now_server,elapsed,count_try+1,public._points(rank_value));
 return jsonb_build_object('correct',true,'rank',rank_value,'message','Senha decifrada! Você ficou em '||rank_value||'º lugar.');
end $$;

create or replace function public._host(p_code text,p_token text) returns public.games language plpgsql security definer set search_path=pg_catalog,public,extensions as $$
declare g public.games;begin select * into g from public.games where code=upper(btrim(p_code)) for update;if not found or not exists(select 1 from public.game_host_secrets where game_id=g.id and token_hash=digest(coalesce(p_token,''),'sha256')) then raise exception 'Sessão do anfitrião inválida.';end if;return g;end$$;
revoke all on function public._host(text,text) from public,anon,authenticated;
create or replace function public.start_game(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;r public.rounds;begin g:=public._host(p_code,p_host_token);if g.status not in('lobby','finished') then raise exception 'A sala não pode iniciar agora.';end if;if not exists(select 1 from public.players where game_id=g.id) then raise exception 'É preciso ter ao menos um participante.';end if;select * into r from public.rounds where game_id=g.id and round_number=g.current_round for update;if not found then raise exception 'Não há uma rodada.';end if;update public.rounds set status='running',started_at=now(),ended_at=null,paused_at=null where id=r.id;update public.games set status='running' where id=g.id;return jsonb_build_object('ok',true);end$$;
create or replace function public.pause_game(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);if g.status<>'running' then raise exception 'A rodada não está em andamento.';end if;update public.games set status='paused' where id=g.id;update public.rounds set status='paused',paused_at=now() where game_id=g.id and round_number=g.current_round;return jsonb_build_object('ok',true);end$$;
create or replace function public.resume_game(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);if g.status<>'paused' then raise exception 'A rodada não está pausada.';end if;update public.games set status='running' where id=g.id;update public.rounds set status='running',started_at=started_at+greatest(interval '0 seconds',now()-paused_at),paused_at=null where game_id=g.id and round_number=g.current_round;return jsonb_build_object('ok',true);end$$;
create or replace function public.reveal_hint(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;r public.rounds;h jsonb;begin g:=public._host(p_code,p_host_token);select * into r from public.rounds where game_id=g.id and round_number=g.current_round for update;select hints into h from public.round_hints where round_id=r.id;if r.revealed_hints>=jsonb_array_length(coalesce(h,'[]')) then raise exception 'Não há mais dicas.';end if;update public.rounds set revealed_hints=revealed_hints+1 where id=r.id;return jsonb_build_object('ok',true);end$$;
create or replace function public.end_round(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);update public.rounds set status='finished',ended_at=now() where game_id=g.id and round_number=g.current_round;update public.games set status='finished' where id=g.id;return jsonb_build_object('ok',true);end$$;
create or replace function public.next_round(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);if exists(select 1 from public.rounds where game_id=g.id and round_number=g.current_round+1) then update public.games set current_round=current_round+1,status='lobby' where id=g.id;return jsonb_build_object('ok',true);end if;update public.games set status='finished' where id=g.id;return jsonb_build_object('ok',true);end$$;
create or replace function public.reset_game(p_code text,p_host_token text) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);delete from public.attempts where round_id in(select id from public.rounds where game_id=g.id);delete from public.solves where round_id in(select id from public.rounds where game_id=g.id);update public.rounds set revealed_hints=0,status='queued',started_at=null,ended_at=null,paused_at=null where game_id=g.id;update public.games set status='lobby',current_round=1 where id=g.id;return jsonb_build_object('ok',true);end$$;
create or replace function public.set_room_lock(p_code text,p_host_token text,p_locked boolean) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);update public.games set settings=jsonb_set(settings,'{lock_room}',to_jsonb(p_locked),true) where id=g.id;return jsonb_build_object('ok',true);end$$;
create or replace function public.remove_player(p_code text,p_host_token text,p_player_id uuid) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$declare g public.games;begin g:=public._host(p_code,p_host_token);delete from public.players where id=p_player_id and game_id=g.id;return jsonb_build_object('ok',true);end$$;
revoke all on function public.create_game(jsonb),public.join_game(text,text,text,text),public.get_game_state(text,text,uuid,text),public.submit_guess(text,uuid,text,text),public.start_game(text,text),public.pause_game(text,text),public.resume_game(text,text),public.reveal_hint(text,text),public.end_round(text,text),public.next_round(text,text),public.reset_game(text,text),public.set_room_lock(text,text,boolean),public.remove_player(text,text,uuid) from public;
grant execute on function public.create_game(jsonb),public.join_game(text,text,text,text),public.get_game_state(text,text,uuid,text),public.submit_guess(text,uuid,text,text),public.start_game(text,text),public.pause_game(text,text),public.resume_game(text,text),public.reveal_hint(text,text),public.end_round(text,text),public.next_round(text,text),public.reset_game(text,text),public.set_room_lock(text,text,boolean),public.remove_player(text,text,uuid) to anon,authenticated;

-- Publish safe rows for instant invalidation. Do not add round_answers or credential tables.
do $$ begin alter publication supabase_realtime add table public.games; exception when duplicate_object then null;when undefined_object then null;end$$;
do $$ begin alter publication supabase_realtime add table public.rounds; exception when duplicate_object then null;when undefined_object then null;end$$;
do $$ begin alter publication supabase_realtime add table public.players; exception when duplicate_object then null;when undefined_object then null;end$$;
do $$ begin alter publication supabase_realtime add table public.solves; exception when duplicate_object then null;when undefined_object then null;end$$;
