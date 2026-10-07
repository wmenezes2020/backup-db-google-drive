# Backup de bancos MySQL para o Google Drive

Você aponta um arquivo com as credenciais. Ele faz o dump de cada banco, um por
um, confere cada dump, e manda para o seu Google Drive.

```bash
./backup-db.sh credentials.json
```

## Três passos

**1. Baixe o script e dê permissão de execução**

```bash
curl -fsSLO https://raw.githubusercontent.com/wmenezes2020/backup-db-google-drive/main/backup-db.sh
chmod +x backup-db.sh
```

**2. Monte o seu credentials.json**

```bash
curl -fsSLO https://raw.githubusercontent.com/wmenezes2020/backup-db-google-drive/main/credentials.exemplo.json
cp credentials.exemplo.json credentials.json
chmod 600 credentials.json
```

Depois edite. O formato é este:

```json
{
  "servidor_padrao": "db.exemplo.com",
  "drive_pasta": "BACKUP-BANCOS",
  "bancos": [
    { "nome": "loja", "porta": 3306, "banco": "loja_producao",
      "usuario": "loja", "senha": "..." },
    { "nome": "blog", "porta": 3307, "banco": "blog",
      "usuario": "blog", "senha": "..." }
  ]
}
```

**3. Ligue o Drive e rode**

```bash
./backup-db.sh --conectar
./backup-db.sh credentials.json --simular
./backup-db.sh credentials.json
```

O `--conectar` mostra um link. Você abre no navegador, escolhe a conta Google,
clica em Permitir, copia a URL em que o navegador caiu e cola de volta.

A página vai dizer que não conseguiu acessar `127.0.0.1`. **Isso é o esperado.**
O endereço dela é a sua resposta. Copie a barra de endereço inteira.

Não precisa criar projeto no Google Cloud, nem chave, nem cartão de crédito.

## Teste antes de confiar

```bash
./backup-db.sh credentials.json --simular
```

Isso conecta em cada banco e diz, em segundos:

```
==> Testando a conexao de cada banco
  ok loja: 42 tabela(s), 1.2 GB, nivel completo
  ok blog: 11 tabela(s), 180.4 MB, nivel sem rotina e evento
  !! blog: o usuario nao tem privilegio para tudo, o dump vai sair no nivel 'sem rotina e evento'
  xx relatorios: nao consegui conectar em db.exemplo.com:3310 como relatorios
  !! antigo: 3 tabela(s) MyISAM. Com --single-transaction o dump NAO fica
     consistente para elas: MyISAM nao tem transacao.

  NOME        BANCO            SERVIDOR               TABELAS   TAMANHO NIVEL
  ---------------------------------------------------------------------------
  loja        loja_producao    db.exemplo.com:3306         42    1.2 GB completo
  blog        blog             db.exemplo.com:3307         11  180.4 MB sem rotina e evento
```

Credencial errada aparece aqui, em segundos, em vez de aparecer depois de uma
hora de dump.

## Três coisas que ele não deixa passar

**Dump que parou no meio.** O `mysqldump` escreve `-- Dump completed on ...` na
última linha. Dump sem essa marca é dump interrompido, e é o pior defeito que
existe: o arquivo abre, tem tabelas dentro, tem cara de backup bom, e não
restaura. O script confere a marca e **apaga** o arquivo em vez de subir.

**Banco com tabela e dump sem tabela.** Se o banco tem 42 tabelas e o dump saiu
com nenhuma, é falha de privilégio, não backup. Ele compara os dois números.

**Nome repetido no seu arquivo.** Se dois bancos tiverem o mesmo `nome`, um
sobrescreveria o outro no Drive e você acharia que tem duas cópias tendo uma. O
script para e diz qual nome está repetido.

Esse último acontece de verdade: é comum o mesmo nome de banco existir em portas
diferentes, uma por cliente. Nesse caso o `nome` é o que separa.

## Histórico é o padrão

Cada execução vai para uma pasta própria:

```
BACKUP-BANCOS/
  2026-10-07_0300/
    loja.sql.gz
    blog.sql.gz
  2026-10-08_0300/
    loja.sql.gz
    blog.sql.gz
  _relatorios/
```

Isso é diferente do que a maioria dos scripts faz, e é de propósito: um dump
ruim sobrescrevendo o único dump bom é como se perde um banco de dados. Se você
quer o comportamento de substituir, use `--sem-data`.

Para não encher o Drive, diga quantas datas guardar:

```bash
./backup-db.sh credentials.json --manter 30
```

## Se parar no meio, rode o mesmo comando outra vez

```bash
./backup-db.sh credentials.json
```

Ele percebe que a execução anterior não terminou, **volta para a mesma pasta de
data** e faz só os bancos que faltaram:

```
!! a execucao de 2026-10-07_0300 nao terminou (2h atras). Vou retomar na MESMA
   pasta e fazer so o que faltou.
  ok loja: pulado, ja subiu nesta mesma pasta em 07/10/2026 03:04
```

Passadas 12 horas ele começa um ciclo novo, porque dump de ontem misturado com
dump de hoje na mesma pasta não é retrato de nada. Para forçar um ciclo novo
antes disso, use `--nova`.

## Agendar

Depois de ter conectado uma vez, roda sozinho:

```bash
0 3 * * * /caminho/backup-db.sh /caminho/credentials.json --manter 30 -s >> /var/log/backup-db.log 2>&1
```

## Restaurar um banco

```bash
# 1. baixe do Drive
rclone copy bancos-drive:BACKUP-BANCOS/2026-10-07_0300/loja.sql.gz .

# 2. confira que o arquivo está inteiro
gunzip -t loja.sql.gz

# 3. restaure
gunzip -c loja.sql.gz | mysql -h db.exemplo.com -P 3306 -u loja -p loja_producao
```

Se você usou `--cifrar`:

```bash
gpg --output loja.sql.gz --decrypt loja.sql.gz.gpg
```

Sem a senha não existe como abrir. Perdeu a senha, perdeu o backup.

## A senha nunca aparece na linha de comando

O jeito óbvio de passar senha para o `mysqldump` é `-p...`, e ele mesmo avisa que
isso é inseguro: argumento de linha de comando aparece no `ps` para qualquer
usuário da máquina. Este script grava um arquivo de opções temporário, com
permissão 600, dentro de um diretório que é apagado quando ele termina.

A bateria de testes tem uma verificação só para isso: ela registra todo argumento
que o `mysql` e o `mysqldump` recebem e reprova se qualquer senha aparecer ali, no
log, no registro ou no relatório.

## Proteja o seu credentials.json

```bash
chmod 600 credentials.json
```

O script avisa se o arquivo estiver legível por outros usuários. Ele está no
`.gitignore` deste repositório e **nunca** deve ser commitado.

## Todas as opções

| Opção | O que faz |
|---|---|
| `--drive-pasta P` | Pasta no Drive. Padrão: o `drive_pasta` do arquivo, ou `BACKUP-BANCOS` |
| `--bancos a,b,c` | Só estes, pelo `nome` |
| `--excluir a,b` | Pula estes |
| `--sem-data` | Não guarda histórico: o dump de hoje substitui o de ontem |
| `--manter N` | Guarda as N pastas de data mais novas |
| `--nova` | Começa um ciclo novo mesmo com um interrompido |
| `--janela-horas N` | Execução interrompida há menos de N horas é retomada. Padrão 12 |
| `-z`, `--compressao N` | Nível do gzip, 1 a 9. Padrão 6 |
| `--so-estrutura` | Dump sem nenhuma linha, só a estrutura |
| `--cifrar` | Cifra cada dump com AES256 antes de subir |
| `--senha-arquivo F` | Lê a senha da cifra do arquivo F |
| `--manter-local` | Não apaga o dump local depois de enviar |
| `--forcar` | Ignora o aviso de espaço em disco |
| `--simular` | Só testa e mede. Não gera dump e não envia nada |
| `-s`, `--sim` | Responde sim às perguntas (cron) |
| `--sem-nice` | Prioridade normal de CPU e disco |
| `--registro` | Mostra o que já foi enviado |
| `--estado DIR` | Onde ficam registro, log, relatório e o dump enquanto sobe |
| `--conectar` | Liga o Drive e sai |
| `--reconectar` | Refaz a autorização |
| `--drive-remote N` | Nome do remote no rclone. Padrão `bancos-drive` |
| `--drive-escopo E` | `total` ou `arquivos` |
| `-h`, `--ajuda` | A ajuda do script |

## O que o script precisa na máquina

- `bash` 4 ou mais novo (no macOS, `brew install bash`)
- `mysql` e `mysqldump`, que ele instala sozinho se faltar
- `jq` **ou** um Python 3 de verdade, para ler o JSON
- `rclone`, que ele instala sozinho se faltar
- `curl`, para a autorização do Google
- `gzip`, `gunzip`, `awk`, `sed`, `stat`

```bash
sudo apt-get install -y jq mysql-client
```

## Perguntas que aparecem

**Por que o campo de espaço em disco é do servidor, e não do dump?**
Porque o tamanho do dump só se sabe depois de gerar. O número que aparece é o
`data_length + index_length` do `information_schema`, que é o tamanho em disco no
servidor. Dump comprimido costuma sair bem menor, mas isso depende do conteúdo.

**O que é esse "nível" que aparece em cada banco?**
Usuário de um banco só costuma não ter privilégio para rotina armazenada e para
evento, e aí o `mysqldump` falha **inteiro** em vez de pular aquela parte. Antes
de gastar tempo, o script testa três combinações com um dump sem dados, que é
rápido, e usa a melhor que o usuário consegue. O relatório registra qual foi.

**E tabela MyISAM?**
O script usa `--single-transaction`, que dá um dump consistente para InnoDB
porque abre uma transação. MyISAM não tem transação, então para essas tabelas a
consistência não é garantida: se alguém escrever durante o dump, o retrato sai
misturado. O script conta quantas tabelas MyISAM existem e avisa. A solução de
verdade é converter para InnoDB.

**O script mexe nos meus bancos?**
Não. Ele só lê. `mysqldump` com `--single-transaction` não bloqueia escrita em
InnoDB.

**Posso usar com MariaDB?**
Sim, o cliente e o protocolo são compatíveis. Dumpar MySQL 8 com cliente MariaDB
(ou o contrário) às vezes gera diferenças de sintaxe na restauração, então use um
cliente da mesma família do servidor quando puder.

**Como sei qual leitor de JSON ele usou?**
A tela e o relatório dizem, na linha `LIDO POR`. Isso importa porque o script tem
dois caminhos (`jq` e Python 3), e saber qual rodou faz um problema de leitura ser
diagnosticável em vez de misterioso.

**Por que o Drive não mostra pasta vazia?**
O Google Drive não guarda pasta sem arquivo. Se todos os bancos de uma execução
falharem, a pasta da data não aparece.

## Como validar o script

```bash
bash -n backup-db.sh        # sintaxe
bash scripts/monta-lab.sh   # monta um MySQL e um Drive de mentira
bash scripts/roda-testes.sh # a bateria
```

O laboratório tem os casos que aparecem na vida real: usuário sem privilégio de
rotina, banco vazio, dump que para no meio, tabela MyISAM, credencial errada,
senha com aspa dupla e com barra invertida, e o mesmo banco em três portas.

## Documentos

- [PRD.md](PRD.md): o que o produto faz, e o que ele não faz
- [docs/SDD_BACKUP_DB.md](docs/SDD_BACKUP_DB.md): as decisões e o porquê de cada uma
- [CLAUDE.md](CLAUDE.md): as armadilhas deste código, descobertas na marra
- [graphify-out/graph.html](graphify-out/graph.html): o mapa do repositório

## Projetos irmãos

- [backup-avulso-google-drive](https://github.com/wmenezes2020/backup-avulso-google-drive):
  envia os arquivos de uma pasta para o Google Drive
- [backup-contas-whm](https://github.com/wmenezes2020/backup-contas-whm):
  compacta cada conta cPanel e envia para o Google Drive

## Licença

MIT. Copyright (c) 2026 Wesley Menezes. Veja [LICENSE](LICENSE).
