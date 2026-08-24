## EC Portfolio

Kotlin(Spring Boot) + React(TypeScript) 기반 이커머스 포트폴리오 프로젝트입니다.

- 백엔드: `apps/api`
- 어드민 프론트: `apps/admin-web`
- 스토어 프론트: `apps/store-web`

---

## 프로젝트 구조

```
ec-portfolio/
├── apps/
│   ├── api/                  # 백엔드 (Kotlin + Spring Boot)
│   │   └── src/
│   │       └── main/kotlin/  # 소스 코드
│   ├── admin-web/            # 어드민 프론트엔드 (React + TypeScript + Vite)
│   │   └── src/
│   │       ├── features/     # auth / categories / products
│   │       ├── components/   # AdminLayout, PrivateRoute
│   │       └── lib/          # api 클라이언트, authStore
│   └── store-web/            # 스토어 프론트엔드 (React + TypeScript + Vite)
│       └── src/
│           ├── features/     # auth / cart / products
│           └── lib/          # api 클라이언트, authStore
├── packages/
│   ├── contracts/            # 공유 타입/인터페이스
│   ├── ui/                   # 공유 UI 컴포넌트
│   └── config/               # 공유 설정
├── docker-compose.yml        # API + MariaDB + Redis
└── package.json              # 워크스페이스 루트
```

---

## 현재 구현 범위

### 1단계: 인증
- 회원가입/로그인(JWT)
- 내 정보 조회(`me`)

### 2단계: 상품/카테고리 + 어드민 로그인
- 어드민 상품 CRUD
- 어드민 카테고리 CRUD
- 어드민 로그인/라우트 가드

### 3단계: 상품 조회/검색
- 키워드 검색
- 가격 범위 필터
- 정렬(`newest`, `priceAsc`, `priceDesc`, `nameAsc`)
- 페이지네이션

### 4단계: 장바구니(Redis)
- 장바구니 조회/추가/수량변경/삭제/비우기
- 스토어 상품 상세/목록에서 장바구니 담기
- 헤더 장바구니 수량 배지 실시간 반영

### 5단계: 주문
- 장바구니 → 주문하기 (주문 생성 + 장바구니 자동 비우기)
- 내 주문 목록 / 주문 상세 조회
- 어드민 전체 주문 목록 조회 + 주문 상태 변경(드롭다운)
- 어드민 주문 상세 조회(아이템 라인/총액/상태 변경)

---

## 요구사항

| 항목 | 버전 | 용도 |
|------|------|------|
| Java | 21 | 백엔드 로컬 실행 (Docker 사용 시 불필요) |
| MariaDB | 10.11 | Flyway 호환성이 검증된 장기 지원 DB 버전 |
| Node.js | 18+ | 프론트 의존성 설치 및 개발 서버 |
| npm | - | 프론트 패키지 관리 |
| Docker Desktop | 최신 권장 | 백엔드 전체 스택 실행 (API + MariaDB + Redis) |

> **참고:** MyBatis Mapper는 소스에 명시적으로 관리되므로 빌드 시 실행 중인 DB가 필요하지 않습니다.

---

## 시작하기

### 1) 저장소 클론

```zsh
git clone git@github.com:nagi4757/ec-portfolio.git
cd ec-portfolio
```

### 2) 프론트 의존성 설치

```zsh
npm install
```

---

## 백엔드 실행 방식

### 로컬 환경변수 준비

최초 실행 전에 저장소 루트에서 local 개발용 환경 파일을 만듭니다.

```zsh
cp .env.example .env
```

`.env`는 Git에서 제외되며, Docker Compose는 저장소 루트의 `.env`를 자동으로 읽습니다. `.env.example`의 값은 기존 local 개발 환경과 호환되는 placeholder이며 실제 운영 Secret이 아닙니다. 운영 환경에서는 이 값을 절대 사용하지 마세요.

### A. 권장: Docker로 백엔드 스택 실행 (API + MariaDB + Redis)

환경 파일을 준비한 뒤 기본 Compose 파일(`docker-compose.yml`)을 실행합니다.

```zsh
docker compose up -d
```

Compose 환경은 Flyway 호환성을 위해 MariaDB `10.11` 버전으로 고정되어 있습니다.

백엔드 소스 변경 후 API 이미지를 다시 빌드해야 할 때는 다음 명령을 사용합니다.

```zsh
docker compose up -d --build
```

> **MariaDB 볼륨 주의:** MariaDB 11.x에서 생성한 데이터 볼륨을 10.11 컨테이너에 직접 연결하는 인플레이스 다운그레이드는 지원되지 않습니다. 이를 방지하기 위해 Compose는 `mariadb-10-11-data`와 `redis-10-11-data` 볼륨을 새로 사용하며, 기존 `mariadb-data`와 `redis-data` 볼륨은 자동으로 삭제하지 않습니다. Redis도 함께 분리하여 이전 DB 사용자와 캐시 데이터가 섞이지 않게 합니다. 기존 데이터가 필요하면 논리 백업 후 새 10.11 볼륨에 복원하세요. 로컬 테스트 데이터가 불필요한 경우에만 `docker compose down -v`로 현재 볼륨을 초기화하세요. 이 명령은 MariaDB와 Redis 데이터를 모두 삭제합니다.

#### 스키마 변경(Flyway) 반영 방법

`V4__add_orders.sql`처럼 새 마이그레이션 파일을 추가한 경우, **API 컨테이너 재시작 시점**에 Flyway가 자동 적용됩니다.

- 최초 실행: `docker compose up -d`
- 이미 실행 중일 때(권장): API만 재시작

```zsh
cd ec-portfolio
docker compose up -d --build api
```

- 전체 스택 재기동이 필요하면:

```zsh
cd ec-portfolio
docker compose down
docker compose up -d --build
```

> 참고: 일반적인 스키마 추가/변경은 `down -v`가 필요하지 않습니다. `down -v`는 DB 볼륨을 삭제해 데이터를 초기화할 때만 사용하세요.

| 서비스 | 호스트(localhost) | 컨테이너 내부 | 비고 |
|------|---|---|---|
| API | `8081` | `8080` | 브라우저/클라이언트는 `http://localhost:8081`로 접근 |
| MariaDB | `3307` | `3306` | 컨테이너 간 통신은 `mariadb:3306` 사용 |
| Redis | `6380` | `6379` | 컨테이너 간 통신은 `redis:6379` 사용 |

`docker-compose.backend.yml`을 직접 지정하면 기존 기본 Host Port인 API `8080`, MariaDB `3306`, Redis `6379`를 사용합니다. 두 Compose 파일은 같은 `.env`의 DB/JWT 값을 사용하지만 Host Port 의미는 서로 다르게 유지됩니다.

- API: `http://localhost:8081`
- MariaDB: `localhost:3307`
- Redis: `localhost:6380`

로그 확인:

```zsh
cd ec-portfolio
docker compose logs -f api
```

중지:

```zsh
cd ec-portfolio
docker compose down
```

볼륨 포함 초기화:

```zsh
cd ec-portfolio
docker compose down -v
```


### B. 로컬 직접 실행

MariaDB/Redis를 실행하고 저장소 루트의 `.env`를 현재 셸에 로드한 뒤 실행합니다.

- `bootRun`은 기본적으로 `local` Profile을 사용합니다.
- local Profile의 기본 연결 포트는 `DB_PORT=3307`, `REDIS_PORT=6380`입니다.
- Spring Boot와 Gradle은 저장소 루트의 `.env`를 자동으로 읽지 않으므로 셸에 명시적으로 로드해야 합니다.

```zsh
cd ec-portfolio
docker compose up -d mariadb redis

set -a
source .env
set +a

cd apps/api
./gradlew bootRun
```

### C. 트러블슈팅 (주문 기능 추가 후 부팅 실패)

다음과 같은 에러가 보이면:

`No qualifying bean of type 'com.nagi4757.ec.api.order.infra.mapper.OrderMapper' available`

수동 MyBatis Mapper 인터페이스에 `@Mapper`가 붙어 있는지 확인하세요.
(`ApiApplication.kt`는 `@Mapper` 기반 자동 스캔으로 설정되어 있습니다.)

```kotlin
@MapperScan(
    basePackages = ["com.nagi4757.ec.api"],
    annotationClass = Mapper::class
)
```

수정 후 재실행:

```zsh
cd ec-portfolio/apps/api
set -a
source ../../.env
set +a
./gradlew bootRun
```

---

## 프론트 실행

### 어드민

```zsh
cd ec-portfolio/apps/admin-web
npm run dev
```

- URL: `http://localhost:5173`

### 스토어

```zsh
cd ec-portfolio/apps/store-web
npm run dev
```

- URL: `http://localhost:5174`

---

## 주요 API 요약

### 인증
- `POST /api/public/auth/signup`
- `POST /api/public/auth/login`
- `GET /api/public/auth/me`

### 상품(공개)
- `GET /api/public/products`
  - query: `keyword`, `minPrice`, `maxPrice`, `sort`, `page`, `size`
- `GET /api/public/products/{id}`

### 카테고리(공개)
- `GET /api/public/categories`
- `GET /api/public/categories/{id}`

### 어드민
- `GET/POST/PATCH/DELETE /api/admin/products`
- `GET/POST/PATCH/DELETE /api/admin/categories`

### 장바구니(로그인 필요)
- `GET /api/user/cart`
- `POST /api/user/cart/items`
- `PATCH /api/user/cart/items/{productId}`
- `DELETE /api/user/cart/items/{productId}`
- `DELETE /api/user/cart`

### 주문(로그인 필요)
- `POST /api/user/orders` — 장바구니로 주문 생성
- `GET /api/user/orders` — 내 주문 목록
- `GET /api/user/orders/{id}` — 내 주문 상세

### 어드민 주문
- `GET /api/admin/orders` — 전체 주문 목록 (query: `page`, `size`)
- `GET /api/admin/orders/{id}` — 주문 상세
- `PATCH /api/admin/orders/{id}/status` — 주문 상태 변경

### 접근 제어 정책
- `/api/public/**` : 누구나 접근 가능
- `/api/user/**` : 로그인 필요 (`USER` 또는 `ADMIN`)
- `/api/admin/**` : 관리자(`ADMIN`)만 접근 가능
- 인증이 필요한 경로에 토큰 없이 접근하면 `401 Unauthorized`를 반환합니다.

---

## 빠른 점검 커맨드

### 백엔드 테스트

```zsh
cd ec-portfolio/apps/api
./gradlew test
```

주문/보안 회귀 테스트만 빠르게 확인:

```zsh
cd ec-portfolio/apps/api
./gradlew test --tests "com.nagi4757.ec.api.order.application.OrderServiceTest"
./gradlew test --tests "com.nagi4757.ec.api.common.config.SecurityConfigPolicyTest"
```

### 프론트 빌드

```zsh
cd ec-portfolio/apps/admin-web
npm run build

cd ec-portfolio/apps/store-web
npm run build
```

---

## 참고

- DB 마이그레이션은 Flyway로 자동 적용됩니다.
- API Docker 이미지는 multi-stage build로 실행 JAR만 포함하며 non-root 사용자로 실행됩니다.
- 인증 토큰 만료(401) 시 프론트에서 자동 로그아웃 처리합니다.

### 백엔드 레이어 일관성 체크리스트

신규 도메인(`order`, `coupon` 등) 추가 시 아래 순서로 맞추면 구조가 일관됩니다.

- `domain/model`: 핵심 엔티티/값 객체 정의
- `domain/repository`: 도메인 기준 저장소 인터페이스 정의
- `domain/factory`: `record <-> domain` 변환 로직 분리
- `infra`: MyBatis/Redis 등 인프라 구현체 (`*Repository`) 작성
- `application`: 유스케이스 단위 서비스 작성
- `presentation`: user/admin/public 컨트롤러 + DTO 분리
- 수동 MyBatis Mapper는 `@Mapper`를 붙이면 자동 스캔됨 (`ApiApplication.kt`에서 설정)

간단 점검 커맨드:

```zsh
cd ec-portfolio/apps/api
set -a
source ../../.env
set +a
./gradlew compileKotlin --no-daemon
./gradlew bootRun --no-daemon
```
