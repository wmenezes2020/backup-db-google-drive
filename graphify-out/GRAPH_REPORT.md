# Graph Report - BACKUP DBS  (2026-10-07)

## Corpus Check
- Corpus is ~29,925 words - fits in a single context window. You may not need a graph.

## Summary
- 111 nodes · 224 edges · 9 communities (8 shown, 1 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- backup-db.sh
- configura_drive
- roda-testes.sh
- backup-db.sh script
- carrega_credenciais
- gerar-grafo.py
- testa_conexao
- envia_arquivo
- monta-lab.sh script

## God Nodes (most connected - your core abstractions)
1. `backup-db.sh script` - 38 edges
2. `configura_drive()` - 13 edges
3. `roda-testes.sh script` - 13 edges
4. `tem()` - 12 edges
5. `autoriza_por_link()` - 11 edges
6. `aviso()` - 9 edges
7. `instala_rclone()` - 9 edges
8. `instala_cliente_mysql()` - 8 edges
9. `falha()` - 7 edges
10. `envia_arquivo()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `backup-db.sh script` --calls--> `aviso()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 3 → community 1_
- `backup-db.sh script` --calls--> `carrega_credenciais()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 3 → community 4_
- `backup-db.sh script` --calls--> `envia_arquivo()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 3 → community 7_
- `backup-db.sh script` --calls--> `escolhe_dump_e_opcoes()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 3 → community 6_
- `carrega_credenciais()` --calls--> `diz()`  [EXTRACTED]
  backup-db.sh → backup-db.sh  _Bridges community 1 → community 4_

## Import Cycles
- None detected.

## Communities (9 total, 1 thin omitted)

### Community 0 - "backup-db.sh"
Cohesion: 0.06
Nodes (22): AJUSTES_DE, AVISOS, BANCO_DE, BONS, BYTES_DE, CLIENTE_DE, CLIENTES_DISPONIVEIS, DUMP_DE (+14 more)

### Community 1 - "configura_drive"
Cohesion: 0.16
Nodes (23): arquivo_conf_rclone(), autoriza_por_link(), aviso(), cifra_arquivo(), configura_drive(), diz(), escopo_codificado(), escreve_remote_rclone() (+15 more)

### Community 2 - "roda-testes.sh"
Cohesion: 0.21
Nodes (16): caso(), conecta(), contem(), desconecta(), estado(), FALHAS, HOME, limpa() (+8 more)

### Community 3 - "backup-db.sh script"
Cohesion: 0.15
Nodes (15): ajuda(), apelido(), arquivo_opcoes_mysql(), confere_dump(), dica_da_recusa(), dump_banco(), espaco_livre(), info_banco() (+7 more)

### Community 4 - "carrega_credenciais"
Cohesion: 0.33
Nodes (7): acha_python(), carrega_credenciais(), le_credenciais(), morre(), na_lista(), pasta_do_json(), tem_jq()

### Community 5 - "gerar-grafo.py"
Cohesion: 0.33
Nodes (6): json, pathlib, dentro_do_escopo(), main(), Gera o grafo do graphify deste repositorio em graphify-out/. Entrega sempre os…, sys

### Community 6 - "testa_conexao"
Cohesion: 0.50
Nodes (5): erro_recente(), escolhe_dump_e_opcoes(), escolhe_opcoes_dump(), linhas_log(), testa_conexao()

### Community 7 - "envia_arquivo"
Cohesion: 0.50
Nodes (4): envia_arquivo(), md5_local(), minusculo(), tamanho_arquivo()

## Knowledge Gaps
- **26 isolated node(s):** `DUMPS_DISPONIVEIS`, `CLIENTES_DISPONIVEIS`, `FLAGS_DUMP`, `NOMES`, `SERVIDOR_DE` (+21 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 39 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `backup-db.sh script` connect `backup-db.sh script` to `backup-db.sh`, `configura_drive`, `carrega_credenciais`, `testa_conexao`, `envia_arquivo`?**
  _High betweenness centrality (0.050) - this node is a cross-community bridge._
- **Why does `tem()` connect `configura_drive` to `backup-db.sh`, `backup-db.sh script`, `carrega_credenciais`, `envia_arquivo`?**
  _High betweenness centrality (0.003) - this node is a cross-community bridge._
- **What connects `DUMPS_DISPONIVEIS`, `CLIENTES_DISPONIVEIS`, `FLAGS_DUMP` to the rest of the system?**
  _26 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `backup-db.sh` be split into smaller, more focused modules?**
  _Cohesion score 0.06451612903225806 - nodes in this community are weakly interconnected._