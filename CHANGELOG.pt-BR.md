# Changelog

[English](CHANGELOG.md) · **Português (Brasil)**

Mudanças relevantes no System Metrics. As versões seguem o [versionamento semântico](https://semver.org/):
o dígito de patch é uma correção, o dígito minor acrescenta algo que uma configuração pode
pedir, e nada precisou de um bump major até agora.

## Não lançado

### Adicionado

- **CPU power e GPU power**: watts do pacote a partir do RAPL e watts da placa a partir
  do sensor de consumo do amdgpu, cada um como métrica própria — medidor, seção no popup
  e coluna no log (`cpu_w`, `gpu_w`).
  O RAPL é só para root por padrão; o README traz a regra do udev que libera o acesso, e
  o popup avisa isso em vez de mostrar um traço solto.

- **Gravação.** Um botão rec no popup registra as leituras que você escolher (um marcador
  vermelho em cada título de seção) em CSV comprimido com zstd em
  `$XDG_STATE_HOME/omarchy-sysmetrics/logs/`, mais os processos que mais usaram CPU e
  memória a cada 30 segundos, com os segundos de CPU de cada janela — o bastante para
  responder "o que esquentou hoje, e qual processo fez isso". As linhas descem por um pipe
  até um único `zstd` de vida longa, então um tick não custa nenhum fork. A faixa mostra
  um ponto vermelho enquanto uma gravação está rodando. Novas chaves de configuração:
  `logMetrics`, `recording`. Um botão de pasta abre os logs e, quando já existe
  uma gravação, um botão de robô a entrega ao seu agente padrão
  (`omarchy agent prompt`) com um prompt que explica os arquivos e pede médias,
  picos, os processos por trás deles e a energia gasta.

- **`showSparkline`** se junta a `showIcon` e `showValue`, então a faixa pode dispensar os
  gráficos e manter as leituras — `cpu 46%` como texto simples ao lado do relógio, sem
  precisar mexer no `BarWidget.qml`. Os três toggles são independentes; desligar todos
  deixa cada medidor sem nada para desenhar, então o widget volta ao mesmo glifo
  provisório que mostra quando nenhuma métrica está fixada, e continua clicável como
  caminho de volta ao popup. Os gráficos do popup não mudam em nenhum caso.
  Obrigado a [@gabrielforster](https://github.com/gabrielforster) ([#1](https://github.com/alextakitani/omarchy-sysmetrics/pull/1)).

- **Listas dos processos que mais usam CPU e memória**, recolhidas por padrão no popup,
  para que a pergunta que os medidores levantam — *o que está fazendo isso?* — seja
  respondida no mesmo lugar.

### Corrigido

- As listas de processos perdiam, em silêncio, a maior parte das linhas sempre que um
  processo terminava no meio da varredura: o gawk trata um `/proc/<pid>/stat` que sumiu
  como erro fatal e parava ali, descartando todos os pids depois dele. Numa máquina
  ocupada — e os próprios leitores deste plugin iniciam e encerram processos de vida
  curta a cada tick — isso era a maioria das varreduras. Agora os arquivos são
  percorridos pelo `head`, que pula os que sumiram.

## 1.3.0 — 2026-08-29

### Alterado

- **O medidor de CPU plota o núcleo mais ocupado em vez da média.** Uma média entre os
  núcleos esconde exatamente o caso que vale a pena ver: um núcleo cravado em 100%
  enquanto a média marca tranquilos 12%. Os limites de urgência também passam a ser
  comparados com o núcleo mais ocupado.

- A página no marketplace ganhou uma imagem de prévia, uma licença MIT explícita e uma
  descrição que diz o que o widget faz.

### Corrigido

- As leituras recorrentes são limitadas na origem, e não depois da leitura, então um
  arquivo grande demais é descartado antes de chegar a virar uma string QML.

- A sondagem de nome do hwmon, a última leitura bruta sem limite, agora é limitada como
  as demais.

## 1.2.0 — 2026-08-27

### Alterado

- **Todo leitor passa pelo controle de amostragem**, não só os três que eram citados
  individualmente — uma métrica não fixada não custa nada enquanto o popup está fechado.

- A lista de núcleos após o parsing é densa, e não apenas limitada, então uma máquina
  com muitos núcleos não carrega um array esparso em toda amostra.

### Corrigido

- As leituras recorrentes do procfs são limitadas antes de virarem strings QML.

- O `/proc/net/route` é limitado — o leitor que a rodada de endurecimento anterior deixou
  passar.

- Um `df` atrasado é encerrado em vez de congelar as leituras de armazenamento para
  sempre.

### Documentação

- As chaves de configuração documentadas agora são as que o código de fato lê.

- O contrato descreve o que o código faz para cada leitor, e o README diz quanto o
  widget custa para rodar.

## 1.1.0 — 2026-08-26

### Adicionado

- **Uma suíte de testes em três camadas e CI**: as bibliotecas de `js/` sob Node em
  milissegundos, o mesmo contrato sob o engine V4 do Qt para pegar divergências entre
  engines, e um smoke test em tempo de execução que instancia o QML de produção num
  Quickshell de verdade — a única camada capaz de enxergar um binding que silenciosamente
  nunca dispara.

### Alterado

- **Cada medidor redesenha com as próprias amostras**, e não com as de todas as
  métricas. Um contador compartilhado redesenhava todos os canvas da barra a cada
  amostra de qualquer métrica.

### Corrigido

- A saída do `df` que chega ao parser de armazenamento é limitada, assim como os
  leitores recorrentes do procfs.

### Documentação

- O popup de detalhe aparece no README, as seções de temperatura têm nomes que dizem o
  que são, e a remoção do plugin está documentada.

## 1.0.0 — 2026-08-25

Versão inicial: uma faixa de medidores ao vivo de CPU, memória, rede, disco e GPU para a
barra do Omarchy, com um popup para o detalhe por núcleo e por dispositivo por trás
deles. As leituras vêm direto de `/proc` e `/sys` — sem daemon de monitoramento, nada
para configurar antes de começar.
