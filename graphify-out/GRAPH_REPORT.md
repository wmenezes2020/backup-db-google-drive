# Graph Report - BACKUP DBS  (2026-10-07)

## Corpus Check
- Corpus is ~22,996 words - fits in a single context window. You may not need a graph.

## Summary
- 96 nodes · 198 edges · 12 communities (11 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- backup-db.sh
- roda-testes.sh
- backup-db.sh script
- tem
- configura_drive
- gerar-grafo.py
- carrega_credenciais
- autoriza_por_link
- ja_enviado
- envia_arquivo
- tem_terminal
- monta-lab.sh script

## God Nodes (most connected - your core abstractions)
1. `backup-db.sh script` - 35 edges
2. `configura_drive()` - 13 edges
3. `roda-testes.sh script` - 13 edges
4. `tem()` - 11 edges
5. `autoriza_por_link()` - 11 edges
6. `aviso()` - 9 edges
7. `instala_rclone()` - 9 edges
8. `falha()` - 7 edges
9. `envia_arquivo()` - 7 edges
10. `instala_cliente_mysql()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `backup-db.sh script` --calls--> `aviso()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 2 → community 4_
- `backup-db.sh script` --calls--> `carrega_credenciais()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 2 → community 6_
- `backup-db.sh script` --calls--> `cifra_arquivo()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 2 → community 3_
- `backup-db.sh script` --calls--> `envia_arquivo()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 2 → community 9_
- `backup-db.sh script` --calls--> `ja_enviado()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 2 → community 8_

## Import Cycles
- None detected.

## Communities (12 total, 1 thin omitted)

### Community 0 - "backup-db.sh"
Cohesion: 0.09
Nodes (15): AVISOS, BANCO_DE, BONS, BYTES_DE, ERROS, FLAGS_DUMP, LINHAS_RELATORIO, MYISAM_DE (+7 more)

### Community 1 - "roda-testes.sh"
Cohesion: 0.21
Nodes (16): caso(), conecta(), contem(), desconecta(), estado(), FALHAS, HOME, limpa() (+8 more)

### Community 2 - "backup-db.sh script"
Cohesion: 0.15
Nodes (13): ajuda(), apelido(), arquivo_opcoes_mysql(), confere_dump(), dump_banco(), escolhe_nivel(), espaco_livre(), info_banco() (+5 more)

### Community 3 - "tem"
Cohesion: 0.32
Nodes (8): acha_python(), cifra_arquivo(), id_curto(), le_credenciais(), md5_local(), pasta_do_json(), tem(), tem_jq()

### Community 4 - "configura_drive"
Cohesion: 0.50
Nodes (8): aviso(), configura_drive(), falha(), feito(), instala_cliente_mysql(), instala_rclone(), passo(), remote_ja_existe()

### Community 5 - "gerar-grafo.py"
Cohesion: 0.33
Nodes (6): json, pathlib, dentro_do_escopo(), main(), Gera o grafo do graphify deste repositorio em graphify-out/. Entrega sempre os…, sys

### Community 6 - "carrega_credenciais"
Cohesion: 0.40
Nodes (5): carrega_credenciais(), diz(), morre(), na_lista(), retencao_drive()

### Community 7 - "autoriza_por_link"
Cohesion: 0.50
Nodes (4): autoriza_por_link(), escopo_codificado(), numero_json(), valor_json()

### Community 8 - "ja_enviado"
Cohesion: 0.67
Nodes (3): arquivo_conf_rclone(), escreve_remote_rclone(), ja_enviado()

### Community 9 - "envia_arquivo"
Cohesion: 0.67
Nodes (3): envia_arquivo(), minusculo(), tamanho_arquivo()

### Community 10 - "tem_terminal"
Cohesion: 0.67
Nodes (3): le_do_tty(), pergunta_sim(), tem_terminal()

## Knowledge Gaps
- **19 isolated node(s):** `FLAGS_DUMP`, `NOMES`, `SERVIDOR_DE`, `PORTA_DE`, `BANCO_DE` (+14 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 31 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `backup-db.sh script` connect `backup-db.sh script` to `backup-db.sh`, `tem`, `configura_drive`, `carrega_credenciais`, `ja_enviado`, `envia_arquivo`, `tem_terminal`?**
  _High betweenness centrality (0.055) - this node is a cross-community bridge._
- **Why does `autoriza_por_link()` connect `autoriza_por_link` to `backup-db.sh`, `tem`, `configura_drive`, `carrega_credenciais`, `ja_enviado`, `tem_terminal`?**
  _High betweenness centrality (0.004) - this node is a cross-community bridge._
- **What connects `FLAGS_DUMP`, `NOMES`, `SERVIDOR_DE` to the rest of the system?**
  _19 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `backup-db.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.08695652173913043 - nodes in this community are weakly interconnected._