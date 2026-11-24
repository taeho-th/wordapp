-- 단어앱 (기획서.md 7장). 예전 퀴즈 테이블과 겹치지 않게 모두 vocab_ 로 시작
create table public.vocab_settings (
  id int primary key default 1 check (id = 1),
  class_code text not null,
  updated_at timestamptz not null default now()
);
comment on table public.vocab_settings is '반 코드 (한 줄). 선생님만 읽고 씀, 학생은 vocab_join 으로만 확인';

create table public.vocab_teachers (
  user_id uuid primary key references auth.users on delete cascade
);
comment on table public.vocab_teachers is '선생님 계정 목록. 대시보드에서 직접 등록';

create table public.vocab_words (
  id uuid primary key default gen_random_uuid(),
  en text not null check (length(trim(en)) > 0),
  ko text not null check (length(trim(ko)) > 0),
  ex text not null default '',
  created_at timestamptz not null default now()
);
comment on table public.vocab_words is '단어장. 로그인한 사람은 읽기, 선생님만 쓰기';

create table public.vocab_students (
  id uuid primary key default gen_random_uuid(),
  number int not null unique check (number between 1 and 99),
  name text not null check (length(trim(name)) > 0),
  created_at timestamptz not null default now()
);
comment on table public.vocab_students is '학생. 번호 기준 하나 (Q17, Q18)';

create table public.vocab_student_devices (
  auth_uid uuid primary key references auth.users on delete cascade,
  student_id uuid not null references public.vocab_students on delete cascade,
  created_at timestamptz not null default now()
);
comment on table public.vocab_student_devices is '익명 로그인 기기 ↔ 학생 연결. vocab_join 만 씀';

create table public.vocab_word_stats (
  student_id uuid not null references public.vocab_students on delete cascade,
  word_id uuid not null references public.vocab_words on delete cascade,
  wrong int not null default 0 check (wrong >= 0),
  correct int not null default 0 check (correct >= 0),
  updated_at timestamptz not null default now(),
  primary key (student_id, word_id)
);
comment on table public.vocab_word_stats is '학생별 오답노트. vocab_mark 만 씀 (Q27)';

create table public.vocab_attempts (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.vocab_students on delete cascade,
  total int not null check (total > 0),
  score int not null check (score between 0 and 100),
  created_at timestamptz not null default now()
);
create index on public.vocab_attempts (student_id, created_at desc);
comment on table public.vocab_attempts is '퀴즈 풀이 회차. vocab_save_attempt 만 씀';

create table public.vocab_attempt_answers (
  id bigint generated always as identity primary key,
  attempt_id uuid not null references public.vocab_attempts on delete cascade,
  word_id uuid references public.vocab_words on delete set null,
  qtype text not null check (qtype in ('en2ko','ko2en','spell','listen')),
  is_correct boolean not null,
  answer text not null default ''
);
create index on public.vocab_attempt_answers (attempt_id);
create index on public.vocab_attempt_answers (word_id);
comment on table public.vocab_attempt_answers is '문항별 결과. 많이 틀린 단어 순위에 씀 (Q26)';

-- 도우미 함수
create function public.vocab_is_teacher() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.vocab_teachers where user_id = auth.uid());
$$;

create function public.vocab_my_student() returns uuid
language sql stable security definer set search_path = public as $$
  select student_id from public.vocab_student_devices where auth_uid = auth.uid();
$$;

-- RLS
alter table public.vocab_settings enable row level security;
alter table public.vocab_teachers enable row level security;
alter table public.vocab_words enable row level security;
alter table public.vocab_students enable row level security;
alter table public.vocab_student_devices enable row level security;
alter table public.vocab_word_stats enable row level security;
alter table public.vocab_attempts enable row level security;
alter table public.vocab_attempt_answers enable row level security;

create policy "teacher reads settings" on public.vocab_settings for select to authenticated using (public.vocab_is_teacher());
create policy "teacher updates settings" on public.vocab_settings for update to authenticated using (public.vocab_is_teacher()) with check (public.vocab_is_teacher());

create policy "read own teacher row" on public.vocab_teachers for select to authenticated using (user_id = auth.uid());

create policy "signed-in reads words" on public.vocab_words for select to authenticated using (true);
create policy "teacher inserts words" on public.vocab_words for insert to authenticated with check (public.vocab_is_teacher());
create policy "teacher updates words" on public.vocab_words for update to authenticated using (public.vocab_is_teacher()) with check (public.vocab_is_teacher());
create policy "teacher deletes words" on public.vocab_words for delete to authenticated using (public.vocab_is_teacher());

create policy "self or teacher reads student" on public.vocab_students for select to authenticated using (id = public.vocab_my_student() or public.vocab_is_teacher());
create policy "teacher renames student" on public.vocab_students for update to authenticated using (public.vocab_is_teacher()) with check (public.vocab_is_teacher());

create policy "read own device" on public.vocab_student_devices for select to authenticated using (auth_uid = auth.uid());

create policy "self or teacher reads stats" on public.vocab_word_stats for select to authenticated using (student_id = public.vocab_my_student() or public.vocab_is_teacher());

create policy "self or teacher reads attempts" on public.vocab_attempts for select to authenticated using (student_id = public.vocab_my_student() or public.vocab_is_teacher());

create policy "self or teacher reads answers" on public.vocab_attempt_answers for select to authenticated using (
  public.vocab_is_teacher() or exists (select 1 from public.vocab_attempts a where a.id = attempt_id and a.student_id = public.vocab_my_student())
);

-- 학생 입장 (Q18, Q22, Q23)
create function public.vocab_join(p_code text, p_number int, p_name text, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_student public.vocab_students;
  v_name text := trim(p_name);
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if p_number is null or p_number not between 1 and 99 then raise exception 'bad_number'; end if;
  if v_name is null or v_name = '' then raise exception 'bad_name'; end if;
  select class_code into v_code from public.vocab_settings where id = 1;
  if v_code is null or lower(trim(p_code)) <> lower(trim(v_code)) then raise exception 'invalid_code'; end if;

  select * into v_student from public.vocab_students where number = p_number;
  if not found then
    insert into public.vocab_students (number, name) values (p_number, v_name) returning * into v_student;
  elsif v_student.name <> v_name and not p_confirm then
    return jsonb_build_object('status', 'confirm', 'number', v_student.number, 'name', v_student.name);
  end if;

  insert into public.vocab_student_devices (auth_uid, student_id) values (auth.uid(), v_student.id)
  on conflict (auth_uid) do update set student_id = excluded.student_id, created_at = now();

  return jsonb_build_object('status', 'ok', 'number', v_student.number, 'name', v_student.name);
end $$;

create function public.vocab_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('number', s.number, 'name', s.name)
  from public.vocab_students s where s.id = public.vocab_my_student();
$$;

create function public.vocab_leave() returns void
language sql security definer set search_path = public as $$
  delete from public.vocab_student_devices where auth_uid = auth.uid();
$$;

-- 오답노트 기록 (Q27): 알면 wrong -1, 모르면 +1
create function public.vocab_mark(p_word uuid, p_known boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_student uuid := public.vocab_my_student();
begin
  if v_student is null then raise exception 'not_student'; end if;
  insert into public.vocab_word_stats (student_id, word_id, wrong, correct)
  values (v_student, p_word, case when p_known then 0 else 1 end, case when p_known then 1 else 0 end)
  on conflict (student_id, word_id) do update set
    wrong = greatest(0, public.vocab_word_stats.wrong + case when p_known then -1 else 1 end),
    correct = public.vocab_word_stats.correct + case when p_known then 1 else 0 end,
    updated_at = now();
end $$;

-- 풀이 저장: p_answers = [{word_id, qtype, is_correct, answer}]. 점수는 서버가 계산
create function public.vocab_save_attempt(p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_student uuid := public.vocab_my_student();
  v_total int; v_ok int; v_attempt uuid;
begin
  if v_student is null then raise exception 'not_student'; end if;
  select count(*), count(*) filter (where (a->>'is_correct')::boolean)
    into v_total, v_ok from jsonb_array_elements(p_answers) a;
  if v_total = 0 then raise exception 'empty'; end if;
  insert into public.vocab_attempts (student_id, total, score)
  values (v_student, v_total, round(100.0 * v_ok / v_total)) returning id into v_attempt;
  insert into public.vocab_attempt_answers (attempt_id, word_id, qtype, is_correct, answer)
  select v_attempt, w.id, a->>'qtype', (a->>'is_correct')::boolean, left(coalesce(a->>'answer', ''), 200)
  from jsonb_array_elements(p_answers) a
  left join public.vocab_words w on w.id = (a->>'word_id')::uuid;
  return jsonb_build_object('attempt_id', v_attempt, 'total', v_total, 'score', round(100.0 * v_ok / v_total));
end $$;

-- 선생님: 학생별 점수 (Q25)
create function public.vocab_teacher_students()
returns table (student_id uuid, number int, name text, recent_score int, avg_score numeric, attempts bigint, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.vocab_is_teacher() then raise exception 'not_teacher'; end if;
  return query
  select s.id, s.number, s.name,
    (select a.score from public.vocab_attempts a where a.student_id = s.id order by a.created_at desc limit 1),
    (select round(avg(a.score), 1) from public.vocab_attempts a where a.student_id = s.id),
    (select count(*) from public.vocab_attempts a where a.student_id = s.id),
    (select max(a.created_at) from public.vocab_attempts a where a.student_id = s.id)
  from public.vocab_students s order by s.number;
end $$;

-- 선생님: 많이 틀린 단어 (Q26) — 퀴즈 결과만, 오답률 순
create function public.vocab_teacher_hard_words()
returns table (word_id uuid, en text, ko text, asked bigint, wrong bigint, wrong_rate numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.vocab_is_teacher() then raise exception 'not_teacher'; end if;
  return query
  select w.id, w.en, w.ko, count(*), count(*) filter (where not x.is_correct),
    round(100.0 * count(*) filter (where not x.is_correct) / count(*), 1)
  from public.vocab_attempt_answers x join public.vocab_words w on w.id = x.word_id
  group by w.id, w.en, w.ko
  having count(*) filter (where not x.is_correct) > 0
  order by 6 desc, 5 desc, w.en;
end $$;

-- 함수 실행 권한: 로그인한 사람만
revoke execute on function public.vocab_is_teacher(), public.vocab_my_student(), public.vocab_join(text,int,text,boolean),
  public.vocab_me(), public.vocab_leave(), public.vocab_mark(uuid,boolean), public.vocab_save_attempt(jsonb),
  public.vocab_teacher_students(), public.vocab_teacher_hard_words() from public, anon;
grant execute on function public.vocab_is_teacher(), public.vocab_my_student(), public.vocab_join(text,int,text,boolean),
  public.vocab_me(), public.vocab_leave(), public.vocab_mark(uuid,boolean), public.vocab_save_attempt(jsonb),
  public.vocab_teacher_students(), public.vocab_teacher_hard_words() to authenticated;

-- 처음 반 코드 (선생님 화면에서 바꿈)
insert into public.vocab_settings (class_code) values ('english1');
