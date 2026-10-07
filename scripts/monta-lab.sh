#!/usr/bin/env bash
# Monta o laboratorio: um MySQL de mentira com os casos que aparecem na vida
# real (usuario sem privilegio de rotina, banco vazio, dump que para no meio,
# tabela MyISAM, credencial errada), um Google Drive de mentira que e uma pasta
# em disco, e uma HOME falsa para o registro e o relatorio nascerem no lab.
set -Eeuo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
LAB="$REPO/.lab"

if [[ -e "$LAB" ]]; then
  rm -rf "$LAB" 2>/dev/null || mv "$LAB" "$LAB.velho.$(date +%s)" 2>/dev/null \
    || { echo "nao consegui limpar $LAB" >&2; exit 1; }
fi
[[ -e "$LAB" ]] && { echo "ainda existe $LAB" >&2; exit 1; }

mkdir -p "$LAB"/{bin,drive,casa}

# ---------------------------------------------------------------------------
# credentials de mentira
#
# Duas senhas tem aspa dupla e barra invertida de proposito: sao os dois unicos
# caracteres que o arquivo de opcoes do MySQL trata de forma especial, e e o
# unico jeito de provar que o escape do script funciona.
# ---------------------------------------------------------------------------
cat > "$LAB/credentials.json" <<'JSON'
{
  "servidor_padrao": "db-falso.teste",
  "drive_pasta": "BANCOS-TESTE",
  "bancos": [
    { "nome": "bom",       "porta": 3306, "banco": "loja",   "usuario": "loja",   "senha": "S3nh@$%&(*[!)-loja" },
    { "nome": "limitado",  "porta": 3307, "banco": "blog",   "usuario": "blog",   "senha": "asp\"as-no-meio" },
    { "nome": "minimo",    "porta": 3308, "banco": "site",   "usuario": "site",   "senha": "barra\\invertida" },
    { "nome": "semacesso", "porta": 3309, "banco": "morto",  "usuario": "errado", "senha": "nao-vale" },
    { "nome": "vazio",     "porta": 3310, "banco": "vazio",  "usuario": "vazio",  "senha": "v4z10" },
    { "nome": "antigo",    "porta": 3311, "banco": "antigo", "usuario": "antigo", "senha": "my1s@m" },
    { "nome": "truncado",  "porta": 3312, "banco": "corta",  "usuario": "corta",  "senha": "c0rt@" },
    { "nome": "fantasma",  "porta": 3313, "banco": "some",   "usuario": "some",   "senha": "s0m3" },
    { "nome": "gemeo-a",   "porta": 3314, "banco": "loja",   "usuario": "loja",   "senha": "S3nh@$%&(*[!)-loja" },
    { "nome": "gemeo-b",   "porta": 3315, "banco": "loja",   "usuario": "loja",   "senha": "S3nh@$%&(*[!)-loja" }
  ]
}
JSON
chmod 600 "$LAB/credentials.json" 2>/dev/null || true

# arquivo com nome repetido, que o script tem que recusar
cat > "$LAB/cred-repetido.json" <<'JSON'
{
  "servidor_padrao": "db-falso.teste",
  "bancos": [
    { "nome": "igual", "porta": 3306, "banco": "loja", "usuario": "loja", "senha": "x" },
    { "nome": "igual", "porta": 3307, "banco": "blog", "usuario": "blog", "senha": "y" }
  ]
}
JSON

# arquivo sem nome em nenhum banco, para o padrao <banco>-<porta> aparecer
cat > "$LAB/cred-sem-nome.json" <<'JSON'
{
  "servidor_padrao": "db-falso.teste",
  "bancos": [
    { "porta": 3306, "banco": "loja", "usuario": "loja", "senha": "S3nh@$%&(*[!)-loja" },
    { "porta": 3314, "banco": "loja", "usuario": "loja", "senha": "S3nh@$%&(*[!)-loja" }
  ]
}
JSON

# arquivo com porta e nome de banco invalidos
cat > "$LAB/cred-porta-ruim.json" <<'JSON'
{
  "servidor_padrao": "db-falso.teste",
  "bancos": [ { "nome": "x", "porta": "tres-mil", "banco": "loja", "usuario": "loja", "senha": "x" } ]
}
JSON
cat > "$LAB/cred-banco-ruim.json" <<'JSON'
{
  "servidor_padrao": "db-falso.teste",
  "bancos": [ { "nome": "x", "porta": 3306, "banco": "lo ja; DROP", "usuario": "loja", "senha": "x" } ]
}
JSON
cat > "$LAB/cred-sem-servidor.json" <<'JSON'
{ "bancos": [ { "nome": "x", "porta": 3306, "banco": "loja", "usuario": "loja", "senha": "x" } ] }
JSON
# Arquivo salvo com fim de linha do Windows, que e o que acontece quando alguem
# edita o credentials.json no Notepad. Nao e caso de laboratorio: foi assim que
# apareceu o defeito do retorno de carro colando no fim da senha.
printf '{\r\n  "servidor_padrao": "db-falso.teste",\r\n  "bancos": [\r\n' \
  > "$LAB/cred-crlf.json"
printf '    { "nome": "bom", "porta": 3306, "banco": "loja", "usuario": "loja", "senha": "S3nh@$%%&(*[!)-loja" },\r\n' \
  >> "$LAB/cred-crlf.json"
printf '    { "nome": "limitado", "porta": 3307, "banco": "blog", "usuario": "blog", "senha": "asp' \
  >> "$LAB/cred-crlf.json"
printf '\\"as-no-meio" }\r\n  ]\r\n}\r\n' >> "$LAB/cred-crlf.json"

cat > "$LAB/cred-quebrado.json" <<'JSON'
{ "bancos": [ isto nao e json
JSON

# ---------------------------------------------------------------------------
# a verdade do MySQL de mentira, num arquivo que os dois stubs leem
#
#   banco : tabelas : bytes : myisam : usuario : senha : nivel_maximo : defeito
# ---------------------------------------------------------------------------
cat > "$LAB/mundo.tsv" <<'TSV'
loja	3	104857600	0	loja	S3nh@$%&(*[!)-loja	completo	-
blog	5	52428800	0	blog	asp"as-no-meio	sem-rotina	-
site	2	10485760	0	site	barra\invertida	minimo	-
morto	0	0	0	errado	nao-vale	completo	semconexao
vazio	0	0	0	vazio	v4z10	completo	-
antigo	4	20971520	3	antigo	my1s@m	completo	-
corta	6	31457280	0	corta	c0rt@	completo	trunca
some	5	15728640	0	some	s0m3	completo	semtabela
TSV

# ---------------------------------------------------------------------------
# le o arquivo de opcoes do MySQL do mesmo jeito que o MySQL le:
# valor entre aspas, com \\ e \" escapados
# ---------------------------------------------------------------------------
cat > "$LAB/bin/_lecnf" <<'STUB'
#!/usr/bin/env bash
# _lecnf <arquivo.cnf> <chave>   ->  imprime o valor
#
# Le o arquivo de opcoes como o MySQL le: valor entre aspas, e dentro das aspas
# a barra invertida comeca uma sequencia de escape. O desescape e UMA passada da
# esquerda para a direita, nao duas trocas em sequencia: trocar a aspa escapada
# primeiro e a barra dobrada depois da resultado errado quando os dois se
# encostam, e ai o teste aceitaria um escape torto do script em vez de reprovar.
set -u
arq="${1:-}"; chave="${2:-}"
[[ -f "$arq" ]] || exit 1
bruto="$(sed -n "s/^${chave}=\(.*\)$/\1/p" "$arq" | head -1)"
case "$bruto" in
  '"'*'"') ;;
  *) printf '%s' "$bruto"; exit 0 ;;
esac
bruto="${bruto#\"}"; bruto="${bruto%\"}"
saida=""
i=0; n=${#bruto}
while ((i < n)); do
  c="${bruto:i:1}"
  if [[ "$c" == "\\" ]] && ((i + 1 < n)); then
    d="${bruto:i+1:1}"
    case "$d" in
      '\')  saida+='\'; i=$((i+2)); continue ;;
      '"')  saida+='"'; i=$((i+2)); continue ;;
      n)    saida+=$'\n'; i=$((i+2)); continue ;;
      t)    saida+=$'\t'; i=$((i+2)); continue ;;
      s)    saida+=' '; i=$((i+2)); continue ;;
    esac
  fi
  saida+="$c"
  i=$((i+1))
done
printf '%s' "$saida"
STUB

cat > "$LAB/bin/mysql" <<'STUB'
#!/usr/bin/env bash
# mysql de mentira
set -u
LAB="$(dirname "$(dirname "$0")")"
printf 'mysql %s\n' "$*" >> "$LAB/argv.log"

CNF=""; SQL=""
args=()
while (($#)); do
  case "$1" in
    --defaults-extra-file=*) CNF="${1#*=}"; shift ;;
    -e) SQL="${2:-}"; shift 2 ;;
    -N|-B|--batch|--skip-column-names) shift ;;
    --*) shift ;;
    -*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done

U="$("$LAB/bin/_lecnf" "$CNF" user)"
S="$("$LAB/bin/_lecnf" "$CNF" password)"
P="$("$LAB/bin/_lecnf" "$CNF" port)"
grep -q '^protocol=TCP$' "$CNF" 2>/dev/null || { echo "mysql: falta protocol=TCP, a porta seria ignorada" >&2; exit 1; }

# acha a linha do mundo pelo usuario, e confere a senha. Senha que nao bate e o
# jeito de provar que o escape do arquivo de opcoes funcionou.
linha="$(awk -F'\t' -v u="$U" '$5==u {print; exit}' "$LAB/mundo.tsv")"
[[ -n "$linha" ]] || { echo "ERROR 1045 (28000): Access denied for user '$U'" >&2; exit 1; }
IFS=$'\t' read -r BANCO TABELAS BYTES MYISAM USUARIO SENHA NIVEL DEFEITO <<< "$linha"
if [[ "$S" != "$SENHA" ]]; then
  echo "ERROR 1045 (28000): Access denied for user '$U' (senha nao bate: o escape do .cnf falhou)" >&2
  exit 1
fi
[[ "$DEFEITO" == "semconexao" ]] && { echo "ERROR 2003 (HY000): Can't connect to MySQL server" >&2; exit 1; }

case "$SQL" in
  "SELECT 1") echo 1; exit 0 ;;
  *information_schema*)
    b="$(printf '%s' "$SQL" | sed -n "s/.*table_schema = '\\([^']*\\)'.*/\\1/p")"
    l="$(awk -F'\t' -v n="$b" '$1==n {print; exit}' "$LAB/mundo.tsv")"
    if [[ -z "$l" ]]; then printf '0\t0\t0\n'; exit 0; fi
    awk -F'\t' -v n="$b" '$1==n {printf "%s\t%s\t%s\n", $2, $3, $4; exit}' "$LAB/mundo.tsv"
    exit 0 ;;
esac
exit 0
STUB

cat > "$LAB/bin/mysqldump" <<'STUB'
#!/usr/bin/env bash
# mysqldump de mentira
set -u
LAB="$(dirname "$(dirname "$0")")"
printf 'mysqldump %s\n' "$*" >> "$LAB/argv.log"

case "${1:-}" in
  --help) printf 'mysqldump falso\n  --no-tablespaces   Do not dump tablespaces\n'; exit 0 ;;
esac

CNF=""; SEM_DADO=0; QUER_ROTINA=0; QUER_EVENTO=0; QUER_GATILHO=0
args=()
while (($#)); do
  case "$1" in
    --defaults-extra-file=*) CNF="${1#*=}"; shift ;;
    --no-data)     SEM_DADO=1; shift ;;
    --routines)    QUER_ROTINA=1; shift ;;
    --events)      QUER_EVENTO=1; shift ;;
    --triggers)    QUER_GATILHO=1; shift ;;
    --*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
BANCO="${args[0]:-}"

U="$("$LAB/bin/_lecnf" "$CNF" user)"
S="$("$LAB/bin/_lecnf" "$CNF" password)"
grep -q '^protocol=TCP$' "$CNF" 2>/dev/null || { echo "mysqldump: falta protocol=TCP" >&2; exit 2; }

linha="$(awk -F'\t' -v u="$U" '$5==u {print; exit}' "$LAB/mundo.tsv")"
[[ -n "$linha" ]] || { echo "mysqldump: Got error: 1045: Access denied for user '$U'" >&2; exit 2; }
IFS=$'\t' read -r MBANCO TABELAS BYTES MYISAM USUARIO SENHA NIVEL DEFEITO <<< "$linha"
[[ "$S" == "$SENHA" ]] || { echo "mysqldump: Got error: 1045: Access denied (senha nao bate)" >&2; exit 2; }
[[ "$DEFEITO" == "semconexao" ]] && { echo "mysqldump: Got error: 2003: Can't connect" >&2; exit 2; }

# o banco pedido tem que existir
awk -F'\t' -v n="$BANCO" '$1==n {achou=1} END{exit !achou}' "$LAB/mundo.tsv" \
  || { echo "mysqldump: Got error: 1049: Unknown database '$BANCO'" >&2; exit 2; }

# privilegio, igual ao de verdade: falta de privilegio derruba o dump INTEIRO
case "$NIVEL" in
  sem-rotina)
    if ((QUER_ROTINA || QUER_EVENTO)); then
      echo "mysqldump: Got error: 1142: SELECT,LOCK TABLES command denied (routine/event)" >&2; exit 2
    fi ;;
  minimo)
    if ((QUER_ROTINA || QUER_EVENTO || QUER_GATILHO)); then
      echo "mysqldump: Got error: 1142: command denied (routine/event/trigger)" >&2; exit 2
    fi ;;
esac

# o dump
echo "-- MySQL dump de mentira"
echo "-- Host: localhost    Database: $BANCO"
n="$TABELAS"
[[ "$DEFEITO" == "semtabela" ]] && n=0
i=0
while ((i < n)); do
  i=$((i + 1))
  echo "DROP TABLE IF EXISTS \`t$i\`;"
  echo "CREATE TABLE \`t$i\` ("
  echo "  \`id\` int NOT NULL AUTO_INCREMENT,"
  echo "  PRIMARY KEY (\`id\`)"
  echo ") ENGINE=InnoDB;"
  if ((SEM_DADO == 0)); then
    echo "INSERT INTO \`t$i\` VALUES (1),(2),(3);"
  fi
done

# o defeito que mais engana: o arquivo existe, abre, e nao tem o fim
if [[ "$DEFEITO" == "trunca" ]] && ((SEM_DADO == 0)); then
  echo "-- cortado aqui de proposito"
  exit 0
fi
echo "-- Dump completed on $(date '+%Y-%m-%d %H:%M:%S')"
exit 0
STUB

# ---------------------------------------------------------------------------
# rclone de mentira: o "Drive" e uma pasta em disco
# ---------------------------------------------------------------------------
cat > "$LAB/bin/rclone" <<'STUB'
#!/usr/bin/env bash
set -u
LAB="$(dirname "$(dirname "$0")")"
DRIVE="$LAB/drive"
CONF="$LAB/rclone.conf"

cmd="${1:-}"; shift || true
args=()
while (($#)); do
  case "$1" in
    --config|--drive-chunk-size|--retries|--low-level-retries|--stats|--log-level|--log-file|--transfers|--checkers) shift 2 ;;
    --stats-one-line|--json|--dirs-only) shift ;;
    --*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
caminho() { printf '%s' "$DRIVE/${1#*:}"; }

case "$cmd" in
  version)     echo "rclone v1.68.0-falso" ;;
  config)      [[ "${args[0]:-}" == file ]] && { echo "Configuration file is stored at:"; echo "$CONF"; } ;;
  listremotes) [[ -f "$LAB/.conectado" ]] && echo "bancos-drive:" ; exit 0 ;;
  lsd)         [[ -f "$LAB/.conectado" ]] || exit 1; mkdir -p "$DRIVE"; exit 0 ;;
  mkdir)       mkdir -p "$(caminho "${args[0]:-}")" || exit 1; exit 0 ;;
  copyto)
    o="${args[0]:-}"; d="${args[1]:-}"
    dst="$(caminho "$d")"
    mkdir -p "$(dirname "$dst")" || exit 1
    cp -f "$o" "$dst" || exit 1
    [[ -f "$LAB/.corromper" ]] && : > "$dst"
    exit 0 ;;
  md5sum)
    p="$(caminho "${args[0]:-}")"
    [[ -f "$p" ]] || exit 0
    if [[ -f "$LAB/.hash-errado" ]]; then
      printf '%s  %s\n' '00000000000000000000000000000000' "${p##*/}"
    else
      md5sum "$p" | awk -v n="${p##*/}" '{print $1"  "n}'
    fi
    exit 0 ;;
  size)
    p="$(caminho "${args[0]:-}")"
    if [[ -f "$p" ]]; then printf '{"count":1,"bytes":%s}\n' "$(stat -c%s "$p")"; exit 0; fi
    if [[ -d "$p" ]]; then
      n=0; b=0
      while IFS= read -r -d '' f; do n=$((n+1)); b=$((b + $(stat -c%s "$f"))); done < <(find "$p" -type f -print0 2>/dev/null)
      printf '{"count":%s,"bytes":%s}\n' "$n" "$b"; exit 0
    fi
    echo "directory not found" >&2; exit 3 ;;
  lsf)
    p="$(caminho "${args[0]:-}")"
    [[ -d "$p" ]] || exit 0
    for e in "$p"/*; do [[ -d "$e" ]] && printf '%s/\n' "$(basename "$e")"; done
    exit 0 ;;
  purge)  rm -rf "$(caminho "${args[0]:-}")"; exit 0 ;;
  delete) rm -f  "$(caminho "${args[0]:-}")"; exit 0 ;;
  *) echo "rclone falso: comando nao previsto: $cmd" >&2; exit 64 ;;
esac
exit 0
STUB

chmod +x "$LAB/bin/"*

printf 'lab montado em %s\n' "$LAB"
printf 'credencial de teste: %s (%s banco(s))\n' "$LAB/credentials.json" \
  "$(grep -c '"nome"' "$LAB/credentials.json")"
bash -n "$REPO/backup-db.sh" && printf 'sintaxe do script: ok\n'
