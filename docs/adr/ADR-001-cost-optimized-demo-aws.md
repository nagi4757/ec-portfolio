# ADR-001: Cost-optimized Demo AWS Architecture

<!-- markdownlint-disable MD013 MD060 -->

- Status: Accepted
- Date: 2026-08-27
- Decision owners: Architect / Infra

## Context

EC Portfolio는 senior backend engineering 역량을 보여주는 demo 환경이 필요하다. 실제 production 수준의 managed service를 모두 사용하면 낮은 traffic에서도 ALB, Fargate, NAT Gateway와 ElastiCache의 fixed cost가 월 ¥5,000 상한을 쉽게 잠식한다.

요구사항은 다음과 같다.

- Tokyo Region
- Free Tier/Credit 없이 월 ¥5,000 이하
- 목표 ¥3,500~¥4,500
- 평일 09:00~19:00 JST 중심의 scheduled demo
- RDS MariaDB와 production Docker image 사용
- security trade-off와 production upgrade path를 숨기지 않음

## Decision

Demo는 다음 architecture를 채택한다.

- CloudFront를 viewer entry point로 사용하고 JP/KR allowlist 적용
- Store/Admin static assets와 media는 private S3 + OAC
- API와 Valkey는 현재 amd64 image와 일치하는 단일 x86_64 `t3a.medium` EC2에서 Docker로 실행
- Database는 private Single-AZ RDS MariaDB `db.t4g.micro`
- EC2와 RDS는 EventBridge Scheduler로 평일 운영 시간에 맞춰 start/stop
- ARM64/Graviton은 multi-platform build, CI architecture validation과 runtime smoke test 이후의 future optimization으로 제한
- EC2는 EIP를 사용하며 application ingress는 CloudFront origin-facing managed prefix list로 제한
- CloudFront custom origin secret을 추가 검증해 direct origin bypass를 줄임
- Standard-tier SSM Parameter Store와 instance role 사용
- ECR, CloudWatch, Route 53, AWS Budgets를 최소 구성으로 사용
- SQS/SES는 application use case가 구현될 때만 도입

Demo에서 ALB, ECS/Fargate, ElastiCache, NAT Gateway, paid WAF와 Shield Advanced를 제외한다.

## Why EC2 instead of ECS/Fargate

단일 EC2는 API와 cache capacity를 한 billing unit에 co-locate하고 scheduled stop으로 compute 시간을 직접 줄일 수 있다. Docker image 사용, instance role, ECR pull과 CloudWatch 관측도 가능해 portfolio demo가 보여줄 운영 요소를 유지한다.

ECS/Fargate는 task isolation, desired state, rolling deployment와 horizontal scaling에 우수하지만 production에 가까운 구성을 만들려면 ALB, multi-AZ networking과 private outbound가 함께 필요하다. 낮은 traffic demo에서는 이 fixed architecture cost와 운영 surface가 business value보다 크다.

이는 EC2가 일반적으로 Fargate보다 우수하다는 결정이 아니다. ¥5,000 hard constraint와 scheduled single-demo workload에 한정된 결정이다.

## Why EC2-local Valkey instead of ElastiCache

Cart cache workload가 작고 demo에서 cache loss와 planned downtime을 허용하므로, Valkey를 EC2에 co-locate해 별도 always-on node 비용을 제거한다.

Trade-offs:

- EC2 stop/restart 또는 disk 장애 시 cache data loss 가능
- API와 memory/CPU contention
- automatic failover, managed patching, replica 없음
- production profile의 TLS/RBAC 계약을 local Valkey deployment에서 별도 충족해야 함

Cache를 source of truth로 사용하지 않고 correctness가 MariaDB에 남는다는 전제가 깨지면 즉시 ElastiCache 또는 다른 durable design을 검토한다.

## Why no ALB

CloudFront가 단일 EC2 custom origin으로 직접 연결한다. ALB의 fixed hourly/LCU cost를 없애는 대신 managed health routing, multiple targets, draining과 HA를 포기한다. EC2 장애와 scheduled stop 동안 API downtime이 발생한다.

## Why no NAT Gateway

단일 EC2를 public subnet에 두고 inbound를 CloudFront prefix list로 제한한다. ECR/SSM/AWS API outbound는 Internet Gateway를 사용한다. RDS는 private subnet과 security group reference로 보호한다.

NAT Gateway가 없으므로 private compute isolation은 production보다 약하다. SSH를 공개하지 않고 SSM Session Manager를 사용하며, production에서는 private tasks와 NAT Gateway 또는 VPC endpoints를 재검토한다.

## Cost impact

¥5,000 constraint는 다음 결정을 직접 만들었다.

- always-on 대신 EC2/RDS schedule
- API와 Valkey co-location
- Single-AZ RDS
- CloudFront direct EC2 origin
- NAT Gateway, ALB, Fargate, ElastiCache 제외
- short log retention과 low-cardinality metrics
- Standard SSM과 monitoring-only AWS Budget

2026-08-27 공식 Tokyo pricing snapshot과 ¥160/USD planning rate 기준 estimate는 약 ¥4,515/month다. ¥5,000 이하는 24/7 운영이 아니라 평일 제한 운영 Demo 기준이며, 같은 EC2/RDS의 24/7 estimate는 약 ¥10,560이다. 자세한 단가, schedule 산식과 buffer는 [Demo AWS Architecture](../architecture/aws-demo.md#monthly-cost-estimate)에 기록한다.

## Security consequences

Positive:

- viewer HTTPS와 CloudFront geo allowlist
- CloudFront managed prefix list + origin secret의 defense in depth
- S3 private origin/OAC
- RDS public access disabled
- SSH 미공개, SSM operational access
- runtime secret injection과 least-privilege roles

Accepted risks:

- public EC2 custom origin
- single instance/single AZ
- public EC2에서 Nginx certificate lifecycle을 직접 운영해야 함
- geo restriction은 identity control이 아님
- paid WAF/rate protection 없음
- Shield Standard만으로는 막기 어려운 bot, cache-busting과 정교한 L7 abuse
- local Valkey lifecycle이 EC2와 결합

이 위험은 public production service에는 허용되지 않는다.

## Alternatives considered

### ECS/Fargate + ALB

운영성과 확장성은 높지만 낮은 traffic에도 복수 fixed cost가 발생해 현재 budget에 부적합하다. Production upgrade target으로 유지한다.

### ElastiCache Valkey

Managed failover와 patching은 유리하지만 demo cache의 availability requirement보다 비용이 크다. Production 또는 cache criticality 상승 시 채택한다.

### NAT Gateway

Private compute outbound의 표준 선택이지만 시간당·data processing cost가 hard budget과 맞지 않는다. Demo는 tightly restricted public EC2를 수용한다.

### All services always-on

운영 단순성은 높지만 scheduled demo의 idle time에 비용을 지불하므로 기각한다.

## Consequences

- Scheduled downtime과 single-node failure를 사용자에게 명확히 표시해야 한다.
- RDS 7-day automatic restart, EC2/RDS scheduler 실패와 EIP 고정 비용을 감시해야 한다.
- 실제 resource 생성 전 Valkey TLS/RBAC compatibility와 ARM64 memory load를 검증해야 한다.
- Monthly price review와 Budget alert response가 architecture 운영의 일부다.
- Production 요구가 생기면 [Production AWS Architecture](../architecture/aws-production.md)의 단계적 upgrade path를 따른다.

## Reviewer findings disposition

| Severity / finding | Document | Resolution | Status |
|---|---|---|---|
| BLOCKER: EC2 image architecture | Demo: EC2 selection | Current `linux/amd64` image에 맞춰 x86_64 `t3a.medium` 선택, ARM64 전환 gate 명시 | RESOLVED |
| BLOCKER: Scheduler/cost alignment | Demo: Runtime; Monthly cost | EC2 223 h 40 m, RDS 231 h를 schedule과 cost table에 동일 적용 | RESOLVED |
| BLOCKER: Direct Origin Protection | Demo: Request and network boundaries | SG 443 prefix-list only, `0.0.0.0/0` 금지, HTTPS-only, `X-Origin-Verify` Nginx 403를 동시 필수화 | RESOLVED |
| BLOCKER: ¥5,000 Cost Assumption | Demo: Monthly cost estimate; ADR: Cost impact | ¥160/USD, actual schedule ¥4,515, 24/7 약 ¥10,560 비교 | RESOLVED |
| MAJOR: RDS 7-day restart | Demo: RDS | 7-day auto-start, storage charge, ordering, DLQ/alarm/actual-state check | RESOLVED |
| MAJOR: Local Valkey durability | Demo: EC2-local Valkey; ADR: Valkey decision | Internal-only 6379, memory policy, ephemeral cart loss를 선택하고 durable order와 분리 | ACCEPTED RISK |
| MAJOR: OIDC Trust | Demo: GitHub OIDC/CD | `aud`, exact repository, main/protected environment, no wildcard와 role 분리 | RESOLVED |
| MAJOR: Rollback contract | Demo: GitHub OIDC/CD | Full SHA/digest, readiness, stable/previous digest, no `latest`, Flyway non-rollback | RESOLVED |
| MAJOR: Budget is not hard cap | Demo: Observability and cost controls | Actual/forecast alerts와 runtime schedule monitoring 역할 분리 | RESOLVED |
| MAJOR: WAF 없는 L7/DDoS control | Demo: Minimum L7 and DDoS controls | CloudFront/Shield Standard/cache contract와 Nginx limit, application follow-up 및 risk 명시 | ACCEPTED RISK |
| MAJOR: VPC Origin explanation | Demo: No NAT Gateway and no ALB | Private EC2 지원을 인정하고 NAT/endpoint fixed cost와 복잡도로 제외 이유 수정 | RESOLVED |
| MINOR: Geo restriction limitation | Demo: CloudFront geo restriction | 인증/인가가 아닌 attack-surface 보조 통제, VPN/proxy 우회 명시 | RESOLVED |
| MINOR: Prefix list quota | Demo: Origin bypass | Weight 55와 단순 origin SG 운영 명시 | RESOLVED |
| MINOR: CloudWatch cost guardrail | Demo: Observability | 7-day retention, INFO, health suppression, expensive telemetry 제외 | RESOLVED |
| NIT: Cost tags | Demo: Cost allocation tags | `Project`, `Environment`, `Owner`, `AutoStop` convention | RESOLVED |
| NIT: Exchange rate documentation | Demo: Monthly cost estimate | ¥160/USD와 tax/rate variability 명시 | RESOLVED |
