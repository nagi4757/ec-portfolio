## 전체 구조

- `apps/api/`  
  EC 사이트의 API 서버 모듈입니다. Spring Boot 애플리케이션으로 동작합니다.

### 주요 디렉터리

- `src/main/kotlin/com/nagi4757/ec/api/`  
  API 관련 비즈니스 로직, 컨트롤러, 서비스, DTO 등이 위치합니다.

- `src/main/resources/`  
  설정 파일(`application.properties`), DB 마이그레이션 SQL, MyBatis 매퍼 XML, 정적 리소스, 템플릿 등이 포함됩니다.

- `build.gradle.kts`, `settings.gradle.kts`  
  Gradle 빌드 및 프로젝트 설정 파일입니다.

### DB 및 마이그레이션

- `src/main/resources/db/migration/`  
  Flyway 기반의 DB 마이그레이션 SQL 파일(`V1__init.sql`, `V2__add_categories.sql`)이 위치합니다.

### MyBatis 관련

- `src/main/resources/mapper/mbg/`  
  MyBatis 매퍼 XML 파일(`CategoryMapper.xml`, `ProductMapper.xml`)이 위치합니다.

- `src/main/resources/mbg/generatorConfig.xml`  
  MyBatis Generator 설정 파일입니다.

### 패키지 구조 예시

- `product/domain/repository/ProductRepository`  
  도메인 레이어의 인터페이스(비즈니스 로직에서 사용).

- `product/infrastructure/repository/mybatis/MyBatisProductRepository`  
  MyBatis 기반의 구현체(인프라스트럭처 레이어).

---

## 장점

- 도메인과 인프라 구현이 명확히 분리되어 유지보수와 확장성이 높음
- API, 서비스, DTO, 매퍼, 마이그레이션 등 핵심 요소가 잘 분리됨
- 표준 기술 스택(Kotlin + Spring Boot + Gradle + MyBatis) 기반으로 협업과 테스트에 용이함

---

## 결론

현재 구조는 중~대규모 EC 사이트에 적합하며, 도메인별 모듈 분리와 공통 유틸리티, 에러 처리, 보안 등 추가 레이어를 점진적으로 도입하면 더욱 견고한 시스템을 구축할 수 있습니다.