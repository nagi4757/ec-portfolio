# Phase 5F-3c boot smoke

## 結論

2026-09-14 の既存 Scheduler による自然起動を利用し、`ec-portfolio-api-converge.service` の実環境 boot convergence を確認しました。

手動の EC2 / RDS start・stop・reboot、Terraform apply、追加 deployment、workflow rerun は実施していません。

基準 main:

```text
6b189db6598c1417c856d979a34af1db49997631
```

## 自然起動ゲート

- RDS は 09:50 JST の既存 Scheduler により先行起動し `available`
- EC2 `i-01aab176822e4e38c` は 10:00 JST の既存 Scheduler により起動
- SSM managed instance は `Online`
- pin 済み AMI `ami-0794a632d5c1058bf` を維持
- Scheduler 4件はすべて `ENABLED` で、cron / timezone は Terraform source と一致

## 実測 boot chain

UTC の journal / systemd timestamp で次を確認しました。

```text
01:00:33  EC2 boot
01:00:40  network-online.target active
01:00:43  docker.service active
01:00:43  ec-portfolio-api-converge.service ExecMainStart
01:00:43  existing API container restored by Docker restart policy
01:00:49  desired image reference resolved
01:01:13  already converged and ready; nothing to deploy
01:01:13  oneshot completed successfully
```

確認できた実行順序:

```text
Scheduler start
  -> EC2 boot
  -> network-online.target
  -> docker.service
  -> ec-portfolio-api-converge.service
  -> deploy-api-from-ssm.sh
  -> desired SHA resolution
  -> already-converged readiness check
  -> success
```

## systemd 判定

成功条件は次の3点を同時に満たしました。

- `Result=success`
- `ExecMainStatus=0`
- journal に convergence / readiness success log が存在

`Type=oneshot` かつ `RemainAfterExit` を設定していないため、成功後の `ActiveState=inactive` / `SubState=dead` は正常です。

実行時間は約30秒で、`TimeoutStartSec=20min` の一部のみを使用しました。

## already-converged path

今回の boot は次の状態でした。

```text
desired SHA == last-known-good SHA == running image SHA
pending migration SHA == none
```

したがって再 deployment は行わず、既存 container の readiness を確認して `Nothing to deploy` で正常終了しました。

stale `-rollback` / `-candidate` container は存在せず、deployment lock 競合も確認されませんでした。

## boot readiness budget の実証

既存 API container は 01:00:43 に復元され、readiness probing は 01:00:49 から 01:01:13 まで約24秒を要しました。

CI/default wrapper の readiness budget は `3回 / 2秒` のままですが、boot unit は次を注入します。

```text
CONVERGED_READINESS_ATTEMPTS=36
CONVERGED_READINESS_INTERVAL_SECONDS=5
```

実測では application cold start に旧 budget を超える時間が必要でした。したがって Phase 5F-3a で追加した boot 専用 `36 / 5` budget は、正常な cold boot を readiness failure と誤判定することを防ぐために必要だったことが実環境で確認できました。

## runtime verification

- running API image tag は desired SHA と一致
- `latest` tag は不使用
- API container は running
- stale rollback / candidate container なし
- host readiness: `UP`
- CloudFront `/actuator/health/readiness`: HTTP 200
- CloudFront `/actuator/health`: HTTP 200
- flock contention log なし
- SSM command timeout / failure なし

## 未検証の境界

今回確認したのは **already-converged path** です。

次の drift convergence path はまだ実環境では未検証です。

```text
EC2 offline
  -> main push advances desired SHA
  -> CI does not start EC2
  -> next scheduled boot
  -> desired SHA != running SHA
  -> boot convergence deploys desired image
  -> readiness succeeds
  -> last-known-good SHA advances
```

この経路は、EC2 が Scheduler により停止している間に通常の main push が発生した機会を利用して検証します。Parameter Store の手動改変や EC2 の手動 stop/start では作りません。

SIGKILL path は引き続き rollback 完了を保証しない設計境界であり、意図的な実環境試験は行いません。
