# Crack the Password

Jogo de sala ao vivo em React, Vite e TypeScript. O app usa Supabase para guardar as salas e atualizar os clientes por Realtime; tentativas e operações do anfitrião passam por RPCs no banco.

## Arquitetura e segurança

- `src/App.tsx` contém os fluxos de anfitrião e participante; `src/lib/supabase.ts` centraliza o cliente, RPCs e tipos; `src/style.css` contém o tema responsivo.
- O navegador lê apenas metadados de sala, dicas já reveladas, participantes e classificação. Realtime notifica mudanças nas tabelas públicas; ao receber uma notificação, o cliente consulta `get_game_state` para obter o estado sanitizado.
- `round_answers`, `game_host_secrets` e `player_secrets` não têm permissões de leitura para `anon` ou `authenticated`, nem entram no Realtime. Senhas e alternativas são armazenadas como SHA-256 com salt aleatório individual.
- `submit_guess` valida token do jogador, estado da rodada, tempo limite, cooldown e limite de tentativas no servidor. Uma trava na rodada serializa tentativas simultâneas; o servidor define o horário de solução e o ranking.
- O anfitrião usa um token aleatório de 256 bits. O banco guarda somente seu SHA-256 e o navegador mantém o token em `localStorage` para recuperar a sessão. Participantes recebem um token próprio do mesmo modo. Nenhum cadastro de conta é necessário.
- O recurso de espiar a senha foi omitido: como a resposta não é armazenada em texto reversível, não há como recuperá-la sem enfraquecer a proteção. O anfitrião consulta a resposta no material da aula.

## Estrutura

```text
src/
  App.tsx                 Telas, fluxo, chamadas RPC e Realtime
  style.css               Tema, responsividade e movimento reduzido
  lib/characters.tsx      Avatares originais em emoji
  lib/supabase.ts         Cliente Supabase, tipos e wrapper RPC
supabase/
  migrations/001_crack_the_password.sql
  seed-round.json         Modelo de rodada para teste
```

## Configurar e executar

1. Crie um projeto no [Supabase](https://supabase.com/).
2. Abra **SQL Editor** no painel do projeto e execute todo o conteúdo de `supabase/migrations/001_crack_the_password.sql`.
3. A migração tenta adicionar `games`, `rounds`, `players` e `solves` à publicação `supabase_realtime`. Confirme em **Database → Publications → supabase_realtime** que essas quatro tabelas estão ativas. Não publique `round_answers`, `game_host_secrets`, `player_secrets` ou `attempts`.
4. Copie `.env.example` para `.env.local` e preencha `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` em **Project Settings → API**. A chave `anon` é pública e segura para este modelo porque as tabelas privadas não concedem leitura ou escrita direta; nunca use a service-role key no frontend.
5. Instale Node.js 20.19+ (ou 22.12+) e rode `npm install`, depois `npm run dev`. Abra o endereço local informado pelo Vite.
6. Para publicar, conecte o repositório ao Vercel ou Netlify. Use `npm run build` como comando de build e `dist` como diretório de publicação. Configure as mesmas duas variáveis de ambiente na hospedagem.

O app não precisa de servidor próprio nem de função Edge. Os RPCs são `SECURITY DEFINER`, validam cada operação e usam `search_path` explícito. Revise políticas/RPCs antes de compartilhar o projeto Supabase com outros aplicativos no mesmo banco.

## Uma sessão em aula

1. No projetor, abra o app e escolha **Criar jogo**.
2. Defina o título, número de rodadas, pergunta, resposta secreta e dicas de cada rodada. Ajuste tentativas, cooldown e entrada tardia.
3. Projete o QR code e o código da sala. O botão **Iniciar jogo** só habilita após alguém entrar.
4. Apresente as perguntas e pistas no material da aula. No painel, revele dicas adicionais, pause ou encerre a rodada.
5. Ao final de uma rodada, clique em **Próxima rodada**. Ao terminar a última, exporte o CSV da classificação.

## Rodada de exemplo

O formulário já começa preenchido com uma rodada de energia solar. Os valores de demonstração também estão em `supabase/seed-round.json`; não execute esse JSON no SQL Editor. Crie a sala pelo app para gerar os tokens e hashes corretamente.

## Design

Extraído do PDF de referência: marinho `#0D1028`, verde-limão `#B9F93C`, lavanda `#C7CCF1` e branco quente `#FFFAF1`. JetBrains Mono é a fonte principal, como no PDF; Inter fica disponível para textos corridos que pedem leitura mais fluida. Títulos e números ganham escala maior no projetor. O padrão de fundo, órbitas e sinalizadores de energia retomam os gráficos e o tema de consumo do material.
