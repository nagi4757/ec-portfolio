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
- 스토어 상품 상세에서 장바구니 담기

---

## 요구사항

| 항목 | 버전 | 용도 |
|------|------|------|
| Java | 21 | 백엔드 로컬 실행 (Docker 사용 시 불필요) |
| Node.js | 18+ | 프론트 의존성 설치 및 개발 서버 |
| npm | - | 프론트 패키지 관리 |
| Docker Desktop | 최신 권장 | 백엔드 전체 스택 실행 (API + MariaDB + Redis) |

> **참고:** MyBatis Generator는 `./gradlew bootRun` 또는 Docker 빌드 시 자동으로 실행됩니다. 별도 설치나 수동 실행이 필요하지 않습니다.

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

### A. 권장: Docker로 백엔드 스택 실행 (API + MariaDB + Redis)

기본 Compose 파일(`docker-compose.yml`)로 설정되어 있어 아래처럼 바로 실행하면 됩니다.

```zsh
cd ec-portfolio
docker compose up -d --build
```

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

MariaDB/Redis를 실행한 뒤 바로 실행합니다.

- 현재 Gradle 설정상 `./gradlew bootRun` 기본값은 `DB_PORT=3307`, `REDIS_PORT=6380`입니다.
- 즉, Docker 스택(`docker compose up`)을 켠 상태라면 별도 환경변수 없이 실행 가능합니다.

```zsh
cd ec-portfolio/apps/api
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

### 어드민
- `GET/POST/PATCH/DELETE /api/admin/products`
- `GET/POST/PATCH/DELETE /api/admin/categories`

### 장바구니(로그인 필요)
- `GET /api/user/cart`
- `POST /api/user/cart/items`
- `PATCH /api/user/cart/items/{productId}`
- `DELETE /api/user/cart/items/{productId}`
- `DELETE /api/user/cart`

---

## 빠른 점검 커맨드

### 백엔드 테스트

```zsh
cd ec-portfolio/apps/api
./gradlew test
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
- MyBatis Generator는 `apps/api/build/generated/mbg` 아래에 생성됩니다.
- 인증 토큰 만료(401) 시 프론트에서 자동 로그아웃 처리합니다.

