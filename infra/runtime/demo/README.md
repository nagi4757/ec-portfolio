# AWS Demo Runtime Deployment / HTTPS Origin Bundle

## 目的

このディレクトリは、Amazon Linux 2023のEC2ホストにDemo API Runtimeを構築するためのhost-side deployment bundleです。Phase 4Bで構築したAPI/Valkey runtime、Phase 4C-1のCloudFront origin向けNginx HTTPS reverse proxyに加え、Phase 4C-3ではLet's Encrypt DNS-01 certificate lifecycleを提供します。コードと運用契約だけを扱い、このPRではAWSへの接続、EC2操作、DNS変更、証明書発行、ECR push、Terraform操作を行いません。

Runtimeの構成は次のとおりです。

```text
EC2 host
├── Nginx
│   └── HTTPS :443 -> http://127.0.0.1:8080
├── API container
│   ├── SPRING_PROFILES_ACTIVE=demo
│   └── 127.0.0.1:8080 -> container:8080
└── Valkey container
    └── ec-portfolio-demo private Docker network only
```

CloudFrontからEC2 originへの通信はHTTPS `443`だけを使用します。Nginxは同一hostのloopback APIへHTTPでproxyし、Docker networkには参加しません。APIをpublic `8080`で公開せず、Valkeyもhost portを一切publishしません。TCP `80` listenerも作成しません。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `bootstrap-host.sh` | Dockerのinstall/startと専用network作成 |
| `deploy-api.sh` | ECR pull、SSM secret取得、Valkey/APIの安全な起動・交換 |
| `deploy-api-from-ssm.sh` | SSM Parameter Storeからdeployment contractを解決し`deploy-api.sh`へ引き渡すhost-side wrapper（Phase 5F-2a） |
| `deploy-runtime.sh` | GitHub ActionsからSSM Run Commandで4 artifactを検証し、installerとwrapperを順に実行するCI側orchestrator（Phase 5F-2b / 5F-3b） |
| `install-api-convergence.sh` | runtime scriptsとboot convergence unitを冪等にinstall・enableするhost-side installer |
| `ec-portfolio-api-converge.service` | EC2起動時にdesired image SHAへ収束するsystemd oneshot unit |
| `smoke-check.sh` | secret不要のcontainer、port、readiness検証 |
| `configure-origin.sh` | Nginx install、TLS origin設定、SSM origin verification設定 |
| `origin-smoke-check.sh` | HTTPS、証明書、origin verification、非公開portの検証 |
| `origin-token-rotation-check.sh` | origin verification token rotation中に、旧/新tokenの受理・拒否をhost上のrequestで検証 |
| `configure-acme.sh` | Certbot/Route 53 DNS-01によるorigin certificate発行とrenewal timer設定 |
| `renew-origin-cert.sh` | 対象certificateだけを更新し、変更時にNginxを安全にreload |
| `sync-origin-tls.sh` | Certbot durable state（package所有の`cli.ini`を除く`/etc/letsencrypt`）をS3へtar退避・復元するorigin TLS state永続化（Phase 6B） |
| `ec-portfolio-certbot-renew.service` | bounded certificate renewalを実行するsystemd oneshot unit |
| `ec-portfolio-certbot-renew.timer` | missed runを補完する永続systemd timer |

bootstrapとdeployを分離することで、ホストの一度だけ必要な変更と、immutable image単位で繰り返すアプリケーションdeployを明確に分けます。Terraform `user_data`には接続せず、EC2 replacementを伴う構成変更も行いません。

## Host bootstrap

対象は標準のAmazon Linux 2023 x86_64 AMIです。AWS CLI v2と`curl-minimal`はAMIの標準契約として検証し、追加installはDocker packageだけに限定します。

```bash
sudo ./bootstrap-host.sh
```

scriptは再実行可能です。Docker daemonをenable/startし、`ec-portfolio-demo` bridge networkが存在しない場合だけ作成します。secret取得、ECR pull、Valkey/API起動は行いません。

参考:

- [Amazon Linux 2023でのDocker install](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-docker.html)
- [Amazon Linux 2023のAWS CLI v2](https://docs.aws.amazon.com/linux/al2023/ug/awscli2.html)

## Deployment inputs

次の値はsecretではなく、実行前に承認済みの環境情報から設定します。

| 変数 | 内容 |
| --- | --- |
| `IMAGE_REF` | Demo ECR repositoryのfull reference。tagは40文字のGit SHAのみ |
| `DB_HOST` | private RDS endpoint |
| `DB_PORT` | MariaDB port |
| `DB_NAME` | database name |
| `DB_USERNAME` | database username |
| `APP_CORS_ALLOWED_ORIGINS` | 承認済みStore/Admin origin |

`IMAGE_REF`は次の形式です。AWS account IDをrepositoryにハードコードせず、承認済みinfra handoffから`ECR_REGISTRY`を取得します。

```bash
export IMAGE_REF="${ECR_REGISTRY}/ec-portfolio-demo-api:${GIT_SHA}"
export DB_HOST="${RDS_ENDPOINT}"
export DB_PORT="3306"
export DB_NAME="ec"
export DB_USERNAME="ec_admin"
export APP_CORS_ALLOWED_ORIGINS="https://demo.example.invalid"

sudo --preserve-env=IMAGE_REF,DB_HOST,DB_PORT,DB_NAME,DB_USERNAME,APP_CORS_ALLOWED_ORIGINS \
  ./deploy-api.sh
```

`IMAGE_REF`が空、`:latest`、full ECR referenceではない、または40文字のlowercase Git SHA tagではない場合、deployは開始前に失敗します。image buildやECR pushはこのbundleの責務ではありません。

## Secret boundary

secretはcommand argumentやcaller environmentでは受け取りません。EC2 instance roleを使い、hostのAWS CLIが次のSecureStringを`--with-decryption`で取得します。

- `/ec-portfolio/demo/db/master-password`
- `/ec-portfolio/demo/app/auth-jwt-secret`

値はstdout/stderrへ出力せず、`/run`配下のroot-only一時ファイルを通じてDockerに渡し、script終了時に削除します。API containerへ渡すのはapplication環境変数だけです。AWS credential、`~/.aws`、Docker socket、IMDS access、AWS SDKをcontainerへ渡したりmountしたりしません。

## Valkey contract

Valkeyはofficial image `valkey/valkey:8.1.9-alpine`に固定します。`ec-portfolio-demo` network上でalias `valkey`を持ち、APIは次の値で接続します。

```text
REDIS_HOST=valkey
REDIS_PORT=6379
```

host port、public port、volumeは使用しません。`restart=unless-stopped`を使用し、Demoではephemeral dataを許容します。

参考: [Valkey supported releases](https://valkey.io/topics/releases/)

## Deployment and rollback

`deploy-api.sh`は次の順序で動作します。

1. root、必須command、Docker daemon、専用network、入力値を検証
2. `IMAGE_REF`からECR registry/Regionを抽出してhost側でlogin
3. immutable API imageをpull
4. pinned Valkey imageを確認・起動し、health checkを待機
5. SSM SecureStringを取得し、root-only runtime environmentを作成
6. host portを持たないcandidate APIでDB/Valkeyを含むreadinessを検証
7. 既存APIを停止・rollback名へ退避し、新APIを`127.0.0.1:8080`で起動
8. 最終readinessがHTTP 200かつ`UP`であることをbounded retryで確認

candidate検証後にだけ既存APIを停止します。最終APIの起動またはreadinessが失敗した場合、失敗containerを削除し、退避した旧containerを元の名前に戻して起動します。成功後は旧containerを削除します。より古いimageへ戻す手動rollbackも、同じscriptへ承認済みの過去Git SHA `IMAGE_REF`を渡して行います。

### signal終了時のrollback（Phase 5F-3b-0）

上記の rollback は EXIT trap の中にあり、終了 status が 0 以外のときだけ実行されます。bash は trap されていない SIGTERM で終了するときも EXIT trap を実行しますが、そこで観測される status は `0` です。そのため signal handler が無いと、**rollback がちょうど必要な場面で飛ばされます**。

これを避けるため `deploy-api.sh` は次を宣言しています。

```bash
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT
```

`128 + signal` という慣例どおりの status で明示的に終了することで、既存の rollback 条件が signal 経路でも正しく評価されます。さらに `cleanup()` の先頭で `trap '' TERM INT` を宣言し、rollback の途中に 2 発目の signal が入って処理が半分で切れることを防いでいます。宣言の順序も重要で、status を保存し、signal を ignore にし、最後に EXIT trap を解除します。EXIT trap を先に解除すると、その隙に届いた 2 発目の signal が handler を再入して `exit` を呼び、解除済みの EXIT trap を素通りして rollback なしで終了し得ます。

#### cleanup 中の child process への影響

`trap '' TERM INT` が設定する SIG_IGN の disposition は、`cleanup()` が起動する **child process にも継承されます**。つまり rollback 中の `docker rm` / `rename` / `start` / `logout` も、後続の SIGTERM では中断されません。これは rollback を半分で終わらせないための意図的な挙動です。

裏返すと、`dockerd` や docker CLI が hang した場合に SIGTERM で断ち切ることはできません。したがって Phase 5F-3b で systemd unit を追加する際は、`TimeoutStopSec` 経過後の SIGKILL が最終的な上限として機能する必要があります。ただし SIGKILL では rollback を保証できません。

#### SIGKILL は保護できません

**SIGKILL は trap できないため、rollback を保証できません。** SIGKILL で中断された場合、旧 container が `-rollback` 名のまま残り、次回の deployment は `validate_prerequisites` の「A rollback container already exists」で fail-closed になります。安全側ではありますが、復旧には手作業が必要です。

したがって、この script を終了させ得る仕組みでは、SIGTERM の後に rollback を完了できるだけの猶予が必要です。Phase 5F-3b の systemd unit は `TimeoutStartSec=20min` と `TimeoutStopSec=2min` を組み合わせ、通常の終了 signal に `SIGTERM`、最終 signal に `SIGKILL` を使用します。詳細は次節の timeout / signal contract を参照してください。

現時点で CI は remote SSM command を polling するだけで command 自体を kill しないため、この script を中断する仕組みは存在しません。

## EC2 boot convergence（Phase 5F-3b）

`ec-portfolio-api-converge.service`は`multi-user.target`にenableされる`Type=oneshot` unitです。`network-online.target`を待ち、`docker.service`を必須dependencyとしてその後に実行し、`deploy-api-from-ssm.sh`が起動時点のdesired image SHAへ収束させます。unit自身はRDSやEC2をstartせず、Docker以外の外部serviceをactivateしません。

boot callerだけが次のreadiness budgetを設定します。

```text
CONVERGED_READINESS_ATTEMPTS=36
CONVERGED_READINESS_INTERVAL_SECONDS=5
```

CIから実行するwrapperにはこの環境変数を注入しません。したがってwrapper defaultの`3回 / 2秒`は変わらず、boot時だけ`36回 / 5秒`になります。同時deploymentを待たずに失敗させる既存のnon-blocking `flock`も維持します。

### timeout / signal contract

`TimeoutStartSec=20min`は、`deploy-api.sh`のconfigured bounded waitsである666秒と同じ値ではありません。また、deployment全体の数学的なworst-caseでもありません。Docker pull、AWS API、Docker daemon operationなどscript-level timeoutを持たない処理も含め、boot convergence全体へ適用する**outer operational bound**です。

`TimeoutStartSec`を超過した場合、次の順序で終了処理が進みます。

```text
TimeoutStartSec=20min expires
  -> systemd sends SIGTERM to the control group
  -> deploy-api.sh exits with status 143
  -> EXIT cleanup runs
  -> rollback runs
  -> cleanup ignores TERM/INT
  -> child Docker CLI processes inherit SIG_IGN
  -> TimeoutStopSec=2min expires
  -> systemd sends SIGKILL to the control group
```

cleanup中は2回目以降のTERM/INTでrollbackを途中終了させません。その代わり、cleanupが起動したDocker CLIもSIG_IGNを継承するため、hangしてもSIGTERMでは停止しません。`TimeoutStopSec=2min`の経過後に送られるSIGKILLがsystemd側の最終escalationです。SIGKILLはtrapできないため、この経路ではrollback完了を保証できません。

20分のstart timeoutと2分のstop graceを合わせた22分は、**configured systemd escalation bound**です。これはOSやkernelのあらゆる状態まで含めた絶対的な終了保証ではありません。

unitは`KillMode=control-group`、`KillSignal=SIGTERM`、`SendSIGKILL=yes`、`FinalKillSignal=SIGKILL`を明示し、signal exitの130/143を成功扱いしません。`Restart=no`であり、transient failureを含めて自動retryしません。`StartLimit*`によるretryも設定しません。`UMask=0077`、`PrivateTmp=true`、`NoNewPrivileges=true`は既存runtimeの`/run`、`/var/lock`、Docker socket、AWS API利用と互換です。

### installer contract

`install-api-convergence.sh`はroot実行とAmazon Linux 2023を検証し、bundle内の3 executable scriptsを`root:root` `0755`、unitを`root:root` `0644`でinstallします。その後、次の順序だけを実行します。

1. `systemctl daemon-reload`
2. `systemctl enable ec-portfolio-api-converge.service`
3. `systemctl is-enabled --quiet ec-portfolio-api-converge.service`

各systemd操作は30秒でtimeoutし、さらに5秒後にkillします。installerは冪等で、2回実行しても同じfileとenable状態へ収束します。`enable --now`、`start`、`restart`、`reset-failed`は使用しないため、installer実行そのものがboot convergenceを開始することはありません。自動retryも行いません。

## CI駆動deployment（Phase 5F-2b）

`main`へのpush時、GitHub Actionsの`deploy-api` jobが`deploy-runtime.sh`を実行します。checkout済みのwrapper、deploy script、convergence installer、systemd unitの4 artifactをbase64で送り、host側で4つすべてのSHA256を検証します。検証はtemporary directoryの作成より前に行い、1つでも不一致ならinstallerもwrapperも実行せず、hostへfileを作成・installしません。

4 artifactが一致した場合だけtemporary bundleを作成してinstallerを実行し、installer成功後にinstall済みwrapperを実行します。EC2がSSM managed instanceとして`Online`でなければ従来どおりzero `SendCommand`、zero auto-startで成功終了し、installationとdeploymentは次のOnline機会までdeferします。

### desired stateの意味

このjobはcommit駆動ではなくdesired state駆動です。

- `GITHUB_SHA`は**このjobを実行してよいかどうかの判定にだけ**使用します。remote `main` HEADと一致しない stale なqueued jobを拒否するためのものです。
- hostが実際にdeployするimageは、**host側wrapperが読んだ時点の**`/ec-portfolio/demo/deploy/desired-image-sha`の値です。

したがって、後続の`main` pushが既にdesired stateを更新していた場合、先行するjobは自分のcommitではなく**より新しいdesired SHAへ収束します**。これは意図した動作です。desired stateを唯一の真実として扱うことで、実行順序が前後しても最終状態が一意に定まり、古いreleaseを後から上書きしてしまう事故を防ぎます。

### 同時実行の防止

hostでの同時deploymentは`flock`による非待機lock（`/var/lock/ec-portfolio-demo-deploy.lock`）で防ぎます。lockを取得できなかった場合は待機せずfail-closedで終了します。待機しない理由は、先行runの結果を観測できないまま順番待ちしても、後続runがどの状態の上で動くか保証できないためです。

CI側は`concurrency` groupでもjobの重複を抑止しますが、hostのlockはSSM Run Commandの再送や手動実行など、CI以外の経路も含めて保護します。

### CI polling budget と timeout 契約

3 つの数字を区別してください。混同すると「900秒あれば必ず deployment が終わる」という誤った結論になります。

#### 1. 明示的に configured された bounded waits: 666秒

`deploy-api.sh`がコード上で明示的に設定している待ち時間の合計です。readiness の 1 回あたりのコストは interval だけでなく probe の timeout も含みます。

| 項目 | 計算 | budget |
| --- | --- | --- |
| Valkey health | `30回 × 2秒` | 60秒 |
| candidate readiness | `36回 × (3秒 + 5秒)` | 288秒 |
| API stop grace（`docker stop --time`） | | 30秒 |
| final readiness | `36回 × (3秒 + 5秒)` | 288秒 |
| **configured waits 合計** | | **666秒** |

これは各 loop が同時に上限まで使い切った場合の保守的な合計であり、**成功した deployment の実測 wall-clock ではありません**。最初の deployment を除いて既存 container の停止待ちも必ず経路に入るため、stop grace も含めています。

#### 2. CI polling observation budget: 900秒

`deploy-runtime.sh`が SSM command の終了を観測し続ける時間です（`90回 × 10秒`）。

#### 3. operational headroom: 約234秒

`900 - 666 = 234秒`。これは **script-level の上限が存在しない** 次の作業のための運用上の余裕です。

- API image の `docker pull`
- Valkey image の `docker pull`
- ECR login
- SSM Parameter Store / STS / ECR の API 呼び出し
- SSM Run Command の pickup
- 一部の Docker daemon operation

これらには timeout が設定されていないため、**「900秒以内に必ず deployment が完了する」とは言えません**。234秒は通常これらにかかる時間から見積もった余裕であって、保証ではありません。

#### 契約の順序

```
configured waits 666秒 < CI polling 900秒 < OIDC credential 1200秒 < job timeout 1800秒
```

`deploy-runtime.test.sh`がこの順序と最低 180秒の headroom を検証します。値はすべて source of truth から読み取ります。

- 各 budget は `deploy-api.sh` と `deploy-runtime.sh` の定数から
- `role-duration-seconds` と `timeout-minutes` は `ci.yml` の `deploy-api` job から
- 要求する credential duration が role の `max_session_duration` を超えていないかは `github_actions_backend_deploy.tf` から

なお job timeout と credential duration は **clock の起点が異なります**。job timeout は job 開始時点から、credential duration は credential 発行時点から数えます。したがって `1800 > 1200` は運用上の余裕であって、credential が必ず先に失効することの証明ではありません。

`deploy-api.sh`の readiness 設定や stop grace を変更する場合は、polling budget も合わせて見直してください。

## Smoke check

deployment後、secretなしで次を実行します。

```bash
sudo ./smoke-check.sh
```

次の条件をすべて検証し、違反時はnon-zeroで終了します。

- Docker daemonが利用可能
- Valkey/API containerがrunning
- Valkeyがhost portをpublishしていない
- API bindingが正確に`127.0.0.1:8080`
- `GET /actuator/health/readiness`がHTTP 200かつ`UP`

## Let's Encrypt DNS-01 certificate lifecycle

Demo origin hostnameは`origin-demo.yoonec.dev`に固定し、Let's Encrypt production endpointとRoute 53 DNS-01 challengeだけを使用します。HTTP-01、wildcard certificate、TCP `80` listenerは使用しません。CertbotはEC2 instance profileだけでRoute 53へアクセスし、AWS access key、profile、Boto2/legacy credential path、web identity、container credential endpoint、IMDS endpoint overrideは受け付けません。

Phase 4C-2AのTerraformがapplyされ、EC2 instance roleに承認済みRoute 53 ACME permissionが付与された後、連絡可能なACME emailと、Phase 6Bのorigin TLS backup bucket名を渡して実行します。bucket名はTerraform output `origin_tls_backup_bucket_name`から取得します。

```bash
export ACME_EMAIL="operator@example.com"
export ORIGIN_TLS_BUCKET="<origin_tls_backup_bucket_name>"
sudo --preserve-env=ACME_EMAIL,ORIGIN_TLS_BUCKET ./configure-acme.sh
```

`ORIGIN_TLS_BUCKET`は必須です。backupされないまま発行すると、certificateがこのhostのdiskにしか存在しない状態になり、host置換時にLet's Encryptへ再発行を要求することになります。

scriptはAmazon Linux 2023とroot実行をfail-closedで検証し、AL2023 package repositoryから`certbot`と`python3-certbot-dns-route53`をinstallします。package installは10分、certificate発行は15分、systemd操作は30秒を上限とします。発行requestはnon-interactiveで、SANが正確に`origin-demo.yoonec.dev`だけであることを確認します。

発行後に次のstandard Certbot live pathを検証します。private keyはEC2 localのroot所有かつroot-only permissionであり、repository、environment、argument、logには保存・出力しません。

```text
/etc/letsencrypt/live/origin-demo.yoonec.dev/fullchain.pem
/etc/letsencrypt/live/origin-demo.yoonec.dev/privkey.pem
```

`ec-portfolio-certbot-renew.timer`は毎日2回のbase scheduleに最大1時間のrandom delayを加えます。`Persistent=true`のため、平日夜間や週末にEC2が停止していても次回起動後にmissed runを処理できます。managed renewalとNginx reloadの順序を一元化するため、AL2023 packageの`certbot-renew.timer`が存在する場合は停止・無効化します。renewal自体は15分でboundedされ、失敗時に既存certificateを削除しません。certificate chainが実際に変更された場合だけ、次の順序でNginxへ反映します。

1. `nginx -t`
2. `systemctl reload nginx`

NginxまたはDemo origin設定がまだ存在しない場合、certificate renewalは完了させたうえでreloadを安全にskipします。Nginx設定検証に失敗した場合はreloadせずnon-zeroで終了するため、実行中のNginxは既存の読み込み済みcertificateを継続利用します。

### origin TLS state の永続化（Phase 6B）

`sync-origin-tls.sh` が Certbot durable state を専用 S3 bucket へ退避し、別 host で復元できるようにします。bucket 名は Terraform output `origin_tls_backup_bucket_name` から取得します。

```bash
ORIGIN_TLS_BUCKET=<bucket> sudo -E ./sync-origin-tls.sh backup
ORIGIN_TLS_BUCKET=<bucket> sudo -E ./sync-origin-tls.sh restore
ORIGIN_TLS_BUCKET=<bucket>      ./sync-origin-tls.sh verify
```

#### なぜ PEM だけでは足りないのか

replacement host が毎回 certificate を新規発行すると、Let's Encrypt の **同一 domain に対する重複 certificate 週 5 件**の制限に数日で到達し、origin TLS が停止します。したがって発行ではなく復元が前提になります。

| 対象 | 必要な理由 |
| --- | --- |
| `live/` | `archive/` を指す symlink 群。Nginx の `ssl_certificate` 参照先 |
| `archive/` | 実体の certificate と private key |
| `renewal/` | plugin 設定（`dns-route53`）を含む renewal 設定 |
| `accounts/` | ACME account key。これが無いと復元後の host は account 再登録が必要 |

#### tar を使う理由

`aws s3 sync` は symlink を追跡して実体を複製し、ownership と permission を失います。その結果 `live/` が symlink ではなく通常ファイルの集合になり、**その日は serving できても renewal ができない host** が出来上がります。`tar` は symlink・所有者・permission を保持するため archive 形式を採用しています。

archive は `/etc/letsencrypt` 配下を原則として選別せず格納します。certbot が必要とするファイルは version により異なり、選別すると取りこぼす可能性があるためです。上表の directory は archive 生成後の**検証項目**として使用します。

例外は `/etc/letsencrypt/cli.ini` ただ一つで、これは archive に含めません。Amazon Linux 2023 では certbot RPM が所有する package file（`preconfigured-renewal` と `max-log-backups` のみ）であり、deployment の durable state ではありません。置換 host は `dnf install certbot` で自分自身の cli.ini を得るため、旧 host のものを復元すると package が書いた設定を上書きしてしまいます。

除外は allowlist ではありません。archive 側の contract は変更しておらず、`letsencrypt/cli.ini` を含む archive は metadata 検証と staged tree 検証の両方で従来どおり拒否されます。つまり「archive に cli.ini がある」＝「誰かが入れた」であり、fail-closed のままです。

#### 安全性の契約

upload と unpack の前に archive を検証します。entry 名の検証と、entry の**種別・link target** の検証を分けている点が重要です。

名前に対する検証:

- 空でないこと、gzip tar として読めること
- **絶対 path と親 traversal を含まないこと**
- `letsencrypt/` 以外の entry を含まないこと
- entry 名が certbot が実際に使う文字種のみであること
- `live` / `archive` / `renewal` / `accounts` が存在すること

metadata に対する検証（**展開前**に実施）:

- entry 種別が regular file / directory / symlink のみであること。hardlink・character device・block device・FIFO・socket は拒否します
- symlink target が `../../archive/<host>/<file>` の形式のみであること
- setuid / setgid bit を含まないこと

**展開後の検証では不十分です。** 名前の一覧には entry の種別も link target も現れないため、`letsencrypt/` 配下の無害な名前を持つ character device や、`/etc` を指す symlink がそのまま通過します。restore は root で `tar` を実行するので、展開後に気付いた時点では device node は既に作成され、脱出用 symlink も既に存在します。さらに復元後の検証は既知の path だけを見るため、余分な entry を列挙しません。したがって metadata 検証は展開前に行います。

展開後には、`tar` の出力文字列の解析ではなく **filesystem に直接問い合わせる** sweep も実施し、regular file / directory / symlink 以外の entry と、staging 外へ解決される symlink・絶対 symlink を拒否します。

#### ownership と permission

展開は `--no-same-owner` で行い、**archive が指定する UID/GID は破棄します**。root で `--same-owner` 展開すると、archive 側が private key の所有者を指定できてしまうためです。`uid 1000` / `mode 0600` の entry は「group/world から読めない」という検査を通過しますが、結果として local user が origin private key の所有者になります。Amazon Linux 2023 上の certbot / Nginx state はすべて root 管理であり保持すべき ownership は存在しないため、破棄が最も単純で安全な契約です。

破棄したうえで、sweep により次を検証します（flag が将来変化した場合に fail-closed とするため）。

- すべての entry が restore 実行者（`restore` が root を強制）の所有であること
- group / world writable な entry が存在しないこと
- setuid / setgid が存在しないこと
- `privkey*.pem` と `private_key.json` が group / world から読めず実行もできないこと

#### Certbot hook の拒否

certbot は `renewal-hooks/` の script と、renewal 設定内の `pre_hook` / `post_hook` / `renew_hook` / `deploy_hook` を **root で実行**します。archive は state の backup であって code の運搬手段ではないため、restore 時点で両方を拒否します。拒否しない場合、archive を書き換えられた時点で次回 renewal 時の任意 root command 実行に直結します。

本 project は `renew-origin-cert.sh` が Nginx reload を自前で行うため Certbot hook を必要とせず、全面拒否に運用上の代償はありません。certbot が自動生成する**空の `renewal-hooks/` directory は許可**します。

なお `renew-origin-cert.sh` の `validate_renewal_configuration` も同じ directive 集合を renewal 実行直前に拒否します。restore 側の検査はそれを置き換えるものではなく、hostile state が install される前に止めるための層です。

復元後の tree も検証します。

- `live/` の 4 ファイルが **symlink であり、`archive/` を指し、実体に解決されること**
- certificate と private key が parse 可能で、**公開鍵が一致すること**
- private key が group / world から読めないこと
- renewal 設定が存在すること

`restore` は staging directory で展開・検証してから設置し、`/etc/letsencrypt` が既に存在する場合は**上書きせず失敗**します。稼働中 host の certbot state を誤って置き換えないためです。

#### bucket と IAM

- Block Public Access 全 4 項目 on、public ACL / policy 禁止
- SSE-S3（AES256）を明示、versioning 有効、noncurrent version は 90 日で失効
- bucket policy は **insecure transport の拒否のみ**。「instance role 以外を全 Deny」のような広範な Deny は Terraform や管理者の正当な access まで遮断し復旧が困難になるため使用しません。access の絞り込みは identity 側で行います
- instance role には固定 object 1 件に対する `s3:GetObject` と `s3:PutObject` のみ。`s3:ListBucket` は object path が固定で探索不要なため付与しません。`s3:DeleteObject` も付与しないため、host は archive を置き換えられても履歴を破壊できません

## ECS EC2 Spot host の AMI pin（Phase 6C・計画中）

> このセクションは **計画段階** の取り決めです。ECS cluster / Launch Template / Auto Scaling group / Spot host は
> まだ Terraform にも AWS にも存在しません。現在稼働している origin host は従来どおり単一の On-Demand EC2 です。

Phase 6C の ECS EC2 host は、Amazon ECS-optimized Amazon Linux 2023 x86_64 AMI を **literal な AMI ID として pin** します。

- 候補 image の discovery には AWS 管理の `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended` を使いますが、
  **Terraform からは参照しません**。これは mutable pointer であり、AWS が新しい image を公開した日に plan が
  launch template version の更新と instance refresh を引き起こすためです。既存の `demo_ami_id` を pin している理由と同じです。
- pin した値は `infra/terraform/demo/locals.tf` の `ecs_ami_id` に置きます。更新は明示的な PR で行います。
- `ecs_ami_id` は既存の `demo_ami_id` とは **別 lifecycle** です。cutover が完了するまで On-Demand origin host は稼働を続けるため、
  一方の image 更新がもう一方を巻き込んではいけません。
- pin した image の root snapshot は **30 GiB gp3** です。Launch Template の root volume は
  **snapshot より小さく設定できません**。Phase 6C-3 の下限値はこの実測値に従います。

## Spot replacement bootstrap（Phase 6C・計画中）

> このセクションも **計画段階** です。ECS cluster / Launch Template / Auto Scaling group / Spot host は
> まだ Terraform にも AWS にも存在しません。現在の origin host は従来どおり単一の On-Demand EC2 です。

`bootstrap-spot-host.sh` は置換 host を「serving-ready」まで持っていく順序契約です。順序そのものが契約であり、
`bootstrap-spot-host.test.sh` が marker 順序で検証します。

1. root / Amazon Linux 2023 / 必要 command の検証
2. **ECS agent を disable + stop**（bootstrap が行う最初の mutating action。以降のどの段階で失敗しても cluster に登録されない）
3. serving-ready marker の reset
4. 信頼済み local bundle の解決と SHA256 検証
5. `/etc/letsencrypt` の不在確認
6. **S3 からの TLS restore**（certbot install より前）
7. restore 失敗は即座に終了。**certbot 再発行への fallback は存在しない**
8. `certbot` / `python3-certbot-dns-route53` を install（package が自身の `cli.ini` を作成）
9. package-owned `cli.ini` contract の検証（RPM ownership / integrity / directive allowlist）
10. renew helper / env / service / timer を install-only で配置
11. `/etc/ecs/ecs.config` を atomic に作成
12. **ECS agent を enable + start**（ここで初めて cluster に参加）
13. cluster 登録の bounded wait（登録先 cluster 名の厳密一致まで確認）
14. API `127.0.0.1:8080` readiness の bounded wait
15. `configure-origin.sh` を `ORIGIN_SMOKE_MODE=ecs` で実行
16. ECS HTTPS smoke の成功
17. renewal timer の有効化
18. serving-ready marker を記録

### 失敗時の cleanup と ASG replacement の境界

どの gate で失敗しても、host は workload scheduler から見て fail-closed でなければなりません。
registration / readiness / HTTPS smoke は ECS agent を起動した後に走るため、EXIT trap で cleanup します。

- commit 前に失敗した場合、serving-ready marker を削除する
- ECS agent に触れた後であれば `systemctl disable --now ecs` を best-effort で実行し cluster から外す
- renewal timer に触れた後であれば `systemctl disable --now ec-portfolio-certbot-renew.timer` を best-effort で実行する
- cleanup の失敗が元の failure exit code を上書きしない
- 成功後は agent も timer も維持する

#### partial side effect を cleanup 対象にする

`systemctl enable --now <unit>` は **enable と start の 2 操作**です。enable が成功して start が失敗した場合、
command は non-zero を返しますが unit は **enabled のまま**残り、次の boot で自動起動します。
成功後に flag を立てる実装ではこの経路が cleanup から漏れ、bootstrap に失敗した host が reboot 後に
cluster へ再登録されたり、証明書 renewal と S3 write-back を実行したりし得ます。

そのため `ecs_agent_may_be_active` / `renew_timer_may_be_enabled` は **command 実行前**に立て、
非 zero 終了なら成功可否に関わらず disable します。「may be」なのは、caller が exit code から
知り得るのがそこまでだからです。

これは **最初の `systemctl disable --now ecs`** にも同じく適用します。ECS-optimized AMI は agent を
**enabled の状態で出荷する**ため、host は起動時点で既に「次の boot で自動起動する」状態にあります。
`disable --now` もまた 2 操作であり、部分的に失敗すれば enabled のまま非 zero を返し得ます。
flag を `start_ecs_agent` まで立てない実装では、この最初の段階で失敗した bootstrap が
「agent が enabled のまま、cleanup は何もしない」状態で終了します。
`default` cluster に登録されるだけ、EIP は付かない、といった周辺条件には依存させません。

cleanup は失敗した最初の disable を **best-effort で再試行**します。test は
「1 回目が失敗した後に 2 回目が実際に実行された」ことを試行回数と成功回数の両方で検証し、
成功経路では再試行が起きないことを positive control で確認します。

test の fake `systemctl` も「単に失敗する」のではなく、**enable の side effect を残してから失敗する**挙動を再現し、
「次の boot で自動起動し得る enabled 状態を残さない」ことを unit state として検証します。
成功経路で cleanup が走らないことは別の positive control で確認します。

> **重要**: この cleanup が保証するのは「失敗した host に work が配置されないこと」だけです。
> **失敗した host を ASG が自動で replacement することは 6C-2 では保証しません。**
> それには Auto Scaling group の lifecycle hook または health check との統合が必要で、**Phase 6C-3 の責務**です。
> 現状は cluster に登録されないまま instance が残るため、6C-3 でこの統合を入れるまでは手動での確認が必要です。

### renewal timer の有効化順序

renewal timer の unit 設置と `daemon-reload` は前半で行いますが、**有効化は最後**です。
timer は `Persistent=true` のため bootstrap 途中で起動する理由がなく、
serving していない host が証明書更新を走らせる状態を避けます。
timer の有効化に失敗した場合は serving-ready を作成しません。

### AWS 呼び出しの identity と Region

bootstrap から起動する AWS child は **EC2 instance role のみ**を使います。static key と profile を消すだけでは
不十分で、credential chain には他の入口があり、呼び出し先と信頼する証明書も環境変数で差し替え可能です。
以下の 3 系統をすべて child から取り除きます。

| 系統 | 変数 | 取り除く理由 |
| --- | --- | --- |
| static credential / profile | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_SECURITY_TOKEN`, `AWS_PROFILE`, `AWS_DEFAULT_PROFILE`, `AWS_CREDENTIAL_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE` | instance role 以外の identity で動作させない |
| credential provider | `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_ROLE_ARN`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, `AWS_EC2_METADATA_DISABLED`, `AWS_EC2_METADATA_SERVICE_ENDPOINT`, `AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE` | 別 provider への切り替え、IMDS の無効化・転送を防ぐ |
| endpoint / trust | `AWS_ENDPOINT_URL`, `AWS_ENDPOINT_URL_S3`, `AWS_ENDPOINT_URL_SSM`, `AWS_ENDPOINT_URL_ROUTE53`, `AWS_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `BOTO_CONFIG` | 呼び出し先の差し替えと、その差し替え先を信頼させる trust store の持ち込みを防ぐ |

これは `renew-origin-cert.sh` が certbot に対して既に適用している policy と同じもので、この bootstrap が使う
S3 / SSM endpoint を追加したものです。TLS restore だけでなく、`cli.ini` contract 検証、`configure-origin.sh`、
ECS smoke の SSM 呼び出しにも同じ処理を適用します。`origin-smoke-check-ecs.sh` は単体実行もできるため、
同一 policy を defence in depth として自身でも適用します。

test はこれを **child process の環境を実際に観測して**検証します。stand-in が自分の process 内から各変数を報告し、
`<unset>` であることを assert します。さらに、identity 除去を通さない child（`dnf`）が同じ変数を
**値付きで観測する**ことを positive control とし、harness が実際に hostile な値を注入していることを保証します
（注入が止まれば `<unset>` の assertion が空虚になるため）。

helper 側の test seam（`ORIGIN_TLS_PARENT_DIRECTORY`、`CERTBOT_CONFIG_PREFIX`）も同様に取り除きます。
caller の環境変数で「どこに TLS state を復元するか」「どの certbot 設定を検証するか」を選べてはいけないためです。

Region は **`ap-northeast-1` を明示的に渡します**。AWS CLI が local config や inherited profile から
偶然 Region を得ることに依存しません。caller が Region を指定した場合は形式と一致を検証し、異なれば失敗します。

### artifact 配送の境界

このスクリプトは **artifact を download しません**。runtime bundle が同じ directory に既に存在することを前提とし、
`bundle.sha256` に対する検証を通過したものだけを使用します。mutable な URL や GitHub の latest から取得して root で実行する経路は
意図的に持ちません。

`bundle.sha256` の位置づけを明確にしておきます。これは **配送の完全性**（truncate、欠落、途中で終わったコピー）を検出するためのものであり、
**真正性の検証ではありません**。この directory に書き込める者は manifest 自体も書き換えられるため、
「同じ directory にある」という理由だけで manifest が信頼されるわけではありません。

したがって真正性は bundle をそこに置いた仕組みが担保します。それは Phase 6C-3 の Launch Template / user_data の責務であり、
本 Phase 6C-2 は **既に信頼された bundle を受け取る host 側の consumer** です。fresh host への配送方法は 6C-3 で別途決定します。

### Elastic IP は bootstrap の責務ではない

serving-ready になった host は、まだ production traffic を受けていません。EIP の付け替えは別の意図的な手順
（Phase 6C-5）であり、このスクリプトに `AssociateAddress` 相当の呼び出しは存在しません。test がその不在を検証します。

### ECS host 向け origin smoke

`origin-smoke-check.sh` は standalone Docker host 用で、container 名と `docker port` の binding を検証します。
host networking ではどちらも存在しないため、ECS host では `origin-smoke-check-ecs.sh` を使用します。
こちらは listener contract を直接検証します。

- `127.0.0.1:8080` と `127.0.0.1:6379` が存在すること
- `0.0.0.0` / `[::]` の 8080 / 6379 が **存在しないこと**
- Nginx active、TCP 443 あり、TCP 80 なし
- header なし / 不正 header は 403、正しい header は 200 かつ `status` が `UP`

`configure-origin.sh` はどちらを使うかを `ORIGIN_SMOKE_MODE`（`standalone` | `ecs`）で選択します。
**任意の path は受け付けません**。root で実行される script に caller 由来の実行 path を渡す seam を作らないためです。
未設定時は `standalone` で、既存の On-Demand 動作と完全に同一です。

## HTTPS origin configuration

`configure-origin.sh`はAmazon Linux 2023専用です。rootでNginx packageをidempotentにinstallし、既存設定を退避してから管理対象設定を検証・反映します。`nginx -t`、service activation、listener検証に加え、bundle内の`origin-smoke-check.sh`によるTLS/hostname/header/readiness検証がすべて成功した場合だけ設定をcommitします。途中で失敗した場合は以前の設定とservice状態をbest-effortで復元し、元の検証failure exit codeを維持します。

AWS SSM APIは30秒、systemd操作は30秒、origin smokeは120秒、Nginx package installは10分を上限とし、外部依存やpackage managerを無期限に待機しません。AWS CLI自身にもconnect 10秒/read 20秒のtimeoutを設定します。

次の値だけをnon-secret inputとして渡します。

| 変数 | 内容 |
| --- | --- |
| `ORIGIN_SERVER_NAME` | CloudFrontが接続するorigin DNS hostname |
| `ORIGIN_CERT_FILE` | OS trust storeで検証可能なorigin certificate chainの絶対path |
| `ORIGIN_KEY_FILE` | 対応するunencrypted private keyの絶対path |

private keyはroot所有かつownerだけがread可能でなければなりません。certificate/keyが存在しない、読めない、形式が不正、またはpermissionが広すぎる場合はNginx設定を変更する前に失敗します。self-signed certificateは使用しません。Phase 4C-3の`configure-acme.sh`が作成するstandard Certbot live pathは、この入力contractと互換です。

```bash
export ORIGIN_SERVER_NAME="origin-demo.yoonec.dev"
export ORIGIN_CERT_FILE="/etc/letsencrypt/live/origin-demo.yoonec.dev/fullchain.pem"
export ORIGIN_KEY_FILE="/etc/letsencrypt/live/origin-demo.yoonec.dev/privkey.pem"

sudo --preserve-env=ORIGIN_SERVER_NAME,ORIGIN_CERT_FILE,ORIGIN_KEY_FILE \
  ./configure-origin.sh
```

AWS CLIのRegionがhostで設定されていない場合のみ、non-secretの`AWS_REGION`または`AWS_DEFAULT_REGION`もsudoで引き継ぎます。AWS credentialはEC2 instance roleから取得し、caller環境やcontainerには渡しません。

生成されるNginx contractは次のとおりです。

- `listen 443 ssl`のみを使用し、TCP `80` listenerを作成しない
- TLS 1.2/1.3を許可する
- `server_name`とcertificate/key pathを明示する
- `server_tokens off`を使用する
- `Host`、`X-Forwarded-For`、`X-Forwarded-Proto`をupstreamへ渡す
- `X-Origin-Verify`自体はSpring Bootへ転送しない
- upstreamは常に`http://127.0.0.1:8080`

## Origin verification secret

CloudFront origin requestには`X-Origin-Verify` headerを設定し、NginxはSSM SecureString `/ec-portfolio/demo/origin/verify-token`と完全一致するrequestだけをproxyします。headerがない、または一致しないrequestはHTTP 403です。この制御は、Security Groupでinbound `443`のsourceをAWS-managed CloudFront origin-facing prefix listに限定するnetwork境界と組み合わせるdefense-in-depthです。

tokenは32〜128文字のURL-safe文字（`A-Z`、`a-z`、`0-9`、`_`、`-`）を使用します。command argument、caller environment、repository、stdout/stderrには渡しません。hostのAWS CLIがEC2 instance roleで`--with-decryption`取得し、root-onlyの一時ファイルと次の分離されたruntime configだけに保存します。

```text
/etc/nginx/ec-portfolio-demo/origin-secret.conf  # token照合map、root:root 0600
/etc/nginx/ec-portfolio-demo/origin-server.conf  # server/proxy設定、tokenなし
```

Nginx master configurationもroot-onlyです。`nginx -T`はsecret mapの内容まで標準出力へ展開するため、実行結果をterminal共有、ticket、CI artifact、ログ収集へ載せてはいけません。syntax確認にはscript内の`nginx -t`だけを使用します。

### Origin verification tokenの無停止rotation

CloudFrontのheader変更はedgeへ段階的に伝播するため、伝播中は旧tokenを送るedgeと新tokenを送るedgeが混在します。originが1つのtokenしか受理しない場合、この間の一部requestが403になります。rotation中だけoriginに旧/新の2 tokenを受理させ、CloudFrontが`Deployed`になってから旧tokenを外します。

新tokenがhostへ届く経路は、既存のEC2 instance role権限で読める`/ec-portfolio/demo/origin/verify-token`だけです。そのためSSM parameterを先に新tokenへ更新し、旧tokenは`configure-origin.sh`が前回installした`origin-secret.conf`から引き継ぎます。追加のSSM parameterやIAM変更は不要です。

- `ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true`: SSM token（新）に加え、installed mapのSSM以外のtoken（旧）も受理するmapを生成します。installed mapは本scriptが書く形式だけを受け付け、それ以外の行や3つ目のtokenがあれば失敗します。mapのtokenは最大2つです。
- 未設定または`false`: 従来どおりSSM tokenだけのmapです（出力はrotation導入前とbyte単位で同一）。

`origin-token-rotation-check.sh`は各段階をhost上のrequest（`--resolve <origin>:443:127.0.0.1`、origin-smoke-checkと同じ方式）で検証します。tokenはroot-onlyのcurl config fileで渡し、出力はHTTP statusとSHA-256先頭12文字のfingerprintだけです。

| mode | 検証内容 |
| --- | --- |
| `capture` | 2 token受理中に、SSM以外のtoken（旧）を`/run/ec-portfolio-demo-origin-rotation/`（tmpfs、root 0700/0600）へ退避 |
| `both` | header無し・不正tokenは403、SSM token（新）と旧tokenは200 |
| `new-only` | header無し・不正tokenは403、SSM token（新）は200、旧tokenは403、installed mapはSSM tokenのみ |
| `forget` | 退避した旧tokenを削除 |

順序（各stepの成功がgate）。他secretのrotation手順と混同しないよう、origin tokenのstepは`OR`で始まる名前で呼びます。

| step | 作業 |
| --- | --- |
| `OR1` | Terraform: `/ec-portfolio/demo/origin/verify-token`だけを新tokenへ更新（CloudFrontは旧tokenのまま） |
| `OR2` | `ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true`で`configure-origin.sh`（旧+新を受理） |
| `OR3` | `origin-token-rotation-check.sh capture`、続けて`both` |
| `OR4` | Terraform: CloudFront `X-Origin-Verify`を新tokenへ更新 |
| `OR5` | CloudFront distributionの`Status`が`Deployed`になるまで待機 |
| `OR6` | CloudFront経由のAPI readinessが200であることを確認 |
| `OR7` | 通常の`configure-origin.sh`（新tokenのみ） |
| `OR8` | `origin-token-rotation-check.sh new-only`、成功後に`forget` |

`OR2`と`OR3`のcommand:

```bash
export ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true
sudo --preserve-env=ORIGIN_SERVER_NAME,ORIGIN_CERT_FILE,ORIGIN_KEY_FILE,ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN \
  ./configure-origin.sh
unset ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN
sudo --preserve-env=ORIGIN_SERVER_NAME ./origin-token-rotation-check.sh capture
sudo --preserve-env=ORIGIN_SERVER_NAME ./origin-token-rotation-check.sh both
```

`OR1`の完了後、`OR7`より前に通常modeの`configure-origin.sh`を実行すると、originは新tokenだけを受理し、旧tokenを送るCloudFront edgeからのrequestが403になります。hostを再起動すると退避した旧tokenは消えますが、Nginxのmap（2 token）は維持されます。

## Phase 4C execution order and Terraform prerequisites

実環境では次の順序を変更しません。

1. Phase 4C-2A Terraform apply
2. EC2 instance roleのACME用Route 53 permission利用可能化
3. `configure-acme.sh`によるcertificate発行
4. `configure-origin.sh`によるHTTPS origin設定
5. `origin-smoke-check.sh`によるend-to-end検証
6. CloudFront Phase 4C-2B

Phase 4C-2Aには、少なくとも次のAWS resource/policyが事前に必要です。

- SSM SecureString `/ec-portfolio/demo/origin/verify-token`
- EC2 instance roleから上記parameterのexact ARNだけに許可する`ssm:GetParameter`
- `origin-demo.yoonec.dev`のDNS-01 challengeを更新・確認するために承認されたRoute 53 permission

そのため、承認済みPhase 4C-2A Terraform変更がapplyされる前に`configure-acme.sh`、`configure-origin.sh`、`origin-smoke-check.sh`を実際のAWS hostで実行することはできません。このruntime PRはTerraformを追加・変更せず、必要なruntime/IAM境界の文書化だけを行います。

## Origin smoke check

origin設定後、実際のcertificate hostname verificationとorigin contractを確認します。

```bash
export ORIGIN_SERVER_NAME="origin-demo.yoonec.dev"
sudo --preserve-env=ORIGIN_SERVER_NAME ./origin-smoke-check.sh
```

scriptは`curl --resolve`でhostnameを`127.0.0.1`へ向けますが、OS trust storeによるcertificate chain/SAN検証を迂回しません。正しいtokenはcommand argumentではなくroot-onlyの一時curl configで渡し、終了時に削除します。

検証項目:

- Nginx serviceがactiveでTCP `443` listenerが存在する
- TCP `80` listenerが存在しない
- certificate chainと`ORIGIN_SERVER_NAME`が検証できる
- headerなし/不正headerはHTTP 403
- 正しいheaderのreadinessはHTTP 200かつ`UP`
- API containerのhost bindingは正確に`127.0.0.1:8080`
- Valkey containerにhost publishがない

## Security and approval gate

- public `8080` / `6379`は禁止
- public `80`は禁止し、CloudFront originはHTTPS `443`のみ
- ACME challengeはRoute 53 DNS-01だけを使用し、HTTP-01は禁止
- privileged、host network、Docker socket mountは禁止
- `latest` tagは禁止
- AWS static credential、Route 53 token file、secret file、certificate/private key、`.env`、AWS account IDのcommitは禁止
- Terraform、`user_data`、Security Group、Docker imageは変更しない
- AWS credential/SSO、AWS CLI mutation、Terraform plan/apply/state、EC2接続、DNS変更、証明書発行、ECR pushはこのPhase 4C-3では実行しない

Phase 4Bの実環境deployment contractは維持します。Nginx設定、certificate発行、CloudFront custom header、Security Group連携を実際のAWS環境へ適用する作業は、承認済みPhase 4C順序とArchitecture/PO gateに従ってのみ実施します。
