# handfree-code

Piloter Claude Code à la voix sur macOS, mains libres.

- **Claude te parle** : ses réponses et ses questions sont lues à voix haute, avec le nom de la session qui parle. Seul le premier paragraphe est lu d'office ; le reste attend que tu dises « Continue ».
- **Tu parles à Claude** : tu dictes avec [Spokenly](https://spokenly.app), tu envoies en disant « stop ». Les questions de Claude passent par Spokenly, tu y réponds à la voix.
- **Tu pilotes la lecture** avec quelques mots : Écoute, Stop, Tais-toi, Continue, Recommence, Mode vocal.

Le plugin installe tout le côté Claude Code. Le côté macOS (raccourcis, commandes vocales, autorisations) se fait à la main, une fois : macOS interdit qu'un programme s'accorde ces droits tout seul.

Testé sur macOS 14.4.1 avec l'app de bureau Claude. Ne dépend que de ce que macOS fournit (`osascript`, `say`) : pas de Python, pas de Node.

## Ce qu'il faut

- macOS, l'app de bureau Claude (Claude Code dans un terminal marche aussi, voir *Réglages*).
- [Spokenly](https://spokenly.app), version gratuite suffisante, avec son serveur MCP déclaré dans Claude Code sous le nom `spokenly` (Spokenly le propose dans ses réglages).
- Deux micros : celui des écouteurs pour Spokenly, celui du Mac pour le Contrôle vocal. Un seul micro pour les deux, et ils se le disputent.
- Des écouteurs, de préférence : sans eux, le micro du Mac entend la voix de lecture, et un mot de commande lu par Claude peut se déclencher tout seul.

**Confidentialité.** Selon le modèle de transcription choisi dans Spokenly, ta voix peut être envoyée à un service en ligne. Vérifie le modèle dans ses réglages. Le plugin lui-même ne contacte aucun service : tout se passe sur le Mac.

## Installation

### 1. Le plugin

```
/plugin marketplace add <chemin-ou-url-de-ce-dépôt>
/plugin install handfree-code@handfree-code
```

Ouvre ensuite une nouvelle session : au démarrage, le plugin dépose une copie de son script dans `~/Library/Application Support/handfree-code/handfree.js`. C'est ce chemin, stable d'une version à l'autre, qu'appellent les raccourcis.

### 2. La voix

Réglages Système > Accessibilité > Contenu énoncé > **Voix système** : choisis une voix dans ta langue et son débit. Le plugin utilise cette voix, sauf si tu en imposes une dans les réglages.

### 3. Spokenly

- Micro : celui de tes écouteurs.
- Raccourci de dictée : **double appui sur Commande droite**, en mode bascule (un appui démarre, un appui arrête). Si tu en choisis un autre, règle `spokenly_trigger` à `none` et lance Spokenly toi-même.
- Laisse désactivée l'option de Spokenly qui lit la question à voix haute : le plugin s'en charge, et les deux se chevaucheraient.
- Raccourcis l'attente de Claude Code sur Spokenly : sans réponse, une question bloque la session 30 minutes. Ajoute `"timeout": 120000` (2 minutes) à l'entrée `spokenly` des `mcpServers` de `~/.claude.json`.

### 4. Les raccourcis (app Raccourcis)

Crée un raccourci par fichier du dossier [`shortcuts/`](shortcuts), en collant son contenu dans l'action indiquée en tête du fichier :

| Raccourci | Action | Fichier |
|---|---|---|
| Écoute Spokenly | Exécuter un script shell | `ecoute.sh` |
| Appuyer Retour | Exécuter un script AppleScript | `appuyer-retour.applescript` |
| Tais-toi | Exécuter un script shell | `tais-toi.sh` |
| Continue | Exécuter un script shell | `continue.sh` |
| Recommence | Exécuter un script shell | `recommence.sh` |
| Mode vocal | Exécuter un script shell | `mode-vocal.sh` |

Lance chacun une fois depuis l'app Raccourcis : macOS demande alors les autorisations, accepte-les.

### 5. Les commandes vocales (Contrôle vocal)

Réglages Système > Accessibilité > Contrôle vocal : active-le, micro **du Mac**. Puis Commandes… > « + », pour chaque commande : « Lors de l'utilisation de : n'importe quelle app », « Effectuer : Exécuter le raccourci ».

| Tu dis | Raccourci |
|---|---|
| Écoute | Écoute Spokenly |
| Stop | Appuyer Retour |
| Tais-toi | Tais-toi |
| Continue | Continue |
| Recommence | Recommence |
| Mode vocal | Mode vocal |

Les mots sont libres : choisis-en d'autres si ceux-ci ne te vont pas, mais garde le mot de « Stop » identique au réglage `validation_word`.

Passe ensuite le Contrôle vocal en **mode commandes** (cherche « mode » dans la liste des commandes pour la formule de ta langue) : sinon, il tape dans le champ de Claude tout ce qu'il entend, y compris la voix de lecture.

Pour changer de session à la voix, ajoute des commandes limitées à Claude avec « Appuyer sur le raccourci clavier » : nouvelle session ⌘N, session suivante ⌘⇧$, précédente ⌘⇧^, rechercher ⌘⇧K (raccourcis lus dans les menus de Claude, clavier AZERTY).

### 6. Les autorisations (Confidentialité et sécurité)

Dans **Accessibilité**, active, en les ajoutant avec « + » au besoin (⌘⇧G pour coller un chemin) :

- Raccourcis (dans Applications) ;
- `/System/Library/CoreServices/Shortcuts Events.app` ;
- `/System/Library/Input Methods/DictationIM.app` — le module de dictée que macOS tient pour responsable des touches envoyées par une commande vocale. Sans lui, la commande marche une fois puis échoue au hasard.

Accepte aussi, quand elles apparaissent, l'autorisation de **contrôler System Events** et l'accès au **micro** pour Spokenly et le Contrôle vocal.

Le chemin de `DictationIM.app` peut différer sur une autre version de macOS. Si une commande vocale échoue, *Dépannage* dit comment trouver le programme refusé.

## Utilisation

- **Écoute** → tu dictes → **Stop** : le message part dans la session affichée. « Écoute » ramène Claude au premier plan et place le curseur dans le champ, d'où que tu sois.
- Une question de Claude : elle est lue (« Session X. Une question. … »), tu réponds, **Stop** valide. La réponse revient toujours à la session qui a posé la question.
- À la fin d'une réponse : le premier paragraphe est lu, suivi de « Il y a une suite » s'il reste du texte. **Continue** lit la suite, **Recommence** relit tout, **Tais-toi** coupe (à placer dans un silence entre deux lignes).
- Plusieurs sessions : les lectures attendent leur tour, chacune annoncée par le nom de sa session. Pendant que tu dictes, rien n'est lu.
- Une session lancée par une autre ne lit pas sa réponse : celle qui l'a lancée te la relaie. Si tu lui parles toi-même, elle te répond à voix haute.
- **Loin du Mac** (sur ton téléphone, par exemple) : quand le clavier et la souris n'ont pas bougé depuis `away_after_idle_seconds`, le plugin refuse l'appel à Spokenly, qui attendrait sur un Mac où tu n'es pas, et la session pose sa question par écrit.
- **Sessions cloud** : sans pont, rien n'est lu et leurs questions restent écrites (la dictée vers elles marche, le champ est sur ton Mac). Avec le pont, tout marche comme en local : voir *Sessions cloud : le pont*.
- **Mode vocal**, ou `/vocal [on|off]` dans Claude : coupe ou rallume tout. Éteint, la file est vidée et les nouvelles sessions ne reçoivent plus les règles vocales.

## Sessions cloud : le pont (facultatif)

Une session cloud tourne sur une machine Linux : sans pont, elle ne parle pas et ses questions restent écrites. Avec le pont, ses hooks et ses questions Spokenly passent par un tunnel jusqu'à ton Mac, et tout marche comme en local, tant que tu es dans la pièce.

```
session cloud ──hooks──▶ https://ton-tunnel/hook ──▶ service du Mac ──▶ lecture, file d'attente
              ──MCP────▶ https://ton-tunnel/mcp  ──▶ service du Mac ──▶ Spokenly (localhost:51089)
```

1. **Le service du Mac** : `sh bin/install-bridge.sh` crée un jeton secret dans `~/.config/claude-speak.json` et lance le service au démarrage de session (port 8765, écoute seulement en local). Il refuse toute requête sans le jeton. `--uninstall` le retire. Il utilise `/usr/bin/python3` (outils de développement d'Apple).
2. **Un tunnel** vers `http://localhost:8765`, à adresse fixe : Cloudflare Tunnel, ngrok, Tailscale Funnel… Avec Cloudflare, sur un domaine protégé, ajoute une règle WAF « Ignorer » et une règle de configuration (niveau de sécurité au minimum, contrôle d'intégrité du navigateur désactivé) pour ce seul nom d'hôte : la page de vérification anti-robots bloquerait la session cloud.
3. **Une clé vérifiée par le tunnel** (recommandé) : chaque appel vers le pont porte l'en-tête `X-Handfree-Key`, avec la valeur de `bridge_edge_key` (`install-bridge.sh` la crée). Fais bloquer par le tunnel toute requête sans la bonne valeur : rien n'atteint alors le Mac. Avec Cloudflare, une règle WAF personnalisée, placée **avant** la règle « Ignorer » :
   ```
   (http.host eq "<ton-tunnel>" and not any(http.request.headers["x-handfree-key"][*] eq "<valeur>"))  →  Bloquer
   ```
4. **L'environnement cloud** (claude.ai, réglages de l'environnement) :
   - variables : `HANDFREE_BRIDGE_URL` (l'adresse du tunnel), `HANDFREE_BRIDGE_TOKEN` (la valeur de `bridge_token`) et, si tu as fait l'étape 3, `HANDFREE_BRIDGE_EDGE_KEY` (la valeur de `bridge_edge_key`) ;
   - réseau : autorise `github.com` et le nom d'hôte du tunnel si l'environnement filtre les sorties ;
   - script de démarrage :
     ```
     curl -fsSL https://raw.githubusercontent.com/fourthscale/handfree-code/main/bin/cloud-setup.sh | bash
     ```
     Il installe le plugin et déclare Spokenly à l'adresse du tunnel, avec le jeton et la clé. Il n'échoue jamais : il manque une pièce, la session reste silencieuse.

Les réglages de lecture sont ceux du Mac (`~/.config/claude-speak.json`) : c'est lui qui lit et qui pose les questions. Un environnement cloud peut en changer quelques-uns pour ses sessions avec la variable facultative `HANDFREE_OVERRIDES`, en JSON, par exemple `{"first_paragraph_only": false, "language": "en"}`. Seuls `language`, `voice`, `validation_word`, `first_paragraph_only`, `pause_between_lines_seconds` et `silence_around_title_ms` sont acceptés : rien qui ferait exécuter un programme au Mac.

Sans `HANDFREE_BRIDGE_URL`, le plugin reste silencieux en cloud. Ses hooks, sur le Mac, ne passent jamais par le pont.

### Comment les sessions joignent Spokenly

Réglage `question_transport`, séparé pour les sessions locales et cloud :

| Valeur | Effet |
|---|---|
| `mcp` | la session appelle le serveur MCP `spokenly` déclaré chez elle (défaut en local) |
| `bridge` | la session passe par le tunnel (défaut en cloud) ; en local, se passe du relais MCP de Spokenly |
| `none` | pas de question à la voix : elles restent écrites |

Les règles vocales ne sont données à une session que si son transport peut aboutir : serveur déclaré pour `mcp`, app Spokenly qui répond pour `bridge`.

Pour changer le transport des sessions locales, et redéclarer `spokenly` en conséquence :

```
sh bin/set-question-transport.sh mcp|bridge|none
```

`bridge` en local demande `bridge_url` et `bridge_token` dans les réglages. Pour le cloud, le transport se règle dans `question_transport.cloud` sur le Mac, et la déclaration de `spokenly` dans le script de démarrage de l'environnement.

Le texte de tes sessions et l'accès à ton micro transitent par le tunnel : choisis un fournisseur auquel tu confies déjà ce trafic, et ne publie jamais le jeton.

## Réglages

Tous facultatifs, dans `~/.config/claude-speak.json` :

| Clé | Défaut | Rôle |
|---|---|---|
| `language` | langue du Mac | phrases dites et règles : `fr`, `en` ou `de` (sinon anglais) |
| `voice` | voix système | nom d'une voix `say` à imposer |
| `validation_word` | `stop` | mot qui envoie une dictée ; les sessions apprennent à l'ignorer en fin de message |
| `first_paragraph_only` | `true` | `false` lit toute la réponse d'office |
| `pause_between_lines_seconds` | `1.2` | silence entre deux lignes, où une commande vocale peut passer |
| `silence_around_title_ms` | `800` | silence autour du nom de la session |
| `max_dictation_seconds` | `180` | après une dictée abandonnée sans « Stop », la lecture reprend |
| `question_tool` | `mcp__spokenly__ask_user_dictation` | outil des questions ; les règles ne sont injectées que si son serveur MCP est déclaré |
| `target_app` | `Claude` | app que « Écoute » ramène ; `iTerm2` ou `Terminal` pour Claude Code dans un terminal |
| `click_prompt` | auto | clic dans le champ : par défaut seulement pour l'app Claude |
| `prompt_name` | `Prompt` | nom d'accessibilité du champ de message de l'app Claude |
| `prompt_fallback` | `{"x_ratio": 0.6, "from_bottom": 55}` | point cliqué quand le champ n'est pas retrouvé |
| `spokenly_trigger` | `double_right_command` | ou `none` |
| `activate_delay_seconds` | `0.5` | attente après avoir ramené l'app |
| `after_click_delay_seconds` | `0.3` | attente après le clic |
| `double_tap_gap_seconds` | `0.12` | écart entre les deux appuis |
| `away_after_idle_seconds` | `300` | au-delà de cette inactivité du Mac, les questions passent par écrit |
| `question_transport` | `{"local": "mcp", "cloud": "bridge"}` | comment chaque type de session joint Spokenly : `mcp`, `bridge` ou `none` |
| `bridge_url` | — | adresse publique du tunnel, pour le transport local `bridge` |
| `bridge_token` | — | jeton du pont, créé par `install-bridge.sh` |
| `bridge_edge_key` | — | valeur de l'en-tête `X-Handfree-Key`, vérifiée par le tunnel ; créée par `install-bridge.sh` |
| `bridge_port` | `8765` | port local du service du pont |

Le hook des questions réagit à tout outil `mcp__…spokenly…__ask_user_dictation`. Pour un autre outil de dictée, change aussi le `matcher` de `hooks/hooks.json`.

## Comment « Écoute » trouve le champ

Le champ de message de l'app Claude est retrouvé par son nom d'accessibilité, au bout d'un chemin mémorisé (25 ms) : il est cliqué là où il est réellement, quelle que soit la taille de la fenêtre ou l'écran. Si ce chemin ne mène plus au champ (mise en page changée), le point de secours est cliqué et le chemin est réappris en arrière-plan (environ 30 s), pour la fois suivante.

## Dépannage

- **Une commande vocale ne fait rien** : une autorisation a sauté. Décoche puis recoche l'app dans Accessibilité. Pour savoir laquelle, lis le journal des autorisations juste après l'échec :
  ```
  /usr/bin/log show --last 5m --style compact --predicate 'process == "tccd"' | grep -E "PostEvent|AUTHREQ_SUBJECT|AUTHREQ_RESULT"
  ```
  `authValue=0` suivi d'un `AUTHREQ_SUBJECT` donne le programme refusé.
- **« Raccourcis n'est pas autorisé à envoyer des saisies »** : retire Raccourcis de la liste (« − ») et rajoute-le. Au besoin, `tccutil reset Accessibility com.apple.shortcuts` force macOS à redemander.
- **Rien n'est lu** : vérifie le mode vocal (`/vocal on`), puis la voix système avec `say bonjour`.
- **Un hook ajouté en cours de session n'est pas pris en compte** : ouvre une nouvelle session.

## Ce qui peut casser avec une mise à jour

- L'app Claude peut renommer ou traduire son champ « Prompt » : le clic de secours prend le relais, et `prompt_name` se règle.
- Le titre des sessions et la détection des tours délégués lisent le format interne des historiques de Claude Code. S'il change, le plugin retombe sur le comportement simple : nom du dossier au lieu du titre, réponse lue plutôt que tue.
- L'état enregistré porte un numéro de version : une version du plugin qui ne le reconnaît pas repart de zéro.

## Développer

```
tests/run.sh
tests/bridge.sh
```

Tests sans son : une fausse commande `say` écrit dans un fichier, l'état et les réglages vivent dans un dossier temporaire. À relancer avant chaque version. La partie « Écoute » (clic, accessibilité) se teste à la main.
