# CLAUDE.md: Backup de bancos MySQL para o Google Drive

Memória deste repositório. Vale junto do `CLAUDE.md` global do usuário, que tem
precedência onde houver conflito.

## O que é este projeto

Um script bash, `backup-db.sh`, que recebe o caminho de um JSON com credenciais de
banco, faz o dump de cada banco listado, confere cada dump, e envia para uma pasta
do Google Drive pelo rclone, um banco por vez.

Não tem build, não tem dependência de pacote, não tem instalação. A validação é
`bash -n` mais a bateria de testes contra um MySQL e um Google Drive simulados.

**Nenhum banco é alterado.** O script só lê deles.

**Nenhuma senha aparece em linha de comando, log, registro ou relatório.** A
bateria tem uma verificação dedicada a isso, que registra todo argumento que o
`mysql` e o `mysqldump` recebem e reprova se qualquer senha aparecer. Qualquer
mudança que ameace isso é regressão.

**`credentials.json` NUNCA entra no repositório.** Ele está no `.gitignore` desde
o primeiro commit, e o que é versionado é o `credentials.exemplo.json` com valores
falsos. Tirar segredo do histórico depois de publicar não desfaz o que já saiu.

## Passo zero de toda tarefa: o grafo

**Antes de escrever o SDD e antes de tocar no PRD, consultar o grafo do
graphify.** Não é para quando travar: é a primeira coisa, sempre.

```bash
graphify.exe query "<pergunta>"
graphify.exe explain "<coisa>"
graphify.exe path A B
```

Sem grafo no repositório, gerar antes de começar:

```bash
python scripts/gerar-grafo.py
```

**Nunca apagar `graphify-out/`.** Ele é versionado, entra no commit da tarefa, e
está fora de qualquer limpeza de disco.

No Git Bash desta máquina o comando é `graphify.exe`. Sem a extensão o shell acha
o arquivo sem extensão e o Python responde "can't open file", com saída vazia e
código de saída 0, o que parece sucesso.

## Como validar antes de commitar

```bash
bash -n backup-db.sh
bash scripts/monta-lab.sh
bash scripts/roda-testes.sh
```

A bateria leva alguns minutos no MSYS, porque ela roda o script umas trinta vezes
e cada execução abre muitos processos. Rode em segundo plano e leia o resultado.

## Armadilhas deste script, descobertas na marra

**Tabulação como separador de campo DESLOCA a linha inteira quando um campo é
vazio.** Tabulação é espaço em branco para o `IFS` do shell, e espaço em branco no
`IFS` tem uma regra que não se vê lendo o código: sequências dele são colapsadas.
Medido aqui:

```
linha:  x <vazio> 3306 loja loja senha
leu:    nome=x  serv=3306  porta=loja  banco=loja  usuario=senha  senha=<vazio>
```

O script tentaria conectar num servidor chamado como a porta, usando a senha como
nome de usuário. Por isso o separador é `0x1f`, que **não** é espaço em branco
para o `IFS`, e por isso o leitor emite `join("\u001f")` em vez de `@tsv`. O teste
de regressão é o caso "banco sem servidor" (T02 servidor): se ele voltar a
reprovar, confira o separador antes de mexer na validação.

**O Python no Windows traduz `\n` para `\r\n` na saída padrão.** Com o campo da
senha sendo o último da linha, esse `\r` colava no fim da senha e o MySQL
respondia `Access denied` por causa de um caractere invisível. Nove de dez bancos
falhavam. A correção é dupla de propósito: o leitor pede saída sem tradução, **e**
o script tira todo `\r` antes de usar qualquer valor, porque a segunda vale para
qualquer leitor que entre depois. Teste de regressão: T02c, um `credentials.json`
salvo com fim de linha do Windows.

**Comando que existe no PATH não é comando que funciona.** No Windows o `python3`
é um atalho da Microsoft Store: está no PATH, imprime um recado pedindo para
instalar, e **sai com 0**. Quem confia no `command -v` acha que tem Python e
recebe saída vazia com cara de sucesso. É a mesma armadilha do `graphify` sem
`.exe`. Por isso `acha_python` testa o interpretador com uma conta (`print(1+1)`)
antes de confiar nele. Não trocar por `command -v`.

**`escapa_cnf` com `sed` nasceu errada e devolvia senha vazia em TODOS os
bancos.** O `sed` recusava a expressão com "unknown option to `s'" e a saída saía
em branco. Citação de barra invertida dentro de um `s///` é campo minado. Hoje a
troca é por expansão do próprio bash, que também economiza dois processos por
banco. Não voltar para `sed`.

**`protocol=TCP` no arquivo de opções não é decoração.** Com `host=localhost` o
MySQL usa o soquete local e **ignora a porta**. Num servidor com dez instâncias em
dez portas, isso é o jeito silencioso de fazer backup do banco errado dez vezes. O
stub do lab recusa um `.cnf` sem `protocol=TCP` justamente para o teste proteger
isso.

**Falta de privilégio derruba o dump INTEIRO, não pula a parte.** Usuário de um
banco só normalmente não tem privilégio para rotina nem para evento, e o
`mysqldump --routines --events` falha por completo. Por isso existe a escada de
três níveis, sondada com `--no-data`, que exercita os mesmos privilégios sem ler
linha nenhuma.

**No MySQL 8, ler tablespace exige o privilégio `PROCESS`.** Usuário de um banco
só não tem, e o `mysqldump` falha com "Access denied; you need (at least one of)
the PROCESS privilege(s)". `--no-tablespaces` resolve, e ele é detectado por
`mysqldump --help` porque não existe nas versões antigas do cliente.

**Dump que parou no meio tem cara de backup bom.** Abre, tem `CREATE TABLE`
dentro, tem tamanho plausível, e não restaura. A única prova de que ele terminou é
a linha `-- Dump completed on ...` que o `mysqldump` escreve por último. Dump sem
ela é **apagado**, não guardado: arquivo ruim ocupa o lugar do bom no inventário e
alguém vai tentar restaurar a partir dele.

**A conferência é UMA passada de `gunzip`.** A mesma leitura prova integridade (o
`gunzip` falha no CRC), conta as tabelas e acha a marca de fim. Em dump de
gigabytes, fazer `gzip -t`, depois contar, depois procurar a marca seria três
leituras completas pela mesma garantia. Não separar.

**Histórico por data é o PADRÃO aqui, ao contrário dos projetos irmãos.** Nos
irmãos o padrão é substituir. Aqui não: dump ruim sobrescrevendo o único dump bom
é exatamente como se perde um banco de dados tendo backup. E `--manter` começa em
0, que não apaga nada, porque o padrão seguro é crescer.

**Execução que termina sem falha APAGA a marca de retomada, de propósito.** Então
não existe o que retomar depois de um ciclo limpo, e um teste de retomada precisa
de uma primeira execução que falhe. A premissa oposta reprovou quatro verificações
de uma vez, e o script estava certo.

**O registro nunca decide sozinho.** Para pular um banco o script exige, ao mesmo
tempo: linha `ok` no registro, destino começando com a pasta **desta** execução, e
o arquivo conferido no Drive com o tamanho certo. Registro apontando para arquivo
apagado à mão viraria um banco pulado sem backup nenhum.

**Permissão POSIX não gruda em NTFS pelo MSYS, e o `stat` mente.** Ele responde
644 no shell que acabou de dar o `chmod` e 600 no processo seguinte. Por isso a
sonda do teste de permissão pergunta a um processo novo (`bash -c 'stat ...'`), e
pula o caso quando não bate. Conferir no mesmo shell dá verde falso e reprova o
script por um defeito do sistema de arquivo.

**O heredoc desta ferramenta come barra invertida.** Patch e sonda com `\\` dentro
de `<<'EOF'` chegaram alterados e me fizeram medir entrada errada duas vezes. Para
qualquer coisa com barra invertida, escreva um arquivo e rode o arquivo.

**Nome de banco repetido em portas diferentes é o caso normal, não a exceção.** Um
servidor com uma instância por cliente tem o mesmo nome de banco várias vezes. Por
isso o `nome` existe como campo próprio, é obrigatoriamente único, e nome repetido
**para** a execução em vez de avisar: aviso no meio de dez bancos passa batido, e o
resultado é um backup que não existe sem ninguém saber.

**Duas execuções da bateria ao mesmo tempo dão resultado falso.** Elas disputam o
mesmo `.lab/drive`. Uma rodada por vez.

**Teste que falha pode estar errado.** Quatro casos nesta entrega: a contagem "7
de 7" quando o certo era "7 de 9", a premissa de retomada acima, uma asserção de
retenção que dependia de a hora virar entre duas execuções, e uma lista de
`--excluir` incompleta. Confira qual dos dois descreve o comportamento certo antes
de corrigir.

## Regras de ouro que se aplicam aqui

- **Travessão proibido** em tudo que uma pessoa lê: README, PRD, SDD, ajuda do
  script, mensagem de saída. Vale também para meia-risca e sinal de menos.
- **Sem acento no script.** `backup-db.sh` escreve em ASCII, para não depender do
  locale do servidor. Os documentos em Markdown usam acento normal.
- **Nenhuma senha, host real ou nome de cliente em documento versionado.** O
  `credentials.exemplo.json` usa `db.exemplo.com` e senha `troque-esta-senha`.
- **Repositório público:** licença MIT, autoria apenas "Wesley Menezes", nenhuma
  citação interna. As skills versionadas em `.claude/skills/` entram redigidas, e
  o hook de SessionStart pode desfazer a redação: **conferir antes de todo
  commit**.
- **Nunca indicar concorrente.** Recurso que falta vira item do PRD.
- **PRD e SDD na mesma entrega.** Toda mudança de comportamento atualiza `PRD.md`
  e `docs/SDD_BACKUP_DB.md`.
- **Commit e push a cada funcionalidade entregue**, com SDD, PRD, este arquivo, as
  skills versionadas e o `graphify-out/` regerado no mesmo commit.
- **`git pull` antes de todo `git push`.** Nunca apagar branch, tag, commit ou
  stash.
- **Honestidade na validação.** O que não foi testado é dito como não testado. A
  bateria roda contra um MySQL de mentira, e isso está escrito como tal no PRD: a
  primeira execução contra o servidor real continua pendente.

## Estado atual

Versão 1.0.0, implementada. Bateria em 28 casos contra o MySQL e o Drive
simulados.

Pendente:

1. **A primeira execução contra o servidor MySQL de verdade.** É o único lugar
   onde privilégio real, versão real do `mysqldump`, tamanho real de dump e
   latência de rede existem.
2. **O leitor por `jq` não é exercitado pela bateria**, porque esta máquina não
   tem `jq`. A mitigação é que um filtro errado produziria campos fora de ordem e
   a validação por campo reprovaria alto, mas isso não é teste.
3. **`--cifrar` não é coberto** pela bateria.
4. Permissão 600, `flock` e a autorização do Google não são verificáveis nesta
   máquina, como nos projetos irmãos.

Resultado da última rodada: **28 casos, 93 verificações, 0 reprovadas**, 2 puladas
nesta máquina (permissão POSIX, porque no MSYS sem ACL o `stat` devolve
`0777 & ~umask` e não a permissão real, e `flock`, que não existe aqui).
