# PRD: Backup de bancos MySQL para o Google Drive

Autoria: Wesley Menezes
Versão: 1.0.0
Data: 07/10/2026

## 1. Para que serve

Um script que recebe o caminho de um arquivo JSON com credenciais de banco, faz
o dump de cada banco listado, confere cada dump, e envia para uma pasta do Google
Drive.

O usuário é quem administra um punhado de bancos MySQL, muitas vezes um por
cliente, espalhados em portas diferentes do mesmo servidor, e precisa de backup
fora da máquina sem montar infraestrutura para isso.

## 2. Problema que resolve

Fazer `mysqldump` num `for` de shell parece suficiente até a primeira vez que
você precisa restaurar. Os problemas que aparecem:

1. **Dump que parou no meio tem cara de backup bom.** O arquivo existe, abre,
   tem tabelas dentro. Só não restaura. Quem não confere a última linha do dump
   descobre isso no pior dia possível.
2. **Falta de privilégio derruba o dump inteiro.** Usuário de um banco só
   normalmente não tem privilégio para rotina armazenada e para evento, e o
   `mysqldump` falha por completo em vez de pular aquela parte. O script ingênuo
   grava um arquivo de zero byte e segue em frente.
3. **A senha vai na linha de comando.** `mysqldump -p$SENHA` deixa a senha
   visível no `ps` para qualquer usuário da máquina. O próprio `mysqldump`
   avisa, e o aviso é ignorado todo dia.
4. **O dump de hoje sobrescreve o de ontem.** Se o de hoje sair ruim, o bom já
   foi. É assim que se perde um banco de dados tendo backup.
5. **Nome de banco repetido em portas diferentes.** Com um arquivo por nome de
   banco, três clientes com o banco `villas` em três portas geram um arquivo só,
   e dois backups desaparecem em silêncio.
6. **Credencial errada só aparece depois de uma hora.** Sem teste prévio, a
   execução quebra no meio da madrugada.
7. **Ninguém confere se chegou.** Dump que subiu truncado para a nuvem fica lá
   parecendo um dump.

## 3. Entregas

### 3.1 `backup-db.sh`

Script bash único, sem dependência de pacote, sem build, sem instalação.

**Fluxo principal**

| Passo | O que faz |
|---|---|
| 1 | Confere os comandos, e que o arquivo de credencial existe e é legível |
| 2 | Avisa se o arquivo de credencial estiver legível por outros usuários |
| 3 | Lê o JSON e valida cada entrada: nome único, porta numérica, campos presentes |
| 4 | Testa a conexão de **cada** banco, mede tabelas e tamanho, e descobre o nível de privilégio |
| 5 | Conecta o Drive. Na primeira vez, conduz a autorização |
| 6 | Mostra o resumo e pede **uma** confirmação |
| 7 | Para cada banco: dump para gzip, conferência tripla, cifra opcional, envio, conferência no destino, libera o disco |
| 8 | Escreve o relatório, e manda uma cópia dele para o Drive |

**Conferência de cada dump, em uma passada de `gunzip`**

A mesma leitura prova três coisas:

1. **integridade do gzip**, porque o `gunzip` falha no CRC se o arquivo veio
   truncado ou corrompido;
2. **quantas tabelas** saíram, contando as linhas `CREATE TABLE`;
3. **que o dump terminou**, achando a linha `-- Dump completed on ...` que o
   `mysqldump` escreve por último.

Falhar em qualquer uma faz o arquivo ser **apagado**, não enviado. Guardar dump
ruim é pior que não ter dump, porque ele ocupa o lugar do bom no inventário.

Além disso, o número de tabelas do dump é comparado com o do
`information_schema`: zero contra algo é falha, menos contra mais é aviso.

**Nível de privilégio, descoberto antes de gastar tempo**

Três combinações, testadas com um dump sem dados, que é rápido:

| Nível | Flags |
|---|---|
| completo | `--routines --events --triggers` |
| sem rotina e evento | `--triggers` |
| mínimo | nenhuma das três |

O nível escolhido aparece na tela e no relatório. Sem isso, um usuário sem
privilégio de rotina produziria falha total do dump, e o motivo ficaria escondido
no log do MySQL.

No MySQL 8, `--no-tablespaces` entra sempre que o `mysqldump` o suporta: sem ele,
o servidor exige o privilégio `PROCESS` só para ler tablespace, e usuário de um
banco só não tem.

**Nenhuma senha na linha de comando**

A credencial vai para o `mysql` e para o `mysqldump` por `--defaults-extra-file`,
num arquivo de opções temporário com permissão 600, dentro de um diretório que é
apagado na saída do script. Barra invertida e aspa dupla são escapadas, que são
os dois únicos caracteres com significado especial nesse arquivo.

A senha também não entra no log, no registro, no relatório, nem na mensagem de
erro.

**Histórico por data é o padrão**

Cada execução grava em `<pasta>/AAAA-MM-DD_HHMM/<nome>.sql.gz`. `--sem-data` muda
para o comportamento de substituir, e `--manter N` apaga as datas mais antigas.

**Retomada automática**

Se a execução não terminar, a seguinte percebe, **volta para a mesma pasta de
data** e faz só os bancos que faltaram. Passada a janela (12 horas por padrão),
começa um ciclo novo, porque dump de ontem misturado com dump de hoje na mesma
pasta não é retrato de nada.

**Filtros e extras**

`--bancos`, `--excluir`, `--simular`, `--so-estrutura`, `--cifrar`,
`--manter-local`, `--forcar`, `--registro`, `--estado`, `--nova`,
`--janela-horas`, `--compressao`, `--conectar`, `--reconectar`.

### 3.2 `credentials.exemplo.json`

O formato documentado, com valores falsos, versionado. O arquivo real
(`credentials.json`) está no `.gitignore` desde o primeiro commit.

### 3.3 Bateria de testes

`scripts/monta-lab.sh` monta um MySQL de mentira que reproduz os defeitos reais
(usuário sem privilégio de rotina, usuário sem privilégio nenhum, banco vazio,
banco que existe e devolve dump sem tabela, dump que para no meio, tabela MyISAM,
credencial que não conecta, o mesmo banco em três portas, senha com aspa dupla e
senha com barra invertida) e um Google Drive de mentira que é uma pasta em disco,
com modo de sabotagem para entregar arquivo cortado e para devolver hash errado.

Os stubs registram todo argumento que recebem, e a bateria reprova se qualquer
senha aparecer ali.

### 3.4 Documentação

`README.md` no padrão de três passos, `PRD.md`, `docs/SDD_BACKUP_DB.md`,
`CLAUDE.md` com as armadilhas, e o grafo do repositório em `graphify-out/`.

## 4. Fora de escopo

- **Não restaura.** A volta é pelo `rclone copy` mais `gunzip -c | mysql`, que o
  relatório escreve pronto. Restauração automática é onde um erro apaga produção.
- **Não altera nenhum banco.** Em nenhuma circunstância, com nenhuma opção.
- **Não faz backup binário nem incremental.** Não é `xtrabackup` nem snapshot de
  volume. É dump lógico, que é o que restaura em qualquer servidor.
- **Não cuida de PostgreSQL, MongoDB ou SQL Server.** Só MySQL e MariaDB.
- **Não roda como serviço.** É um comando que começa e termina, e o cron resolve
  a repetição.
- **Não gerencia a chave da cifra.** Quem usa `--cifrar` guarda a senha. Sem
  ela, o backup não volta.

## 5. Decisões de produto e o porquê

**Histórico por data é o padrão, ao contrário dos projetos irmãos.**
Nos outros dois (pasta e conta cPanel) o padrão é substituir. Aqui não: um dump
ruim sobrescrevendo o único dump bom é exatamente como se perde um banco de
dados. Quem quiser o outro comportamento pede com `--sem-data`.

**`--manter` começa em 0, que não apaga nada.**
O padrão seguro é crescer, não apagar. O README e a ajuda dizem para definir
`--manter` ao montar o cron, e a decisão de apagar fica com quem opera.

**O `nome` é obrigatoriamente único, e o script para se houver repetido.**
Parar é melhor que avisar. Um aviso no meio de dez bancos passa batido, e o
resultado é um backup que não existe sem ninguém saber.

**O teste de conexão roda sempre, mesmo no backup de verdade.**
Ele custa segundos e dá o inventário que o relatório precisa. Descobrir credencial
errada depois de uma hora de dump de outro banco é desperdício.

**Dump que falha na conferência é apagado, não guardado.**
Arquivo ruim no disco vira arquivo ruim no Drive na próxima tentativa de alguém,
ou pior, vira o arquivo que alguém tenta restaurar.

**A conferência é uma passada só.**
Gzip, contagem de tabelas e marca de fim saem da mesma leitura. Em dump de
gigabytes, três leituras seriam três vezes o tempo pela mesma garantia.

**Autorização do Google pela chave embutida do rclone.**
Sem projeto no Google Cloud, sem faturamento, sem tela de verificação. O token
gravado sai sem `client_id` e sem `client_secret`, para o rclone renovar o acesso
com a chave dele mesmo.

**O script é ASCII puro.**
Para não depender do locale do servidor. Os documentos em Markdown usam acento
normal.

## 6. Validação feita nesta entrega

```
bash -n backup-db.sh          sintaxe: ok
bash scripts/monta-lab.sh     lab montado
bash scripts/roda-testes.sh   28 casos, 93 verificações, 0 reprovadas
```

### 6.1 O que a bateria cobre

| Caso | O que prova |
|---|---|
| T01 | `--simular` lê os 10 bancos, mede tabelas e tamanho, descobre os três níveis de privilégio, aponta a credencial que não conecta, avisa MyISAM e banco sem tabela visível, sai com 2 e não cria nada no Drive |
| T01b | Nenhuma das 7 senhas aparece na linha de comando do `mysql` ou do `mysqldump`. Senha com aspa dupla e senha com barra invertida atravessam o arquivo de opções e conectam |
| T02 | Recusa nome repetido, porta que não é número, nome de banco com caractere estranho, banco sem servidor, JSON quebrado e arquivo inexistente |
| T02b | Sem `nome`, o padrão `<banco>-<porta>` não colide quando o mesmo banco está em duas portas |
| T02c | Um `credentials.json` salvo com fim de linha do Windows: nenhuma senha chega com retorno de carro colado no fim |
| T03 | Backup completo com pasta de data por padrão. Os 7 bancos saudáveis sobem; o truncado, o de dump vazio e o sem conexão não sobem |
| T03b | O mesmo banco em três portas gera três arquivos distintos |
| T04 | O dump no Drive passa no `gunzip -t`, tem as tabelas, tem dados e termina com a marca de completo |
| T05 | Dump sem a marca de `Dump completed` é recusado, apagado, e não sobra no disco local |
| T05b | Banco com 5 tabelas e dump com nenhuma é recusado |
| T06 | Nenhuma senha em log, registro, relatório local, relatório enviado ou linha de comando |
| T06b | Nenhum arquivo de opções do MySQL sobra na máquina depois da execução |
| T07 | Relatório com contagem, nível de privilégio usado, conferência e instrução de restauração. Sobe para `_relatorios` |
| T07b | A cópia local do dump é liberada depois de conferida, e `--manter-local` a guarda |
| T08 | Retomada: percebe a execução interrompida, volta para a mesma pasta de data e pula o que já subiu |
| T08b | `--nova` começa uma pasta nova |
| T08c | Execução mais velha que a janela vira ciclo novo e não grava na pasta velha |
| T08d | Ciclo que termina sem falha apaga a marca de retomada |
| T09 | `--sem-data` grava na raiz e não cria pasta de data. `--manter` sem histórico é recusado |
| T09b | `--manter` apaga a data mais antiga e guarda as N mais novas |
| T10 | `--bancos`, `--excluir`, e `--so-estrutura` levando estrutura sem nenhuma linha |
| T11 | `--registro` lista o que subiu e diz onde o registro mora |
| T12 | Arquivo que chega cortado no Drive é pego pelo tamanho |
| T13 | Conteúdo trocado com o tamanho certo é pego pelo MD5 |
| T14 | Sem conexão e sem terminal, diz que a primeira autorização pede terminal e ensina `--conectar` |
| T15 | O `rclone.conf` ganha a seção nova sem perder a que já existia, e sem `client_id` nem `client_secret` |
| T16 | Avisa quando o arquivo de credencial está legível por outros usuários |
| T17 | A trava recusa duas execuções ao mesmo tempo |

### 6.2 Resultado

**28 casos, 93 verificações, 0 reprovadas.** Duas verificações puladas nesta
máquina, com o motivo registrado na seção 6.3: permissão POSIX e `flock`.

### 6.3 O que NÃO foi verificado, e por quê

| Item | Por que | Como fica |
|---|---|---|
| Um servidor MySQL de verdade | A bateria roda contra `mysql` e `mysqldump` de mentira. Eles reproduzem o comportamento que importa (código de saída por falta de privilégio, dump sem a marca de fim, banco inexistente), mas são modelo, não o produto | A primeira execução contra o servidor real continua pendente |
| Permissão 600 | `chmod` não gruda em NTFS pelo MSYS | Não afirmado como verificado |
| Trava com `flock` | Esta máquina não tem `flock` | Verificação pulada |
| Autorização do Google | Precisa de alguém clicando em Permitir numa tela do Google | Registrado como não testado |
| `--cifrar` | Precisa de `gpg` ou `openssl` com interação de senha | Não coberto pela bateria |
| Dump de vários gigabytes | O lab gera dump de alguns kilobytes | O comportamento com arquivo grande (tempo, pico de disco, `--drive-chunk-size`) não foi medido |

## 7. Próximos passos sugeridos

1. **Conferência de restauração, automática.** Restaurar o dump num banco
   descartável e comparar a contagem de linhas por tabela. Ganho: hoje o script
   prova que o arquivo está íntegro e completo, não que ele restaura. É a única
   garantia que falta, e é a que mais importa.
2. **Dump por tabela quando o banco é grande.** Ganho: falha numa tabela custa
   aquela tabela, não o banco inteiro, e a retomada fica mais fina.
3. **Aviso por e-mail ou webhook ao terminar.** Ganho: backup no cron que falha
   em silêncio é backup que não existe.
4. **Verificação periódica do que está no Drive.** Reler o MD5 de uma amostra e
   comparar com o registro. Ganho: achar corrupção silenciosa antes de precisar.
5. **PostgreSQL.** Mesmo desenho, `pg_dump` em vez de `mysqldump`. Ganho: um
   script só para quem tem os dois.
6. **Suporte a bash 3.2.** Hoje o script exige bash 4 e recusa claramente o 3.2
   do macOS. Ganho: rodar no macOS de fábrica.
7. **Leitor de JSON sem dependência.** Hoje exige `jq` ou Python 3. Ganho: rodar
   em servidor mínimo sem instalar nada. O custo é escrever um analisador de JSON
   em bash, que é onde erro silencioso mora, então isto é um item de roadmap e
   não uma pendência.
