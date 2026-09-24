# System Metrics

[English](README.md) · **Português (Brasil)**

Um widget de barra para o shell do [Omarchy](https://omarchy.org/): uma faixa
de medidores do sistema ao vivo, e um popup com o detalhe por trás deles.

As leituras vêm direto de `/proc` e `/sys` — não há daemon de monitoramento
para instalar, nem nada para configurar antes de começar.

![The strip in the bar](docs/strip.png)

## Rodar custa quase nada

Um monitor de sistema que mede carga não deveria ser uma fonte relevante dela.
De fábrica, este amostra CPU e memória a cada dois segundos, e esse ciclo
inteiro é **duas leituras de arquivo e cerca de 13µs de parsing** — mais ou
menos um milésimo de por cento de um núcleo.

Esse número vem do que o widget *não* faz:

- **Nenhum subprocesso no caminho recorrente.** `/proc` e `/sys` são lidos
  diretamente pela API de arquivos do próprio shell. Chamar `awk`, `ps` ou
  `sensors` num timer significa fazer fork de um interpretador a cada tick, o
  que custa milissegundos de CPU real — centenas de vezes mais do que ler o
  mesmo arquivo, e isso se repete para sempre. Duas leituras realmente não dá
  para obter desse jeito, e as duas ficam isoladas. A capacidade dos sistemas
  de arquivos vem de `statfs`, que o `/proc` não expõe: um único pipeline
  `sh -c "df … | head -c 65536"`, a cada quinze ticks, só enquanto Storage
  está sendo exibido. As listas de processos precisam de um
  `/proc/<pid>/stat` por processo, que a API de arquivos do shell não
  consegue expandir por glob: uma varredura com `awk`, e só enquanto uma lista
  está de fato expandida — o popup simplesmente aberto não paga nada. Nada
  mais faz fork.
- **Nada é amostrado a menos que alguém esteja olhando.** Com o popup
  fechado, só as métricas que você fixou na barra custam alguma coisa; o resto
  fica ocioso. Abra o popup e todos os medidores passam a amostrar, porque
  cada seção precisa de dados ao vivo. Feche e eles param. As duas listas de
  processos têm um controle ainda mais fino: só amostram enquanto a própria
  seção está expandida, então um popup apenas aberto nunca paga por uma
  varredura.
- **Cada medidor redesenha com as próprias amostras.** Uma amostra de CPU
  redesenha o medidor de CPU, não o de rede. Parece óbvio, mas a versão
  ingênua — um único contador de "algo mudou" — faz N medidores redesenharem N
  vezes por tick, e redesenhar um canvas é bem mais caro do que a amostra que o
  disparou.
- **As leituras são limitadas.** Tabelas de montagem e listas de interfaces
  são entradas cujo tamanho outra pessoa controla, então todo leitor
  recorrente tem um teto de bytes, de linhas e de tamanho de nome, e descarta
  a entrada que passa desse teto em vez de fazer parsing de uma linha
  truncada. Um `/proc` hostil não consegue transformar o widget num vazamento
  de memória dentro do seu shell.

Os dois últimos pesam mais do que parece: isto roda dentro do processo
Quickshell *compartilhado* que desenha o seu desktop inteiro. Qualquer
desperdício aqui não é um widget se comportando mal, é a sua barra
engasgando.

Nada disso é afirmado na base da fé — os números acima são medidos, e os
limites e o controle de amostragem são cobertos pela suíte de testes
(`tests/run`), incluindo um smoke test que roda o widget de verdade dentro de
um `quickshell` de verdade.

## O que ele mostra

Onze métricas, e você escolhe se cada uma aparece na barra ou fica no popup
(os nomes estão como aparecem no app, em inglês):

| Métrica | Na barra | No popup |
|---|---|---|
| CPU | núcleo mais ocupado | grade por núcleo, média de todos os núcleos, load average |
| CPU temperature (temperatura da CPU) | linha em faixa | leitura do sensor com limite |
| Memory (memória) | % usada, swap como segunda linha | usada / disponível / cache / buffers / swap |
| GPU | % ocupada | medidor de ocupação |
| VRAM | % usada | usada do total |
| GPU temperature (temperatura da GPU) | linha em faixa | leitura do die |
| Storage (armazenamento) | sistema de arquivos mais cheio | todos os sistemas de arquivos, usado do total |
| Network (rede) | download e upload | taxas por direção, interface |
| Disk I/O (E/S de disco) | leitura e escrita | taxas de leitura e escrita por dispositivo |
| CPU power (consumo da CPU) | watts do pacote | watts ao longo do tempo |
| GPU power (consumo da GPU) | watts da placa | watts ao longo do tempo |

O medidor de CPU plota o **núcleo mais ocupado**, não a média de todos eles. O
agregado do kernel tira a média de todos os núcleos, o que esconde justamente
a carga que as pessoas costumam querer ver: numa máquina de 16 núcleos, um
núcleo cravado em 93% aparece como 7% no agregado, então uma compilação mal
mexe no gráfico. `cpu.urgent` é comparado com esse mesmo número. A média de
todos os núcleos continua aparecendo, no popup.

### Qual processo está fazendo isso

Os medidores dizem que a máquina está ocupada; duas listas no popup dizem o
que a está ocupando. **Top processes · CPU** (os processos que mais usam CPU)
fica logo abaixo dos gráficos de CPU, e **Top processes · memory** (os que
mais usam memória) abaixo dos medidores de memória — cada uma
detalhando a leitura acima dela. As duas ficam recolhidas até você clicar no
título.

São as únicas seções que não podem ser fixadas na barra (dez linhas de nomes
de processos não cabem numa faixa), então os títulos delas têm uma seta de
expandir em vez do ponto de fixar. Cada linha mostra o nome do processo, o
pid e a leitura pela qual ele é ranqueado.

A coluna de CPU é o que cada processo usou *desde a varredura anterior*, não a
média de vida inteira que o `ps` imprime como `%CPU`. As duas respondem
perguntas diferentes: um processo que rodou quente por uma hora e desde então
ficou ocioso lidera a lista de vida inteira para sempre, que é exatamente a
linha que ninguém quer ver ali. É uma porcentagem de um núcleo, então um
processo com várias threads passa de 100% — a mesma leitura que o `top` dá.
Espere um traço no primeiro tick depois de expandir: com uma só varredura não
há intervalo contra o qual medir, e inventar um número ali seria mentira.

A coluna de memória é o RSS, que conta duas vezes as páginas compartilhadas
entre processos, então as linhas não somam a memória usada da máquina; elas
respondem qual processo está segurando mais.

Clicar na faixa abre a visão de detalhe, que também é onde você escolhe o que
a barra mostra:

<img src="docs/popup.png" alt="The detail popup" width="420">

## Instalação

```bash
omarchy plugin add https://github.com/alextakitani/omarchy-sysmetrics.git --enable
```

A instalação é só isso: o widget se posiciona à direita da barra e começa com
CPU e memória. Todo o resto é opcional — você pode adicionar ou remover
métricas clicando nos títulos delas no popup, sem nunca tocar num arquivo de
configuração.

Para colocá-lo em outro lugar:

```bash
omarchy plugin enable takitani.sysmetrics --section center      # ou: --before omarchy.clock
```

### Removendo

```bash
omarchy plugin remove takitani.sysmetrics
```

Isso tira o widget da barra e apaga o plugin. Para mantê-lo instalado mas
escondido, use `omarchy plugin disable takitani.sysmetrics`.

## Uso

- **Clique** na faixa para abrir o popup.
- **Clique no título de uma seção** do popup para adicionar ou remover aquela
  métrica da barra. Um ponto preenchido quer dizer que ela está na barra; um
  vazado, que ela vive só no popup.
- **Pin** (fixar, no canto superior direito do popup) mantém o popup aberto em vez de
  fechá-lo no próximo clique em outro lugar.
- **refresh − +** ajusta o intervalo de amostragem, de 500ms a 15s.
- **Clique do meio** na faixa força uma amostra imediata.

Toda seção está presente no popup, esteja a métrica na barra ou não, então uma
métrica que você escondeu continua ao alcance para trazer de volta.

### Consumo de energia

Duas métricas, uma por dispositivo, para que cada uma seja fixada, plotada e
registrada separadamente: **CPU power** é o pacote, a partir do contador de
energia do RAPL, e **GPU power** é a placa, a partir do sensor de consumo do
driver dela (`power1_average` no amdgpu). O resto da placa-mãe, os discos e as
ventoinhas não são medidos, então as duas juntas dão menos do que o consumo na
tomada.

A leitura da GPU funciona de fábrica. **A do pacote da CPU não**: o kernel
deixa o `energy_uj` do RAPL legível só pelo root, e o popup avisa isso até
você liberar o acesso. Ele é bloqueado porque leituras de energia de alta
resolução podem vazar informação sobre o que outros processos estão
computando (o ataque PLATYPUS), o que importa numa máquina compartilhada e bem
menos num desktop de um usuário só. Se essa troca está boa para você, uma
regra do udev libera a leitura:

```bash
echo 'ACTION=="add", SUBSYSTEM=="powercap", KERNEL=="intel-rapl:*", RUN+="/usr/bin/chmod 0444 /sys%p/energy_uj"' \
  | sudo tee /etc/udev/rules.d/60-rapl-energy-read.rules
sudo udevadm trigger --subsystem-match=powercap --action=add   # aplica agora, sem reboot
```

O widget tenta a leitura de novo a cada tick, então o CPU power aparece em
poucos segundos, sem reiniciar o shell. Para desfazer, apague a regra e
reinicie.

O que o número da CPU cobre: o domínio *package* do RAPL (`intel-rapl:0`), que
é o processador inteiro — todos os núcleos mais as partes compartilhadas do
chip (L3, controlador de memória, interconexão). Não inclui a placa-mãe nem
os reguladores de tensão dela.

**Na AMD também, apesar do nome.** O RAPL é uma interface que a Intel criou e
a AMD implementa a partir do Zen; o kernel atende as duas pelo driver
`intel_rapl`, então CPUs AMD também aparecem como `intel-rapl`. Na AMD a
leitura vem do modelo de consumo do próprio chip, e não de uma medição nas
linhas de alimentação, então ela serve para tendências e picos, não tem
precisão de medidor.

## Gravação

O popup pode registrar as leituras em disco para análise posterior — a CPU e
a temperatura de um dia inteiro, e quais processos estavam por trás delas.

- O **marcador vermelho** à direita de cada título de seção escolhe se aquela
  leitura é registrada, independentemente de ela estar na barra. As duas
  listas de processos compartilham um marcador. Até você mexer neles, uma
  gravação registra o que estiver fixado.
- **rec** (topo do popup) inicia e para uma gravação. Enquanto uma está
  rodando, ele mostra a duração, e a faixa ganha um ponto vermelho, porque uma
  gravação mantém as métricas dela sendo amostradas com o popup fechado.
- Uma gravação sobrevive a um restart do shell: ela continua num novo par de
  arquivos.
- O botão de **pasta** ao lado do **rec** abre a pasta onde as gravações são
  salvas.
- Quando já existe uma gravação, um botão de **robô** a entrega ao seu agente
  padrão (`omarchy agent prompt`), aberto na pasta de logs com um prompt que
  explica os arquivos e pede médias, picos, os processos por trás deles e a
  energia gasta. Uma gravação em andamento troca de arquivos antes, então o
  agente vê tudo até o clique.

Os arquivos vão para `$XDG_STATE_HOME/omarchy-sysmetrics/logs/` (normalmente
`~/.local/state/…`), nomeados pela hora de início:

- `<stamp>-metrics.csv.zst` — uma linha por tick de amostragem: `t_ms` (unix
  ms) mais as colunas escolhidas (`cpu_max_pct`, `cpu_avg_pct`, `cputemp_c`,
  `mem_pct`, `swap_pct`, `gpu_pct`, `vram_pct`, `gputemp_c`, `net_rx_Bps`,
  `net_tx_Bps`, `disk_read_Bps`, `disk_write_Bps`, `storage_pct`, `cpu_w`,
  `gpu_w`). Uma leitura ausente é um campo vazio, não 0.
- `<stamp>-processes.csv.zst` — a cada 30 segundos, os cinco processos que
  mais usaram CPU e os cinco que mais seguravam memória naquela janela:
  `t_ms,pid,comm,cpu_s,rss_bytes`. `cpu_s` é o tempo de CPU gasto *naquela
  janela*, então somá-lo dá o total de cada processo.

Cada arquivo é escrito por um único `zstd` de vida longa alimentado por um
pipe, então um tick custa uma linha escrita num pipe — sem fork, sem reabrir
arquivo. No intervalo padrão, isso dá mais ou menos 650 KB por dia. Os
arquivos existem desde o início da gravação, mas o zstd comprime em blocos de
128 KiB, então o arquivo de uma gravação em andamento fica pequeno — no
intervalo padrão, vazio nos primeiros vinte minutos, mais ou menos — e fica até
um bloco atrás dos dados ao vivo. Parar a gravação, ou reiniciar o shell, grava
tudo. A varredura de processos é o único fork, uma vez por janela.

Lendo de volta, por exemplo com DuckDB:

```sql
-- temperatura ao longo do dia
SELECT avg(cputemp_c), max(cputemp_c), quantile_cont(cputemp_c, 0.95)
FROM 'logs/*-metrics.csv.zst';

-- quem queimou a CPU
SELECT comm, round(sum(cpu_s) / 60, 1) AS cpu_minutes
FROM 'logs/*-processes.csv.zst' GROUP BY comm ORDER BY 2 DESC LIMIT 10;
```

## Configuração

O popup cobre os casos comuns (quais métricas aparecem, com que frequência
atualizam), então isto só é necessário para os ajustes que ele não expõe.
Adicione as chaves que quiser à entrada do widget em
`~/.config/omarchy/shell.json`:

```jsonc
{
  "id": "takitani.sysmetrics",
  "metrics": ["cpu", "memory"],   // qualquer subconjunto, em qualquer ordem
  "logMetrics": ["cpu", "cputemp", "processes"],  // o que uma gravação registra
  "recording": false,             // o botão rec; persiste entre restarts
  "intervalMs": 2000,             // 500–60000 (o seletor do popup vai até 15000)
  "historyLength": 60,            // amostras guardadas por métrica
  "sparklineWidth": 34,           // px por gráfico de medidor, 12–200
  "showSparkline": true,          // false: só valores e ícones, sem gráficos
  "showValue": true,
  "showIcon": true,
  "cpu":         { "urgent": 90 },   // comparado com o núcleo mais ocupado
  "memory":      { "urgent": 90 },
  "gpu":         { "card": "auto", "urgent": 95 },
  "storage":     { "urgent": 90 },
  "network":     { "interface": "auto", "minCeiling": 65536 },
  "disk":        { "devices": "auto", "minCeiling": 1048576 },
  "cputemp":     { "sensor": "auto", "range": [30, 95], "urgent": 85 },
  "gputemp":     { "sensor": "auto", "range": [30, 95], "urgent": 85 }
}
```

`"auto"` é resolvido em tempo de execução: a GPU pelo driver DRM, os sensores
de temperatura pelo nome no hwmon, a interface de rede pela rota padrão, e os
discos excluindo partições e dispositivos virtuais. Nenhum deles é acessível
por um caminho fixo — os números de placa do DRM e os índices do hwmon não são
estáveis entre reboots.

`showIcon`, `showSparkline` e `showValue` são independentes, então a faixa
pode ser reduzida às partes que você quiser — `"showSparkline": false` deixa
uma fileira de leituras simples, sem gráficos. Desligar os três deixa cada
medidor sem nada para desenhar, então o widget volta ao mesmo glifo
provisório que mostra quando nenhuma métrica está fixada: continua lá,
continua clicável, continua sendo um caminho de volta ao popup. Uma barra
vertical nem tem faixa onde organizar as coisas, então ela continua mostrando
o rótulo de valor único. O popup mantém os gráficos em qualquer caso.

Chaves desconhecidas são ignoradas e valores malformados voltam ao padrão,
então uma configuração ruim degrada em vez de quebrar.

## Notas de design

Vale conhecer duas decisões, porque sem elas o código parece inconsistente:

**Cada métrica é desenhada na forma que combina com ela.** Uma área preenchida
implica uma linha de base em zero, então as temperaturas — que vivem entre uns
30°C e 95°C — são desenhadas como uma linha sem preenchimento ao longo dessa
faixa. Plotado a partir de 0°C, todo o intervalo entre ocioso e throttling
ocuparia um par de pixels. Rede e disco são colunas espelhadas, porque
juntar duas direções numa linha só descarta metade da informação. O tempo de
GPU ocupada é em colunas porque uma linha interpola atividade entre duas
amostras ociosas, atividade que nunca aconteceu.

**As larguras dos rótulos são fixadas por contrato.** Cada rótulo fica numa
caixa dimensionada medindo uma string modelo na própria fonte do tema, então a
faixa não fica se remexendo conforme os valores mudam — o que moveria os alvos
de clique debaixo do cursor. Os modelos vêm do contrato de formato, nunca de
valores observados.

Tudo usa os próprios tokens de cor do shell, então o widget segue o tema que
estiver ativo, inclusive quando o tema é trocado em tempo real.

[docs/CONTRACT.md](docs/CONTRACT.md) registra o raciocínio completo, junto com
os modos de falha encontrados durante a construção.

## Requisitos

Omarchy com o shell baseado em Quickshell e suporte a plugins de widget de
barra. `df` (coreutils) para a métrica Storage; todo o resto é `/proc` e
`/sys`.

## Mudanças

O [CHANGELOG.pt-BR.md](CHANGELOG.pt-BR.md) registra o que mudou em cada versão.

## Licença

MIT
