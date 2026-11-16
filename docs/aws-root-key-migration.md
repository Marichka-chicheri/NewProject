# Перехід з root-ключа AWS на ключ IAM-користувача `new-project-deployer`

Акаунт `274394226432`. Цей проєкт (`new-project`, Spry) живе в **us-east-1**; ресурси ReadCycle
(`readcycle-*`) — в eu-central-1, їх ніхто не чіпав. Перевірка 2026-11-16, лише читання
(IAM, CloudTrail, Lambda, CloudFormation). В AWS нічого не змінено.

## 1. Де знайдено root-ключ

В акаунті root має **два активні ключі**:

| Ключ (маска) | Створено | Востаннє використано | Де лежить |
|---|---|---|---|
| `AKIA…QV` | 2026-10-07 | **сьогодні 09:12**, cognito-idp, eu-central-1 | `.env` (рядок 17, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`) **і** `~/.aws/credentials` профіль `[default]`: той самий ключ |
| `AKIA…7L` | 2026-09-30 | 2026-09-30 18:32, cloudformation, us-east-1 | у файлах на ноутбуці не знайдено; найімовірніше, у GitHub-секретах (див. питання 1) |

Що використовує `AKIA…QV` (CloudTrail за 90 днів; усі виклики з однієї IP, тобто з ноутбука):

- `make deploy-backend / deploy-frontend / update-lambdas / add-domain / llm-* / parse / report-now`
  — через `.env` (Makefile → `AWS_ENV` → `infra/*.sh`, boto3).
- AWS CLI і boto3 без профілю: `[default]` у `~/.aws/credentials` (Lab 8: Athena, Glue, Kinesis;
  `infra/bootstrap` локально).
- **Terraform проєкту ReadCycle**: сьогодні 09:02–09:12 у eu-central-1 він створював Lambda,
  DynamoDB, S3, API Gateway і ролі `readcycle-*` саме цим root-ключем через `[default]`.
  Це не цей проєкт, але **якщо деактивувати ключ, Terraform ReadCycle на ноутбуці перестане
  працювати**, поки його не перевести на SSO-профіль `readcycle` (див. крок 6).

Де ключа **немає**:

- HCP Terraform (`infra/*.tf`) ходить через OIDC-роль `hcp-terraform-ooad-marichka-chicheri`, без
  ключів (ADR 0007).
- Задеплоєні Lambda (`new-project-backend`, `-agenda-parser`, `-report-builder`,
  `-report-mailer`) працюють зі своїми ролями; в їхніх змінних середовища ключів немає.
- `docker-compose.yml` не передає AWS-ключі в контейнери.
- Змінних середовища `AWS_*` у системі немає. `~/.aws/cli/cache` містить тимчасові `ASIA…`
  токени SSO: це нормально.
- IAM-користувачів в акаунті зараз немає взагалі.

## 2. Які сервіси потрібні проєкту

| Команда | Сервіси / дії | Ресурси |
|---|---|---|
| `make deploy-backend` | CloudFormation deploy (стеки `-ecr`, `-backend`), SSM get/put/tag, ECR login + push, `sts:GetCallerIdentity` | `stack/new-project-*`, `parameter/new-project/*`, `repository/new-project-*` |
| `make update-lambdas` | `lambda:GetFunction`, `UpdateFunctionCode` | `function:new-project-*` |
| `make deploy-frontend` | CloudFormation deploy (`-frontend`), S3 sync, CloudFront invalidation | бакет `new-project-frontend-*`, дистрибуція з тегом `PROJECT_NAME=new-project` |
| `make add-domain` / `remove-domain` | CloudFormation (`-certificate`, `-frontend`), `acm:DescribeCertificate` | `certificate/*` в us-east-1 |
| `make report-now` | `sqs:SendMessage` | `new-project-report-requests` |
| `make llm-* / parse` | Bedrock `InvokeModel` / Converse, `ListFoundationModels`, bedrock-mantle | inference profiles us-east-1, foundation models |
| логи (`aws logs tail`) | `logs:FilterLogEvents`, `GetLogEvents`, `StartLiveTail` | `/new-project/*`, `/aws/lambda/new-project-*` |

Шаблони CloudFormation створюють VPC, підмережі, security groups, Aurora, Lambda + URL, лог-групу,
ECR, S3 + CloudFront, ACM і, за потреби, Route 53. Якщо дати все це самому ключу, вийде майже
адмінська політика. Тому ресурси створює **сервісна роль CloudFormation**, а ключ може лише
передати стек цій ролі.

## 3. Політика (код: `infra/bootstrap/deployer.tf`)

**Користувач `new-project-deployer`** (шлях `/apps/`, без пароля в консоль): inline-політика з
`infra/bootstrap/policies/deployer-user.json.tftpl`. Повний текст у додатку нижче. Коротко:
CloudFormation лише для стеків `new-project-*`, `iam:PassRole` лише на одну роль і лише для
CloudFormation, ECR/Lambda/S3/SSM/SQS/логи лише за іменами `new-project-*`, CloudFront лише за тегом
проєкту. Ключ **не може** створювати IAM-ролі, VPC, бази даних чи будь-що поза проєктом напряму.

**Роль `new-project-cfn-deployer`** (її бере на себе лише CloudFormation, і лише для стеків
`new-project-*` цього акаунта):

- `PowerUserAccess` (керована AWS): усе, що описують шаблони, крім IAM. Короткий ручний список дій
  тут вирішив би менше: пропущена одна дія = деплой падає на півдорозі.
- IAM лише на ролі `new-project-*`, а прикріпити до них можна лише `AWSLambdaBasicExecutionRole` /
  `AWSLambdaVPCAccessExecutionRole` (жодного `AdministratorAccess`).
- **Deny** на все поза `us-east-1` (крім глобальних IAM/CloudFront/Route 53/STS), тобто на
  eu-central-1, де ReadCycle.
- **Deny** на `readcycle-*` (S3, Lambda, DynamoDB, IAM-ролі) і на ролі `AWSReservedSSO_*`.

Чесно про межі: хто має ключ, може задеплоїти довільний шаблон у стек `new-project-*`, тобто
отримати права ролі. Це властиво будь-якому ключу для деплою інфраструктури. Але це значно менше
за root: ні IAM поза проєктом, ні регіону ReadCycle, ні білінгу, ні закриття акаунта, і ключ
можна відкликати.

Перевірено: `terraform validate` — OK; `terraform plan` (`infra/bootstrap`) — **5 to add, 0 to
change, 0 to destroy** (наявна роль HCP не змінюється); IAM Access Analyzer `validate-policy` для
обох політик — лише косметичні SUGGESTION (зайвий ARN `…/*`), без помилок і попереджень.

Зміни в репозиторії (ще не закомічені):

- `infra/bootstrap/deployer.tf`, `infra/bootstrap/policies/deployer-user.json.tftpl`: нові.
- `infra/common.sh`: якщо задано `CFN_ROLE_ARN`, `aws cloudformation deploy` / `delete-stack`
  отримують `--role-arn`. Якщо змінна порожня, усе працює як раніше (перевірено з
  фейковим `aws`).
- `Makefile`: передає `CFN_ROLE_ARN` у скрипти. `.env.example`: нова змінна `CFN_ROLE_ARN`.
- `.github/workflows/deploy.yml`: записує `CFN_ROLE_ARN` у `.env` у CI.

## 4. Інструкція для власниці

> Порядок важливий: спершу роль і користувач (крок 1), потім ключ, потім підстановка, і лише
> потім пуш змін у `main`. Інакше CI спробує роль, якої ще немає.

**Крок 0. Вхід через SSO, не root-ключем.**

```bash
aws sso login --profile readcycle
```

**Крок 1. Створити роль і користувача** (лише IAM; стан локальний у `infra/bootstrap`):

```bash
cd infra/bootstrap
AWS_PROFILE=readcycle terraform plan  -var tfc_organization=ooad-marichka-chicheri
AWS_PROFILE=readcycle terraform apply -var tfc_organization=ooad-marichka-chicheri
terraform output -raw cfn_role_arn   # arn:aws:iam::274394226432:role/new-project-cfn-deployer
```

Очікувано: 5 to add, 0 to change, 0 to destroy. Якщо план хоче змінити чи видалити щось інше,
зупинитися.

*Без Terraform:* IAM → Roles → Create role → AWS service → CloudFormation → назва
`new-project-cfn-deployer`, `PowerUserAccess` + inline-політика з `deployer.tf`; IAM → Users →
Create user `new-project-deployer`, **без** доступу до консолі, inline-політика з додатка.

**Крок 2. Ключ створює власниця.** IAM → Users → `new-project-deployer` → Security credentials →
Create access key → *Command Line Interface (CLI)* → поставити галочку → Create. Секрет
показується один раз: одразу в менеджер паролів, нікуди більше.

**Крок 3. Підставити ключ.** Нічого з цього не зроблено.

| Де | Що змінити |
|---|---|
| `.env` (локально) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` = новий ключ; додати `CFN_ROLE_ARN=arn:aws:iam::274394226432:role/new-project-cfn-deployer` |
| GitHub → репозиторій `NewProject` → Settings → Secrets and variables → Actions | оновити `AWS_ACCESS_KEY_ID` і `AWS_SECRET_ACCESS_KEY` новим ключем |
| `~/.aws/credentials` | **видалити** секцію `[default]` з root-ключем (ключ проєкту живе в `.env`). Для адмінських дій: `--profile readcycle` (SSO). За бажанням додати `[new-project]` з новим ключем для ручних команд |
| HCP Terraform | нічого: там OIDC |

**Крок 4. Перевірка.**

```bash
set -a; . ./.env; set +a
aws sts get-caller-identity --query Arn --output text
```

Очікувано: `arn:aws:iam::274394226432:user/apps/new-project-deployer`, **не** `…:root`.

```bash
aws s3 ls
```

Очікувано: `AccessDenied` (ключ не бачить чужих бакетів; root побачив би все).

```bash
make deploy
```

Деплой бекенду й фронтенду. Без змін у коді CloudFormation відповідає «No changes to deploy», і
команда закінчується перевіркою здоров'я бекенду; фронтенд синхронізується в S3 й робить
інвалідацію. Потім відкрити https://app.mary-meetings.online.

Далі запушити зміни в `main` і перевірити, що GitHub Actions → Deploy зелений.

Через 1–2 дні:

```bash
aws iam get-access-key-last-used --access-key-id <ключ> --profile readcycle
```

Root-ключі не мають з'являтися з датою після переходу.

**Крок 5. Root-ключі (робить лише власниця, вручну).** Root → Security credentials → Access keys:
обидва ключі → **Deactivate**. Через 1–2 тижні без проблем → **Delete**.

**Крок 6. ReadCycle (до деактивації!).** Його Terraform сьогодні працював через `[default]`
(root). Код ReadCycle міняти **не треба**: провайдер не має жорстко заданих ключів, а CI
ReadCycle ходить через OIDC-роль (`vars.AWS_ROLE_ARN`, без ключів). Локально достатньо профілю SSO:

```bash
aws sso login --profile readcycle
export AWS_PROFILE=readcycle          # PowerShell: $env:AWS_PROFILE = "readcycle"
aws sts get-caller-identity --query Arn --output text   # ...assumed-role/AWSReservedSSO_AdministratorAccess_...
cd ReadCycle/infra && terraform init -backend-config="bucket=readcycle-tfstate-274394226432" && terraform plan
```

Перевірено лише читанням: SSO-профіль бачить бакети `readcycle-*` і таблицю блокувань
`readcycle-tf-locks`. Прописувати `profile = "readcycle"` у `versions.tf` не варто: це зламало б
CI, де профілю немає. Після кроку 3 (видалення `[default]`) змінна `AWS_PROFILE` стає
обов'язковою для ReadCycle в кожному новому терміналі (можна додати її в профіль PowerShell).

## 5. Питання до власниці

1. **Що в GitHub-секретах?** `gh` не встановлено, тож я не бачу, який ключ там. За CloudTrail
   жоден root-ключ не викликався з серверів GitHub з 2026-10-07: або деплой у CI падає раніше, або
   в секретах ключ `AKIA…7L` (створений 30.09, у день, коли додано workflow), який з тих пір не
   працював. Чи проходить зараз workflow Deploy?
2. **ReadCycle** зараз деплоїться root-ключем з ноутбука. Перевести його на SSO (крок 6) до
   деактивації? Це вирішує власниця, я його не чіпаю.
3. Ресурси Lab 8 (бакет `lab8-payments-274394226432`, Glue crawler, роль `lab8-glue-crawler`)
   ключ `new-project-deployer` не покриває: для них SSO-профіль. Чи ще потрібні?

Наступний крок, кращий за ключ: CI через GitHub OIDC (роль без довгоживучого ключа, як уже
зроблено для HCP Terraform). Ключ потрібен тоді лише для деплою з ноутбука, а там можна
обійтися SSO.

## Додаток: політика користувача `new-project-deployer`

Згенеровано з `infra/bootstrap/policies/deployer-user.json.tftpl` для `us-east-1`,
`274394226432`, `new-project`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WhoAmI",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "CloudFormationProjectStacks",
      "Effect": "Allow",
      "Action": [
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResource",
        "cloudformation:DescribeStackResources",
        "cloudformation:ListStackResources",
        "cloudformation:GetTemplate",
        "cloudformation:CreateChangeSet",
        "cloudformation:DescribeChangeSet",
        "cloudformation:DescribeChangeSetHooks",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DeleteChangeSet",
        "cloudformation:ListChangeSets",
        "cloudformation:DeleteStack",
        "cloudformation:TagResource"
      ],
      "Resource": [
        "arn:aws:cloudformation:us-east-1:274394226432:stack/new-project-*/*",
        "arn:aws:cloudformation:us-east-1:274394226432:changeSet/*/*"
      ]
    },
    {
      "Sid": "CloudFormationAccountLevelReads",
      "Effect": "Allow",
      "Action": [
        "cloudformation:GetTemplateSummary",
        "cloudformation:ValidateTemplate",
        "cloudformation:ListStacks"
      ],
      "Resource": "*"
    },
    {
      "Sid": "HandStacksToTheServiceRoleOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::274394226432:role/new-project-cfn-deployer",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "cloudformation.amazonaws.com"
        }
      }
    },
    {
      "Sid": "DatabasePasswordParameter",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:PutParameter",
        "ssm:AddTagsToResource"
      ],
      "Resource": "arn:aws:ssm:us-east-1:274394226432:parameter/new-project/*"
    },
    {
      "Sid": "EcrLogin",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushBackendImage",
      "Effect": "Allow",
      "Action": [
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:GetRepositoryPolicy",
        "ecr:SetRepositoryPolicy"
      ],
      "Resource": "arn:aws:ecr:us-east-1:274394226432:repository/new-project-*"
    },
    {
      "Sid": "LambdaImageUpdates",
      "Effect": "Allow",
      "Action": [
        "lambda:GetFunction",
        "lambda:GetFunctionConfiguration",
        "lambda:GetFunctionUrlConfig",
        "lambda:UpdateFunctionCode"
      ],
      "Resource": "arn:aws:lambda:us-east-1:274394226432:function:new-project-*"
    },
    {
      "Sid": "FrontendBucketSync",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::new-project-frontend-*",
        "arn:aws:s3:::new-project-frontend-*/*"
      ]
    },
    {
      "Sid": "FrontendCacheInvalidation",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetInvalidation",
        "cloudfront:GetDistribution"
      ],
      "Resource": "arn:aws:cloudfront::274394226432:distribution/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/PROJECT_NAME": "new-project"
        }
      }
    },
    {
      "Sid": "CustomDomainCertificateStatus",
      "Effect": "Allow",
      "Action": "acm:DescribeCertificate",
      "Resource": "arn:aws:acm:us-east-1:274394226432:certificate/*"
    },
    {
      "Sid": "BackendLogs",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "logs:StartLiveTail"
      ],
      "Resource": [
        "arn:aws:logs:us-east-1:274394226432:log-group:/new-project/*",
        "arn:aws:logs:us-east-1:274394226432:log-group:/aws/lambda/new-project-*"
      ]
    },
    {
      "Sid": "ReportOnDemand",
      "Effect": "Allow",
      "Action": "sqs:SendMessage",
      "Resource": "arn:aws:sqs:us-east-1:274394226432:new-project-*"
    },
    {
      "Sid": "BedrockFromTheLaptop",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:us-east-1:274394226432:inference-profile/*",
        "arn:aws:bedrock:*::foundation-model/*"
      ]
    },
    {
      "Sid": "BedrockListModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModelAvailability",
        "bedrock-mantle:CreateInference",
        "bedrock-mantle:List*",
        "bedrock-mantle:Get*"
      ],
      "Resource": "*"
    }
  ]
}
```
