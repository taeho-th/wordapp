-- 게임 요소 (기획서 4-6절): 경험치·레벨, 외운 단어, 연속 공부, 배지, 반 목표, 도전 모드, 강아지 꾸미기

alter table public.vocab_students
  add column xp int not null default 0 check (xp >= 0),
  add column equipped text[] not null default '{}',
  add column best_combo int not null default 0,
  add column best_heart int not null default 0,
  add column best_time int not null default 0;

alter table public.vocab_word_stats
  add column streak int not null default 0 check (streak >= 0);   -- 연속으로 맞힌 횟수. 3 이상이면 '외운 단어'

alter table public.vocab_attempts
  add column mode text not null default 'quiz' check (mode in ('quiz','heart','time','match')),
  add column correct_count int not null default 0,
  add column best_combo int not null default 0,
  add column xp int not null default 0;

alter table public.vocab_attempt_answers drop constraint vocab_attempt_answers_qtype_check;
alter table public.vocab_attempt_answers add constraint vocab_attempt_answers_qtype_check
  check (qtype in ('en2ko','ko2en','spell','listen','match'));

alter table public.vocab_settings add column weekly_goal int not null default 300 check (weekly_goal between 10 and 100000);

create table public.vocab_badges (
  student_id uuid not null references public.vocab_students on delete cascade,
  badge text not null,
  earned_at timestamptz not null default now(),
  primary key (student_id, badge)
);
alter table public.vocab_badges enable row level security;
create policy "self or teacher reads badges" on public.vocab_badges for select to authenticated
  using (student_id = public.vocab_my_student() or public.vocab_is_teacher());
comment on table public.vocab_badges is '학생별 받은 배지. vocab_save_attempt 만 씀';

-- 레벨: 다음 레벨까지 필요한 경험치 = 50 × 레벨 + 50 (Lv.1→2: 100, Lv.5→6: 300)
create function public.vocab_level(p_xp int)
returns table (level int, into_level int, need int)
language plpgsql immutable set search_path = public as $$
declare l int := 1; rest int := greatest(coalesce(p_xp, 0), 0); n int;
begin
  loop
    n := 50 * l + 50;
    exit when rest < n;
    rest := rest - n; l := l + 1;
  end loop;
  return query select l, rest, n;
end $$;

-- 꾸미기 아이템: 이름, 부위, 열리는 레벨
create function public.vocab_items()
returns table (item text, slot text, unlock_level int)
language sql immutable set search_path = public as $$
  values ('ribbon','head',1), ('hat','head',3), ('glasses','face',5), ('scarf','neck',7), ('flower','head',10), ('crown','head',15)
$$;

-- 연속 공부일: 오늘(또는 어제)부터 거꾸로 하루도 빠짐없이 퀴즈를 푼 날 수 (한국 시간)
create function public.vocab_streak_days(p_student uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'Asia/Seoul')::date; n int := 0;
begin
  if not exists (select 1 from public.vocab_attempts where student_id = p_student and (created_at at time zone 'Asia/Seoul')::date = d) then
    d := d - 1;
  end if;
  while exists (select 1 from public.vocab_attempts where student_id = p_student and (created_at at time zone 'Asia/Seoul')::date = d) loop
    n := n + 1; d := d - 1;
  end loop;
  return n;
end $$;

-- 오답노트 기록 + 연속 정답(외운 단어) 기록
create or replace function public.vocab_mark(p_word uuid, p_known boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_student uuid := public.vocab_my_student();
begin
  if v_student is null then raise exception 'not_student'; end if;
  insert into public.vocab_word_stats (student_id, word_id, wrong, correct, streak)
  values (v_student, p_word, case when p_known then 0 else 1 end, case when p_known then 1 else 0 end, case when p_known then 1 else 0 end)
  on conflict (student_id, word_id) do update set
    wrong = greatest(0, public.vocab_word_stats.wrong + case when p_known then -1 else 1 end),
    correct = public.vocab_word_stats.correct + case when p_known then 1 else 0 end,
    streak = case when p_known then public.vocab_word_stats.streak + 1 else 0 end,
    updated_at = now();
end $$;

-- 배지 확인: 새로 받은 배지 코드를 돌려줌
create function public.vocab_award_badges(p_student uuid) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  s public.vocab_students;
  v_streak int := public.vocab_streak_days(p_student);
  v_learned int;
  v_new text[] := '{}';
  b text;
begin
  select * into s from public.vocab_students where id = p_student;
  select count(*) into v_learned from public.vocab_word_stats where student_id = p_student and streak >= 3;
  for b in
    select x.code from (values
      ('first_quiz', exists (select 1 from public.vocab_attempts where student_id = p_student)),
      ('score90',   exists (select 1 from public.vocab_attempts where student_id = p_student and mode = 'quiz' and score >= 90)),
      ('perfect',   exists (select 1 from public.vocab_attempts where student_id = p_student and mode = 'quiz' and score = 100 and total >= 10)),
      ('combo10',   s.best_combo >= 10),
      ('streak3',   v_streak >= 3),
      ('streak7',   v_streak >= 7),
      ('learned10', v_learned >= 10),
      ('learned50', v_learned >= 50),
      ('heart20',   s.best_heart >= 20),
      ('time15',    s.best_time >= 15),
      ('match_clear', exists (select 1 from public.vocab_attempts where student_id = p_student and mode = 'match'))
    ) as x(code, ok)
    where x.ok and not exists (select 1 from public.vocab_badges where student_id = p_student and badge = x.code)
  loop
    insert into public.vocab_badges (student_id, badge) values (p_student, b);
    v_new := v_new || b;
  end loop;
  return v_new;
end $$;

-- 풀이 저장 (모드 추가). 경험치·콤보·점수는 서버가 계산
-- 경험치: 정답 10, 3콤보 이상인 정답은 +5, 10문제 이상 만점 +20, 짝맞추기는 짝 하나에 5
drop function public.vocab_save_attempt(jsonb);
create function public.vocab_save_attempt(p_answers jsonb, p_mode text default 'quiz') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := public.vocab_my_student();
  s public.vocab_students;
  v_total int; v_ok int; v_score int; v_attempt uuid;
  v_combo int := 0; v_best int := 0; v_xp int := 0; a jsonb;
  v_lv_before int; v_lv_after int; v_badges text[]; v_items text[];
begin
  if v_student is null then raise exception 'not_student'; end if;
  if p_mode not in ('quiz','heart','time','match') then raise exception 'bad_mode'; end if;
  select count(*), count(*) filter (where (x->>'is_correct')::boolean) into v_total, v_ok from jsonb_array_elements(p_answers) x;
  if v_total = 0 then raise exception 'empty'; end if;
  v_score := round(100.0 * v_ok / v_total);

  for a in select * from jsonb_array_elements(p_answers) loop
    if (a->>'is_correct')::boolean then
      v_combo := v_combo + 1; v_best := greatest(v_best, v_combo);
      v_xp := v_xp + case when p_mode = 'match' then 5 when v_combo >= 3 then 15 else 10 end;
    else
      v_combo := 0;
    end if;
  end loop;
  if p_mode = 'match' then v_best := 0; end if;
  if p_mode = 'quiz' and v_score = 100 and v_total >= 10 then v_xp := v_xp + 20; end if;

  select * into s from public.vocab_students where id = v_student for update;
  select level into v_lv_before from public.vocab_level(s.xp);

  insert into public.vocab_attempts (student_id, total, score, mode, correct_count, best_combo, xp)
  values (v_student, v_total, v_score, p_mode, v_ok, v_best, v_xp) returning id into v_attempt;
  insert into public.vocab_attempt_answers (attempt_id, word_id, qtype, is_correct, answer)
  select v_attempt, w.id, x->>'qtype', (x->>'is_correct')::boolean, left(coalesce(x->>'answer', ''), 200)
  from jsonb_array_elements(p_answers) x left join public.vocab_words w on w.id = (x->>'word_id')::uuid;

  update public.vocab_students set
    xp = xp + v_xp,
    best_combo = greatest(best_combo, v_best),
    best_heart = case when p_mode = 'heart' then greatest(best_heart, v_ok) else best_heart end,
    best_time  = case when p_mode = 'time'  then greatest(best_time,  v_ok) else best_time  end
  where id = v_student;

  select level into v_lv_after from public.vocab_level(s.xp + v_xp);
  select coalesce(array_agg(item order by unlock_level), '{}') into v_items
    from public.vocab_items() where unlock_level > v_lv_before and unlock_level <= v_lv_after;
  v_badges := public.vocab_award_badges(v_student);

  return jsonb_build_object(
    'attempt_id', v_attempt, 'mode', p_mode, 'total', v_total, 'correct', v_ok, 'score', v_score,
    'best_combo', v_best, 'xp_gained', v_xp, 'level_before', v_lv_before, 'level_after', v_lv_after,
    'new_items', to_jsonb(v_items), 'new_badges', to_jsonb(v_badges),
    'best_heart', (select best_heart from public.vocab_students where id = v_student),
    'best_time',  (select best_time  from public.vocab_students where id = v_student));
end $$;

-- 내 진행 상황 한 번에: 레벨, 연속 공부, 외운 단어, 배지, 꾸미기, 반 목표
create function public.vocab_my_progress() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_student uuid := public.vocab_my_student();
  s public.vocab_students; lv record;
  v_week timestamp := date_trunc('week', now() at time zone 'Asia/Seoul');
  v_goal int; v_total int; v_mine int;
begin
  if v_student is null then raise exception 'not_student'; end if;
  select * into s from public.vocab_students where id = v_student;
  select * into lv from public.vocab_level(s.xp);
  select weekly_goal into v_goal from public.vocab_settings where id = 1;
  select count(*) filter (where x.is_correct), count(*) filter (where x.is_correct and t.student_id = v_student)
    into v_total, v_mine
    from public.vocab_attempt_answers x join public.vocab_attempts t on t.id = x.attempt_id
    where (t.created_at at time zone 'Asia/Seoul') >= v_week;
  return jsonb_build_object(
    'xp', s.xp, 'level', lv.level, 'into_level', lv.into_level, 'need', lv.need,
    'streak_days', public.vocab_streak_days(v_student),
    'learned', (select count(*) from public.vocab_word_stats where student_id = v_student and streak >= 3),
    'badges', coalesce((select jsonb_agg(badge order by earned_at) from public.vocab_badges where student_id = v_student), '[]'),
    'equipped', to_jsonb(s.equipped),
    'best_combo', s.best_combo, 'best_heart', s.best_heart, 'best_time', s.best_time,
    'goal', jsonb_build_object('target', v_goal, 'total', v_total, 'mine', v_mine,
      'days_left', 7 - extract(isodow from now() at time zone 'Asia/Seoul')::int));
end $$;

-- 꾸미기 저장: 열린 아이템만, 부위마다 하나씩
create function public.vocab_equip(p_items text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := public.vocab_my_student();
  v_level int; v_bad int; v_dup int;
begin
  if v_student is null then raise exception 'not_student'; end if;
  select level into v_level from public.vocab_level((select xp from public.vocab_students where id = v_student));
  select count(*) into v_bad from unnest(coalesce(p_items, '{}')) u(item)
    left join public.vocab_items() i on i.item = u.item where i.item is null or i.unlock_level > v_level;
  if v_bad > 0 then raise exception 'item_locked'; end if;
  select count(*) - count(distinct i.slot) into v_dup from unnest(coalesce(p_items, '{}')) u(item) join public.vocab_items() i on i.item = u.item;
  if v_dup > 0 then raise exception 'one_per_slot'; end if;
  update public.vocab_students set equipped = coalesce(p_items, '{}') where id = v_student;
  return coalesce(p_items, '{}');
end $$;

-- 선생님 화면: 점수는 일반 퀴즈만, 레벨 추가
drop function public.vocab_teacher_students();
create function public.vocab_teacher_students()
returns table (student_id uuid, number int, name text, recent_score int, avg_score numeric, attempts bigint, last_at timestamptz, level int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.vocab_is_teacher() then raise exception 'not_teacher'; end if;
  return query
  select s.id, s.number, s.name,
    (select a.score from public.vocab_attempts a where a.student_id = s.id and a.mode = 'quiz' order by a.created_at desc limit 1),
    (select round(avg(a.score), 1) from public.vocab_attempts a where a.student_id = s.id and a.mode = 'quiz'),
    (select count(*) from public.vocab_attempts a where a.student_id = s.id),
    (select max(a.created_at) from public.vocab_attempts a where a.student_id = s.id),
    (select l.level from public.vocab_level(s.xp) l)
  from public.vocab_students s order by s.number;
end $$;

-- 많이 틀린 단어: 짝맞추기는 빼고 퀴즈 문항만
create or replace function public.vocab_teacher_hard_words()
returns table (word_id uuid, en text, ko text, asked bigint, wrong bigint, wrong_rate numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.vocab_is_teacher() then raise exception 'not_teacher'; end if;
  return query
  select w.id, w.en, w.ko, count(*), count(*) filter (where not x.is_correct),
    round(100.0 * count(*) filter (where not x.is_correct) / count(*), 1)
  from public.vocab_attempt_answers x join public.vocab_words w on w.id = x.word_id
  where x.qtype <> 'match'
  group by w.id, w.en, w.ko
  having count(*) filter (where not x.is_correct) > 0
  order by 6 desc, 5 desc, w.en;
end $$;

-- 실행 권한: 로그인한 사람만 (내부용 함수는 브라우저에서 못 부름)
revoke execute on function public.vocab_level(int), public.vocab_items(), public.vocab_streak_days(uuid), public.vocab_award_badges(uuid),
  public.vocab_save_attempt(jsonb, text), public.vocab_my_progress(), public.vocab_equip(text[]), public.vocab_teacher_students() from public, anon;
revoke execute on function public.vocab_streak_days(uuid), public.vocab_award_badges(uuid) from authenticated;
grant execute on function public.vocab_level(int), public.vocab_items(), public.vocab_save_attempt(jsonb, text), public.vocab_my_progress(),
  public.vocab_equip(text[]), public.vocab_teacher_students() to authenticated;
