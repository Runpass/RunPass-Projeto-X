# Deploy em DEV: roteiro com comandos

Estado: **roteiro preparado, nada executado**. Cada passo marcado com "CRIA" cria recurso real na conta DEV e só roda com a **autorização explícita dos dois responsáveis**, registrada no `PDLC/M4/S09-integracao-dev.md`. Sem ela, pare no passo 3. Região `sa-east-1`, conta DEV `263097734277`, perfil `runpass-dev-sa`.

Regras: nenhum valor secreto vai para arquivo, Git, chat ou histórico do shell. Os e-mails de alerta não são versionados. Dados sintéticos. Parar e pedir nova aprovação se a previsão do change set ou o custo observado indicar ultrapassagem do teto (ver `PDLC/M4/ORCAMENTO-RunPass-DEV.md`).

## 0. Conferir identidade e variáveis (só leitura)

```sh
export AWS_PROFILE=runpass-dev-sa AWS_REGION=sa-east-1
aws sts get-caller-identity --query Arn --output text   # deve ser user/runpass-dev-thiago ou o do Rafael, nunca root
ACCOUNT=263097734277
BUCKET=runpass-dev-artifacts-$ACCOUNT
```

## 1. Pacote da Lambda (local, sem AWS)

```sh
make check mobile-check      # verde no commit que será implantado
make lambda-package          # build/lambda/runpass-lambda.zip, python3.12/arm64
SHA=$(shasum -a 256 build/lambda/runpass-lambda.zip | cut -c1-16)
KEY=lambda/runpass-$SHA.zip  # chave imutável por build; o template referencia a chave, não a versão do objeto
```

Registrar o SHA-256 completo e o commit no relatório da S09.

## 2. Revisão dos change sets (leitura e validação, sem criar nada)

```sh
for t in identity.template.json data.template.yaml app.template.yaml; do
  aws cloudformation validate-template --template-body file://infra/$t --query Capabilities
done
```

## 3. Bucket de artefatos (CRIA)

```sh
aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint=sa-east-1
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
```

## 4. Chaves no SSM Parameter Store (CRIA)

O nome do parâmetro **precisa começar com `/`**, porque a política IAM do `app.template.yaml` monta o ARN como `parameter${Nome}`. O valor é gerado e enviado pelo pipe, sem aparecer na tela, em arquivo ou no histórico.

```sh
python3 -c "import secrets,sys; sys.stdout.write(secrets.token_hex(32))" |
  aws ssm put-parameter --name /runpass/dev/erasure-hmac --type SecureString --value file:///dev/stdin
.venv/bin/python -c "from cryptography.fernet import Fernet; import sys; sys.stdout.write(Fernet.generate_key().decode())" |
  aws ssm put-parameter --name /runpass/dev/cursor-key --type SecureString --value file:///dev/stdin
```

HMAC das exclusões: texto de 64 caracteres (o código exige pelo menos 32 bytes). Chave dos cursores: chave Fernet (32 bytes em base64url). Não rodar duas vezes com `--overwrite` depois de haver dados: trocar a chave invalida cursores e o controle de exclusões.

## 5. Envio do artefato (CRIA)

```sh
aws s3 cp build/lambda/runpass-lambda.zip "s3://$BUCKET/$KEY"
```

## 6. Stack de identidade (CRIA)

```sh
aws cloudformation create-change-set --stack-name runpass-dev-identity --change-set-name inicial \
  --change-set-type CREATE --template-body file://infra/identity.template.json \
  --parameters ParameterKey=Environment,ParameterValue=dev
aws cloudformation describe-change-set --stack-name runpass-dev-identity --change-set-name inicial
```

Criar o change set cria a stack vazia em `REVIEW_IN_PROGRESS`. **Revisar com a outra pessoa e só então:**

```sh
aws cloudformation execute-change-set --stack-name runpass-dev-identity --change-set-name inicial
aws cloudformation wait stack-create-complete --stack-name runpass-dev-identity
POOL=$(aws cloudformation describe-stacks --stack-name runpass-dev-identity --query "Stacks[0].Outputs[?OutputKey=='RunnerPool'].OutputValue" --output text)
CLIENT=$(aws cloudformation describe-stacks --stack-name runpass-dev-identity --query "Stacks[0].Outputs[?OutputKey=='RunnerClient'].OutputValue" --output text)
```

## 7. Stack de dados (CRIA)

Os e-mails de alerta vêm de variáveis digitadas na hora, nunca de arquivo versionado (ver a memória do projeto e o `docs/operadores.md`).

```sh
read -r E1; read -r E2; read -r E3; read -r E4      # um endereço por linha
aws cloudformation create-change-set --stack-name runpass-dev-data --change-set-name inicial \
  --change-set-type CREATE --template-body file://infra/data.template.yaml \
  --parameters ParameterKey=Environment,ParameterValue=dev \
    ParameterKey=AlertEmail1,ParameterValue="$E1" ParameterKey=AlertEmail2,ParameterValue="$E2" \
    ParameterKey=AlertEmail3,ParameterValue="$E3" ParameterKey=AlertEmail4,ParameterValue="$E4"
aws cloudformation describe-change-set --stack-name runpass-dev-data --change-set-name inicial
```

Revisar e executar como no passo 6. Depois, **cada destinatário confirma o e-mail de assinatura** do SNS. O tópico usa chave KMS própria (CloudWatch não publica em tópico cifrado com `alias/aws/sns`).

## 8. Stack da aplicação (CRIA)

Depende dos exports da stack de dados.

```sh
aws cloudformation create-change-set --stack-name runpass-dev-app --change-set-name inicial \
  --change-set-type CREATE --template-body file://infra/app.template.yaml --capabilities CAPABILITY_IAM \
  --parameters ParameterKey=Environment,ParameterValue=dev ParameterKey=DataStack,ParameterValue=runpass-dev-data \
    ParameterKey=ArtifactBucket,ParameterValue="$BUCKET" ParameterKey=ArtifactKey,ParameterValue="$KEY" \
    ParameterKey=RunnerUserPoolId,ParameterValue="$POOL" ParameterKey=RunnerClientId,ParameterValue="$CLIENT" \
    ParameterKey=ErasureHmacParameter,ParameterValue=/runpass/dev/erasure-hmac \
    ParameterKey=CursorKeyParameter,ParameterValue=/runpass/dev/cursor-key
aws cloudformation describe-change-set --stack-name runpass-dev-app --change-set-name inicial
```

Revisar (erros de permissão `AccessDenied` inesperados contam como falha) e executar como no passo 6. Saída: `ApiUrl`.

## 9. Validação

1. Carga do catálogo sintético (idempotente), pelo caminho do operador com MFA: `scripts/operator_tool.py` (`enroll`, `grant`, `load-catalog`), ver `docs/operadores.md`.
2. Usuário sintético no pool de corredores, token por `aws cognito-idp initiate-auth`, **sem imprimir o token**.
3. `RUNPASS_ACCESS_TOKEN=... python3 scripts/smoke_journey.py --base-url "$APIURL" --max-image-seconds 5`.
4. Testes transversais, carga, restore e relatório: `PDLC/M4/S09-roteiro-e-relatorio.md`.
5. Alarme de teste para provar o recebimento: `aws cloudwatch set-alarm-state --alarm-name <alarme> --state-value ALARM --state-reason teste-de-recebimento`.

## Desfazer

As tabelas têm `DeletionPolicy: Retain`. Para encerrar DEV: excluir as stacks na ordem inversa (app, dados, identidade), esvaziar os buckets versionados e remover as chaves do SSM e o bucket de artefatos. Registrar o custo final no relatório da S09.
