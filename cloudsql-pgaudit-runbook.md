# Cloud SQL (PostgreSQL) 감사 로그 활성화 런북

> 목적: 개발자 읽기 전용 계정(`alice`, `bob` 등)의 **조회 행위만** 감사 로그로 남긴다.
> ⚠️ **STEP 1은 인스턴스 재시작(짧은 다운타임)을 유발한다. 트래픽 적은 시간에 실행할 것.**

## 치환할 값
- `INSTANCE`            : Cloud SQL 인스턴스 이름
- `PROJECT_ID`          : GCP 프로젝트 ID
- `velvetalk`           : 대상 데이터베이스
- `alice`, `bob`        : 감사 대상 개발자 롤 (실제 이름으로)
- `velvetalk_app`       : 앱 유저 (감사 켤지는 선택)

---

## STEP 0. 기존 플래그 백업 (필수)

`--database-flags`는 기존 플래그를 **전부 덮어쓴다.** 먼저 현재 값을 확인해 그대로 포함시킨다.

```bash
gcloud sql instances describe INSTANCE \
  --format="value(settings.databaseFlags)"
```

→ 출력에 이미 플래그가 있으면 STEP 1 명령의 `--database-flags`에 **모두 함께** 나열할 것.

---

## STEP 1. 인스턴스 플래그 활성화 (⚠️ 재시작 발생)

```bash
gcloud sql instances patch INSTANCE \
  --database-flags=cloudsql.enable_pgaudit=on,log_connections=on,log_disconnections=on
```

- `cloudsql.enable_pgaudit=on` : pgAudit 확장 사용 가능 (재시작 필요)
- `log_connections=on`         : 접속 기록 (누가/언제/어디서)
- `log_disconnections=on`      : 접속 종료 기록

> STEP 0에서 기존 플래그가 있었다면 위 3개 뒤에 콤마로 이어서 모두 포함.
> 예: `--database-flags=max_connections=200,cloudsql.enable_pgaudit=on,log_connections=on,log_disconnections=on`

재시작 완료 확인:
```bash
gcloud sql instances describe INSTANCE --format="value(state)"   # RUNNABLE 이면 완료
```

---

## STEP 2. 확장 설치 (Cloud SQL Studio, DB=velvetalk 접속 후)

```sql
CREATE EXTENSION IF NOT EXISTS pgaudit;
```

---

## STEP 3. 유저별 감사 설정 (감사 대상에만)

```sql
-- 읽기 전용 개발자: SELECT / COPY 읽기 추적
ALTER ROLE alice SET pgaudit.log = 'read';
ALTER ROLE bob   SET pgaudit.log = 'read';

-- (선택) 쿼리 파라미터 값까지 기록 — 디테일↑, 단 민감정보 노출 주의
-- ALTER ROLE alice SET pgaudit.log_parameter = 'on';

-- (선택) 앱 유저까지 감사 — 쓰기/DDL 포함, 로그 양 많음
-- ALTER ROLE velvetalk_app SET pgaudit.log = 'write,ddl';
```

`pgaudit.log` 분류값: `read`(SELECT) / `write`(INSERT·UPDATE·DELETE) / `ddl` / `role` / `all`
→ 읽기 전용 감사 목적이면 `read` 로 충분.

> 이 설정은 해당 유저의 **다음 새 접속부터** 적용됨(기존 세션 미적용). 대상 유저 재접속 필요.

---

## STEP 4. 검증

```sql
-- alice 로 재접속 후 아무 SELECT 실행
SELECT * FROM <테이블> LIMIT 1;
```

몇 초 뒤 Cloud Logging에서 확인:
```bash
gcloud logging read \
  'resource.type="cloudsql_database" AND textPayload:"AUDIT"' \
  --limit=20 --format='value(timestamp, textPayload)'
```

콘솔 Logs Explorer 필터:
```
resource.type="cloudsql_database"
resource.labels.database_id="PROJECT_ID:INSTANCE"
textPayload:"SESSION"
```

→ alice 의 SELECT 문장이 AUDIT 항목으로 찍히면 정상.

---

## 롤백 / 비활성화

특정 유저 감사만 끄기 (재시작 불필요):
```sql
ALTER ROLE alice RESET pgaudit.log;
```

pgAudit 자체를 끄기 (⚠️ 재시작 발생, 기존 플래그 함께 유지):
```bash
gcloud sql instances patch INSTANCE \
  --database-flags=cloudsql.enable_pgaudit=off,log_connections=on,log_disconnections=on
# 그 후 필요시: DROP EXTENSION pgaudit;
```

---

## 실행 순서 요약

```
STEP 0  기존 플래그 백업
STEP 1  플래그 patch  ← ⚠️ 재시작(다운타임)
STEP 2  CREATE EXTENSION pgaudit   (DB=velvetalk)
STEP 3  ALTER ROLE <개발자> SET pgaudit.log='read'
STEP 4  재접속 후 SELECT → Cloud Logging 확인
```
