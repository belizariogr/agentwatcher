# Agent Watcher

App de menu bar para macOS que mostra os limites de uso dos harnesses de IA
instalados na máquina: **Claude Code** e **Codex**.

Inspirado no plugin `belizario.agents` do Omarchy (dotfiles), refeito
nativamente em Swift/SwiftUI.

- **Clique esquerdo** no ícone: painel com cada harness, plano, % usado de
  cada janela (sessão de 5h, semanal, limites por modelo) e quando renova.
- **Clique direito**: Atualizar / Configurações… / Sair.
- O ícone é um anel com uma faísca no centro; o anel enche conforme a janela
  mais apertada entre todos os harnesses. Quando qualquer harness fica com
  **15% ou menos** restantes (limiar configurável), o ícone sai da cor do
  sistema e vai de amarelo → laranja → **vermelho** em 0%.

## Instalar

Requer macOS 14+ e Xcode / Command Line Tools (Swift 6).

```bash
make install   # gera build/AgentWatcher.app, copia para ~/Applications e abre
```

Para ele subir com o login, ative "Iniciar com o sistema" nas Configurações.

Outros alvos: `make run` (gera e abre o .app local), `make test`, `make clean`.

### Ícone do app

O ícone ("Faísca Neon") é gerado por `scripts/app_icon.py` em
`Resources/AppIcon.icns`. Para trocar a paleta (requer `rsvg-convert`, do
`librsvg`):

```bash
make icon PALETTE=aurora && make run   # oceano, aurora, lilas, ambar, gelo
```

## De onde vêm os números

| Harness | Limites | Credenciais |
|---|---|---|
| Claude Code | `GET https://api.anthropic.com/api/oauth/usage` | Token OAuth do CLI no Keychain (`Claude Code-credentials`), ou `$CLAUDE_CONFIG_DIR/.credentials.json` |
| Codex | JSON-RPC `account/rateLimits/read` no `codex app-server` | O próprio CLI (`~/.codex/auth.json`, ou `$CODEX_HOME`) |

Nenhum token sai da máquina além do header da consulta à Anthropic. O token
do Claude não é renovado pelo app: se expirar, abrir o Claude Code renova.
Se uma atualização falhar (ex.: a Anthropic limitando consultas), o painel
mantém os últimos números bons e mostra o aviso.

## Configuração

O botão **Configurações** (⌘,) no rodapé do painel abre uma janela com:

- intervalo de atualização (1 min a 1 h; padrão 5 min);
- iniciar com o sistema;
- limiar de alerta do ícone (5–50%; padrão 15%);
- esconder harnesses do painel e do ícone.

As mesmas opções ficam em `UserDefaults`, então também dá para ajustar pelo
terminal:

```bash
# Intervalo de atualização em segundos (padrão 300, mínimo 60)
defaults write com.belizariogr.agentwatcher refreshInterval -int 600
# Fração restante em que o ícone começa a mudar de cor (padrão 0.15)
defaults write com.belizariogr.agentwatcher alertThreshold -float 0.2
# Harnesses escondidos (ids: claude, codex)
defaults write com.belizariogr.agentwatcher hiddenProviders -array codex
```

## Depuração

```bash
swift build
.build/debug/AgentWatcher --dump              # imprime os limites e sai
.build/debug/AgentWatcher --snapshot /tmp/aw # renderiza painel e ícone em PNG
```

## Adicionar um harness

Implemente `UsageProvider` em `Sources/AgentWatcherCore/Providers/`
(`isInstalled()` + `fetch()` devolvendo `ProviderUsage`) e registre em
`UsageStore.allProviders`. Um logo opcional vai em
`Sources/AgentWatcher/Logos.swift`.
