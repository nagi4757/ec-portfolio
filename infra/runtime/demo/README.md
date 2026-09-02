# AWS Demo Runtime Deployment / HTTPS Origin Bundle

## 目的

このディレクトリは、Amazon Linux 2023のEC2ホストにDemo API Runtimeを構築するためのhost-side deployment bundleです。Phase 4Bで構築したAPI/Valkey runtimeに加え、Phase 4C-1ではCloudFront origin向けのNginx HTTPS reverse proxy foundationを提供します。コードと運用契約だけを扱い、このPRではAWSへの接続、EC2操作、証明書発行、ECR push、Terraform操作を行いません。

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

## HTTPS origin configuration

`configure-origin.sh`はAmazon Linux 2023専用です。rootでNginx packageをidempotentにinstallし、既存設定を退避してから管理対象設定を検証・反映します。`nginx -t`、service activation、listener検証に加え、bundle内の`origin-smoke-check.sh`によるTLS/hostname/header/readiness検証がすべて成功した場合だけ設定をcommitします。途中で失敗した場合は以前の設定とservice状態をbest-effortで復元し、元の検証failure exit codeを維持します。

AWS SSM APIは30秒、systemd操作は30秒、origin smokeは120秒、Nginx package installは10分を上限とし、外部依存やpackage managerを無期限に待機しません。AWS CLI自身にもconnect 10秒/read 20秒のtimeoutを設定します。

次の値だけをnon-secret inputとして渡します。

| 変数 | 内容 |
| --- | --- |
| `ORIGIN_SERVER_NAME` | CloudFrontが接続するorigin DNS hostname |
| `ORIGIN_CERT_FILE` | OS trust storeで検証可能なorigin certificate chainの絶対path |
| `ORIGIN_KEY_FILE` | 対応するunencrypted private keyの絶対path |

private keyはroot所有かつownerだけがread可能でなければなりません。certificate/keyが存在しない、読めない、形式が不正、またはpermissionが広すぎる場合はNginx設定を変更する前に失敗します。self-signed certificateは使用しません。certificateの発行、配置、renewal方式はPhase 4C TLS Architecture Decisionの責務であり、このbundleはsourceに依存しません。

```bash
export ORIGIN_SERVER_NAME="origin.demo.example.com"
export ORIGIN_CERT_FILE="/etc/pki/tls/certs/origin-fullchain.pem"
export ORIGIN_KEY_FILE="/etc/pki/tls/private/origin.key"

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

## Phase 4C-2 Terraform prerequisites

現在のrepository/mainには、次のAWS resource/policyがまだ実装されていません。

- SSM SecureString `/ec-portfolio/demo/origin/verify-token`
- EC2 instance roleから上記parameterのexact ARNだけに許可する`ssm:GetParameter`

そのため、承認済みPhase 4C-2 Terraform変更がapplyされる前に`configure-origin.sh`または`origin-smoke-check.sh`を実際のAWS hostで実行することはできません。このruntime PRはTerraformを追加・変更せず、必要なruntime/IAM境界の文書化だけを行います。

## Origin smoke check

origin設定後、実際のcertificate hostname verificationとorigin contractを確認します。

```bash
export ORIGIN_SERVER_NAME="origin.demo.example.com"
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
- privileged、host network、Docker socket mountは禁止
- `latest` tagは禁止
- secret file、certificate private key、`.env`、AWS account IDのcommitは禁止
- Terraform、`user_data`、Security Group、Docker imageは変更しない
- AWS credential/SSO、AWS CLI mutation、Terraform plan/apply/state、EC2接続、証明書発行、ECR pushはこのPhase 4C-1では実行しない

Phase 4Bの実環境deployment contractは維持します。Nginx設定、certificate配置、CloudFront custom header、Security Group連携を実際のAWS環境へ適用する作業は、Phase 4CのTLS Architecture DecisionとArchitecture/PO gateの後にのみ実施します。
