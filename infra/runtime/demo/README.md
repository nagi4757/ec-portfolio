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
| `smoke-check.sh` | secret不要のcontainer、port、readiness検証 |
| `configure-origin.sh` | Nginx install、TLS origin設定、SSM origin verification設定 |
| `origin-smoke-check.sh` | HTTPS、証明書、origin verification、非公開portの検証 |
| `configure-acme.sh` | Certbot/Route 53 DNS-01によるorigin certificate発行とrenewal timer設定 |
| `renew-origin-cert.sh` | 対象certificateだけを更新し、変更時にNginxを安全にreload |
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

Phase 4C-2AのTerraformがapplyされ、EC2 instance roleに承認済みRoute 53 ACME permissionが付与された後、連絡可能なACME emailだけを渡して実行します。

```bash
export ACME_EMAIL="operator@example.com"
sudo --preserve-env=ACME_EMAIL ./configure-acme.sh
```

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
