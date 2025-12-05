## 프로젝트 전체 구조

```
ec-portfolio/
├── apps/
│   └── api/                # 백엔드(Spring Boot, Kotlin)
│       ├── src/
│       ├── build.gradle.kts
│       └── ...
├── store-web/               # 프론트엔드(React, TypeScript, Vite)
│   ├── src/
│   ├── public/
│   ├── package.json
│   └── ...
├── packages/                # 공통 패키지(타입, UI 등)
│   ├── contracts/
│   ├── config/
│   └── ui/
├── package.json             # 루트 워크스페이스 설정
├── README.md
└── ...
```

---

## 깃 클론 후 셋팅 방법

1. **레포지토리 클론**
   ```bash
   git clone git@github.com:nagi4757/ec-portfolio.git
   cd ec-portfolio
   ```

2. **백엔드(API) 셋팅**
  - JDK 17 이상 설치 필요
  - Gradle Wrapper 사용
   ```bash
   cd apps/api
   ./gradlew build
   ```

3. **프론트엔드(store-web) 셋팅**
  - Node.js 18 이상 설치 필요
  - 루트에서 의존성 설치 (모노레포 워크스페이스)
   ```bash
   npm install
   ```

---

## 실행 방법

### 백엔드(API 서버) 실행

```bash
cd apps/api
./gradlew bootRun
```
- 기본 포트: `8080`

### 프론트엔드(store-web) 실행

```bash
cd store-web
npm run dev
```
- 기본 포트: `5173`
- 브라우저에서 `http://localhost:5173` 접속

---

## 기타 참고

- DB 마이그레이션은 Flyway로 자동 적용됨
- 환경 변수 예시는 `.env.example` 참고
- 상세 설정 및 커스텀은 각 모듈의 `README.md` 참고

---