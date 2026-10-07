#!/usr/bin/env bash
#
# backup-db.sh
# Faz o dump de cada banco MySQL listado num credentials.json e envia para o
# Google Drive.
#
# O que faz, em ordem:
#   1. le o credentials.json que voce apontou
#   2. testa a conexao de cada banco antes de gastar tempo
#   3. faz o dump de um banco por vez, direto para gzip
#   4. confere o dump: CRC do gzip, quantas tabelas sairam, e a marca de
#      "Dump completed" que o mysqldump escreve no fim
#   5. envia para o Google Drive e confere o conteudo no destino
#   6. libera o espaco local e vai para o proximo banco
#
# Uso:
#   ./backup-db.sh /caminho/credentials.json
#
# Ajuda:
#   ./backup-db.sh --ajuda
#
# Nao precisa criar projeto no Google Cloud, nem chave, nem faturamento. A
# autorizacao usa a chave que ja vem embutida no rclone.

set -Eeuo pipefail

# Array associativo, mapfile e ${var,,} sao de bash 4. O bash do macOS e o 3.2,
# de 2007, e la o script quebraria no meio com erro que nao explica nada. Melhor
# dizer na primeira linha o que falta.
if [[ -z "${BASH_VERSINFO:-}" ]] || ((BASH_VERSINFO[0] < 4)); then
  printf 'ERRO: este script precisa de bash 4 ou mais novo (aqui e o %s).\n' "${BASH_VERSION:-desconhecido}" >&2
  printf '      no macOS:  brew install bash  e rode com  /opt/homebrew/bin/bash %s\n' "$0" >&2
  exit 1
fi

VERSAO_SCRIPT="1.1.0"
NOME_SCRIPT="$(basename "$0")"

# ---------------------------------------------------------------------------
# Opcoes
# ---------------------------------------------------------------------------
ARQUIVO_CRED=""
DRIVE_PASTA=""
BANCOS_PEDIDOS=""
BANCOS_EXCLUIDOS=""
SEM_DATA=0                   # historico por data e o PADRAO aqui
MANTER=0
NOVA=0
JANELA_HORAS=12
NIVEL_COMPRESSAO=6
SO_ESTRUTURA=0
CIFRAR=0
ARQUIVO_SENHA=""
SIMULAR=0
SIM=0
SEM_NICE=0
MANTER_LOCAL=0
FORCAR=0
SO_REGISTRO=0
SO_CONECTAR=0
RECONECTAR=0
ESTADO_PEDIDO=""
DRIVE_REMOTE="bancos-drive"
DRIVE_ESCOPO="total"
MARGEM_MB=200

# ---------------------------------------------------------------------------
# Estado interno
# ---------------------------------------------------------------------------
INICIO_EPOCH="$(date +%s)"
CARIMBO="$(date +%Y%m%d-%H%M%S)"
PASTA_DATA="$(date +%Y-%m-%d_%H%M)"
LOG=""
TMP=""
TRAVA=""
ESTADO=""
REGISTRO=""
EXECUCAO=""
DUMPS=""
RELATORIO=""
PASTA_DRIVE=""
RETOMANDO=0
TEM_NO_TABLESPACES=0
TEM_COLUMN_STATISTICS=0
BIN_MYSQL=""
BIN_DUMP=""
SABOR_CLIENTE=""
declare -a DUMPS_DISPONIVEIS=()     # "binario|sabor"
declare -a CLIENTES_DISPONIVEIS=()  # "binario|sabor"
ERRO_CLIENTE=""
AJUSTES=""
NIVEL_DUMP=""
declare -a FLAGS_DUMP=()
declare -a NOMES=()
declare -A SERVIDOR_DE=() PORTA_DE=() BANCO_DE=() USUARIO_DE=() SENHA_DE=()
declare -a AVISOS=() ERROS=() LINHAS_RELATORIO=()
declare -A SABOR_DE=() AJUSTES_DE=() DUMP_DE=()
CORES=0
OK_BANCOS=0
FALHA_BANCOS=0
PULADOS=0
BYTES_ENVIADOS=0
CONFERENCIA=""
CONFERENCIA_POR_TAMANHO=0
MD5_ENVIADO=""

# ---------------------------------------------------------------------------
# Saida
# ---------------------------------------------------------------------------
cor() { if ((CORES)); then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
agora() { date '+%H:%M:%S'; }
diz()   { printf '%s %s\n' "$(cor '0;90' "[$(agora)]")" "$*"; }
passo() { printf '\n%s %s\n' "$(cor '1;36' '==>')" "$(cor '1' "$*")"; }
feito() { printf '%s %s\n' "$(cor '0;32' '  ok')" "$*"; }
aviso() { AVISOS+=("$*"); printf '%s %s\n' "$(cor '1;33' '  !!')" "$*"; }
falha() { ERROS+=("$*");  printf '%s %s\n' "$(cor '1;31' '  xx')" "$*"; }
morre() { printf '\n%s %s\n' "$(cor '1;31' 'ERRO:')" "$*" >&2; exit 1; }

if [[ -t 1 ]]; then CORES=1; fi

ajuda() {
  cat <<AJUDA
$NOME_SCRIPT v$VERSAO_SCRIPT

Faz o dump de cada banco MySQL listado num credentials.json e envia para o
Google Drive. Um banco por vez: gera, confere, envia, confere no destino,
libera o disco, segue para o proximo.

USO
  ./$NOME_SCRIPT /caminho/credentials.json

PRIMEIRA VEZ
  Na primeira execucao ele mesmo liga o Google Drive: mostra um link, voce
  abre no navegador, escolhe a conta Google, clica em Permitir, copia a URL em
  que o navegador caiu e cola de volta aqui. Acabou.
  Nao precisa criar projeto no Google Cloud, nem chave, nem faturamento.

  Para ligar o Drive sem fazer backup nenhum:
      ./$NOME_SCRIPT --conectar

ANTES DE CONFIAR, TESTE
      ./$NOME_SCRIPT credentials.json --simular

  Conecta em cada banco, diz quantas tabelas tem, o tamanho, o motor de
  armazenamento e se o usuario tem privilegio para rotina e evento. Nao gera
  dump e nao envia nada. E o jeito de descobrir credencial errada em segundos
  em vez de descobrir depois de uma hora de dump.

O ARQUIVO credentials.json
  {
    "servidor_padrao": "db.exemplo.com",
    "drive_pasta": "BACKUP-BANCOS",
    "bancos": [
      { "nome": "loja",  "porta": 3306, "banco": "loja_prod",
        "usuario": "loja", "senha": "..." },
      { "nome": "blog",  "servidor": "outro.exemplo.com", "porta": 3307,
        "banco": "blog", "usuario": "blog", "senha": "..." }
    ]
  }

  "nome" e o nome do arquivo que vai para o Drive, e tem que ser UNICO. Sem
  ele o script usa <banco>-<porta>. Dois bancos com o mesmo nome param a
  execucao, porque um sobrescreveria o outro e voce acharia que tem duas
  copias tendo uma.
  "servidor" e opcional em cada banco: sem ele vale o "servidor_padrao".
  Veja credentials.exemplo.json.

OPCOES
      --drive-pasta P   Pasta no Drive. Padrao: o "drive_pasta" do arquivo, ou
                        BACKUP-BANCOS.
      --bancos a,b,c    So estes (pelo "nome").
      --excluir a,b     Pula estes.
      --sem-data        NAO guarda historico: grava direto em <pasta>/ e o
                        dump de hoje substitui o de ontem.
                        Padrao: cada execucao vai para <pasta>/AAAA-MM-DD_HHMM
      --manter N        Guarda as N pastas de data mais novas e apaga as mais
                        antigas. Padrao 0, que nao apaga nada.
      --nova            Comeca um ciclo novo mesmo que exista um interrompido.
      --janela-horas N  Execucao interrompida ha menos de N horas e retomada
                        na mesma pasta de data. Padrao: $JANELA_HORAS
  -z, --compressao N    Nivel do gzip, 1 a 9. Padrao: $NIVEL_COMPRESSAO
      --so-estrutura    Dump sem nenhuma linha, so a estrutura. Serve para
                        guardar o desenho do banco, nao para restaurar dado.
      --cifrar          Cifra cada dump antes de subir. Gera .gpg no Drive.
      --senha-arquivo F Le a senha da cifra do arquivo F em vez de perguntar.
      --manter-local    Nao apaga o dump local depois de enviar. Padrao:
                        apaga, e so depois de conferir no Drive.
      --forcar          Ignora o aviso de espaco em disco insuficiente.
      --simular         So testa e mede. Nao gera dump e nao envia nada.
  -s, --sim             Responde sim as perguntas (uso no cron).
      --sem-nice        Prioridade normal de CPU e disco. Padrao: baixa.
      --registro        Mostra o que ja foi enviado, e sai.
      --estado DIR      Onde ficam registro, log, relatorio e o dump enquanto
                        ele sobe. Padrao: \$HOME/.backup-db/<arquivo>-<id>
  -h, --ajuda           Esta ajuda.

GOOGLE DRIVE
      --conectar        Liga o Drive e sai, sem backup.
      --reconectar      Refaz a autorizacao mesmo se ja existir uma.
      --drive-remote N  Nome do remote no rclone. Padrao: $DRIVE_REMOTE
      --drive-escopo E  'total' (padrao) ou 'arquivos'.

SE PARAR NO MEIO
  Todo dump que sobe deixa uma linha no registro. Se a execucao morrer no
  banco 7 de 10, rode o mesmo comando outra vez dentro de $JANELA_HORAS horas:
  ele volta para a MESMA pasta de data e faz so os que faltaram. Mais velho
  que isso, ele comeca um ciclo novo, porque dump de ontem misturado com dump
  de hoje na mesma pasta nao e retrato de nada.

RESTAURAR UM BANCO
  1. baixe <nome>.sql.gz do Drive
  2. confira:   gunzip -t <nome>.sql.gz
  3. restaure:  gunzip -c <nome>.sql.gz | mysql -h HOST -P PORTA -u USUARIO -p BANCO

CRON, DEPOIS DE JA TER CONECTADO UMA VEZ
  0 3 * * * /caminho/$NOME_SCRIPT /caminho/credentials.json --manter 30 -s >> /var/log/backup-db.log 2>&1
AJUDA
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
while (($#)); do
  case "$1" in
    --drive-pasta)     DRIVE_PASTA="${2:?nome}"; shift 2 ;;
    --bancos)          BANCOS_PEDIDOS="${2:?lista}"; shift 2 ;;
    --excluir)         BANCOS_EXCLUIDOS="${2:?lista}"; shift 2 ;;
    --sem-data)        SEM_DATA=1; shift ;;
    --manter)          MANTER="${2:?numero}"; shift 2 ;;
    --nova)            NOVA=1; shift ;;
    --janela-horas)    JANELA_HORAS="${2:?horas}"; shift 2 ;;
    -z|--compressao)   NIVEL_COMPRESSAO="${2:?nivel}"; shift 2 ;;
    --so-estrutura)    SO_ESTRUTURA=1; shift ;;
    --cifrar)          CIFRAR=1; shift ;;
    --senha-arquivo)   ARQUIVO_SENHA="${2:?arquivo}"; CIFRAR=1; shift 2 ;;
    --manter-local)    MANTER_LOCAL=1; shift ;;
    --forcar)          FORCAR=1; shift ;;
    --simular)         SIMULAR=1; shift ;;
    -s|--sim)          SIM=1; shift ;;
    --sem-nice)        SEM_NICE=1; shift ;;
    --registro)        SO_REGISTRO=1; shift ;;
    --estado)          ESTADO_PEDIDO="${2:?caminho}"; shift 2 ;;
    --conectar)        SO_CONECTAR=1; shift ;;
    --reconectar)      RECONECTAR=1; SO_CONECTAR=1; shift ;;
    --drive-remote)    DRIVE_REMOTE="${2:?nome}"; shift 2 ;;
    --drive-escopo)    DRIVE_ESCOPO="${2:?escopo}"; shift 2 ;;
    -h|--ajuda|--help) ajuda; exit 0 ;;
    -*) morre "opcao desconhecida: $1 (use --ajuda)" ;;
    *)  if [[ -z "$ARQUIVO_CRED" ]]; then ARQUIVO_CRED="$1"; shift
        else morre "so um arquivo de credencial por execucao (recebi '$ARQUIVO_CRED' e '$1')"; fi ;;
  esac
done

[[ "$NIVEL_COMPRESSAO" =~ ^[1-9]$ ]] || morre "--compressao precisa ser de 1 a 9"
[[ "$MANTER" =~ ^[0-9]+$ ]]          || morre "--manter precisa ser um numero"
[[ "$JANELA_HORAS" =~ ^[0-9]+$ ]]    || morre "--janela-horas precisa ser um numero"
case "$DRIVE_ESCOPO" in total|arquivos) ;; *) morre "--drive-escopo aceita 'total' ou 'arquivos'" ;; esac
if ((MANTER > 0)) && ((SEM_DATA)); then
  morre "--manter so faz sentido com historico por data (sem --sem-data, que e o padrao)"
fi

# O dump tem dado de cliente, e o registro diz quais bancos existem e onde eles
# moram. Nasce 600, em vez de nascer 644 e virar 600 no chmod de depois: nesse
# meio tempo qualquer usuario da maquina leria.
umask 077

# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------
tem() { command -v "$1" >/dev/null 2>&1; }

legivel() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    s="B KB MB GB TB PB"; split(s,u," "); i=1;
    while (b>=1024 && i<6) { b/=1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

tamanho_arquivo() {
  [[ -f "$1" ]] || { echo 0; return 0; }
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

espaco_livre() {
  local v=""
  v="$(df -P "$1" 2>/dev/null | awk 'NR==2{print ($4+0)*1024; exit}')" || v=""
  [[ -n "$v" ]] || v=0
  printf '%s\n' "$v"
}

md5_local() {
  if tem md5sum; then md5sum "$1" | awk '{print $1}'; return 0; fi
  if tem md5;    then md5 -q "$1"; return 0; fi
  printf ''
}

minusculo() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

tem_terminal() { ( exec 3<>/dev/tty ) 2>/dev/null; }

pergunta_sim() {
  local r=""
  ((SIM)) && return 0
  tem_terminal || return 1
  printf '  %s [s/N] ' "$1" > /dev/tty
  read -r r < /dev/tty || true
  [[ "$r" == [sS]* ]]
}

le_do_tty() {
  local r=""
  tem_terminal || return 1
  printf '  %s: ' "$1" > /dev/tty
  if [[ "${2:-}" == "oculto" ]]; then
    read -r -s r < /dev/tty || true
    printf '\n' > /dev/tty
  else
    read -r r < /dev/tty || true
  fi
  printf '%s' "$r"
}

na_lista() {
  local alvo="$1" lista="$2" item
  [[ -n "$lista" ]] || return 1
  local IFS=','
  for item in $lista; do
    item="${item// /}"
    [[ "$item" == "$alvo" ]] && return 0
  done
  return 1
}

na_saida() {
  local st=$?
  trap - EXIT INT TERM
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"
  exit "$st"
}

id_curto() {
  local texto="$1" h=""
  if tem sha1sum;  then h="$(printf '%s' "$texto" | sha1sum | cut -c1-8)"
  elif tem shasum; then h="$(printf '%s' "$texto" | shasum  | cut -c1-8)"
  elif tem md5sum; then h="$(printf '%s' "$texto" | md5sum  | cut -c1-8)"
  fi
  [[ -n "$h" ]] || h="semid"
  printf '%s' "$h"
}

apelido() { printf '%s' "$1" | tr '/\\: ' '----' | tr -cd 'A-Za-z0-9._-' | cut -c1-40; }

# ---------------------------------------------------------------------------
# Google Drive
#
# O transporte e o rclone. A autorizacao usa a chave que ja vem embutida nele:
# nao precisa de projeto no Google Cloud, nem de faturamento, nem de aprovacao.
# O token fica em rclone.conf com permissao 600, e o rclone renova o acesso
# sozinho depois, sem pedir nada de novo.
# ---------------------------------------------------------------------------
instala_rclone() {
  tem rclone && return 0
  passo "Instalando o rclone (transporte para o Google Drive)"
  if tem apt-get && [[ $EUID -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y rclone >>"$LOG" 2>&1 && tem rclone && {
      feito "rclone instalado pelo apt"; return 0; }
  elif tem dnf && [[ $EUID -eq 0 ]]; then
    dnf install -y rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo dnf"; return 0; }
  elif tem yum && [[ $EUID -eq 0 ]]; then
    yum install -y rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo yum"; return 0; }
  elif tem brew; then
    brew install rclone >>"$LOG" 2>&1 && tem rclone && { feito "rclone instalado pelo brew"; return 0; }
  fi
  aviso "o gerenciador de pacotes nao tinha o rclone, ou faltou permissao"
  printf '\n  O jeito oficial de instalar e baixar e rodar o script do site do rclone:\n'
  printf '    curl https://rclone.org/install.sh | sudo bash\n\n'
  printf '  Isso baixa e executa um script de rclone.org nesta maquina.\n'
  if pergunta_sim "Autoriza esse download e execucao?"; then
    tem curl || { falha "preciso do curl para baixar o instalador"; return 1; }
    local comsudo=""
    [[ $EUID -eq 0 ]] || comsudo="sudo"
    if curl -fsSL https://rclone.org/install.sh 2>>"$LOG" | ${comsudo:+$comsudo} bash >>"$LOG" 2>&1 && tem rclone; then
      feito "rclone instalado"
      return 0
    fi
    falha "a instalacao do rclone nao terminou (veja $LOG)"
    return 1
  fi
  falha "sem rclone nao da para enviar ao Drive. Instale a mao e rode de novo."
  return 1
}

arquivo_conf_rclone() {
  local c=""
  c="$(rclone config file 2>/dev/null | tail -1 | tr -d '\r')" || c=""
  [[ -n "$c" ]] || c="$HOME/.config/rclone/rclone.conf"
  printf '%s' "$c"
}

remote_ja_existe() { rclone listremotes 2>/dev/null | grep -qx "${DRIVE_REMOTE}:"; }
testa_remote()     { rclone lsd "${DRIVE_REMOTE}:" >/dev/null 2>>"$LOG"; }

escreve_remote_rclone() {
  local token="$1" escopo="${2:-}"
  local conf; conf="$(arquivo_conf_rclone)"
  mkdir -p "$(dirname "$conf")" && chmod 700 "$(dirname "$conf")" 2>/dev/null || true
  if [[ -f "$conf" ]]; then
    cp -p "$conf" "$conf.antes-$CARIMBO" 2>/dev/null || true
    awk -v alvo="[$DRIVE_REMOTE]" '
      /^\[/ { dentro = ($0 == alvo) }
      !dentro { print }
    ' "$conf" > "$conf.novo" && mv "$conf.novo" "$conf"
  fi
  umask 077
  if [[ -s "$conf" ]] && [[ -n "$(tail -c 2 "$conf" | tr -d '\n')" ]]; then
    printf '\n' >> "$conf"
  fi
  {
    printf '[%s]\n' "$DRIVE_REMOTE"
    printf 'type = drive\n'
    # client_id e client_secret ficam de fora de proposito: assim o rclone usa
    # a chave que vem embutida nele, inclusive para renovar o acesso. Gravar
    # campo vazio faria a renovacao falhar depois.
    [[ -n "$escopo" ]] && printf 'scope = %s\n' "$escopo"
    printf 'token = %s\n' "$token"
    printf '\n'
  } >> "$conf"
  chmod 600 "$conf"
  feito "remote '$DRIVE_REMOTE' gravado em $conf"
}

escopo_conf() {
  case "$DRIVE_ESCOPO" in arquivos) printf 'drive.file' ;; *) printf 'drive' ;; esac
}
escopo_codificado() {
  case "$DRIVE_ESCOPO" in
    arquivos) printf 'https%%3A%%2F%%2Fwww.googleapis.com%%2Fauth%%2Fdrive.file' ;;
    *)        printf 'https%%3A%%2F%%2Fwww.googleapis.com%%2Fauth%%2Fdrive' ;;
  esac
}

valor_json() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
numero_json() {
  printf '%s' "$1" | tr -d '\n\r' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p" | head -1
}

# ---------------------------------------------------------------------------
# Autorizacao: um link, e a URL de volta. So isso.
#
# O script monta o link, voce abre no navegador, escolhe a conta Google e clica
# em Permitir. O Google devolve o navegador para 127.0.0.1:53682, que nao tem
# ninguem escutando, entao a pagina da erro. Isso e o esperado: o que importa
# esta na barra de endereco. Voce copia a URL inteira, cola aqui, e o script
# troca o codigo dela por um token.
#
# A chave usada e a que ja vem embutida no proprio rclone, publicada no codigo
# dele. Credencial de aplicativo instalado nao e confidencial por desenho, e e
# por usar essa que nao existe projeto no Google Cloud para criar, nem
# faturamento, nem tela de verificacao. O token gravado sai sem client_id e sem
# client_secret, para o rclone renovar o acesso com a chave dele mesmo.
# ---------------------------------------------------------------------------
CLIENTE_RCLONE="202264815644.apps.googleusercontent.com"
SEGREDO_RCLONE="X4Z3ca8xfWDb1Voo-F9a7ZxJ"
REDIRECIONAMENTO="http://127.0.0.1:53682/"
REDIRECIONAMENTO_CODIFICADO="http%3A%2F%2F127.0.0.1%3A53682%2F"

autoriza_por_link() {
  local id="$CLIENTE_RCLONE" segredo="$SEGREDO_RCLONE"

  local verificador="" desafio="" parte_pkce=""
  if tem openssl; then
    verificador="$(openssl rand -base64 48 2>/dev/null | tr -d '\n\r=' | tr '+/' '-_')"
    desafio="$(printf '%s' "$verificador" | openssl dgst -binary -sha256 2>/dev/null \
               | openssl base64 2>/dev/null | tr -d '\n\r=' | tr '+/' '-_')"
    if [[ -n "$verificador" && -n "$desafio" ]]; then
      parte_pkce="&code_challenge=$desafio&code_challenge_method=S256"
    else
      verificador=""
    fi
  fi

  local url
  url="https://accounts.google.com/o/oauth2/v2/auth?client_id=${id}"
  url="${url}&redirect_uri=${REDIRECIONAMENTO_CODIFICADO}&response_type=code"
  url="${url}&scope=$(escopo_codificado)&access_type=offline&prompt=consent${parte_pkce}"

  {
    printf '\n'
    printf '  ABRA ESTE LINK NO NAVEGADOR DO SEU COMPUTADOR:\n\n'
    printf '%s\n\n' "$url"
    printf '  1. escolha a conta Google onde o backup vai ficar;\n'
    printf '  2. se aparecer aviso de aplicativo nao verificado, clique em\n'
    printf '     Avancado e depois em Acessar;\n'
    printf '  3. clique em Permitir;\n'
    printf '  4. a pagina seguinte vai dizer que nao conseguiu acessar\n'
    printf '     127.0.0.1. E isso mesmo, nao deu errado: o endereco dela E a\n'
    printf '     sua resposta. Copie a barra de endereco INTEIRA e cole aqui.\n\n'
    printf '  A URL comeca com %s e tem code= no meio.\n\n' "$REDIRECIONAMENTO"
  } > /dev/tty

  local colado codigo
  colado="$(le_do_tty 'Cole a URL completa')"
  codigo="$(printf '%s' "$colado" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p' | head -1)"
  [[ -n "$codigo" ]] || codigo="$(printf '%s' "$colado" | tr -d '[:space:]')"
  if [[ -z "$codigo" ]]; then
    falha "nao achei o code= no que voce colou"
    aviso "cole a URL inteira da barra de endereco, a que comeca com $REDIRECIONAMENTO"
    return 1
  fi
  case "$colado" in
    *error=access_denied*) falha "a autorizacao foi recusada na tela do Google"; return 1 ;;
    *error=*)              falha "o Google devolveu um erro na URL: ${colado#*error=}"; return 1 ;;
  esac
  codigo="$(printf '%s' "$codigo" | sed 's/%2F/\//g; s/%2f/\//g')"

  diz "trocando o codigo por um token"
  local d resposta acesso atualizacao segundos expiracao erro
  d="$(mktemp -d)"; chmod 700 "$d"
  umask 077
  printf '%s' "$codigo"           > "$d/code"
  printf '%s' "$id"               > "$d/id"
  printf '%s' "$segredo"          > "$d/secret"
  printf '%s' "$REDIRECIONAMENTO" > "$d/redirect"
  [[ -n "$verificador" ]] && printf '%s' "$verificador" > "$d/verifier"

  declare -a extra=()
  [[ -n "$verificador" ]] && extra=(--data-urlencode "code_verifier@$d/verifier")

  resposta="$(curl -fsS --max-time 60 https://oauth2.googleapis.com/token \
    --data-urlencode "code@$d/code" \
    --data-urlencode "client_id@$d/id" \
    --data-urlencode "client_secret@$d/secret" \
    --data-urlencode "redirect_uri@$d/redirect" \
    ${extra[@]+"${extra[@]}"} \
    -d grant_type=authorization_code 2>>"$LOG")" || resposta=""
  rm -rf "$d"

  if [[ -z "$resposta" ]]; then
    falha "o Google nao aceitou a troca do codigo pelo token"
    aviso "o codigo vale poucos minutos. Rode --conectar de novo e cole a URL logo depois de autorizar."
    return 1
  fi

  erro="$(valor_json "$resposta" error)"
  if [[ -n "$erro" ]]; then
    falha "o Google recusou: $erro"
    [[ "$erro" == "invalid_grant" ]] && aviso "o codigo ja foi usado ou venceu. Autorize de novo e cole a URL na hora."
    return 1
  fi

  acesso="$(valor_json "$resposta" access_token)"
  atualizacao="$(valor_json "$resposta" refresh_token)"
  segundos="$(numero_json "$resposta" expires_in)"
  [[ -n "$segundos" ]] || segundos=3600

  if [[ -z "$acesso" ]]; then
    falha "a resposta do Google nao trouxe access_token"
    return 1
  fi
  if [[ -z "$atualizacao" ]]; then
    falha "a resposta do Google nao trouxe refresh_token, entao o envio pararia de funcionar em uma hora"
    aviso "isso acontece quando esta conta ja autorizou antes. Remova o acesso em myaccount.google.com/permissions e autorize de novo."
    return 1
  fi

  expiracao="$(date -u -d "+${segundos} seconds" '+%Y-%m-%dT%H:%M:%S.000000000Z' 2>/dev/null)" \
    || expiracao="$(date -u '+%Y-%m-%dT%H:%M:%S.000000000Z')"

  escreve_remote_rclone \
    "{\"access_token\":\"$acesso\",\"token_type\":\"Bearer\",\"refresh_token\":\"$atualizacao\",\"expiry\":\"$expiracao\"}" \
    "$(escopo_conf)"
  return 0
}

configura_drive() {
  passo "Conectando o Google Drive"
  instala_rclone || return 1
  if remote_ja_existe && ((RECONECTAR == 0)); then
    if testa_remote; then
      feito "o remote '$DRIVE_REMOTE' ja esta conectado e respondendo"
      return 0
    fi
    aviso "o remote '$DRIVE_REMOTE' existe mas nao responde, vou refazer a autorizacao"
  fi
  if ! tem_terminal; then
    falha "a primeira autorizacao do Drive precisa de terminal, porque alguem clica em Permitir"
    aviso "rode uma vez na mao: ./$NOME_SCRIPT --conectar. Depois disso o backup roda sozinho no cron."
    return 1
  fi
  tem curl || { falha "preciso do curl para trocar o codigo pelo token"; return 1; }
  autoriza_por_link || return 1
  diz "testando a conexao"
  if testa_remote; then
    feito "Google Drive conectado"
    return 0
  fi
  falha "o remote foi gravado mas o Drive nao respondeu (veja $LOG)"
  return 1
}

opcoes_rclone() {
  printf '%s\n' \
    --config "$(arquivo_conf_rclone)" \
    --drive-chunk-size 64M \
    --retries 5 --low-level-retries 20 \
    --stats 20s --stats-one-line \
    --log-level INFO --log-file "$LOG"
}

envia_arquivo() {
  local arquivo="$1" nome="$2"
  local local_bytes remoto md5l md5r
  declare -a opcoes=()
  mapfile -t opcoes < <(opcoes_rclone)
  MD5_ENVIADO=""

  local_bytes="$(tamanho_arquivo "$arquivo")"
  if ! rclone copyto "${opcoes[@]}" "$arquivo" "$PASTA_DRIVE/$nome"; then
    falha "$nome: o envio para o Drive falhou (veja $LOG)"
    return 1
  fi

  remoto="$(rclone size --config "$(arquivo_conf_rclone)" --json "$PASTA_DRIVE/$nome" 2>>"$LOG" \
            | sed -n 's/.*"bytes":[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -1)" || remoto=""
  if [[ "$remoto" != "$local_bytes" ]]; then
    falha "$nome: o tamanho no Drive (${remoto:-nada}) nao bate com o local ($local_bytes)"
    return 1
  fi

  CONFERENCIA="tamanho"
  md5r="$(rclone md5sum --config "$(arquivo_conf_rclone)" "$PASTA_DRIVE/$nome" 2>>"$LOG" \
          | awk 'NR==1{print $1}')" || md5r=""
  if [[ "$md5r" =~ ^[0-9a-fA-F]{32}$ ]]; then
    md5l="$(md5_local "$arquivo")"
    if [[ -n "$md5l" ]]; then
      if [[ "$(minusculo "$md5r")" != "$(minusculo "$md5l")" ]]; then
        falha "$nome: o conteudo no Drive nao confere (MD5 $md5r contra $md5l)"
        return 1
      fi
      CONFERENCIA="MD5"
      MD5_ENVIADO="$(minusculo "$md5l")"
    fi
  fi

  BYTES_ENVIADOS=$((BYTES_ENVIADOS + local_bytes))
  return 0
}

retencao_drive() {
  ((SEM_DATA)) && return 0
  ((MANTER > 0)) || return 0
  local base="${DRIVE_REMOTE}:${DRIVE_PASTA}"
  passo "Guardando as $MANTER pastas de data mais novas no Drive"
  local n=0 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    n=$((n + 1))
    ((n > MANTER)) || continue
    if rclone purge --config "$(arquivo_conf_rclone)" "$base/$p" >>"$LOG" 2>&1; then
      diz "removida do Drive: $p"
    else
      aviso "nao consegui remover do Drive: $p"
    fi
  done < <(rclone lsf --dirs-only --config "$(arquivo_conf_rclone)" "$base" 2>>"$LOG" \
           | sed 's#/$##' \
           | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$' \
           | sort -r || true)
  return 0
}

# ---------------------------------------------------------------------------
# MySQL
# ---------------------------------------------------------------------------
# O mesmo trabalho tem dois nomes de programa, e as duas familias nao sao
# intercambiaveis: o mysqldump 8 do MySQL consulta uma tabela de histograma que o
# MariaDB nao tem, e o mariadb-dump nao conhece algumas opcoes do MySQL 8. Em
# Debian e Ubuntu o pacote do MariaDB instala "mysqldump" como atalho para
# "mariadb-dump", entao o nome do programa NAO diz de que familia ele e: quem diz
# e o --version.
sabor_do_binario() {
  local v=""
  v="$("$1" --version 2>/dev/null | head -1)" || v=""
  case "$v" in
    *MariaDB*|*mariadb*) printf 'MariaDB' ;;
    "")                  printf 'desconhecido' ;;
    *)                   printf 'MySQL' ;;
  esac
}

mapeia_clientes() {
  local b caminho visto=""
  DUMPS_DISPONIVEIS=(); CLIENTES_DISPONIVEIS=()
  for b in mysqldump mariadb-dump; do
    tem "$b" || continue
    caminho="$(command -v "$b")"
    # em Debian o mysqldump e atalho para o mariadb-dump: o mesmo arquivo nao
    # entra duas vezes, senao a troca de cliente tentaria o mesmo programa
    caminho="$(readlink -f "$caminho" 2>/dev/null || printf '%s' "$caminho")"
    case "$visto" in *"|$caminho|"*) continue ;; esac
    visto="$visto|$caminho|"
    DUMPS_DISPONIVEIS+=("$b|$(sabor_do_binario "$b")")
  done
  visto=""
  for b in mysql mariadb; do
    tem "$b" || continue
    caminho="$(command -v "$b")"
    caminho="$(readlink -f "$caminho" 2>/dev/null || printf '%s' "$caminho")"
    case "$visto" in *"|$caminho|"*) continue ;; esac
    visto="$visto|$caminho|"
    CLIENTES_DISPONIVEIS+=("$b|$(sabor_do_binario "$b")")
  done
  ((${#DUMPS_DISPONIVEIS[@]})) || return 1
  ((${#CLIENTES_DISPONIVEIS[@]})) || return 1
  BIN_DUMP="${DUMPS_DISPONIVEIS[0]%%|*}"
  BIN_MYSQL="${CLIENTES_DISPONIVEIS[0]%%|*}"
  SABOR_CLIENTE="${DUMPS_DISPONIVEIS[0]##*|}"
  return 0
}

# Os binarios de dump na ordem que faz sentido para ESTE servidor: a familia que
# bate com a do servidor primeiro, a outra depois. Servidor MariaDB com
# mariadb-dump disponivel nunca mais cai no COLUMN_STATISTICS.
candidatos_dump() {  # <sabor do servidor>
  local sabor="$1" item
  for item in ${DUMPS_DISPONIVEIS[@]+"${DUMPS_DISPONIVEIS[@]}"}; do
    [[ "${item##*|}" == "$sabor" ]] && printf '%s\n' "$item"
  done
  for item in ${DUMPS_DISPONIVEIS[@]+"${DUMPS_DISPONIVEIS[@]}"}; do
    [[ "${item##*|}" == "$sabor" ]] || printf '%s\n' "$item"
  done
}

instala_cliente_mysql() {
  mapeia_clientes && return 0
  passo "Instalando o cliente MySQL"
  if tem apt-get && [[ $EUID -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-client >>"$LOG" 2>&1 \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-client >>"$LOG" 2>&1
  elif tem dnf && [[ $EUID -eq 0 ]]; then
    dnf install -y mysql >>"$LOG" 2>&1 || dnf install -y mariadb >>"$LOG" 2>&1
  elif tem yum && [[ $EUID -eq 0 ]]; then
    yum install -y mysql >>"$LOG" 2>&1 || yum install -y mariadb >>"$LOG" 2>&1
  elif tem brew; then
    brew install mysql-client >>"$LOG" 2>&1
  fi
  if mapeia_clientes; then
    feito "cliente instalado"
    return 0
  fi
  falha "preciso de um cliente de linha de comando (mysql ou mariadb) e de um programa de dump (mysqldump ou mariadb-dump)"
  aviso "no Ubuntu:  sudo apt-get install -y mysql-client   ou   sudo apt-get install -y mariadb-client"
  aviso "ter OS DOIS instalados e melhor: o script escolhe por servidor qual usar"
  return 1
}

# Arquivo de opcoes do MySQL, em vez de senha na linha de comando. Argumento de
# linha de comando aparece no ps para qualquer usuario da maquina, e o proprio
# mysqldump avisa disso. O arquivo nasce 600 dentro do TMP, que e apagado na
# saida do script.
# Barra invertida e aspa dupla sao os dois unicos caracteres que o arquivo de
# opcoes do MySQL trata de forma especial, e os dois precisam ser dobrados. A
# troca e feita pelo proprio bash, nao por sed: a citacao de barra invertida
# dentro de um s/// de sed e um campo minado, e aqui ela nasceu errada uma vez,
# com o sed recusando a expressao e devolvendo senha vazia. De quebra, isto nao
# abre dois processos por banco.
escapa_cnf() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

arquivo_opcoes_mysql() {  # <servidor> <porta> <usuario> <senha> -> caminho
  local h="$1" p="$2" u="$3" s="$4" arq
  arq="$TMP/mysql-$RANDOM.cnf"
  ( umask 077
    {
      printf '[client]\n'
      printf 'host="%s"\n'     "$(escapa_cnf "$h")"
      printf 'port=%s\n'       "$p"
      printf 'user="%s"\n'     "$(escapa_cnf "$u")"
      printf 'password="%s"\n' "$(escapa_cnf "$s")"
      # sem isto, host=localhost usa o soquete local e IGNORA a porta, que e o
      # jeito silencioso de fazer backup do banco errado
      printf 'protocol=TCP\n'
    } > "$arq" )
  chmod 600 "$arq" 2>/dev/null || true
  printf '%s' "$arq"
}

# Quantas linhas o log tem agora, para depois ler SO o que o cliente acrescentou.
linhas_log() { [[ -f "$LOG" ]] || { echo 0; return; }; wc -l < "$LOG" 2>/dev/null | tr -d ' ' || echo 0; }

# A mensagem que o servidor deu, em uma linha, para entrar no aviso em vez de
# virar "veja o log". Mandar a pessoa abrir um arquivo e pior quando o arquivo
# fica dentro de um diretorio temporario que o proprio script apaga na saida,
# que foi o que aconteceu na primeira execucao real deste script.
erro_recente() {  # <marca de linhas_log>
  local marca="${1:-0}" t=""
  [[ -f "$LOG" ]] || { printf ''; return; }
  t="$(tail -n "+$((marca + 1))" "$LOG" 2>/dev/null \
       | grep -iE "error|denied|unknown|failed|can.t|cannot|refused|timed out" \
       | tail -2 | tr "\n" " ")" || t=""
  printf '%s' "$t" | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-240
}

# Testa a conexao com cada cliente disponivel e para no primeiro que responder.
# Cliente MariaDB e cliente MySQL negociam autenticacao de forma diferente, e um
# servidor que recusa um pode aceitar o outro.
testa_conexao() {  # <opc>
  local opc="$1" item bin marca
  ERRO_CLIENTE=""
  for item in ${CLIENTES_DISPONIVEIS[@]+"${CLIENTES_DISPONIVEIS[@]}"}; do
    bin="${item%%|*}"
    marca="$(linhas_log)"
    if "$bin" --defaults-extra-file="$opc" -N -B -e "SELECT 1" >/dev/null 2>>"$LOG"; then
      BIN_MYSQL="$bin"
      return 0
    fi
    ERRO_CLIENTE="$(erro_recente "$marca")"
  done
  return 1
}

# O servidor ja diz por que recusou. Esta funcao so traduz a frase dele para o
# que a pessoa precisa fazer, porque as causas moram em lugares diferentes: senha
# esta no credentials.json, firewall esta na rede, plugin esta no cliente.
dica_da_recusa() {  # <frase do servidor>
  case "$1" in
    *"Access denied for user"*|*"access denied for user"*)
      printf 'a senha ou o usuario nao conferem, ou esse usuario nao tem permissao de vir do IP desta maquina. Confira o credentials.json e o GRANT do usuario.' ;;
    *"Unknown database"*|*"unknown database"*)
      printf 'o usuario conecta, mas nao existe banco com esse nome nesta porta. Confira o campo "banco".' ;;
    *"Can't connect"*|*"Connection refused"*|*"connect to server"*)
      printf 'nada atendeu nessa porta. Confira se a instancia esta no ar, se a porta e essa, e se o firewall deixa esta maquina chegar.' ;;
    *"timed out"*|*"Lost connection"*|*timeout*)
      printf 'o servidor nao respondeu em tempo. Costuma ser rede no caminho ou servidor sobrecarregado.' ;;
    *plugin*|*"authentication"*|*caching_sha2*)
      printf 'o servidor pede um metodo de autenticacao que este cliente nao faz. Instalar a outra familia de cliente costuma resolver: sudo apt-get install -y mysql-client mariadb-client' ;;
    *"too many connections"*|*"Too many"*)
      printf 'o servidor esta com todas as conexoes ocupadas. Tente de novo mais tarde, ou aumente max_connections.' ;;
    *"SSL"*|*"TLS"*|*"secure connection"*)
      printf 'o servidor exige conexao cifrada e a negociacao falhou. Confira a configuracao de TLS do servidor.' ;;
    "")
      printf 'o cliente nao devolveu mensagem nenhuma, o que costuma ser rede: a conexao morreu antes de o servidor falar.' ;;
    *) printf '' ;;
  esac
}

# "MariaDB 10.11.6" ou "MySQL 8.0.36". Vazio quando nao deu para saber.
sabor_servidor() {  # <opc>
  local v=""
  v="$("$BIN_MYSQL" --defaults-extra-file="$1" -N -B -e "SELECT VERSION()" 2>>"$LOG" | head -1 | tr -d "\r")" || v=""
  [[ -n "$v" ]] || { printf ''; return 1; }
  case "$v" in
    *MariaDB*|*mariadb*) printf 'MariaDB %s' "${v%%-*}" ;;
    *)                   printf 'MySQL %s' "${v%%-*}" ;;
  esac
  return 0
}

# imprime "tabelas bytes myisam" do banco
info_banco() {
  local opc="$1" b="$2"
  "$BIN_MYSQL" --defaults-extra-file="$opc" -N -B -e "
    SELECT COUNT(*),
           COALESCE(SUM(data_length + index_length), 0),
           COALESCE(SUM(engine = 'MyISAM'), 0)
    FROM information_schema.tables
    WHERE table_schema = '$b' AND table_type = 'BASE TABLE'" 2>>"$LOG"
}

# ---------------------------------------------------------------------------
# As opcoes do dump, escolhidas lendo o que o servidor responde
#
# Em servidor de verdade o mysqldump falha por motivos que nao se sabe de
# antemao, e cada um tem uma correcao diferente:
#
#   o que o servidor responde                      o que resolve
#   ---------------------------------------------  -----------------------
#   Unknown table 'COLUMN_STATISTICS'              --column-statistics=0
#   you need (at least one of) the PROCESS ...      --no-tablespaces
#   Access denied ... LOCK TABLES                  --skip-lock-tables
#   PROCEDURE, mysql.proc, EVENT                   sem --routines --events
#   TRIGGER                                        sem --triggers
#
# O COLUMN_STATISTICS e o mais comum e o menos obvio: ele aparece quando o
# CLIENTE e o mysqldump 8 do MySQL e o SERVIDOR e MariaDB. O mysqldump 8 consulta
# uma tabela de histograma que o MariaDB nao tem, e o dump INTEIRO morre com
# "Unknown table", que nao parece ter nada a ver com o que esta errado. Na
# primeira execucao real deste script, seis de dez bancos falharam assim e a
# mensagem dizia apenas que nem o nivel minimo passou.
#
# Por isso a sonda nao e uma escada fixa de tres degraus: ela tenta, LE o erro,
# muda o que o erro aponta, e tenta de novo. Converge em uma a tres tentativas,
# diz na tela qual ajuste foi preciso, e quando nao ha jeito mostra a frase do
# servidor em vez de mandar abrir um arquivo.
#
# A sonda e um dump SEM DADO, que exercita os mesmos privilegios e as mesmas
# consultas de metadado sem ler uma linha de tabela.
# ---------------------------------------------------------------------------
escolhe_opcoes_dump() {  # <opc> <banco> <sabor do servidor>
  local opc="$1" b="$2" sabor="${3:-}"
  local rotinas=1 gatilhos=1 tablespaces=0 colstats=0 semtrava=0
  local tentativa=0 marca erro antes
  declare -a feitos=()

  ((TEM_NO_TABLESPACES)) && tablespaces=1
  # cliente MySQL 8 contra servidor MariaDB: o histograma nao existe la, entao
  # desligar ja na primeira tentativa poupa uma ida e volta
  if ((TEM_COLUMN_STATISTICS)) && [[ "$sabor" == MariaDB* ]]; then
    colstats=1
    feitos+=("sem estatistica de coluna, porque o servidor e MariaDB")
  fi

  AJUSTES=""; ERRO_CLIENTE=""; NIVEL_DUMP=""

  while ((tentativa < 8)); do
    tentativa=$((tentativa + 1))
    FLAGS_DUMP=(--single-transaction --quick --default-character-set=utf8mb4)
    ((tablespaces)) && FLAGS_DUMP+=(--no-tablespaces)
    ((colstats))    && FLAGS_DUMP+=(--column-statistics=0)
    ((semtrava))    && FLAGS_DUMP+=(--skip-lock-tables)
    ((rotinas))     && FLAGS_DUMP+=(--routines --events)
    ((gatilhos))    && FLAGS_DUMP+=(--triggers)

    marca="$(linhas_log)"
    if "$BIN_DUMP" --defaults-extra-file="$opc" "${FLAGS_DUMP[@]}" --no-data "$b" >/dev/null 2>>"$LOG"; then
      NIVEL_DUMP="completo"
      ((rotinas))  || NIVEL_DUMP="sem rotina e evento"
      ((gatilhos)) || NIVEL_DUMP="minimo"
      AJUSTES="$(printf '%s; ' ${feitos[@]+"${feitos[@]}"})"
      AJUSTES="${AJUSTES%; }"
      return 0
    fi

    erro="$(erro_recente "$marca")"
    ERRO_CLIENTE="$erro"
    antes="$colstats$tablespaces$semtrava$rotinas$gatilhos"
    diagnosticou=0

    # O diagnostico so vale quando ele consegue MUDAR alguma coisa. Um erro que
    # aponta um ajuste ja aplicado nao e diagnostico: insistir nele parava a
    # sonda e dois bancos que deviam apenas degradar passaram a falhar.
    case "$erro" in
      *COLUMN_STATISTICS*|*column_statistics*|*column-statistics*)
        if ((TEM_COLUMN_STATISTICS)) && ((colstats == 0)); then
          colstats=1; diagnosticou=1
          feitos+=("sem estatistica de coluna, que o servidor nao tem")
        fi ;;
      *PROCESS*|*TABLESPACE*|*tablespace*|*Tablespace*)
        if ((TEM_NO_TABLESPACES)) && ((tablespaces == 0)); then
          tablespaces=1; diagnosticou=1
          feitos+=("sem tablespace, que pede o privilegio PROCESS")
        fi ;;
      *"LOCK TABLES"*|*"lock tables"*|*LOCK_TABLES*)
        if ((semtrava == 0)); then
          semtrava=1; diagnosticou=1
          feitos+=("sem travar tabela, que o usuario nao pode")
        fi ;;
    esac

    # Rotina, evento e gatilho nao aparecem no erro com essas palavras: o que
    # aparece e a consulta que o mysqldump tentou. Estas sao as frases que os
    # servidores devolvem de verdade.
    if ((diagnosticou == 0)); then
      case "$erro" in
        *"FUNCTION STATUS"*|*"PROCEDURE STATUS"*|*"function status"*|*"procedure status"*\
        |*mysql.proc*|*"SHOW EVENTS"*|*"show events"*|*EVENT*|*ROUTINE*|*PROCEDURE*)
          if ((rotinas)); then
            rotinas=0; diagnosticou=1
            feitos+=("sem rotina e evento, que o usuario nao alcanca")
          fi ;;
        *"SHOW TRIGGERS"*|*"show triggers"*|*TRIGGER*|*trigger*)
          if ((gatilhos)); then
            gatilhos=0; diagnosticou=1
            feitos+=("sem gatilho, que o usuario nao alcanca")
          fi ;;
      esac
    fi

    # Sem pista aproveitavel, degrada na ordem que custa menos: primeiro o que e
    # extra (rotina, evento, gatilho), depois o que e opcao de leitura.
    if ((diagnosticou == 0)); then
      if ((rotinas)); then
        rotinas=0
        feitos+=("sem rotina e evento, por tentativa")
      elif ((gatilhos)); then
        gatilhos=0
        feitos+=("sem gatilho, por tentativa")
      elif ((TEM_NO_TABLESPACES)) && ((tablespaces == 0)); then
        tablespaces=1
        feitos+=("sem tablespace, por tentativa")
      elif ((semtrava == 0)); then
        semtrava=1
        feitos+=("sem travar tabela, por tentativa")
      elif ((TEM_COLUMN_STATISTICS)) && ((colstats == 0)); then
        colstats=1
        feitos+=("sem estatistica de coluna, por tentativa")
      else
        break
      fi
    fi

    # nada mudou: insistir seria laco infinito
    [[ "$antes" == "$colstats$tablespaces$semtrava$rotinas$gatilhos" ]] && break
  done

  AJUSTES="$(printf '%s; ' ${feitos[@]+"${feitos[@]}"})"
  AJUSTES="${AJUSTES%; }"
  return 1
}

# Tenta cada programa de dump disponivel, come a familia do servidor primeiro.
# Cliente de uma familia contra servidor da outra falha de formas que nenhuma
# opcao conserta, e nesse caso trocar de programa e a correcao.
escolhe_dump_e_opcoes() {  # <opc> <banco> <sabor do servidor>
  local opc="$1" b="$2" sabor="${3:-}" item bin erro_guardado="" ajuste_guardado=""
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    bin="${item%%|*}"
    BIN_DUMP="$bin"
    if escolhe_opcoes_dump "$opc" "$b" "$sabor"; then
      return 0
    fi
    [[ -n "$erro_guardado" ]] || erro_guardado="$ERRO_CLIENTE"
    [[ -n "$ajuste_guardado" ]] || ajuste_guardado="$AJUSTES"
  done < <(candidatos_dump "$sabor")
  ERRO_CLIENTE="${ERRO_CLIENTE:-$erro_guardado}"
  AJUSTES="${AJUSTES:-$ajuste_guardado}"
  return 1
}

dump_banco() {  # <opc> <banco> <saida>
  declare -a estados=()
  declare -a flags=("${FLAGS_DUMP[@]}")
  ((SO_ESTRUTURA)) && flags+=(--no-data)
  set +e
  "$BIN_DUMP" --defaults-extra-file="$1" "${flags[@]}" "$2" 2>>"$LOG" | gzip -"$NIVEL_COMPRESSAO" > "$3"
  estados=("${PIPESTATUS[@]}")
  set -e
  [[ "${estados[0]:-1}" == 0 ]] || return 1
  [[ "${estados[1]:-1}" == 0 ]] || return 1
  return 0
}

# Uma passada so de gunzip prova tres coisas ao mesmo tempo: o CRC do gzip (o
# gunzip falha se o arquivo veio truncado ou corrompido), quantas tabelas
# sairam, e a marca que o mysqldump escreve na ultima linha. Dump sem essa marca
# e dump que parou no meio, e e o jeito mais comum de ter um arquivo com cara de
# backup bom que nao restaura nada.
TABELAS_NO_DUMP=0
confere_dump() {  # <arquivo>
  local arq="$1" r=""
  TABELAS_NO_DUMP=0
  r="$(gunzip -c "$arq" 2>>"$LOG" | awk '
        /^CREATE TABLE/        { t++ }
        /^-- Dump completed/   { fim = 1 }
        END { printf "%d %d", t+0, fim+0 }')" || return 1
  local t fim
  read -r t fim <<< "$r"
  TABELAS_NO_DUMP="${t:-0}"
  [[ "${fim:-0}" == 1 ]] || return 2
  return 0
}

cifra_arquivo() {  # <arquivo> -> imprime o novo caminho
  local arq="$1"
  declare -a senha=()
  if tem gpg; then
    [[ -n "$ARQUIVO_SENHA" ]] && senha=(--batch --yes --passphrase-file "$ARQUIVO_SENHA")
    gpg "${senha[@]+${senha[@]}}" --batch --yes --symmetric --cipher-algo AES256 \
        -o "$arq.gpg" "$arq" 2>>"$LOG" || return 1
    rm -f "$arq"
    printf '%s' "$arq.gpg"
    return 0
  fi
  [[ -n "$ARQUIVO_SENHA" ]] && senha=(-pass "file:$ARQUIVO_SENHA")
  openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
    -in "$arq" -out "$arq.enc" "${senha[@]+${senha[@]}}" 2>>"$LOG" || return 1
  rm -f "$arq"
  printf '%s' "$arq.enc"
  return 0
}

# ---------------------------------------------------------------------------
# credentials.json
# ---------------------------------------------------------------------------
# Comando que existe no PATH nao e comando que funciona. No Windows o "python3"
# costuma ser um atalho da Microsoft Store: ele esta no PATH, imprime um recado
# pedindo para instalar, e SAI COM 0. Quem confia no "command -v" acha que tem
# Python e recebe saida vazia com cara de sucesso. A unica pergunta honesta e se
# o comando responde certo, entao a sonda e uma conta que ele tem que acertar.
PY_BOM=""
acha_python() {
  [[ -n "$PY_BOM" ]] && { printf '%s' "$PY_BOM"; return 0; }
  local c
  for c in python3 python; do
    tem "$c" || continue
    [[ "$("$c" -c 'print(1+1)' 2>/dev/null)" == "2" ]] || continue
    PY_BOM="$c"
    printf '%s' "$c"
    return 0
  done
  return 1
}

# o mesmo cuidado com o jq: existir no PATH e responder sao coisas diferentes
tem_jq() { tem jq && jq --version >/dev/null 2>&1; }

# Devolve uma linha por banco, com os campos separados por 0x1f:
#   nome  servidor  porta  banco  usuario  senha
#
# O separador NAO e tabulacao, e isso e deliberado. Tabulacao e espaco em branco
# para o IFS do shell, que colapsa sequencias dele: um campo vazio no meio da
# linha desaparece e todos os seguintes andam uma casa. Medido aqui: a linha
# "x <vazio> 3306 loja loja senha" entregava serv=3306, porta=loja e
# usuario=senha, e o script tentaria conectar num servidor chamado como a porta,
# usando a senha como nome de usuario. O separador de unidade (0x1f) nao e
# espaco em branco, entao campo vazio e preservado.
LEITOR=""
le_credenciais() {
  local arq="$1" py=""
  if tem_jq; then
    LEITOR="jq $(jq --version 2>/dev/null | tr -d '\r')"
    jq -r '
      (.servidor_padrao // "") as $sp
      | (.bancos // [])[]
      | [ (.nome // ((.banco // "") + "-" + ((.porta // 3306) | tostring))),
          (.servidor // $sp),
          ((.porta // 3306) | tostring),
          (.banco // ""),
          (.usuario // ""),
          (.senha // "") ]
      | join("\u001f")' "$arq" 2>>"$LOG"
    return $?
  fi
  if py="$(acha_python)"; then
    LEITOR="$py $("$py" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null)"
    "$py" - "$arq" <<'PY' 2>>"$LOG"
import json, sys
# No Windows a saida padrao do Python traduz \n para \r\n, e com IFS de
# tabulacao esse \r cola no ultimo campo, que e justamente a senha. O MySQL
# responderia "Access denied" por causa de um caractere invisivel.
try:
    sys.stdout.reconfigure(newline='\n')
except Exception:
    pass
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    sys.stderr.write('credentials.json invalido: %s\n' % e)
    sys.exit(1)
sp = d.get('servidor_padrao') or ''
for b in d.get('bancos') or []:
    porta = str(b.get('porta') or 3306)
    nome = b.get('nome') or ((b.get('banco') or '') + '-' + porta)
    campos = [nome, b.get('servidor') or sp, porta,
              b.get('banco') or '', b.get('usuario') or '', b.get('senha') or '']
    for c in campos:
        if any(x in c for x in ('\n', '\r', '\x1f')):
            sys.stderr.write('valor com caractere de controle em %s\n' % nome)
            sys.exit(1)
    print('\x1f'.join(campos))
PY
    return $?
  fi
  return 127
}

pasta_do_json() {
  local arq="$1" py=""
  if tem_jq; then jq -r '.drive_pasta // ""' "$arq" 2>/dev/null; return 0; fi
  if py="$(acha_python)"; then
    "$py" -c "import json,sys; print(json.load(open(sys.argv[1],encoding='utf-8')).get('drive_pasta') or '')" "$arq" 2>/dev/null
    return 0
  fi
  printf ''
}

carrega_credenciais() {
  local arq="$1" linha nome serv porta banco usuario senha st=0
  local -A visto=()
  local saida
  saida="$(le_credenciais "$arq")" || st=$?
  if ((st == 127)); then
    printf '
%s %s
' "$(cor '1;31' 'ERRO:')" "nao achei um leitor de JSON que funcione nesta maquina." >&2
    printf '  Instale o jq, que resolve em um comando:
' >&2
    printf '      Ubuntu e Debian ... sudo apt-get install -y jq
' >&2
    printf '      Red Hat e Rocky ... sudo dnf install -y jq
' >&2
    printf '      macOS ............. brew install jq
' >&2
    printf '  Ou tenha um Python 3 de verdade no PATH. Atencao: no Windows o
' >&2
    printf '  "python3" costuma ser um atalho da Microsoft Store que sai com 0
' >&2
    printf '  sem fazer nada, e por isso este script testa o interprete antes
' >&2
    printf '  de confiar nele.

' >&2
    exit 1
  fi
  ((st == 0)) || morre "nao consegui ler $arq. Confira se o JSON esta valido (veja $LOG)"
  [[ -n "$saida" ]] || morre "o arquivo $arq nao tem nenhum banco na lista 'bancos'"

  # Nenhum campo de credencial pode terminar em retorno de carro. Um \r invisivel
  # no fim da senha faz o MySQL responder "Access denied" sem dizer por que, e
  # foi exatamente o que aconteceu aqui: a saida do leitor de JSON vinha com
  # CRLF e o \r colava no ultimo campo da linha, que e a senha. A limpeza fica
  # aqui, e nao so no leitor, porque ela vale para qualquer leitor que entre
  # depois, e porque custa uma linha.
  saida="${saida//$'\r'/}"

  while IFS=$'\037' read -r nome serv porta banco usuario senha; do
    [[ -n "$nome" ]] || continue

    [[ "$nome" =~ ^[A-Za-z0-9._-]+$ ]] \
      || morre "o nome '$nome' nao serve como nome de arquivo. Use letra, numero, ponto, traco e sublinhado."
    [[ -n "${visto[$nome]:-}" ]] \
      && morre "o nome '$nome' aparece duas vezes no arquivo. Um sobrescreveria o outro no Drive, e voce acharia que tem duas copias tendo uma."
    visto["$nome"]=1

    [[ -n "$serv" ]]    || morre "$nome: falta o servidor (no banco ou em servidor_padrao)"
    [[ -n "$banco" ]]   || morre "$nome: falta o nome do banco"
    [[ -n "$usuario" ]] || morre "$nome: falta o usuario"
    [[ -n "$senha" ]]   || aviso "$nome: a senha esta vazia no arquivo"
    [[ "$porta" =~ ^[0-9]+$ ]] || morre "$nome: a porta '$porta' nao e um numero"
    # o nome do banco entra numa consulta ao information_schema, entao so entra
    # o que e nome de banco de verdade
    [[ "$banco" =~ ^[A-Za-z0-9_$-]+$ ]] \
      || morre "$nome: o nome de banco '$banco' tem caractere que este script nao aceita"

    if [[ -n "$BANCOS_PEDIDOS" ]] && ! na_lista "$nome" "$BANCOS_PEDIDOS"; then continue; fi
    if na_lista "$nome" "$BANCOS_EXCLUIDOS"; then
      diz "pulado por --excluir: $nome"
      PULADOS=$((PULADOS + 1))
      continue
    fi

    NOMES+=("$nome")
    SERVIDOR_DE["$nome"]="$serv"
    PORTA_DE["$nome"]="$porta"
    BANCO_DE["$nome"]="$banco"
    USUARIO_DE["$nome"]="$usuario"
    SENHA_DE["$nome"]="$senha"
  done <<< "$saida"
  return 0
}

# ---------------------------------------------------------------------------
# Registro e retomada
#
# Uma linha por dump enviado, separada por tabulacao:
#   epoch  data_legivel  nome  situacao  bytes  tabelas  md5  destino
# ---------------------------------------------------------------------------
registra() {  # <nome> <situacao> <bytes> <tabelas> <md5> <destino>
  [[ -n "$REGISTRO" ]] || return 0
  { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date +%s)" "$(date '+%d/%m/%Y %H:%M')" "$1" "$2" "${3:-0}" "${4:-0}" "${5:--}" "${6:--}" \
      >> "$REGISTRO"; } 2>/dev/null || true
  chmod 600 "$REGISTRO" 2>/dev/null || true
  return 0
}

EXISTE_QUANDO=""; EXISTE_BYTES=0

# 0 = ja esta no Drive, nesta mesma pasta, e pode pular
ja_enviado() {
  local nome="$1" linha epoch quando bytes destino remoto
  EXISTE_QUANDO=""; EXISTE_BYTES=0
  ((RETOMANDO)) || return 1
  [[ -f "$REGISTRO" ]] || return 1
  linha="$(awk -F'\t' -v n="$nome" '$3==n && $4=="ok" {l=$0} END{print l}' "$REGISTRO" 2>/dev/null)" || linha=""
  [[ -n "$linha" ]] || return 1
  IFS=$'\t' read -r epoch quando _n _s bytes _t _m destino <<< "$linha"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  # So vale o que foi para ESTA pasta de data. Dump de ontem nao conta como
  # feito hoje, e dump de outra pasta do Drive nao esta aqui.
  [[ "$destino" == "$PASTA_DRIVE/"* ]] || return 1
  remoto="$(rclone size --config "$(arquivo_conf_rclone)" --json "$destino" 2>>"$LOG" \
            | sed -n 's/.*"bytes":[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -1)" || remoto=""
  if [[ -z "$remoto" || "$remoto" != "$bytes" ]]; then
    aviso "$nome: o registro apontava para $destino, mas o arquivo nao esta la do mesmo jeito. Vou refazer."
    return 1
  fi
  EXISTE_QUANDO="$quando"; EXISTE_BYTES="$bytes"
  return 0
}

mostra_registro() {
  if [[ ! -s "$REGISTRO" ]]; then
    printf '\n  Nenhum dump registrado ainda em %s\n\n' "$REGISTRO"
    return 0
  fi
  printf '\n  %-26s %-18s %10s %8s %-8s %s\n' BANCO QUANDO TAMANHO TABELAS SITUACAO ONDE
  printf '  %s\n' "$(printf '%.0s-' {1..110})"
  local epoch quando nome situacao bytes tabelas md5 destino
  while IFS=$'\t' read -r epoch quando nome situacao bytes tabelas md5 destino; do
    [[ -n "$nome" ]] || continue
    printf '  %-26s %-18s %10s %8s %-8s %s\n' \
      "$nome" "$quando" "$(legivel "${bytes:-0}")" "${tabelas:-0}" "$situacao" "$destino"
  done < "$REGISTRO"
  printf '\n  O registro fica em %s\n\n' "$REGISTRO"
  return 0
}

# ---------------------------------------------------------------------------
# Modo --conectar
# ---------------------------------------------------------------------------
if ((SO_CONECTAR)); then
  TMP="$(mktemp -d)"; chmod 700 "$TMP"
  trap na_saida EXIT
  trap 'morre "interrompido pelo operador"' INT TERM
  LOG="$TMP/conectar.log"; : > "$LOG"
  if configura_drive; then
    printf '\n%s\n' "$(cor '1;32' 'Google Drive conectado.')"
    printf '  Agora rode o backup apontando o arquivo de credencial:\n\n'
    printf '    ./%s /caminho/credentials.json\n\n' "$NOME_SCRIPT"
    printf '  Antes disso, vale testar as credenciais sem gerar nada:\n\n'
    printf '    ./%s /caminho/credentials.json --simular\n\n' "$NOME_SCRIPT"
    exit 0
  fi
  morre "a autorizacao do Google Drive nao terminou"
fi

# ---------------------------------------------------------------------------
# Conferindo o terreno
# ---------------------------------------------------------------------------
passo "Conferindo o terreno"

for prog in awk sed sort date stat mktemp tr cut gzip gunzip df; do
  tem "$prog" || morre "falta o comando '$prog' nesta maquina"
done

if [[ -z "$ARQUIVO_CRED" ]]; then
  if tem_terminal; then
    ARQUIVO_CRED="$(le_do_tty 'Caminho do credentials.json')"
  fi
  [[ -n "$ARQUIVO_CRED" ]] || morre "diga qual arquivo usar: ./$NOME_SCRIPT /caminho/credentials.json"
fi
case "$ARQUIVO_CRED" in "~/"*) ARQUIVO_CRED="$HOME/${ARQUIVO_CRED#\~/}" ;; "~") ARQUIVO_CRED="$HOME" ;; esac
[[ -e "$ARQUIVO_CRED" ]] || morre "nao achei esse arquivo: $ARQUIVO_CRED"
[[ -f "$ARQUIVO_CRED" ]] || morre "isso nao e um arquivo: $ARQUIVO_CRED"
[[ -r "$ARQUIVO_CRED" ]] || morre "sem permissao de leitura em: $ARQUIVO_CRED"
ARQUIVO_CRED="$(cd "$(dirname "$ARQUIVO_CRED")" && pwd -P)/$(basename "$ARQUIVO_CRED")"
feito "credencial: $ARQUIVO_CRED"

# o arquivo tem senha de banco de producao: ele nao pode ser legivel por todo
# mundo da maquina, e dizer isso uma vez vale mais que um comentario no README
PERM="$(stat -c '%a' "$ARQUIVO_CRED" 2>/dev/null || stat -f '%OLp' "$ARQUIVO_CRED" 2>/dev/null || echo '')"
if [[ "$PERM" =~ ^[0-7]?[0-7][0-7][0-7]$ ]] && [[ "${PERM: -2}" != "00" ]]; then
  aviso "$(basename "$ARQUIVO_CRED") esta com permissao $PERM e tem senha de banco dentro. Corrija com: chmod 600 $ARQUIVO_CRED"
fi

instala_cliente_mysql || morre "sem cliente de banco nao da para fazer dump"

# O que o CLIENTE instalado aceita. Nao se pergunta a versao e se deduz a opcao:
# pergunta-se a ele mesmo, porque distribuicao nenhuma garante o que empacotou.
AJUDA_DUMP="$("$BIN_DUMP" --help 2>/dev/null || true)"
grep -q -- '--no-tablespaces'     <<< "$AJUDA_DUMP" && TEM_NO_TABLESPACES=1
grep -q -- '--column-statistics'  <<< "$AJUDA_DUMP" && TEM_COLUMN_STATISTICS=1

lista_bin=""
for item in "${CLIENTES_DISPONIVEIS[@]}"; do lista_bin="$lista_bin ${item%%|*} (${item##*|})"; done
feito "cliente:${lista_bin}"
lista_bin=""
for item in "${DUMPS_DISPONIVEIS[@]}"; do lista_bin="$lista_bin ${item%%|*} (${item##*|})"; done
feito "dump:${lista_bin}"
if ((${#DUMPS_DISPONIVEIS[@]} == 1)); then
  outro="mariadb-client"
  [[ "${DUMPS_DISPONIVEIS[0]##*|}" == MariaDB ]] && outro="mysql-client"
  diz "so uma familia de cliente instalada. Com as duas, o script escolhe por servidor: sudo apt-get install -y $outro"
fi

if ((SEM_NICE == 0)); then
  renice -n 19 -p $$ >/dev/null 2>&1 || true
  tem ionice && ionice -c 3 -p $$ >/dev/null 2>&1 || true
  feito "prioridade baixa de CPU e disco"
fi

if [[ -n "$ARQUIVO_SENHA" && ! -r "$ARQUIVO_SENHA" ]]; then
  morre "nao consigo ler o arquivo de senha: $ARQUIVO_SENHA"
fi
if ((CIFRAR)) && ! tem gpg && ! tem openssl; then
  morre "--cifrar precisa de gpg ou openssl instalado"
fi
if ((CIFRAR)) && [[ -z "$ARQUIVO_SENHA" ]] && ! tem_terminal; then
  morre "--cifrar sem --senha-arquivo precisa de terminal para pedir a senha"
fi

# ---------------------------------------------------------------------------
# Estado
# ---------------------------------------------------------------------------
if [[ -n "$ESTADO_PEDIDO" ]]; then
  ESTADO="$ESTADO_PEDIDO"
else
  ESTADO="${HOME:-/tmp}/.backup-db/$(apelido "$(basename "$ARQUIVO_CRED" .json)")-$(id_curto "$ARQUIVO_CRED")"
fi
mkdir -p "$ESTADO" || morre "nao consegui criar a pasta de estado: $ESTADO"
ESTADO="$(cd "$ESTADO" && pwd -P)"
chmod 700 "$ESTADO" 2>/dev/null || true
REGISTRO="$ESTADO/registro.tsv"
EXECUCAO="$ESTADO/execucao-atual"
DUMPS="$ESTADO/dumps"
feito "estado: $ESTADO"

if ((SO_REGISTRO)); then
  mostra_registro
  exit 0
fi

TMP="$(mktemp -d)"; chmod 700 "$TMP"

if ((SIMULAR)); then
  # NAO dentro do TMP: ele e apagado na saida, e a mensagem de erro apontaria
  # para um arquivo que o proprio script acabou de remover.
  LOG="$ESTADO/simulacao-$CARIMBO.log"
  : > "$LOG"; chmod 600 "$LOG"
else
  LOG="$ESTADO/backup-$CARIMBO.log"
  : > "$LOG"; chmod 600 "$LOG"
  TRAVA="$ESTADO/backup-db.lock"
  if tem flock; then
    exec 9>"$TRAVA"
    flock -n 9 || morre "ja existe um backup destes bancos em andamento (trava: $TRAVA)"
  fi
fi

trap na_saida EXIT
trap 'morre "interrompido pelo operador"' INT TERM

# ---------------------------------------------------------------------------
# Lista dos bancos
# ---------------------------------------------------------------------------
passo "Lendo $ARQUIVO_CRED"
carrega_credenciais "$ARQUIVO_CRED"
((${#NOMES[@]})) || morre "nenhum banco para copiar depois dos filtros"
feito "${#NOMES[@]} banco(s): ${NOMES[*]}"
[[ -n "$LEITOR" ]] && diz "arquivo lido por: $LEITOR"

if [[ -z "$DRIVE_PASTA" ]]; then
  DRIVE_PASTA="$(pasta_do_json "$ARQUIVO_CRED")"
  [[ -n "$DRIVE_PASTA" ]] || DRIVE_PASTA="BACKUP-BANCOS"
fi
DRIVE_PASTA="${DRIVE_PASTA#/}"; DRIVE_PASTA="${DRIVE_PASTA%/}"
case "$DRIVE_PASTA" in
  "")    morre "a pasta no Drive nao pode ser vazia" ;;
  *:*)   morre "a pasta no Drive nao pode ter ':', que o rclone usa para separar o remote" ;;
  *..*)  morre "a pasta no Drive nao pode ter '..'" ;;
  *'\'*) morre "a pasta no Drive nao pode ter barra invertida" ;;
esac

# ---------------------------------------------------------------------------
# Retomada: mesma pasta de data, se a execucao anterior morreu ha pouco
# ---------------------------------------------------------------------------
if ((SEM_DATA == 0)) && ((NOVA == 0)) && [[ -f "$EXECUCAO" ]]; then
  ant_data=""; ant_epoch=0
  IFS=$'\t' read -r ant_data ant_epoch < "$EXECUCAO" 2>/dev/null || true
  if [[ "$ant_data" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$ ]] && [[ "$ant_epoch" =~ ^[0-9]+$ ]]; then
    idade_h=$(( ( $(date +%s) - ant_epoch ) / 3600 ))
    if ((idade_h < JANELA_HORAS)); then
      PASTA_DATA="$ant_data"
      RETOMANDO=1
      aviso "a execucao de $ant_data nao terminou (${idade_h}h atras). Vou retomar na MESMA pasta e fazer so o que faltou."
    else
      diz "havia uma execucao de $ant_data, de ${idade_h}h atras. Mais velha que ${JANELA_HORAS}h, entao comeco um ciclo novo."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Teste de conexao, sempre, antes de gastar tempo
# ---------------------------------------------------------------------------
passo "Testando a conexao de cada banco"

declare -A TABELAS_DE=() BYTES_DE=() MYISAM_DE=() NIVEL_DE=() FLAGS_DE=() CLIENTE_DE=()
declare -a BONS=()
for nome in "${NOMES[@]}"; do
  opc="$(arquivo_opcoes_mysql "${SERVIDOR_DE[$nome]}" "${PORTA_DE[$nome]}" "${USUARIO_DE[$nome]}" "${SENHA_DE[$nome]}")"
  if ! testa_conexao "$opc"; then
    falha "$nome: nao conectei em ${SERVIDOR_DE[$nome]}:${PORTA_DE[$nome]} como ${USUARIO_DE[$nome]}. O servidor disse: ${ERRO_CLIENTE:-nada, nem respondeu}"
    dica="$(dica_da_recusa "$ERRO_CLIENTE")"
    [[ -z "$dica" ]] || aviso "$nome: $dica"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	${BANCO_DE[$nome]}	${SERVIDOR_DE[$nome]}:${PORTA_DE[$nome]}	0	0	sem-conexao	0")
    rm -f "$opc"
    continue
  fi
  CLIENTE_DE["$nome"]="$BIN_MYSQL"
  SABOR_DE["$nome"]="$(sabor_servidor "$opc" || true)"
  info="$(info_banco "$opc" "${BANCO_DE[$nome]}")" || info=""
  tabelas=0; bytes=0; myisam=0
  [[ -n "$info" ]] && IFS=$'\t' read -r tabelas bytes myisam <<< "$info"
  TABELAS_DE["$nome"]="${tabelas:-0}"
  BYTES_DE["$nome"]="${bytes:-0}"
  MYISAM_DE["$nome"]="${myisam:-0}"

  if ((${TABELAS_DE[$nome]} == 0)); then
    aviso "$nome: o usuario conecta, mas nao enxerga nenhuma tabela em '${BANCO_DE[$nome]}'. Confira o nome do banco e o privilegio."
  fi
  if ((${MYISAM_DE[$nome]} > 0)); then
    aviso "$nome: ${MYISAM_DE[$nome]} tabela(s) MyISAM. Com --single-transaction o dump NAO fica consistente para elas: MyISAM nao tem transacao."
  fi

  if escolhe_dump_e_opcoes "$opc" "${BANCO_DE[$nome]}" "${SABOR_DE[$nome]}"; then
    NIVEL_DE["$nome"]="$NIVEL_DUMP"
    FLAGS_DE["$nome"]="${FLAGS_DUMP[*]}"
    DUMP_DE["$nome"]="$BIN_DUMP"
    AJUSTES_DE["$nome"]="$AJUSTES"
    [[ "$NIVEL_DUMP" == "completo" ]] \
      || aviso "$nome: o dump vai sair no nivel '$NIVEL_DUMP', porque o usuario nao alcanca o resto"
    [[ -z "$AJUSTES" ]] \
      || diz "$nome: ajustei o dump: $AJUSTES"
  else
    falha "$nome: nenhum programa de dump conseguiu ler a estrutura de '${BANCO_DE[$nome]}'. O servidor disse: ${ERRO_CLIENTE:-nada}"
    [[ -z "$AJUSTES" ]] || aviso "$nome: tentei com: $AJUSTES"
    tentados=""
    for item in ${DUMPS_DISPONIVEIS[@]+"${DUMPS_DISPONIVEIS[@]}"}; do tentados="$tentados ${item%%|*} (${item##*|})"; done
    aviso "$nome: servidor ${SABOR_DE[$nome]:-de versao desconhecida}. Tentei com:${tentados}."
    if ((${#DUMPS_DISPONIVEIS[@]} == 1)); then
      outra="mariadb-client"
      [[ "${DUMPS_DISPONIVEIS[0]##*|}" == MariaDB ]] && outra="mysql-client"
      aviso "$nome: so existe UMA familia de cliente nesta maquina. Programa de uma familia contra servidor da outra falha de formas que opcao nenhuma conserta. Instale a outra: sudo apt-get install -y $outra"
    fi
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	${BANCO_DE[$nome]}	${SERVIDOR_DE[$nome]}:${PORTA_DE[$nome]}	${BYTES_DE[$nome]}	0	sem-dump	0")
    rm -f "$opc"
    continue
  fi
  rm -f "$opc"

  feito "$nome: ${TABELAS_DE[$nome]} tabela(s), $(legivel "${BYTES_DE[$nome]}"), ${SABOR_DE[$nome]:-versao desconhecida}, nivel ${NIVEL_DE[$nome]}, dump pelo ${DUMP_DE[$nome]}"
  BONS+=("$nome")
done

((${#BONS[@]})) || morre "nenhum banco respondeu. Confira o credentials.json e o acesso de rede ao servidor."

# ---------------------------------------------------------------------------
# Simulacao
# ---------------------------------------------------------------------------
if ((SIMULAR)); then
  passo "Simulando (nada foi gerado e nada foi enviado)"
  total=0
  printf '\n  %-24s %-20s %-24s %7s %10s %-18s %s\n' NOME BANCO SERVIDOR TABELAS TAMANHO VERSAO NIVEL
  printf '  %s\n' "$(printf '%.0s-' {1..132})"
  for nome in "${BONS[@]}"; do
    total=$((total + ${BYTES_DE[$nome]}))
    printf '  %-24s %-20s %-24s %7s %10s %-18s %s\n' \
      "$nome" "${BANCO_DE[$nome]}" "${SERVIDOR_DE[$nome]}:${PORTA_DE[$nome]}" \
      "${TABELAS_DE[$nome]}" "$(legivel "${BYTES_DE[$nome]}")" \
      "${SABOR_DE[$nome]:-?}" "${NIVEL_DE[$nome]}"
  done
  printf '  %s\n' "$(printf '%.0s-' {1..132})"
  printf '  %-24s %-20s %-24s %7s %10s\n\n' "${#BONS[@]} banco(s)" "" "" "" "$(legivel "$total")"
  for nome in "${BONS[@]}"; do
    [[ -n "${AJUSTES_DE[$nome]:-}" ]] && printf '  ajuste em %s: %s\n' "$nome" "${AJUSTES_DE[$nome]}"
  done
  printf '  Tamanho em disco no servidor, nao do dump: o dump comprimido costuma\n'
  printf '  sair bem menor, mas isso depende do conteudo.\n\n'
  printf '  Pasta no Drive: %s:%s%s\n' "$DRIVE_REMOTE" "$DRIVE_PASTA" \
    "$( ((SEM_DATA)) || printf '/%s' "$PASTA_DATA" )"
  printf '  Pico de disco local esperado: o dump de um banco por vez, nao a soma.\n'
  if ((FALHA_BANCOS > 0)); then
    printf '\n  %s\n' "$(cor '1;31' "$FALHA_BANCOS banco(s) NAO passaram. Veja as falhas acima.")"
  fi
  printf '\n  Log desta simulacao: %s\n' "$LOG"
  printf '  Ele fica guardado, com a resposta crua do servidor de cada banco.\n\n'
  ((FALHA_BANCOS > 0)) && exit 2
  exit 0
fi

# ---------------------------------------------------------------------------
# Drive antes de gastar tempo
# ---------------------------------------------------------------------------
if ! instala_rclone; then
  morre "sem rclone nao da para enviar ao Google Drive"
fi
if ! remote_ja_existe || ! testa_remote; then
  configura_drive || morre "o Google Drive nao esta conectado. Rode: ./$NOME_SCRIPT --conectar"
else
  feito "Google Drive respondendo no remote '$DRIVE_REMOTE'"
fi

PASTA_DRIVE="${DRIVE_REMOTE}:${DRIVE_PASTA}"
((SEM_DATA)) || PASTA_DRIVE="$PASTA_DRIVE/$PASTA_DATA"
if rclone mkdir --config "$(arquivo_conf_rclone)" --log-level ERROR --log-file "$LOG" "$PASTA_DRIVE" 2>>"$LOG"; then
  feito "destino no Drive: $PASTA_DRIVE"
else
  aviso "nao consegui criar $PASTA_DRIVE agora; o envio cria a pasta no caminho"
fi

mkdir -p "$DUMPS" || morre "nao consegui criar $DUMPS"
chmod 700 "$DUMPS" 2>/dev/null || true

if ((CIFRAR)) && [[ -z "$ARQUIVO_SENHA" ]]; then
  senha1="$(le_do_tty 'Senha da cifra' oculto)"
  senha2="$(le_do_tty 'Repita a senha' oculto)"
  [[ -n "$senha1" ]] || morre "senha vazia"
  [[ "$senha1" == "$senha2" ]] || morre "as duas senhas nao sao iguais"
  ARQUIVO_SENHA="$TMP/senha"
  ( umask 077; printf '%s' "$senha1" > "$ARQUIVO_SENHA" )
  unset senha1 senha2
  feito "senha da cifra guardada so pelo tempo desta execucao"
  aviso "dump cifrado so volta com essa senha. Perdeu a senha, perdeu o backup."
fi

# ---------------------------------------------------------------------------
# A pergunta, uma vez
# ---------------------------------------------------------------------------
TOTAL_BYTES=0
for nome in "${BONS[@]}"; do TOTAL_BYTES=$((TOTAL_BYTES + ${BYTES_DE[$nome]})); done
printf '\n'
printf '  Vou copiar %s banco(s), %s em disco no servidor, para\n' "${#BONS[@]}" "$(legivel "$TOTAL_BYTES")"
printf '    %s\n' "$PASTA_DRIVE"
((RETOMANDO)) && printf '  Retomando a execucao de %s: o que ja subiu vai ser pulado.\n' "$PASTA_DATA"
printf '  Nenhum banco e alterado: o script so le deles.\n\n'
if ! pergunta_sim "Pode comecar?"; then
  morre "nada foi copiado"
fi

# marca que esta execucao comecou, para a proxima saber onde retomar
if ((SEM_DATA == 0)); then
  { printf '%s\t%s\n' "$PASTA_DATA" "$(date +%s)" > "$EXECUCAO"; } 2>/dev/null || true
  chmod 600 "$EXECUCAO" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Um banco por vez
# ---------------------------------------------------------------------------
MARGEM=$((MARGEM_MB * 1024 * 1024))
TOTAL=${#BONS[@]}
N=0

for nome in "${BONS[@]}"; do
  N=$((N + 1))
  passo "Banco $nome  ($N de $TOTAL)"
  comeco="$(date +%s)"
  banco="${BANCO_DE[$nome]}"
  endereco="${SERVIDOR_DE[$nome]}:${PORTA_DE[$nome]}"
  arquivo="$DUMPS/$nome.sql.gz"
  enviado_ok=0

  if ja_enviado "$nome"; then
    feito "$nome: pulado, ja subiu nesta mesma pasta em $EXISTE_QUANDO ($(legivel "$EXISTE_BYTES"))"
    PULADOS=$((PULADOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	${BYTES_DE[$nome]}	0	ja-estava	0")
    continue
  fi

  livre="$(espaco_livre "$DUMPS")"
  preciso=$(( ${BYTES_DE[$nome]} / 2 + MARGEM ))
  diz "$banco em $endereco | ${TABELAS_DE[$nome]} tabela(s) | $(legivel "${BYTES_DE[$nome]}") em disco"
  diz "livre em $DUMPS: $(legivel "$livre") | estimativa de que preciso: ~$(legivel "$preciso")"
  if ((livre < preciso)) && ((FORCAR == 0)); then
    falha "$nome: espaco livre insuficiente ($(legivel "$livre") para ~$(legivel "$preciso"))"
    aviso "$nome: use --forcar para tentar assim mesmo, --estado OUTRO_DISCO, ou libere disco"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	${BYTES_DE[$nome]}	0	sem-espaco	0")
    continue
  fi

  # As opcoes sao as MESMAS que a sonda achou, lidas de volta inteiras. Remontar
  # a partir do nome do nivel perderia os ajustes que o erro do servidor pediu,
  # como --column-statistics=0, e o dump de verdade falharia depois de a sonda ter
  # passado, que e o pior jeito de errar: parece defeito aleatorio.
  NIVEL_DUMP="${NIVEL_DE[$nome]}"
  BIN_DUMP="${DUMP_DE[$nome]}"
  read -r -a FLAGS_DUMP <<< "${FLAGS_DE[$nome]}"

  opc="$(arquivo_opcoes_mysql "${SERVIDOR_DE[$nome]}" "${PORTA_DE[$nome]}" "${USUARIO_DE[$nome]}" "${SENHA_DE[$nome]}")"
  rm -f "$arquivo"
  diz "gerando o dump pelo $BIN_DUMP, nivel $NIVEL_DUMP${AJUSTES_DE[$nome]:+, ${AJUSTES_DE[$nome]}}"
  marca_log="$(linhas_log)"
  if ! dump_banco "$opc" "$banco" "$arquivo"; then
    falha "$nome: o $BIN_DUMP falhou. O servidor disse: $(erro_recente "$marca_log")"
    rm -f "$arquivo" "$opc"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	${BYTES_DE[$nome]}	0	erro-dump	$(( $(date +%s) - comeco ))")
    registra "$nome" falha "0" "0" "-" "-"
    continue
  fi
  rm -f "$opc"

  comprimido="$(tamanho_arquivo "$arquivo")"
  feito "$nome.sql.gz ($(legivel "$comprimido"))"

  diz "conferindo o dump"
  rc=0; confere_dump "$arquivo" || rc=$?
  if ((rc == 1)); then
    falha "$nome: o dump nao passou no teste do gzip, veio truncado ou corrompido"
    rm -f "$arquivo"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	$comprimido	0	gzip-ruim	$(( $(date +%s) - comeco ))")
    registra "$nome" falha "$comprimido" "0" "-" "-"
    continue
  fi
  if ((rc == 2)); then
    falha "$nome: o dump nao tem a marca de 'Dump completed' no fim, entao ele parou no meio"
    aviso "$nome: o arquivo foi apagado de proposito. Dump pela metade tem cara de backup bom e nao restaura."
    rm -f "$arquivo"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	$comprimido	$TABELAS_NO_DUMP	incompleto	$(( $(date +%s) - comeco ))")
    registra "$nome" falha "$comprimido" "$TABELAS_NO_DUMP" "-" "-"
    continue
  fi
  if ((SO_ESTRUTURA == 0)) && ((TABELAS_NO_DUMP == 0)) && ((${TABELAS_DE[$nome]} > 0)); then
    falha "$nome: o banco tem ${TABELAS_DE[$nome]} tabela(s), e o dump saiu com nenhuma"
    rm -f "$arquivo"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	$comprimido	0	dump-vazio	$(( $(date +%s) - comeco ))")
    registra "$nome" falha "$comprimido" "0" "-" "-"
    continue
  fi
  if ((TABELAS_NO_DUMP < ${TABELAS_DE[$nome]})); then
    aviso "$nome: o banco tem ${TABELAS_DE[$nome]} tabela(s) e o dump trouxe $TABELAS_NO_DUMP. Confira o privilegio do usuario."
  fi
  feito "dump conferido: $TABELAS_NO_DUMP tabela(s), e termina com 'Dump completed'"

  if ((CIFRAR)); then
    diz "cifrando"
    if novo="$(cifra_arquivo "$arquivo")"; then
      arquivo="$novo"
      feito "cifrado: $(basename "$arquivo")"
    else
      falha "$nome: a cifra falhou"
      rm -f "$arquivo"
      FALHA_BANCOS=$((FALHA_BANCOS + 1))
      LINHAS_RELATORIO+=("$nome	$banco	$endereco	$comprimido	$TABELAS_NO_DUMP	erro-cifra	$(( $(date +%s) - comeco ))")
      continue
    fi
  fi
  chmod 600 "$arquivo" 2>/dev/null || true

  diz "enviando para $PASTA_DRIVE"
  if envia_arquivo "$arquivo" "$(basename "$arquivo")"; then
    enviado_ok=1
    if [[ "$CONFERENCIA" == "MD5" ]]; then
      feito "$nome: no Drive, conteudo conferido por MD5"
    else
      feito "$nome: no Drive, tamanho conferido"
      CONFERENCIA_POR_TAMANHO=1
    fi
  fi

  gasto=$(( $(date +%s) - comeco ))
  if ((enviado_ok)); then
    ((MANTER_LOCAL)) || { rm -f "$arquivo"; diz "copia local liberada ($(legivel "$comprimido"))"; }
    OK_BANCOS=$((OK_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	$comprimido	$TABELAS_NO_DUMP	ok	$gasto")
    registra "$nome" ok "$comprimido" "$TABELAS_NO_DUMP" "${MD5_ENVIADO:--}" "$PASTA_DRIVE/$(basename "$arquivo")"
  else
    falha "$nome: o envio nao terminou. O dump continua em $arquivo"
    FALHA_BANCOS=$((FALHA_BANCOS + 1))
    LINHAS_RELATORIO+=("$nome	$banco	$endereco	$comprimido	$TABELAS_NO_DUMP	erro-envio	$gasto")
    registra "$nome" falha "$comprimido" "$TABELAS_NO_DUMP" "-" "$PASTA_DRIVE/$(basename "$arquivo")"
  fi
  feito "$nome terminou em $((gasto / 60))m $((gasto % 60))s"
done

# ---------------------------------------------------------------------------
# Relatorio
# ---------------------------------------------------------------------------
passo "Escrevendo o relatorio"

DURACAO=$(( $(date +%s) - INICIO_EPOCH ))
RELATORIO="$ESTADO/RELATORIO-$CARIMBO.txt"

{
  echo "BACKUP DE BANCOS MYSQL PARA O GOOGLE DRIVE"
  echo
  echo "MAQUINA ........ $(hostname 2>/dev/null || echo desconhecida)"
  echo "DATA ........... $(date '+%d/%m/%Y %H:%M:%S')"
  echo "SCRIPT ......... $NOME_SCRIPT v$VERSAO_SCRIPT"
  echo "CREDENCIAL ..... $ARQUIVO_CRED"
  echo "LIDO POR ....... ${LEITOR:-desconhecido}"
  printf 'CLIENTES ....... '
  for item in ${CLIENTES_DISPONIVEIS[@]+"${CLIENTES_DISPONIVEIS[@]}"}; do printf '%s (%s)  ' "${item%%|*}" "${item##*|}"; done
  printf '\n'
  printf 'DUMP ........... '
  for item in ${DUMPS_DISPONIVEIS[@]+"${DUMPS_DISPONIVEIS[@]}"}; do printf '%s (%s)  ' "${item%%|*}" "${item##*|}"; done
  printf '\n'
  echo "DESTINO DRIVE .. $PASTA_DRIVE"
  echo "ESTADO ......... $ESTADO"
  echo "HISTORICO ...... $( ((SEM_DATA)) && echo 'nao, o dump de hoje substitui o de ontem' || echo "sim, uma pasta por execucao ($PASTA_DATA)" )"
  echo "RETOMADA ....... $( ((RETOMANDO)) && echo 'sim, continuou uma execucao interrompida' || echo 'nao, ciclo novo' )"
  echo "CONTEUDO ....... $( ((SO_ESTRUTURA)) && echo 'SO A ESTRUTURA, sem nenhuma linha' || echo 'estrutura e dados' )"
  echo "CIFRA .......... $( ((CIFRAR)) && echo AES256 || echo nao )"
  if ((CONFERENCIA_POR_TAMANHO)); then
    echo "CONFERENCIA .... tamanho no Drive em pelo menos um dump (o Drive nao devolveu hash)"
  else
    echo "CONFERENCIA .... MD5 do conteudo lido no proprio Drive"
  fi
  echo "DURACAO ........ $((DURACAO / 60))m $((DURACAO % 60))s"
  echo
  printf '%-26s %-22s %-28s %12s %8s %-14s %8s\n' NOME BANCO SERVIDOR DUMP TABELAS SITUACAO TEMPO
  printf '%s\n' "$(printf '%.0s-' {1..124})"
  for linha in ${LINHAS_RELATORIO[@]+"${LINHAS_RELATORIO[@]}"}; do
    IFS=$'\t' read -r n b e by tb si te <<< "$linha"
    printf '%-26s %-22s %-28s %12s %8s %-14s %7ss\n' "$n" "$b" "$e" "$(legivel "$by")" "$tb" "$si" "$te"
  done
  echo
  echo "SERVIDOR E OPCOES, BANCO POR BANCO"
  for nome in ${NOMES[@]+"${NOMES[@]}"}; do
    printf '  %-24s %-20s %-18s %s\n' "$nome" "${SABOR_DE[$nome]:-nao respondeu}" \
      "${DUMP_DE[$nome]:--}" "${AJUSTES_DE[$nome]:-nenhum ajuste}"
  done
  echo
  echo "BANCOS OK ...... $OK_BANCOS"
  echo "COM ERRO ....... $FALHA_BANCOS"
  echo "PULADOS ........ $PULADOS"
  echo "ENVIADO ........ $(legivel "$BYTES_ENVIADOS")"
  echo
  echo "AVISOS (${#AVISOS[@]})"
  for a in ${AVISOS[@]+"${AVISOS[@]}"}; do echo "  - $a"; done
  echo
  echo "FALHAS (${#ERROS[@]})"
  for e in ${ERROS[@]+"${ERROS[@]}"}; do echo "  - $e"; done
  echo
  echo "COMO RESTAURAR UM BANCO"
  echo "  1. baixe <nome>.sql.gz do Drive"
  echo "  2. confira:   gunzip -t <nome>.sql.gz"
  echo "  3. restaure:  gunzip -c <nome>.sql.gz | mysql -h HOST -P PORTA -u USUARIO -p BANCO"
  if ((CIFRAR)); then
    echo "  Cada dump esta cifrado. Para abrir um:"
    echo "    gpg --output <nome>.sql.gz --decrypt <nome>.sql.gz.gpg"
    echo "  Sem a senha nao existe como abrir."
  fi
  echo
  echo "ESTE RELATORIO LISTA SERVIDOR, PORTA E NOME DE BANCO. Nao tem senha"
  echo "nenhuma, mas e mapa da sua infraestrutura: trate como informacao sua."
} > "$RELATORIO"
chmod 600 "$RELATORIO"
feito "$(basename "$RELATORIO")"

pasta_rel="${DRIVE_REMOTE}:${DRIVE_PASTA}/_relatorios"
if rclone copyto --config "$(arquivo_conf_rclone)" --log-level ERROR --log-file "$LOG" \
     "$RELATORIO" "$pasta_rel/$(basename "$RELATORIO")" 2>>"$LOG"; then
  feito "relatorio enviado para $pasta_rel"
else
  aviso "o relatorio nao foi enviado ao Drive, mas esta em $RELATORIO"
fi

# ciclo completo sem falha: a proxima execucao comeca uma pasta nova
if ((SEM_DATA == 0)) && ((FALHA_BANCOS == 0)); then
  rm -f "$EXECUCAO"
fi

retencao_drive

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
printf '\n%s\n' "$(cor '1;32' '=========================== BACKUP CONCLUIDO ===========================')"
printf '  Bancos ok ..... %s de %s\n' "$OK_BANCOS" "$TOTAL"
printf '  Com erro ...... %s\n' "$FALHA_BANCOS"
printf '  Pulados ....... %s\n' "$PULADOS"
printf '  No Drive ...... %s\n' "$PASTA_DRIVE"
printf '  Enviado ....... %s\n' "$(legivel "$BYTES_ENVIADOS")"
printf '  Relatorio ..... %s\n' "$RELATORIO"
printf '  Duracao ....... %dm %ds\n' $((DURACAO / 60)) $((DURACAO % 60))
printf '  Avisos ........ %s\n' "${#AVISOS[@]}"
printf '  Falhas ........ %s\n' "${#ERROS[@]}"

if ((${#ERROS[@]})); then
  printf '\n%s\n' "$(cor '1;31' 'FALHAS QUE PRECISAM DE OLHO:')"
  for e in "${ERROS[@]}"; do printf '  - %s\n' "$e"; done
  printf '\n  Rode o mesmo comando de novo dentro de %sh: ele volta para a MESMA\n' "$JANELA_HORAS"
  printf '  pasta de data e tenta so o que faltou.\n'
fi
if ((${#AVISOS[@]})); then
  printf '\n%s\n' "$(cor '1;33' 'AVISOS:')"
  for a in "${AVISOS[@]}"; do printf '  - %s\n' "$a"; done
fi

printf '\n  O dump tem dado de cliente. Guarde como segredo.\n\n'

if ((FALHA_BANCOS > 0 || ${#ERROS[@]} > 0)); then exit 2; fi
exit 0
