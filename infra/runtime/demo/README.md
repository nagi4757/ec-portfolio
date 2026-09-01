# AWS Demo Runtime Deployment Bundle

## 目的

このディレクトリは、Phase 4B-1でAmazon Linux 2023のEC2ホストにDemo API Runtimeを構築するためのhost-side deployment bundleです。コードと運用契約だけを提供し、このPRではAWSへの接続、EC2操作、ECR push、Terraform操作を行いません。実環境への適用はPhase 4B-2のArchitecture/PO承認後に限定します。

Runtimeの構成は次のとおりです。

```text
EC2 host
├── API container
│   ├── SPRING_PROFILES_ACTIVE=demo
│   └── 127.0.0.1:8080 -> container:8080
└── Valkey container
    └── ec-portfolio-demo private Docker network only
```

APIをpublic `8080`で公開せず、Valkeyもhost portを一切publishしません。Nginx、origin TLS、CloudFrontはPhase 4Cの対象です。そのためPhase 4B時点のAPIはEC2 hostのloopbackからのみ到達できます。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `bootstrap-host.sh` | Dockerのinstall/startと専用network作成 |
| `deploy-api.sh` | ECR pull、SSM secret取得、Valkey/APIの安全な起動・交換 |
| `smoke-check.sh` | secret不要のcontainer、port、readiness検証 |

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

## Security and approval gate

- public `8080` / `6379`は禁止
- privileged、host network、Docker socket mountは禁止
- `latest` tagは禁止
- secret file、`.env`、AWS account IDのcommitは禁止
- Terraform、`user_data`、Security Group、Docker imageは変更しない
- AWS credential/SSO、AWS CLI mutation、Terraform plan/apply/state、EC2接続、ECR pushはこのPhase 4B-1では実行しない

実際のhost bootstrapとdeploymentは、対象commit、image SHA、AWS identity/Region、RDS endpoint、CORS origin、maintenance windowをArchitecture/POが確認したPhase 4B-2 gateの後にのみ実施します。
