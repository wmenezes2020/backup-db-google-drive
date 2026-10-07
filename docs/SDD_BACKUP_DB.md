# SDD: Backup de bancos MySQL para o Google Drive

Autoria: Wesley Menezes
Versão: 1.0.0
Data: 07/10/2026

## 1. Problema

Um administrador tem um punhado de bancos MySQL, frequentemente um por cliente,
em portas diferentes do mesmo servidor. Ele precisa de backup fora da máquina,
todo dia, sem montar infraestrutura.

O que ele escreve é um `for` com `mysqldump`. Funciona na primeira vez, e os
defeitos só aparecem no dia em que ele precisa restaurar.

## 2. Causas raiz que viraram requisito

### 2.1 Dump que parou no meio tem cara de backup bom

Esse é o defeito central. O arquivo existe, tem o tamanho plausível, abre no
`gunzip`, tem `CREATE TABLE` dentro. Só não restaura, porque metade das tabelas
não está lá.

O `mysqldump` escreve `-- Dump completed on ...` como última linha, e só escreve
se terminou. Quem não confere isso não tem backup, tem um arquivo.

Requisito: nenhum dump é enviado sem a marca de fim, e dump sem a marca é
**apagado**, não guardado. Guardar arquivo ruim é pior que não ter: ele ocupa o
lugar do bom no inventário e alguém vai tentar restaurar a partir dele.

### 2.2 Falta de privilégio derruba o dump inteiro

Usuário de um banco só normalmente não tem privilégio para rotina armazenada nem
para evento. O `mysqldump` com `--routines --events` não pula essa parte: ele
**falha por completo**, com código de saída diferente de zero, e o script ingênuo
grava um arquivo truncado e segue.

No MySQL 8 tem outro: ler tablespace exige o privilégio `PROCESS`, que usuário de
um banco só não tem, e o `mysqldump` falha com "Access denied; you need (at least
one of) the PROCESS privilege(s)". A solução é `--no-tablespaces`, que não existe
nas versões antigas do cliente.

Requisito: descobrir o que o usuário consegue ANTES de gastar tempo, e dizer qual
nível foi usado.

### 2.3 A senha na linha de comando

`mysqldump -p"$SENHA"` deixa a senha visível no `ps` para qualquer usuário da
máquina. O próprio `mysqldump` imprime um aviso sobre isso, e o aviso é ignorado
todo dia.

Requisito: a senha nunca passa por argumento, nem aparece em log, registro,
relatório ou mensagem de erro.

### 2.4 O dump de hoje sobrescrevendo o de ontem

É assim que se perde um banco de dados **tendo** backup: o dump de hoje sai ruim,
sobrescreve o único dump bom, e ninguém olha até precisar.

Requisito: histórico por data é o padrão, e apagar o histórico é uma escolha
explícita.

### 2.5 O mesmo nome de banco em portas diferentes

Com um arquivo nomeado pelo banco, três clientes com o banco `villas` em três
portas geram um arquivo só. Dois backups desaparecem em silêncio, e o inventário
diz que existem três.

Requisito: o nome do arquivo é um campo próprio, obrigatoriamente único, e nome
repetido **para** a execução.

### 2.6 Credencial errada que só aparece depois de uma hora

Sem teste prévio, a execução quebra no meio da madrugada, no banco 7 de 10,
depois de uma hora de dump dos seis primeiros.

Requisito: testar a conexão de todos os bancos antes de dumpar qualquer um.

### 2.7 Envio sem conferência não é backup

Dump que subiu truncado para a nuvem fica lá parecendo um dump.

Requisito: nada é contado como enviado sem conferência no destino.

## 3. Objetivo

Um script bash único, sem dependência de pacote, que receba o caminho de um JSON
com credenciais e:

1. valide o arquivo e recuse o que não serve, com a razão;
2. teste a conexão de cada banco e meça tabelas e tamanho;
3. descubra o nível de privilégio de cada usuário;
4. faça o dump de um banco por vez, direto para gzip;
5. confira cada dump: integridade, contagem de tabelas e marca de fim;
6. envie e confira no destino;
7. consiga ser rodado de novo e continuar de onde parou;
8. escreva um relatório, sem nenhuma senha dentro.

Critério de conclusão: a bateria verde contra um MySQL de mentira que reproduz os
defeitos das seções 2.1, 2.2, 2.5 e 2.6, com uma verificação dedicada a provar
que nenhuma senha vazou.

## 4. Solução

### 4.1 O formato do arquivo de credencial

```json
{
  "servidor_padrao": "db.exemplo.com",
  "drive_pasta": "BACKUP-BANCOS",
  "bancos": [
    { "nome": "loja", "porta": 3306, "banco": "loja_producao",
      "usuario": "loja", "senha": "..." }
  ]
}
```

`nome` é o nome do arquivo no Drive, e é a resposta para a seção 2.5. Sem ele o
padrão é `<banco>-<porta>`, que também não colide. Nome repetido para a execução
em vez de avisar: aviso no meio de dez bancos passa batido, e o resultado é um
backup que não existe sem ninguém saber.

`servidor` é opcional por banco, e cai no `servidor_padrao`. Isso cobre o caso
comum, que é um servidor com muitas portas.

### 4.2 O leitor de JSON, e o separador de campo

JSON com um vetor de objetos não se lê com `sed` sem errar. O script usa `jq`
quando existe, e um Python 3 quando não. Os dois emitem uma linha por banco.

**O separador não é tabulação, e isso é deliberado.**

Tabulação é "espaço em branco" para o `IFS` do shell, e espaço em branco no `IFS`
tem uma regra que não se vê lendo o código: sequências dele são **colapsadas**.
Um campo vazio no meio da linha desaparece, e todos os campos seguintes andam uma
casa para a esquerda.

Medido aqui, com `IFS=$'\t'`:

```
linha:  x <vazio> 3306 loja loja senha
leu:    nome=x  serv=3306  porta=loja  banco=loja  usuario=senha  senha=<vazio>
```

O script tentaria conectar num servidor chamado como a porta, usando a senha como
nome de usuário. Não é uma falha limpa: é uma falha confusa, e numa disposição
diferente de campos poderia levar a credencial de um banco para outro lugar.

O separador de unidade (`0x1f`) não é espaço em branco para o `IFS`, então cada
ocorrência delimita um campo e campo vazio é preservado. De quebra, senha com
tabulação dentro passa a funcionar.

### 4.3 Retorno de carro, a causa e a defesa

A saída padrão do Python no Windows traduz `\n` para `\r\n`. Com o campo da senha
sendo o último da linha, esse `\r` colava no fim da senha, e o MySQL respondia
`Access denied` por causa de um caractere invisível. Nove de dez bancos falhavam,
e a mensagem não dizia nada sobre a causa.

Duas correções, de propósito:

1. **a causa:** o leitor pede saída sem tradução de fim de linha;
2. **a defesa:** o script tira todo `\r` da saída antes de usar qualquer valor.

A segunda existe porque ela vale para qualquer leitor que entre depois, e porque
custa uma linha. O teste de regressão é um `credentials.json` salvo com fim de
linha do Windows, que é o que acontece quando alguém edita o arquivo no Notepad.

### 4.4 A senha vai por arquivo de opções, nunca por argumento

Para cada banco o script escreve um arquivo temporário:

```
[client]
host="..."
port=3307
user="..."
password="..."
protocol=TCP
```

com permissão 600, dentro de um `mktemp -d` que é apagado na saída do script. O
`mysql` e o `mysqldump` recebem `--defaults-extra-file=` como primeiro argumento,
que é onde eles exigem que ele venha.

**`protocol=TCP` não é decoração.** Com `host=localhost`, o MySQL usa o soquete
local e **ignora a porta**. Num servidor com dez instâncias em dez portas, isso é
o jeito silencioso de fazer backup do banco errado dez vezes.

**O escape é de barra invertida e aspa dupla**, os dois únicos caracteres com
significado especial no arquivo de opções do MySQL, e é feito por expansão do
próprio bash. A primeira versão usava `sed` e nasceu errada: o `sed` recusava a
expressão e devolvia senha vazia, em todos os bancos. Citação de barra invertida
dentro de um `s///` é campo minado, e aqui não há motivo para entrar nele.

### 4.5 O nível de privilégio, descoberto com um dump sem dados

Três combinações, em ordem:

| Nível | Flags extras |
|---|---|
| completo | `--routines --events --triggers` |
| sem rotina e evento | `--triggers` |
| mínimo | nenhuma |

A sonda é `mysqldump <flags> --no-data <banco>`, que exercita exatamente os mesmos
privilégios e é rápida porque não lê linha nenhuma. O nível escolhido fica na tela
e no relatório.

`--no-tablespaces` entra na base sempre que o `mysqldump` o suporta, detectado por
`mysqldump --help`.

### 4.6 A conferência de cada dump, em uma passada

```bash
gunzip -c "$arq" | awk '
  /^CREATE TABLE/      { t++ }
  /^-- Dump completed/ { fim = 1 }
  END { printf "%d %d", t+0, fim+0 }'
```

A mesma leitura prova três coisas:

1. **integridade**, porque o `gunzip` falha no CRC se o arquivo veio truncado;
2. **quantas tabelas** saíram;
3. **que o dump terminou**.

Em dump de gigabytes, fazer `gzip -t`, depois contar, depois procurar a marca
seria três leituras completas pela mesma garantia.

Depois disso, o número de tabelas do dump é comparado com o do
`information_schema`: zero contra algo é **falha**, menos contra mais é **aviso**.

Falhar em qualquer dessas faz o arquivo ser apagado.

### 4.7 Histórico por data é o padrão, ao contrário dos projetos irmãos

Nos irmãos (pasta e conta cPanel) o padrão é substituir. Aqui o padrão é
`<pasta>/AAAA-MM-DD_HHMM/<nome>.sql.gz`, pela razão da seção 2.4.

`--manter N` começa em 0, que não apaga nada. O padrão seguro é crescer: a decisão
de apagar histórico de banco fica com quem opera, e a ajuda diz para definir
`--manter` ao montar o cron.

### 4.8 Retomada automática, sem bandeira

Quando a execução começa, ela grava `execucao-atual` com a pasta de data e o
instante. Quando termina **sem nenhuma falha**, apaga.

Na execução seguinte, se o arquivo existe e tem menos de `--janela-horas` (12 por
padrão), o script volta para a **mesma pasta de data** e pula os bancos que já
subiram. Mais velho que isso, começa um ciclo novo, porque dump de ontem
misturado com dump de hoje na mesma pasta não é retrato de nada.

Não existe bandeira para pedir retomada porque no cron não há ninguém para passar
bandeira. `--nova` força o contrário.

Para decidir pular, o script exige, ao mesmo tempo: linha `ok` no registro, o
destino gravado começando com a pasta **desta** execução, e o arquivo conferido no
Drive com o tamanho certo. O registro sozinho nunca decide: registro apontando
para arquivo apagado à mão viraria um banco pulado sem backup nenhum.

### 4.9 Conferência no destino

Tamanho primeiro, depois o MD5 que o próprio Google Drive guarda e devolve, lido
pelo rclone sem baixar nada. Quando o Drive não devolve hash, fica só o tamanho, e
o relatório registra isso. Dizer "conferido" sem dizer como dá mais confiança do
que a pessoa tem direito.

### 4.10 Autorização do Drive: um link, e a URL de volta

Igual aos projetos irmãos, e pela mesma razão medida contra a API do Google:

| Tentativa | Resposta do Google |
|---|---|
| `urn:ietf:wg:oauth:2.0:oob` | `Error 400: invalid_request`, "not supported". Desligado em 2022 |
| Fluxo de dispositivo (RFC 8628) | `invalid_client`, "Invalid client type" |

O loopback em `127.0.0.1:53682` é o que sobrou. A página de erro no navegador faz
parte do procedimento, e o texto na tela diz isso antes de a pessoa clicar.

A chave é a que vem embutida no rclone. O token gravado sai sem `client_id` e sem
`client_secret`, para o rclone renovar o acesso com a chave dele mesmo.

### 4.11 Permissão nasce certa

`umask 077` no começo. O registro diz quais bancos existem e onde moram, o
relatório a mesma coisa, o arquivo de opções tem a senha, e o `rclone.conf` tem o
token. Nascer 600 é diferente de nascer 644 e virar 600 no `chmod` de depois:
nesse meio tempo qualquer usuário da máquina leria.

O script também avisa quando o próprio `credentials.json` está legível por outros.

## 5. Não objetivos

- Restaurar. O relatório escreve o comando pronto; a execução é humana, porque é
  onde um erro apaga produção.
- Alterar qualquer banco, com qualquer opção.
- Backup binário ou incremental. É dump lógico.
- PostgreSQL, MongoDB, SQL Server.
- Rodar como serviço. O cron resolve a repetição.
- Gerenciar a chave da cifra.

## 6. Decisões e o porquê

| Decisão | Por quê |
|---|---|
| Separador `0x1f` e não tabulação | Tabulação é espaço em branco no IFS e colapsa campo vazio, deslocando a linha |
| Tirar `\r` de toda a saída do leitor | Um caractere invisível no fim da senha dá "Access denied" sem dizer por quê |
| Escape do `.cnf` em bash, não em `sed` | A versão com `sed` nasceu errada e devolvia senha vazia em todos os bancos |
| `protocol=TCP` sempre | Sem ele, `localhost` usa soquete e ignora a porta: backup do banco errado |
| Sonda de privilégio com `--no-data` | Exercita os mesmos privilégios sem ler linha nenhuma |
| `--no-tablespaces` quando existe | No MySQL 8, ler tablespace exige `PROCESS`, que usuário de um banco só não tem |
| Conferência em uma passada de `gunzip` | Três garantias pelo preço de uma leitura |
| Dump ruim é apagado, não guardado | Arquivo ruim ocupa o lugar do bom no inventário |
| Histórico por data é o padrão | Dump ruim sobrescrevendo o único bom é como se perde um banco tendo backup |
| `--manter` começa em 0 | O padrão seguro é crescer; apagar é escolha de quem opera |
| Nome repetido **para** a execução | Aviso no meio de dez bancos passa batido |
| Teste de conexão sempre, não só no `--simular` | Credencial errada tem que aparecer em segundos |
| Senha por arquivo de opções 600 em `mktemp -d` | `ps` é legível por qualquer usuário |
| Registro nunca decide sozinho | Registro apontando para arquivo apagado viraria banco pulado sem backup |
| Script em ASCII puro | Para não depender do locale do servidor |
| Recusa clara de bash 3.2 | Melhor dizer na primeira linha do que quebrar no meio |

## 7. Validação feita nesta entrega

Os casos estão listados na seção 6.1 do [PRD.md](../PRD.md), e o resultado na
seção "Estado atual" do [CLAUDE.md](../CLAUDE.md).

### 7.1 O que NÃO foi verificado, e por quê

| Item | Por que | Como fica |
|---|---|---|
| Um servidor MySQL de verdade | A bateria roda contra `mysql` e `mysqldump` de mentira, que reproduzem o comportamento que importa, mas são modelo | Primeira execução real pendente |
| O leitor por `jq` | Esta máquina não tem `jq`, então a bateria exercita só o leitor por Python | Registrado como não coberto. Mitigação: um filtro `jq` errado produziria campos fora de ordem, e a validação por campo (porta numérica, nome de banco, nome de arquivo) reprovaria alto em vez de passar em silêncio |
| Permissão 600 | `chmod` não gruda em NTFS pelo MSYS: o `stat` responde 644 no shell que deu o `chmod` e 600 no processo seguinte | Verificação pulada, com sonda que pergunta a um processo novo |
| Trava com `flock` | Esta máquina não tem `flock` | Verificação pulada |
| Autorização do Google | Precisa de alguém clicando em Permitir | Registrado como não testado |
| `--cifrar` | Precisa de `gpg` ou `openssl` com interação de senha | Não coberto |
| Dump de vários gigabytes | O lab gera dump de kilobytes | Tempo, pico de disco e `--drive-chunk-size` não medidos |

### 7.2 Defeitos que a construção pegou

Quatro coisas que estariam em produção se não tivesse teste. As duas primeiras
são as caras:

1. **Separador de tabulação deslocando a linha inteira.** Um campo vazio no meio
   fazia o script ler a porta como servidor e a senha como usuário. Achado porque
   o caso "banco sem servidor" reprovou com a mensagem errada. Corrigido com
   `0x1f`, e aquele caso virou o teste de regressão.
2. **Retorno de carro colado no fim da senha.** O Python no Windows traduz `\n`
   para `\r\n`, e o `\r` entrava no último campo. Nove de dez bancos davam
   "Access denied". Achado comparando o tamanho da senha que o cliente recebia
   com o tamanho real: 19 contra 18.
3. **`escapa_cnf` com `sed` recusando a própria expressão.** Devolvia senha vazia
   em todos os bancos. Trocado por expansão do bash, que também economiza dois
   processos por banco.
4. **`python3` que existe no PATH e não funciona.** No Windows é um atalho da
   Microsoft Store que imprime um recado e **sai com 0**. `command -v` dizia que
   existia. Agora o script testa o interpretador com uma conta antes de confiar
   nele.

E quatro casos em que **o teste estava errado, não o script**: a contagem "7 de
7" quando o certo era "7 de 9", a premissa de que uma execução bem-sucedida
deixaria o que retomar (ela apaga a marca de propósito), uma asserção de retenção
que dependia de a hora virar entre duas execuções, e uma lista de `--excluir`
incompleta.

Registrar isso importa porque a tentação, nos quatro, é mexer no script até o
teste passar.
