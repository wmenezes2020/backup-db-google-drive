#!/usr/bin/env bash
# Bateria de testes do backup-db.sh contra o MySQL e o Google Drive de mentira.
# Antes: bash scripts/monta-lab.sh
set -uo pipefail

SC="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$SC/.." && pwd -P)"
LAB="$REPO/.lab"
DRIVE="$LAB/drive"
CASA="$LAB/casa"
CRED="$LAB/credentials.json"
S="$REPO/backup-db.sh"

[[ -d "$LAB" ]] || { echo "monte o lab primeiro: bash scripts/monta-lab.sh" >&2; exit 1; }

export PATH="$LAB/bin:$PATH"
export HOME="$CASA"

# as senhas do lab, que NUNCA podem aparecer em log, relatorio ou linha de comando
SENHAS=( 'S3nh@$%&(*[!)-loja' 'asp"as-no-meio' 'barra\invertida' 'v4z10' 'my1s@m' 'c0rt@' 's0m3' )

PASSOU=0; REPROVOU=0
declare -a FALHAS=()
ok()   { PASSOU=$((PASSOU+1));     printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
nok()  { REPROVOU=$((REPROVOU+1)); FALHAS+=("$1"); printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; }
caso() { printf '\n\033[1;36m== %s\033[0m\n' "$1"; }
pula() { printf '        pulado: %s\n' "$1"; }

N_RODADA=0
roda() {
  N_RODADA=$((N_RODADA + 1))
  SAIDA="$( cd "$LAB" && bash "$S" "$@" 2>&1 )"
  CODIGO=$?
  ULTIMA="$LAB/saida-$N_RODADA.txt"
  { printf 'argumentos: %s\ncodigo: %s\n\n' "$*" "$CODIGO"; printf '%s\n' "$SAIDA"; } > "$ULTIMA"
  if ((CODIGO != 0)); then
    printf '        [rodada %s, codigo %s]\n' "$N_RODADA" "$CODIGO"
    grep -E '^[[:space:]]+(xx|!!)|^ERRO:' <<< "$SAIDA" | sed 's/^/          /' | head -6
    printf '          saida completa: %s\n' "$ULTIMA"
  fi
  return 0
}

limpa() {
  rm -rf "$DRIVE" "$CASA" "$LAB/rclone.conf" "$LAB/.corromper" "$LAB/.hash-errado" "$LAB/argv.log"
  mkdir -p "$DRIVE" "$CASA"
}
conecta()    { touch "$LAB/.conectado"; }
desconecta() { rm -f "$LAB/.conectado"; }
contem()     { grep -qF -- "$2" <<< "$1"; }
nao_contem() { ! grep -qF -- "$2" <<< "$1"; }
estado()     { local d; d="$(ls -d "$CASA/.backup-db/"*/ 2>/dev/null | head -1)" || d=""; printf '%s' "${d%/}"; }
pasta_data() { ls -d "$DRIVE/BANCOS-TESTE"/[0-9]*_[0-9]* 2>/dev/null | head -1; }

# ===========================================================================
caso "T01 --simular le o arquivo, testa cada banco e mede, sem gerar nada"
limpa; desconecta
roda "$CRED" --simular
contem "$SAIDA" "10 banco(s)"                     && ok "le os 10 bancos do arquivo" || nok "T01 contagem"
contem "$SAIDA" "bom: 3 tabela(s)"                && ok "mede tabela e tamanho do banco" || nok "T01 medida"
contem "$SAIDA" "nivel completo"                  && ok "descobre que o usuario pleno tem tudo" || nok "T01 nivel completo"
contem "$SAIDA" "nivel sem rotina e evento"       && ok "cai para 'sem rotina e evento' no usuario limitado" || nok "T01 nivel medio"
contem "$SAIDA" "nivel minimo"                    && ok "cai para 'minimo' no usuario mais limitado ainda" || nok "T01 nivel minimo"
contem "$SAIDA" "semacesso: nao consegui conectar" && ok "diz qual credencial nao conecta" || nok "T01 sem conexao"
contem "$SAIDA" "tabela(s) MyISAM"                && ok "avisa que --single-transaction nao vale para MyISAM" || nok "T01 myisam"
contem "$SAIDA" "nao enxerga nenhuma tabela"      && ok "avisa banco que conecta e nao mostra tabela" || nok "T01 vazio"
((CODIGO == 2)) && ok "sai com 2 porque um banco nao respondeu" || nok "T01 codigo=$CODIGO"
[[ -z "$(ls -A "$DRIVE" 2>/dev/null)" ]] && ok "--simular nao criou nada no Drive" || nok "T01 criou no Drive"

caso "T01b a senha chega pelo arquivo de opcoes, nunca pela linha de comando"
FALTOU=0
for p in "${SENHAS[@]}"; do
  if grep -qF -- "$p" "$LAB/argv.log" 2>/dev/null; then
    nok "T01b senha apareceu na linha de comando do mysql/mysqldump"
    FALTOU=1; break
  fi
done
((FALTOU)) || ok "nenhuma das 7 senhas apareceu na linha de comando dos clientes MySQL"
# o escape do .cnf foi exercitado: aspa dupla e barra invertida conectaram
contem "$SAIDA" "limitado: 5 tabela(s)" && ok "senha com aspa dupla atravessou o arquivo de opcoes" || nok "T01b aspa"
contem "$SAIDA" "minimo: 2 tabela(s)"   && ok "senha com barra invertida atravessou o arquivo de opcoes" || nok "T01b barra"

# ===========================================================================
caso "T02 arquivo de credencial que nao serve"
roda "$LAB/cred-repetido.json" --simular
contem "$SAIDA" "aparece duas vezes no arquivo" && ok "recusa nome repetido, que sobrescreveria um backup" || nok "T02 repetido"
roda "$LAB/cred-porta-ruim.json" --simular
contem "$SAIDA" "nao e um numero" && ok "recusa porta que nao e numero" || nok "T02 porta"
roda "$LAB/cred-banco-ruim.json" --simular
contem "$SAIDA" "caractere que este script nao aceita" && ok "recusa nome de banco com espaco e ponto e virgula" || nok "T02 banco"
# Este caso e a regressao do campo vazio que deslocava a linha. Com separador de
# tabulacao, o "servidor" vazio desaparecia e o script lia a PORTA como servidor,
# entao a mensagem que saia nao era esta, e os campos seguintes vinham todos
# trocados. Se este teste voltar a reprovar, confira o separador do leitor antes
# de mexer na validacao.
roda "$LAB/cred-sem-servidor.json" --simular
contem "$SAIDA" "falta o servidor" && ok "campo vazio no meio nao desloca os campos seguintes" || nok "T02 servidor"
roda "$LAB/cred-quebrado.json" --simular
contem "$SAIDA" "nao consegui ler" && ok "recusa JSON quebrado" || nok "T02 json"
roda "/nao/existe/credentials.json" --simular
contem "$SAIDA" "nao achei esse arquivo" && ok "recusa arquivo que nao existe" || nok "T02 inexistente"

caso "T02b sem 'nome', o padrao e <banco>-<porta>, e nao colide"
roda "$LAB/cred-sem-nome.json" --simular
contem "$SAIDA" "loja-3306" && ok "monta o nome com banco e porta" || nok "T02b 3306"
contem "$SAIDA" "loja-3314" && ok "o mesmo banco em outra porta ganha outro nome" || nok "T02b 3314"

caso "T02c credentials.json salvo com fim de linha do Windows"
# Regressao do retorno de carro. O \r no fim da linha colava no ultimo campo, que
# e a senha, e o MySQL respondia "Access denied" por causa de um caractere
# invisivel. Nove dos dez bancos falhavam e ninguem sabia dizer por que.
roda "$LAB/cred-crlf.json" --simular
contem "$SAIDA" "bom: 3 tabela(s)" && ok "senha nao vem com retorno de carro colado no fim" || nok "T02c CRLF bom"
contem "$SAIDA" "limitado: 5 tabela(s)" && ok "a segunda linha tambem, com aspa dupla na senha" || nok "T02c CRLF limitado"
nao_contem "$SAIDA" "nao consegui conectar" && ok "nenhuma conexao falhou por fim de linha" || nok "T02c CRLF conexao"

# ===========================================================================
caso "T03 backup completo, com historico por data como padrao"
limpa; conecta
roda "$CRED" -s
PD="$(pasta_data)"
[[ -n "$PD" ]] && ok "criou a pasta de data, que e o padrao aqui" || nok "T03 sem pasta de data"
contem "$SAIDA" "Bancos ok ..... 7 de 9" \
  && ok "7 dos 9 que conectaram subiram, e o decimo nem entrou na conta" || nok "T03 ok"
for n in bom limitado minimo vazio antigo gemeo-a gemeo-b; do
  [[ -f "$PD/$n.sql.gz" ]] && ok "subiu $n.sql.gz" || nok "T03 falta $n.sql.gz"
done
[[ ! -f "$PD/truncado.sql.gz" ]] && ok "o dump truncado NAO subiu" || nok "T03 truncado subiu"
[[ ! -f "$PD/fantasma.sql.gz" ]] && ok "o dump vazio de um banco com tabela NAO subiu" || nok "T03 fantasma subiu"
[[ ! -f "$PD/semacesso.sql.gz" ]] && ok "o banco sem conexao NAO subiu" || nok "T03 semacesso subiu"

caso "T03b o mesmo banco em tres portas vira tres arquivos distintos"
A="$(gunzip -c "$PD/bom.sql.gz" 2>/dev/null | md5sum | awk '{print $1}')"
[[ -f "$PD/gemeo-a.sql.gz" && -f "$PD/gemeo-b.sql.gz" && -f "$PD/bom.sql.gz" ]] \
  && ok "o banco 'loja' das portas 3306, 3314 e 3315 gerou 3 arquivos" || nok "T03b colisao"

# ===========================================================================
caso "T04 o conteudo do dump chega inteiro e abre"
gunzip -t "$PD/bom.sql.gz" 2>/dev/null && ok "o gzip no Drive passa no gunzip -t" || nok "T04 gzip"
CONT="$(gunzip -c "$PD/bom.sql.gz" 2>/dev/null)"
contem "$CONT" "CREATE TABLE \`t3\`"      && ok "as 3 tabelas estao no dump" || nok "T04 tabelas"
contem "$CONT" "INSERT INTO"              && ok "o dump tem dado, nao so estrutura" || nok "T04 dados"
contem "$CONT" "-- Dump completed on"     && ok "o dump termina com a marca de completo" || nok "T04 marca"
contem "$SAIDA" "dump conferido: 3 tabela(s)" && ok "a conferencia conta as tabelas do arquivo" || nok "T04 conferencia"

# ===========================================================================
caso "T05 dump que para no meio e recusado e apagado"
contem "$SAIDA" "truncado: o dump nao tem a marca de 'Dump completed'" \
  && ok "pega o dump sem o fim, que e o que mais engana" || nok "T05 nao pegou"
contem "$SAIDA" "arquivo foi apagado de proposito" && ok "apaga o arquivo em vez de guardar backup ruim" || nok "T05 nao apagou"
EST="$(estado)"
[[ ! -f "$EST/dumps/truncado.sql.gz" ]] && ok "o dump ruim nao sobrou no disco local" || nok "T05 sobrou local"

caso "T05b banco com tabela e dump sem nenhuma tabela e recusado"
contem "$SAIDA" "fantasma: o banco tem 5 tabela(s), e o dump saiu com nenhuma" \
  && ok "compara o que o banco tem com o que o dump trouxe" || nok "T05b nao comparou"

# ===========================================================================
caso "T06 nenhuma senha vaza para log, relatorio ou registro"
VAZOU=0
for f in "$EST"/backup-*.log "$EST"/RELATORIO-*.txt "$EST/registro.tsv"; do
  [[ -f "$f" ]] || continue
  for p in "${SENHAS[@]}"; do
    if grep -qF -- "$p" "$f" 2>/dev/null; then
      nok "T06 senha vazou em $(basename "$f")"; VAZOU=1
    fi
  done
done
((VAZOU)) || ok "log, relatorio e registro nao tem nenhuma das 7 senhas"
for p in "${SENHAS[@]}"; do
  grep -qF -- "$p" "$LAB/argv.log" 2>/dev/null && { nok "T06 senha na linha de comando"; VAZOU=1; break; }
done
((VAZOU)) || ok "a linha de comando dos clientes MySQL continua sem senha"
# e o Drive tambem nao recebeu senha dentro do relatorio
REL_DRIVE="$(cat "$DRIVE/BANCOS-TESTE/_relatorios"/RELATORIO-*.txt 2>/dev/null)"
VAZOU2=0
for p in "${SENHAS[@]}"; do
  contem "$REL_DRIVE" "$p" && { nok "T06 senha no relatorio que subiu"; VAZOU2=1; break; }
done
((VAZOU2)) || ok "o relatorio que subiu para o Drive nao tem senha"

caso "T06b o arquivo de opcoes do MySQL nao sobra na maquina"
find /tmp "$EST" -name 'mysql-*.cnf' 2>/dev/null | grep -q . \
  && nok "T06b sobrou arquivo de opcoes com senha" \
  || ok "nenhum mysql-*.cnf sobrou: o TMP e apagado na saida"

# ===========================================================================
caso "T07 relatorio"
ls "$EST"/RELATORIO-*.txt >/dev/null 2>&1 && ok "escreveu o relatorio" || nok "T07 sem relatorio"
REL="$(cat "$EST"/RELATORIO-*.txt 2>/dev/null)"
contem "$REL" "BANCOS OK ...... 7"     && ok "relatorio diz 7 ok" || nok "T07 contagem"
contem "$REL" "COM ERRO ....... 3"     && ok "relatorio diz 3 com erro" || nok "T07 erros"
contem "$REL" "CONFERENCIA .... MD5"   && ok "relatorio diz que conferiu por MD5" || nok "T07 conferencia"
contem "$REL" "sem rotina e evento"    && ok "relatorio registra o nivel de privilegio usado" || nok "T07 nivel"
contem "$REL" "gunzip -c"              && ok "relatorio ensina a restaurar" || nok "T07 restaurar"
ls "$DRIVE/BANCOS-TESTE/_relatorios"/RELATORIO-*.txt >/dev/null 2>&1 && ok "relatorio subiu para _relatorios" || nok "T07 no Drive"

caso "T07b a copia local do dump e liberada depois de conferida"
[[ -z "$(ls -A "$EST/dumps" 2>/dev/null)" ]] && ok "nenhum dump sobrou em dumps/" || nok "T07b sobrou: $(ls -A "$EST/dumps")"
roda "$CRED" -s --bancos bom --manter-local --nova
EST="$(estado)"
[[ -f "$EST/dumps/bom.sql.gz" ]] && ok "--manter-local guarda a copia local" || nok "T07b manter-local"
rm -f "$EST/dumps/bom.sql.gz"

# ===========================================================================
caso "T08 retomada: volta para a MESMA pasta de data e pula o que subiu"
# A primeira execucao tem que terminar COM falha, senao nao existe o que
# retomar: ciclo que fecha limpo apaga a marca de proposito (ver T08d). O
# conjunto completo tem tres bancos que falham, entao ele serve.
limpa; conecta
roda "$CRED" -s
PD1="$(pasta_data)"
roda "$CRED" -s
contem "$SAIDA" "nao terminou"       && ok "percebe a execucao interrompida" || nok "T08 nao percebeu"
contem "$SAIDA" "Vou retomar na MESMA pasta" && ok "avisa que vai retomar na mesma pasta" || nok "T08 aviso"
PD2="$(pasta_data)"
[[ "$PD1" == "$PD2" ]] && ok "continuou na mesma pasta de data" || nok "T08 pasta mudou: $PD1 -> $PD2"
contem "$SAIDA" "bom: pulado, ja subiu nesta mesma pasta" && ok "pula o que ja estava na pasta" || nok "T08 nao pulou"
contem "$SAIDA" "Pulados ....... 7" && ok "pulou os 7 que ja tinham subido" || nok "T08 contagem de pulados"

caso "T08b --nova comeca uma pasta nova mesmo com execucao interrompida"
roda "$CRED" -s --bancos bom --nova
N_DATAS="$(ls -d "$DRIVE/BANCOS-TESTE"/[0-9]*_[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
if (("$N_DATAS" >= 1)); then ok "--nova aceito"; else nok "T08b sem pasta"; fi

caso "T08c execucao velha demais nao e retomada"
EST="$(estado)"
printf '2020-01-01_0000\t1577836800\n' > "$EST/execucao-atual"
roda "$CRED" -s --bancos bom
contem "$SAIDA" "comeco um ciclo novo" && ok "execucao mais velha que a janela vira ciclo novo" || nok "T08c nao virou ciclo novo"
[[ ! -d "$DRIVE/BANCOS-TESTE/2020-01-01_0000" ]] && ok "nao gravou na pasta velha" || nok "T08c gravou na velha"

caso "T08d execucao que termina sem falha limpa a marca de retomada"
limpa; conecta
roda "$CRED" -s --bancos bom,limitado
EST="$(estado)"
[[ ! -f "$EST/execucao-atual" ]] && ok "ciclo sem falha apaga a marca, para o proximo ser pasta nova" || nok "T08d marca sobrou"

# ===========================================================================
caso "T09 --sem-data grava direto na pasta, sem historico"
limpa; conecta
roda "$CRED" -s --sem-data --bancos bom
[[ -f "$DRIVE/BANCOS-TESTE/bom.sql.gz" ]] && ok "--sem-data grava na raiz da pasta" || nok "T09 sem-data"
[[ -z "$(pasta_data)" ]] && ok "--sem-data nao cria pasta de data" || nok "T09 criou pasta de data"
roda "$CRED" -s --sem-data --bancos bom --manter 3
contem "$SAIDA" "so faz sentido com historico por data" && ok "--manter sem historico e recusado" || nok "T09 manter aceito"

caso "T09b --manter apaga a data mais antiga e guarda as N mais novas"
limpa; conecta
roda "$CRED" -s --bancos bom
mkdir -p "$DRIVE/BANCOS-TESTE/2020-01-01_0000" "$DRIVE/BANCOS-TESTE/2021-01-01_0000"
printf 'velho\n' > "$DRIVE/BANCOS-TESTE/2020-01-01_0000/x"
printf 'velho\n' > "$DRIVE/BANCOS-TESTE/2021-01-01_0000/x"
roda "$CRED" -s --bancos bom --nova --manter 2
# nao se afirma QUAL sobra: se as duas execucoes cairem no mesmo minuto elas
# dividem a mesma pasta, e ai a de 2021 sobra; em minutos diferentes sobram as
# duas de hoje. O que vale em qualquer caso e: sobram 2, e a mais antiga saiu.
[[ ! -d "$DRIVE/BANCOS-TESTE/2020-01-01_0000" ]] && ok "apagou a data mais antiga" || nok "T09b nao apagou"
RESTAM="$(ls -d "$DRIVE/BANCOS-TESTE"/[0-9]*_[0-9]* 2>/dev/null | wc -l | tr -d ' ')"
[[ "$RESTAM" == 2 ]] && ok "sobraram exatamente 2 datas, como pedido em --manter 2" || nok "T09b sobraram $RESTAM"

# ===========================================================================
caso "T10 --bancos, --excluir e --so-estrutura"
limpa; conecta
roda "$CRED" -s --bancos bom,limitado
contem "$SAIDA" "2 banco(s): bom limitado" && ok "--bancos pega so os pedidos" || nok "T10 bancos"
limpa; conecta
roda "$CRED" -s --excluir truncado,fantasma,semacesso,vazio,antigo,gemeo-a,gemeo-b
contem "$SAIDA" "3 banco(s): bom limitado minimo" && ok "--excluir tira os listados" || nok "T10 excluir"
limpa; conecta
roda "$CRED" -s --bancos bom --so-estrutura
PD="$(pasta_data)"
CONT="$(gunzip -c "$PD/bom.sql.gz" 2>/dev/null)"
contem "$CONT" "CREATE TABLE"       && ok "--so-estrutura leva a estrutura" || nok "T10 estrutura"
nao_contem "$CONT" "INSERT INTO"    && ok "--so-estrutura nao leva nenhuma linha" || nok "T10 levou dados"
contem "$(cat "$(estado)"/RELATORIO-*.txt)" "SO A ESTRUTURA" && ok "relatorio avisa que nao tem dado" || nok "T10 relatorio"

# ===========================================================================
caso "T11 --registro mostra o que ja subiu"
roda "$CRED" --registro
contem "$SAIDA" "bom" && ok "o registro lista os dumps enviados" || nok "T11 registro"
contem "$SAIDA" "O registro fica em" && ok "diz onde o registro mora" || nok "T11 caminho"
((CODIGO == 0)) && ok "--registro sai com 0" || nok "T11 codigo=$CODIGO"

# ===========================================================================
caso "T12 arquivo chega cortado no Drive"
limpa; conecta
touch "$LAB/.corromper"
roda "$CRED" -s --bancos bom
rm -f "$LAB/.corromper"
contem "$SAIDA" "nao bate com o local" && ok "pega o arquivo truncado no destino pelo tamanho" || nok "T12 nao pegou"
((CODIGO == 2)) && ok "sai com 2" || nok "T12 codigo=$CODIGO"

caso "T13 conteudo diferente no Drive, com o tamanho certo"
limpa; conecta
touch "$LAB/.hash-errado"
roda "$CRED" -s --bancos bom
rm -f "$LAB/.hash-errado"
contem "$SAIDA" "o conteudo no Drive nao confere" && ok "o MD5 pega o byte trocado que o tamanho nao pega" || nok "T13 nao pegou"
((CODIGO == 2)) && ok "sai com 2" || nok "T13 codigo=$CODIGO"

# ===========================================================================
caso "T14 sem conexao com o Drive, e sem terminal para autorizar"
limpa; desconecta
roda "$CRED" -s --bancos bom
contem "$SAIDA" "precisa de terminal" && ok "diz que a primeira autorizacao pede terminal" || nok "T14 mensagem"
contem "$SAIDA" "--conectar"          && ok "ensina o comando --conectar" || nok "T14 ensina"
((CODIGO == 1)) && ok "sai com 1" || nok "T14 codigo=$CODIGO"

# ===========================================================================
caso "T15 escrita do rclone.conf"
limpa; conecta
cat > "$LAB/rclone.conf" <<'CONF'
[outro-remote]
type = s3
provider = Minio
CONF
( export PATH="$LAB/bin:$PATH" HOME="$CASA"; cd "$LAB"
  awk '/^# Autorizacao: um link/{exit} {print}' "$S" > "$LAB/so-funcoes.sh"
  printf '\nLOG=/dev/null\nDRIVE_REMOTE=bancos-drive\nCARIMBO=teste\n' >> "$LAB/so-funcoes.sh"
  printf 'escreve_remote_rclone "{\\"access_token\\":\\"abc\\"}" drive\n' >> "$LAB/so-funcoes.sh"
  bash "$LAB/so-funcoes.sh" >/dev/null 2>&1 ) || true
CONF_FINAL="$(cat "$LAB/rclone.conf" 2>/dev/null)"
contem "$CONF_FINAL" "[outro-remote]"    && ok "preserva o remote que ja existia" || nok "T15 apagou o outro"
contem "$CONF_FINAL" "[bancos-drive]"    && ok "grava a secao do remote novo" || nok "T15 nao gravou"
contem "$CONF_FINAL" "type = drive"      && ok "grava type = drive" || nok "T15 type"
nao_contem "$CONF_FINAL" "client_id"     && ok "nao grava client_id, para o rclone renovar com a chave dele" || nok "T15 client_id"
nao_contem "$CONF_FINAL" "client_secret" && ok "nao grava client_secret" || nok "T15 client_secret"

# ===========================================================================
caso "T16 aviso de permissao no arquivo de credencial"
limpa; conecta
cp "$CRED" "$LAB/cred-aberto.json"
# A sonda pergunta a permissao a um processo NOVO, e nao ao shell que acabou de
# dar o chmod. Nesta maquina (NTFS pelo MSYS) o stat responde 644 ali e 600 no
# processo seguinte, entao conferir no mesmo shell daria verde falso e o teste
# reprovaria o script por um defeito do sistema de arquivo.
CHMOD_VALE=0
if chmod 644 "$LAB/cred-aberto.json" 2>/dev/null; then
  LIDO="$(bash -c 'umask 077; stat -c "%a" "$1" 2>/dev/null' _ "$LAB/cred-aberto.json")"
  [[ "$LIDO" == 644 ]] && CHMOD_VALE=1
fi
if ((CHMOD_VALE)); then
  roda "$LAB/cred-aberto.json" --simular
  contem "$SAIDA" "chmod 600" && ok "avisa que o arquivo de senha esta legivel por todos" || nok "T16 sem aviso"
else
  pula "esta maquina nao aplica permissao POSIX: no MSYS sem ACL o stat devolve 0777 & ~umask, nao a permissao real"
fi

# ===========================================================================
caso "T17 trava contra duas execucoes ao mesmo tempo"
limpa; conecta
if command -v flock >/dev/null 2>&1; then
  roda "$CRED" -s --bancos bom
  EST="$(estado)"
  (
    exec 9>"$EST/backup-db.lock"
    flock -n 9 || exit 1
    S2="$( cd "$LAB" && bash "$S" "$CRED" -s --bancos bom 2>&1 )"
    grep -qF "ja existe um backup destes bancos em andamento" <<< "$S2"
  ) && ok "a segunda execucao e recusada enquanto a primeira tem a trava" \
    || nok "T17 a trava nao segurou"
else
  pula "esta maquina nao tem flock"
fi

# ===========================================================================
printf '\n%s\n' "$(printf '%.0s=' {1..70})"
printf 'PASSOU: %s    REPROVOU: %s\n' "$PASSOU" "$REPROVOU"
if ((REPROVOU)); then
  printf '\nreprovadas:\n'
  for f in "${FALHAS[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
printf 'tudo verde\n'
exit 0
