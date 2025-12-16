## 프로젝트 전체 구조

```
ec-portfolio/
├── apps/
│   ├── api/                # 백엔드(Spring Boot, Kotlin)
│   │   ├── build.gradle.kts
│   │   ├── gradlew
│   │   ├── src/
│   │   │   ├── main/
│   │   │   │   ├── kotlin/
│   │   │   │   └── resources/
│   │   │   │       ├── application.properties
│   │   │   │       ├── db/
│   │   │   │       ├── mbg/
│   │   │   │       ├── mapper/
│   │   │   │       ├── static/
│   │   │   │       └── templates/
│   │   │   └── test/
│   ├── admin-web/          # 어드민 프론트엔드(React, TypeScript, Vite)
│   │   ├── package.json
│   │   ├── public/
│   │   └── src/
│   │       ├── features/
│   │       ├── lib/
│   │       └── types/
│   └── store-web/          # 스토어 프론트엔드(React, TypeScript, Vite)
│       ├── package.json
│       ├── public/
│       └── src/
│           ├── features/
│           ├── lib/
│           └── types/
├── packages/               # 공통 패키지(타입, UI 등)
│   ├── config/
│   ├── contracts/
│   │   └── src/
│   └── ui/
│       └── src/
├── package.json            # 루트 워크스페이스 설정
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
   - JDK 17 이상 필요
   - Gradle Wrapper 사용
   ```bash
   cd apps/api
   ./gradlew build
   ```

3. **프론트엔드 셋팅**
   - Node.js 18 이상 필요
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

### 어드민 프론트엔드 실행

```bash
cd apps/admin-web
npm run dev
```
- 기본 포트: `5173`
- 브라우저에서 `http://localhost:5173` 접속

### 스토어 프론트엔드 실행

```bash
cd apps/store-web
npm run dev
```
- 기본 포트: `5174`
- 브라우저에서 `http://localhost:5174` 접속

---

## 마이바티스 제네레이터(MBG) 설정 및 실행

1. **설정 파일 위치**
   - `apps/api/src/main/resources/mbg/generatorConfig.xml` 등에서 관리

2. **Gradle 플러그인 및 설정**
   - `apps/api/build.gradle.kts`에 아래와 같이 추가
   ```kotlin
   plugins {
       id("com.thinkimi.gradle.MybatisGenerator") version "2.4"
   }

   mybatisGenerator {
       configFile = "$projectDir/src/main/resources/mbg/generatorConfig.xml"
   }
   ```

3. **제네레이터 실행**
   ```bash
   ./gradlew mybatisGenerator
   ```
   - 실행 후, `build/generated/mbg/java` 및 `build/generated/mbg/resources/mapper` 등에 코드가 생성됨

4. **DB 접속 정보 등은 `generatorConfig.xml` 또는 `application.properties`에서 관리**

---

## 기타 참고

- DB 마이그레이션은 Flyway로 자동 적용됨
- 환경 변수 예시는 `.env.example` 참고
- 상세 설정 및 커스텀은 각 모듈의 `README.md` 참고

---