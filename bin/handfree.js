// handfree-code — read Claude Code aloud and drive it by voice on macOS.
// Runs with `osascript -l JavaScript handfree.js <command>`: osascript ships with every Mac, unlike python3.
//
// Hooks
//   (none)            Stop: queues the new reply (stdin)
//   --question        PreToolUse on the dictation tool: pauses the queue, reads the question, then waits for the dictation
//   --notify          Notification: queues "Claude needs your answer"
//   --session-rules   SessionStart: prints the voice rules; refreshes the stable copy the listener, bridge and app run
//                     (voice mode off too)
//   --guard-question  PreToolUse on AskUserQuestion, the app's session offer and end-of-turn question: sends Claude to the dictation tool instead
//   --permission      PermissionRequest: reads the request, answers it from a spoken yes or no (voice_permissions)
//   --prompt-sent     UserPromptSubmit: a message sent (Return, a click) ends a free dictation that "Stop" did not;
//                     a session that has not heard voice mode was switched is told with it (voice mode off too)
//   --answered        PostToolUse on the dictation tool: the answer is in, however it was sent; the queue goes on.
//                     Answered "the rest": the rest of the text before the question is read, and Claude asks again
// Spoken commands (bin/listener.py runs them)
//   --listen          "Claude Listen": silence, then a dictation in the app's pill, its text sent to Claude's message
//                     field (Claude left behind when it was said in another app, else brought forward)
//   --reply           "Claude Reply": the same, in the session that spoke last
//   --search-session  "Claude Session": open the app's session search and start the dictation; "Stop" opens the one named
//   --done            "Stop": the dictation is sent, the queue goes on
//   --cancel          "Claude Cancel": Escape was pressed in the dictation window; a free dictation ends, nothing is sent
//   --quiet / --continue / --restart   "Claude Quiet" / "Claude Continue" / "Claude Restart"
//   --on / --off      "Claude Voice mode on" / "Claude Voice mode off" (--toggle: /vocal with no argument)
// Internal: --read (the reader process), --learn-prompt-path (background search of the message field),
//   --go-back <bundle> <since> (brings the app "Listen" was said in back, once the dictated message is sent),
//   --dictate-behind <session> (records in the app's pill and sends the text to Claude left behind),
//   --dictating (holds the readings as a free dictation does; the tests use it),
//   --refresh-stable-copy (the installers: copies the scripts to the stable copy, whatever its version)

ObjC.import('Foundation')
ObjC.import('AppKit')
ObjC.import('CoreGraphics')

const STATE_VERSION = 1
const HOME = ObjC.unwrap($.NSHomeDirectory())
const ENV = ObjC.deepUnwrap($.NSProcessInfo.processInfo.environment)
// Before 0.3.2 the plugin was "claude-speak": its files move to the new names once, a link left behind for a part
// not yet updated (the app until it is rebuilt).
const OLD_CONFIG_PATH = `${HOME}/.config/claude-speak.json`
const OLD_STATE_DIR = `${HOME}/Library/Caches/claude-speak`
const CONFIG_PATH = ENV.HANDFREE_CONFIG || `${HOME}/.config/handfree-code.json`
const STATE_DIR = ENV.HANDFREE_STATE_DIR || `${HOME}/Library/Caches/handfree-code`
if (!ENV.HANDFREE_CONFIG && !ENV.HANDFREE_STATE_DIR) moveOldFiles()
const STATE_PATH = `${STATE_DIR}/state.json`
const LOCK_PATH = `${STATE_DIR}/state.lock`
const SPEECH_LOCK_PATH = `${STATE_DIR}/speech.lock`
const STABLE_COPY = `${ENV.HANDFREE_SUPPORT_DIR || `${HOME}/Library/Application Support/handfree-code`}/handfree.js`
const LAUNCH_AGENTS_DIR = ENV.HANDFREE_LAUNCH_AGENTS_DIR || `${HOME}/Library/LaunchAgents`
const LISTENER_LABEL = 'com.handfree-code.listener'
const BRIDGE_LABEL = 'com.handfree-code.bridge'
// Where the Claude app keeps its Code sessions, one local_<id>.json each, naming the Claude Code session it runs.
const APP_SESSIONS_DIR = ENV.HANDFREE_APP_SESSIONS_DIR || `${HOME}/Library/Application Support/Claude/claude-code-sessions`

const DEFAULTS = {
  language: null, // null: the Mac's first language
  voice: null, // null: the system voice and rate (Accessibility > Spoken Content)
  say_path: '/usr/bin/say',
  speak_command: null, // another voice: a shell script given the text as its argument, done when it has spoken (speak-openai.sh)
  pause_between_lines_seconds: 1.2, // a pause between lines, where a spoken command gets through
  silence_around_title_ms: 800,
  announce_session: 'on_change', // or 'always': before every reply, question and resumed reading
  pause_media: true, // pause the Now Playing app (music, YouTube…) while speaking, resume afterwards
  media_control: null, // null: media-control used when installed (needed from macOS 15.4); a path to it; false never
  max_dictation_seconds: 180, // a dictation abandoned without "Stop" frees the reader after this
  first_paragraph_only: true, // the rest waits for "Continue"
  summarize_rest: true, // answering "the rest" to a question: a summary first, "the details" for the full text
  validation_word: null, // the spoken word that sends a dictation (the transcription may keep it); null: the "Stop" phrase
  question_tool: null, // null: the Handfree Code app's tool (mcp__handfree__ask_user_dictation), or a name of your own
  dictation_url: null, // null: the Handfree Code app on this Mac (http://localhost:51290)
  target_app: 'Claude', // the app "Listen" brings forward
  dictate_behind: true, // said in another app, Claude stays behind: the app records, the text is sent through accessibility
  dictation_log: false, // true: how each dictation with Claude behind went, in the state folder's dictate-behind.log
  return_to_previous_app: true, // after "Stop", back to the app "Listen" was said in (none if it was already target_app)
  click_prompt: null, // null: only for the Claude desktop app; a terminal has no field to click
  prompt_name: 'Prompt', // accessibility description of the desktop app's message field
  prompt_fallback: { x_ratio: 0.6, from_bottom: 55 }, // clicked while the field's path is relearnt
  activate_delay_seconds: 0.5,
  after_click_delay_seconds: 0.3,
  open_session_delay_seconds: 0.8, // wait for the app to show the session "Claude Reply" opened
  away_after_idle_seconds: 300, // keyboard and mouse untouched this long: the user is not at the Mac (on the phone, say)
  // Answer permission prompts by voice. Off by default: a misheard "yes" would allow the action.
  voice_permissions: false,
  permission_answer_seconds: 90,
  // How a session reaches the dictation: 'mcp' (its MCP server declared in the session), 'bridge' (through the tunnel),
  // or 'none' (questions stay written). Set per context; switch the local one with bin/set-question-transport.sh.
  question_transport: { local: 'mcp', cloud: 'bridge' },
  bridge_url: null, // the tunnel's public address, used when the local transport is 'bridge'
}



// ---------- every text per language, in one place. Adding a language: an entry here, then the files outside this
// one listed in docs/development.md ("Adding a language").
//   spoken  said to the user, in the user's language
//   claude  told to Claude (the voice rules, the hooks' reasons); a language without them uses English
//   words   what answers and the app's buttons are recognised by: every language's, whatever the language set
const TEXTS = {
  fr: {
    spoken: { session: 'Session {title}.', question: 'Une question.', link: 'lien', code: 'Bloc de code omis.', more: 'Détail disponible.', detail: 'Pour tout entendre, réponds « le détail ».', dictate: 'Ton message pour Claude.', cloud: 'cloud', not_sent: 'Message pas envoyé : il attend dans Claude.', voice_on: 'Mode vocal activé.', voice_off: 'Mode vocal désactivé.', permission: 'Autorisation demandée : {action}. Autoriser ?', idle: "Claude t'attend", waiting: 'Claude attend ta réponse' },
    claude: {
      rules:
        'Mode vocal actif.\n' +
        "- Quand tu dois me poser une question et attendre ma réponse (un grill, un choix, une validation), utilise l'outil `{tool}` plutôt que `AskUserQuestion`. " +
        "Y compris la question de fin de tour : les boutons de l'app ne me sont pas lus, je ne peux pas y répondre à la voix. " +
        "Quand la question porte sur un texte (des options, une explication), écris ce texte en entier dans ta réponse, la question à la fin, et termine ton tour sans appeler l'outil : " +
        "on te demandera alors de poser la question seule avec l'outil, et ton texte me sera lu avant. Le texte écrit juste avant un appel d'outil peut être caché dans l'app.\n" +
        "- Quand ta réponse est longue (plus de deux ou trois paragraphes), commence-la par un paragraphe de deux ou trois phrases qui la résume en entier : " +
        "c'est lui qui m'est lu, puis « détail disponible » ; le reste seulement si je le demande.\n" +
        "- Je dicte et je valide en disant « {word} » : un « {word} » en fin de message ou de réponse dictée est cette commande, pas une demande d'arrêter. Ignore-le.",
      voice_off: "Mode vocal désactivé : les règles vocales données plus tôt dans cette session ne s'appliquent plus. Pose tes questions comme d'habitude.",
      unspoken_question: "Ce tour se termine sur une question posée seulement à l'écrit ou dans la boîte de l'app : l'utilisateur pilote à la voix et ne peut pas y répondre. Pose-la maintenant avec l'outil `{tool}`, la question seule : ta réponse est affichée et lui est lue avant. Puis termine sans la répéter à l'écrit.",
      screen_only_question: "Mode vocal actif : cette question s'affiche seulement à l'écran, l'utilisateur ne l'entend pas et ne peut pas y répondre à la voix. Pose-la avec l'outil `{tool}` à la place (la question seule ; le texte qu'elle concerne va dans ta réponse écrite).",
      screen_only_session_offer: "Mode vocal actif : cette proposition attend un clic à l'écran, l'utilisateur ne l'entend pas. Demande-lui avec l'outil `{tool}` s'il veut cette tâche dans une nouvelle session ou ici. S'il choisit une nouvelle session, lance-la (initiation \"user_asked\") ; sinon fais-la ici.",
      screen_only_end_of_turn_question: "Mode vocal actif : la question de cette boîte de fin de tour s'affiche seulement à l'écran, l'utilisateur ne l'entend pas. Rappelle l'outil sans `ask` ni `actions` (le résumé seul), puis pose la question avec l'outil `{tool}`.",
      away: "L'utilisateur n'est pas devant son Mac (aucune activité depuis {minutes} min) : la dictée ne l'atteindrait pas. Pose ta question par écrit dans ta réponse.",
      busy: "Une autre question ou une dictée est en cours depuis plus d'une minute : la tienne ne serait pas entendue. Pose ta question par écrit dans ta réponse.",
    },
    words: { yes: ['oui', 'ouais', 'autorise', 'autoriser', 'vas-y', 'valide', "d'accord"], no: ['non', 'refuse', 'refuser'], more: ['la suite', 'suite', 'continue', 'lis la suite'], detail: ['le détail', 'détail', 'les détails', 'détails', 'montre le détail', 'lis le détail', 'tout'], send_button: ['envoyer'] },
  },
  en: {
    spoken: { session: 'Session {title}.', question: 'A question.', link: 'link', code: 'Code block skipped.', more: 'Details available.', detail: 'To hear it all, answer "the details".', dictate: 'Your message for Claude.', cloud: 'cloud', not_sent: 'Message not sent: it is waiting in Claude.', voice_on: 'Voice mode on.', voice_off: 'Voice mode off.', permission: 'Permission requested: {action}. Allow?', idle: 'Claude is waiting', waiting: 'Claude needs your answer' },
    claude: {
      rules:
        'Voice mode is on.\n' +
        '- When you need to ask me a question and wait for the answer (a grill, a choice, a go-ahead), use the `{tool}` tool rather than `AskUserQuestion`, ' +
        "including the end-of-turn question: the app's buttons are not read to me and I cannot answer them by voice. " +
        "When the question is about some text (options, an explanation), write that text in full in your reply, the question last, and end your turn without calling the tool: " +
        "you will then be asked to put the question alone to the tool, and your text is read to me first. Text written just before a tool call may be hidden in the app.\n" +
        '- When your reply is long (more than two or three paragraphs), open it with a paragraph of two or three sentences summing it all up: ' +
        'that is what is read to me, then "details available"; the rest only if I ask for it.\n' +
        '- I dictate and send by saying "{word}": a trailing "{word}" in a dictated message or answer is that command, not a request to stop. Ignore it.',
      voice_off: 'Voice mode is off: the voice rules given earlier in this session no longer apply. Ask your questions as usual.',
      unspoken_question: "This turn ends on a question asked only in writing or in the app's box: the user drives by voice and cannot answer it. Ask it now with the `{tool}` tool, the question alone: your reply is on screen and is read to them first. Then finish without repeating it in writing.",
      screen_only_question: 'Voice mode is on: this question only shows on screen; the user does not hear it and cannot answer it by voice. Ask it with the `{tool}` tool instead (the question alone; the text it is about goes in your written reply).',
      screen_only_session_offer: 'Voice mode is on: this offer waits for a click on screen; the user does not hear it. Ask them with the `{tool}` tool whether they want this task in a new session or here. If they pick a new session, start it (initiation "user_asked"); otherwise do it here.',
      screen_only_end_of_turn_question: 'Voice mode is on: the question in this end-of-turn box only shows on screen; the user does not hear it. Call the tool again without `ask` or `actions` (the recap alone), then ask the question with the `{tool}` tool.',
      away: 'The user is not at their Mac (no activity for {minutes} min): the dictation would not reach them. Ask your question in writing in your reply.',
      busy: 'Another question or dictation has been under way for over a minute: yours would not be heard. Ask your question in writing in your reply.',
    },
    words: { yes: ['yes', 'allow', 'approve', 'go ahead'], no: ['no', 'deny'], more: ['the rest', 'more', 'go on'], detail: ['the details', 'details', 'the detail', 'detail', 'all of it'], send_button: ['send'] },
  },
  de: {
    spoken: { session: 'Sitzung {title}.', question: 'Eine Frage.', link: 'Link', code: 'Codeblock ausgelassen.', more: 'Details verfügbar.', detail: 'Um alles zu hören, antworte „die Details“.', dictate: 'Deine Nachricht an Claude.', cloud: 'Cloud', not_sent: 'Nachricht nicht gesendet: sie wartet in Claude.', voice_on: 'Sprachmodus an.', voice_off: 'Sprachmodus aus.', permission: 'Erlaubnis angefragt: {action}. Erlauben?', idle: 'Claude wartet', waiting: 'Claude wartet auf deine Antwort' },
    words: { yes: ['ja', 'erlauben'], no: ['nein', 'ablehnen'], more: ['weiter', 'mehr', 'der rest'], detail: ['die details', 'details zeigen', 'alles'], send_button: ['senden', 'absenden'] },
  },
}

// Answers and buttons in any of the languages: the user may answer in another one than the plugin speaks.
const anyLanguage = (kind) => Object.values(TEXTS).flatMap((texts) => texts.words[kind])
const YES_WORDS = anyLanguage('yes') // clear words only: anything else leaves the usual dialog on screen
const NO_WORDS = anyLanguage('no')
// Answers that only ask for the rest of the text read before the question: summed up first, then in full.
const MORE_ANSWERS = anyLanguage('more')
const DETAIL_ANSWERS = anyLanguage('detail')
const SEND_BUTTON = new RegExp(`^(${anyLanguage('send_button').join('|')})\\b`, 'i')

const DELEGATED_TURN_ORIGINS = ['sdk', 'peer'] // an unknown value, after a Claude Code update, reads the reply
const LEARNING_TIMEOUT_SECONDS = 120
const MAX_SEND_BACKS = 3 // written questions sent back in a row with none asked aloud: then Claude is let go
const RETURN_KEY = 36
const SEND_WAIT_SECONDS = 5 // for the app to take the text in, then to send it
const RETURN_WAIT_SECONDS = 30 // for the dictated message to be sent before going back
const RETURN_APP_KEPT_SECONDS = 300 // a session search abandoned long ago does not decide where "Stop" goes
const LOCK_STALE_SECONDS = 10
const SPEECH_LOCK_STALE_SECONDS = 20 // the speaker touches it every 5 s: older, its holder is gone
// One deadline for waiting on another dictation, then on the reading under way: the question hook has 120 s in all,
// its own reading included; the permission hook 150 s, the answer's 90 included.
const QUESTION_WAIT_SECONDS = Number(ENV.HANDFREE_QUESTION_WAIT_SECONDS) || 90
// What the question hook reads before its question stops this long after it started, however long it waited: the
// question itself, then the microphone, still fit in its 120 s (105 s through the bridge). The lines not said stay
// for "the rest".
const QUESTION_READING_SECONDS = Number(ENV.HANDFREE_QUESTION_READING_SECONDS) || 85
const PERMISSION_WAIT_SECONDS = Number(ENV.HANDFREE_QUESTION_WAIT_SECONDS) || 40
const SESSION_NOTE_SECONDS = 24 * 3600 // a note kept per session (a reply sent back, a question sent back) is dropped after this
// `say` returns with the end of its line still in the speakers: the microphone opening then makes it crackle.
const QUESTION_TAIL_SECONDS = 0.5

// ---------- system helpers

const app = Application.currentApplication()
app.includeStandardAdditions = true

function moveOldFiles() {
  const manager = $.NSFileManager.defaultManager
  const isReal = (path) => {
    const attributes = manager.attributesOfItemAtPathError(path, null)
    return !attributes.isNil() && ObjC.unwrap(attributes.fileType) !== ObjC.unwrap($.NSFileTypeSymbolicLink)
  }
  if (!isReal(OLD_CONFIG_PATH) && !isReal(OLD_STATE_DIR)) return
  const q = (path) => `'${path.replace(/'/g, "'\\''")}'`
  const config = `[ -f ${q(OLD_CONFIG_PATH)} ] && [ ! -L ${q(OLD_CONFIG_PATH)} ] && [ ! -e ${q(CONFIG_PATH)} ] && mv ${q(OLD_CONFIG_PATH)} ${q(CONFIG_PATH)} && ln -s ${q(CONFIG_PATH)} ${q(OLD_CONFIG_PATH)}`
  const state = `[ -d ${q(OLD_STATE_DIR)} ] && [ ! -L ${q(OLD_STATE_DIR)} ] && mkdir -p ${q(STATE_DIR)} && (cd ${q(OLD_STATE_DIR)} && for f in * .[!.]*; do [ -e "$f" ] && [ ! -e ${q(STATE_DIR)}/"$f" ] && mv "$f" ${q(STATE_DIR)}/; done; true) && rm -rf ${q(OLD_STATE_DIR)} && ln -s ${q(STATE_DIR)} ${q(OLD_STATE_DIR)}`
  const runner = Application.currentApplication() // `app` is not made yet: this runs before the settings are read
  runner.includeStandardAdditions = true
  try {
    runner.doShellScript(`${config}; ${state}; true`)
  } catch (e) {}
}

function readFile(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null)
  return text.isNil() ? null : ObjC.unwrap(text)
}

function writeFile(path, text) {
  ensureDirectory(path.replace(/\/[^/]*$/, ''))
  $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
}

function ensureDirectory(path) {
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, true, $(), null)
}

function readJson(path) {
  try {
    return JSON.parse(readFile(path))
  } catch (e) {
    return null
  }
}

function shell(command) {
  try {
    return app.doShellScript(command)
  } catch (e) {
    return ''
  }
}

// The same, stopped after `seconds`: for a program that may hang (media-control waiting on a stuck player).
function shellWithin(seconds, command) {
  return shell(`perl -e 'alarm shift; exec @ARGV' ${Math.ceil(seconds)} /bin/sh -c ${quote(command)}`)
}

function quote(text) {
  return "'" + String(text).replace(/'/g, "'\\''") + "'"
}

function now() {
  return Date.now() / 1000
}

function readStdin() {
  const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile
  const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding))
  try {
    return JSON.parse(text)
  } catch (e) {
    return {}
  }
}

// ---------- configuration and phrases

// A cloud environment may adjust how its sessions are read; nothing that would run a program on this Mac.
const CLOUD_OVERRIDABLE = ['language', 'voice', 'validation_word', 'first_paragraph_only', 'summarize_rest', 'pause_between_lines_seconds', 'silence_around_title_ms']
const CONFIG = Object.assign({}, DEFAULTS, readJson(CONFIG_PATH) || {}, cloudOverrides())

function cloudOverrides() {
  let overrides
  try {
    overrides = JSON.parse(ENV.HANDFREE_OVERRIDES || '{}')
  } catch (e) {
    return {}
  }
  return Object.fromEntries(Object.entries(overrides || {}).filter(([key]) => CLOUD_OVERRIDABLE.includes(key)))
}
const LANGUAGE = (CONFIG.language || macLanguage()).slice(0, 2)
const PHRASE = (TEXTS[LANGUAGE] || TEXTS.en).spoken
const FOR_CLAUDE = (TEXTS[LANGUAGE] || {}).claude || TEXTS.en.claude
if (!CONFIG.validation_word) CONFIG.validation_word = stopPhrase()

// The listener's "Stop": the user's own phrase, else the language's (voice-commands.json, shared with the app). "stopp" in German.
function stopPhrase() {
  const chosen = (CONFIG.voice_commands || {}).stop || (CONFIG.voice_commands || {}).Stop
  const defaults = readJson(`${scriptPath().replace(/\/[^/]*$/, '')}/voice-commands.json`) || {}
  const phrase = [].concat(chosen || ((defaults.phrases || {})[LANGUAGE] || {}).stop || [])[0]
  return typeof phrase === 'string' && phrase.trim() ? phrase.trim() : 'stop'
}
const SILENCE = `[[slnc ${Math.round(CONFIG.silence_around_title_ms)}]]`

function macLanguage() {
  const match = shell('defaults read -g AppleLanguages').match(/"?([a-z]{2})[-_"]/)
  return match ? match[1] : 'en'
}

// One voice at a time, whichever process speaks (the reader, a question, "the rest"): a line waits for the one being said.
function say(text) {
  ensureDirectory(STATE_DIR)
  acquireLock(SPEECH_LOCK_PATH, SPEECH_LOCK_STALE_SECONDS)
  try {
    sayNow(text)
  } finally {
    releaseLock(SPEECH_LOCK_PATH)
  }
}

function sayNow(text) {
  pauseMediaIfPlaying()
  // A program that cannot be started or fails (no network, a wrong key) must never silence the voice: say takes over.
  const seconds = longestSpeaking(text)
  if (!CONFIG.speak_command || !speakWith('/bin/sh', [CONFIG.speak_command.replace(/^~(?=\/)/, HOME), text.replace(/\[\[slnc \d+\]\]/g, ' ').replace(/\s+/g, ' ').trim()], seconds)) {
    // "--": a line starting with "-" is text, never an option (`-o` would write a file).
    speakWith(CONFIG.say_path, (CONFIG.voice ? ['-v', CONFIG.voice] : []).concat('--', text), seconds)
  }
  withState((state) => {
    state.last_speech_end = now()
  })
}

const TASK_KILLED = 2 // NSTaskTerminationReasonUncaughtSignal

// The speaking process is recorded so that "Quiet" can stop it, whatever program it is.
// How long a line may take: a slow voice reads 100 words a minute, and a long paragraph is one line. A voice still
// going after that has hung (an audio device changing under it).
function longestSpeaking(text) {
  return 30 + 0.6 * String(text).split(/\s+/).filter(Boolean).length
}

function speakWith(path, args, maxSeconds) {
  let task
  try {
    task = $.NSTask.launchedTaskWithLaunchPathArguments(path, args)
  } catch (e) {
    return false
  }
  withState((state) => {
    state.speaker_pid = task.processIdentifier
  })
  // A voice that hangs must not hold everything up: cut it once it has gone on far longer than the line needs.
  // Meanwhile the speech lock is kept fresh, so that a long line is never taken for a dead one.
  const deadline = now() + maxSeconds
  for (let tick = 0; task.isRunning && now() < deadline; tick++) {
    if (tick % 50 === 49) touch(SPEECH_LOCK_PATH)
    delay(0.1)
  }
  if (task.isRunning) task.terminate
  task.waitUntilExit
  withState((state) => {
    state.speaker_pid = null
  })
  // Stopped by "Quiet" is not a failure: say must not take the line over.
  return task.terminationStatus === 0 || task.terminationReason === TASK_KILLED
}

// ---------- pausing what plays while speaking

// MediaRemote commands sent to the Now Playing app, the one the keyboard's play/pause key drives.
// A synthetic media key does not work from osascript: the event it builds reaches nobody.
const MEDIA_COMMAND = { play: 0, pause: 1 }
const MEDIA_COMMAND_SEND_SECONDS = 0.5 // the command leaves asynchronously: the process must outlive it
const MEDIA_CONTROL_SECONDS = 3 // media-control answers at once; a player that hangs must not hold a hook
// The fallback below sees audio about ten seconds after it stops: within that window, it may be our own voice.
const AUDIO_SIGNAL_LINGER_SECONDS = 12

// macOS 15.4 and later keep MediaRemote to Apple's own programs: there, `media-control` (brew install media-control),
// when installed, reads and drives what plays instead. Without it, MediaRemote as before (fine up to macOS 15.3).
function mediaControl() {
  if (ENV.HANDFREE_MEDIA_CONTROL !== undefined) return ENV.HANDFREE_MEDIA_CONTROL
  const configured = CONFIG.media_control
  if (configured === false) return ''
  const candidates = configured ? [configured] : ['/opt/homebrew/bin/media-control', '/usr/local/bin/media-control']
  return candidates.find((path) => shell(`test -x ${quote(path)} && echo yes`) === 'yes') || ''
}

function loadMediaRemote() {
  $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load
}

// Asked of the Now Playing app itself: paused a second ago is paused. null when this macOS cannot say.
function nowPlayingIsPlaying() {
  if (ENV.HANDFREE_NOW_PLAYING) return { 1: true, 0: false }[ENV.HANDFREE_NOW_PLAYING] ?? null
  const tool = mediaControl()
  if (tool) {
    // `get` prints the Now Playing app's state as JSON, or null when nothing has one.
    const output = shellWithin(MEDIA_CONTROL_SECONDS, `${quote(tool)} get 2>/dev/null`)
    if (output === 'null') return false
    try {
      return Boolean(JSON.parse(output).playing)
    } catch (e) {} // an unreadable answer: MediaRemote, then the audio signal, decide
  }
  try {
    loadMediaRemote()
    const request = $.NSClassFromString('MRNowPlayingRequest')
    if (request.isNil() || !request.respondsToSelector('localIsPlaying')) return null
    return Boolean(request.localIsPlaying)
  } catch (e) {
    return null
  }
}

// Fallback: coreaudiod holds an assertion per device in use, naming the process it serves; inputs are marked
// audio-in. Older macOS mark outputs audio-out, macOS 14 only names the device: anything not audio-in is an output.
function audioOutputInUse(state) {
  if (now() - state.last_speech_end < AUDIO_SIGNAL_LINGER_SECONDS) return false
  if (ENV.HANDFREE_AUDIO_PLAYING) return ENV.HANDFREE_AUDIO_PLAYING === '1'
  const pids = [...shell('pmset -g assertions').matchAll(/Created for PID: (\d+)\.?\s*[\r\n]\s*Resources: (?!audio-in)/g)].map((m) => m[1])
  if (!pids.length) return false
  // Our own voice is not music; an assertion outliving its process is a sound that ended.
  return shell(`ps -o comm= -p ${pids.join(',')}; true`).split(/[\r\n]+/).some((command) => command.trim() && !/(^|\/)say$/.test(command.trim()))
}

function mediaIsPlaying(state) {
  const playing = nowPlayingIsPlaying()
  return playing === null ? audioOutputInUse(state) : playing
}

// Paused only when something plays, never on a doubt: resuming afterwards must not start what the user had stopped.
// Paused by us but playing again (resumed by hand after a dictation sent with Return, say): pause it again. Only when the
// Now Playing app answers; the audio-signal fallback cannot tell our own voice from music.
// Asked and sent outside the state's lock: the player, media-control or pmset may take their time, and every other
// process waits on that lock.
function pauseMediaIfPlaying() {
  if (!CONFIG.pause_media) return
  const known = readState()
  const playing = known.media_paused ? nowPlayingIsPlaying() === true : mediaIsPlaying(known)
  if (!playing) return
  sendMediaCommand('pause')
  withState((state) => (state.media_paused = true))
}

// Inside the lock: whether what we paused is to be resumed, the mark taken off. The caller sends "play" once out of it.
function takeMediaPause(state) {
  const paused = Boolean(state.media_paused)
  state.media_paused = false
  return paused
}

function sendMediaCommand(name) {
  if (ENV.HANDFREE_MEDIA_KEY_LOG) return writeFile(ENV.HANDFREE_MEDIA_KEY_LOG, (readFile(ENV.HANDFREE_MEDIA_KEY_LOG) || '') + name + '\n')
  const tool = mediaControl()
  if (tool) return shellWithin(MEDIA_CONTROL_SECONDS, `${quote(tool)} ${name === 'pause' ? 'pause' : 'play'} 2>/dev/null; true`)
  try {
    loadMediaRemote()
    ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']])
    $.MRMediaRemoteSendCommand(MEDIA_COMMAND[name], $())
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(MEDIA_COMMAND_SEND_SECONDS))
  } catch (e) {} // a command that cannot be sent must never silence the voice
}

// ---------- state, shared by every process, behind a lock

function emptyState() {
  return { version: STATE_VERSION, current: null, cut: null, queue: [], announced_id: null, last_speaker: null, reader_pid: null, next_id: 0, dictating_since: null, dictating_session: null, held_by: null, reading_requested: false, finishing_current: false, quiet_since: 0, return_app: null, sent_backs: {}, read_before_questions: {}, replies_before_question: {}, detail: null, voice_off: false, prompt_path: null, learning_since: null, media_paused: false, last_speech_end: 0, speaker_pid: null }
}

// A note kept for each session (several may wait on a question at once). An old one, from a session long gone, is dropped.
function sessionNotes(state, field) {
  const notes = state[field] && typeof state[field] === 'object' ? state[field] : {}
  for (const [session, note] of Object.entries(notes)) if (!note || now() - (note.at || 0) > SESSION_NOTE_SECONDS) delete notes[session]
  state[field] = notes
  return notes
}

function takeSessionNote(state, field, session) {
  const notes = sessionNotes(state, field)
  const note = notes[session] || null
  delete notes[session]
  return note
}

// The shared state as it is now, without the lock: only to look (what plays, before asking the player), never to change.
function readState() {
  const saved = readJson(STATE_PATH)
  // A state written by another plugin version may mean something else: start over. Never bump STATE_VERSION: older
  // sessions write the same file, and each would wipe the other's state at every write. Add optional fields instead.
  return saved && saved.version === STATE_VERSION ? Object.assign(emptyState(), saved) : emptyState()
}

// Every change goes through here, under the lock. A change that changed nothing (a mere look) writes nothing.
function withState(change) {
  ensureDirectory(STATE_DIR)
  acquireLock()
  try {
    const state = readState()
    const before = JSON.stringify(state)
    const result = change(state)
    const after = JSON.stringify(state)
    if (after !== before || !readFile(STATE_PATH)) writeFile(STATE_PATH, after)
    return result
  } finally {
    releaseLock()
  }
}

// A lock is a folder holding its owner's token: a holder slower than the stale delay, its lock taken over meanwhile,
// must not then remove the new owner's.
const LOCK_TOKEN = `${$.NSProcessInfo.processInfo.processIdentifier}-${Math.random()}`

function acquireLock(path = LOCK_PATH, staleSeconds = LOCK_STALE_SECONDS) {
  const manager = $.NSFileManager.defaultManager
  for (;;) {
    if (manager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, false, $(), null)) {
      $(LOCK_TOKEN).writeToFileAtomicallyEncodingError(`${path}/owner`, false, $.NSUTF8StringEncoding, null)
      return
    }
    const attributes = manager.attributesOfItemAtPathError(path, null)
    if (!attributes.isNil() && now() - attributes.fileModificationDate.timeIntervalSince1970 > staleSeconds) releaseLock(path, true)
    delay(0.02)
  }
}

function touch(path) {
  $.NSFileManager.defaultManager.setAttributesOfItemAtPathError($({ NSFileModificationDate: $.NSDate.date }), path, null)
}

// `force`: whoever holds it (a stale lock, or a line cut short by "Quiet"). Otherwise only a lock this process still owns.
function releaseLock(path = LOCK_PATH, force = false) {
  if (!force && readFile(`${path}/owner`) !== LOCK_TOKEN) return
  $.NSFileManager.defaultManager.removeItemAtPathError(path, null)
}

// ---------- transcripts

function readTranscript(path) {
  const text = path ? readFile(path) : null
  if (!text) return []
  return text.split('\n').flatMap((line) => {
    try {
      return [JSON.parse(line)]
    } catch (e) {
      return []
    }
  })
}

function promptText(entry) {
  const content = (entry.message || {}).content
  if (typeof content === 'string') return content
  return (content || []).filter((b) => b && b.type === 'text').map((b) => b.text || '').join(' ')
}

function lastReply(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i]
    if (entry.type !== 'assistant') continue
    const text = ((entry.message || {}).content || []).filter((b) => b && b.type === 'text' && (b.text || '').trim()).map((b) => b.text).join('\n')
    if (text) return text
  }
  return ''
}

// The session that delegated the turn relays its outcome: reading it here too says it twice.
function startedByAnotherSession(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i]
    // A hook's feedback (isMeta) continues the turn, it does not start one.
    if (entry.type !== 'user' || entry.isMeta || !entry.turnOrigin || !promptText(entry).trim()) continue
    // App events are also sdk-originated but arrive wrapped in a tag; briefs and messages do not.
    return DELEGATED_TURN_ORIGINS.includes(entry.turnOrigin) && !promptText(entry).trimStart().startsWith('<')
  }
  return false
}

// The title Claude Code keeps for a session, else its folder's name. A cloud session has no title in its transcript (it
// lives on claude.ai): "cloud" before the folder's name tells where it runs.
function sessionTitle(entries, cwd) {
  const titles = entries.filter((e) => e.type === 'custom-title' && e.customTitle).map((e) => e.customTitle)
  if (titles.length) return titles[titles.length - 1]
  const folder = (cwd || '').split('/').pop() || '?'
  return CONTEXT === 'cloud' ? `${PHRASE.cloud} ${folder}` : folder
}

// ---------- turning markdown into speakable lines

function withoutCodeBlocks(text) {
  return text.replace(/```[\s\S]*?```/g, `\n${PHRASE.code}\n`)
}

function stripMarkdown(line) {
  return line
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/<?https?:\/\/[^\s>)]*[^\s>).,;:!?]>?/g, PHRASE.link)
    .replace(/[`*_>#]/g, '')
    .replace(/^\s*(?:[-•]|\d+\.)\s+/, '')
    .trim()
}

function tableRowAsSentence(line) {
  const cells = line.trim().replace(/^\||\|$/g, '').split('|').map(stripMarkdown)
  if (cells.filter(Boolean).every((c) => /^:?-+:?$/.test(c))) return ''
  return cells.filter(Boolean).join(', ') + '.'
}

function speakableLines(text) {
  return withoutCodeBlocks(text)
    .split('\n')
    .map((line) => (line.trimStart().startsWith('|') ? tableRowAsSentence(line) : stripMarkdown(line)))
    .filter(Boolean)
    .map((line) => (/[.:?!]$/.test(line) ? line : line + '.'))
}

function linesThroughFirstParagraph(text) {
  let count = 0
  for (const paragraph of withoutCodeBlocks(text).trim().split(/\n\s*\n/)) {
    count += speakableLines(paragraph).length
    if (count && !/^\s*[|#]/.test(paragraph)) return count
  }
  return 0
}

// ---------- the reader process

function isAlive(pid) {
  return Boolean(pid) && shell(`kill -0 ${pid} && echo alive`) === 'alive'
}

// ---------- the hold: while it is on, the reader starts nothing new, so that no voice talks over a dictation
//
// One hold at a time, in four fields of the state (their names are older than the word "hold"; sessions on older
// versions share the file, so they stay):
//   dictating_session  its owner: null for a free dictation ("Listen"), a session's id for its question (asked, about
//                      to be, or sent back), `permission:<session>` for a permission request read aloud
//   dictating_since    when it started; older than max_dictation_seconds it was abandoned and holds nothing
//   held_by            'send_back': a question sent back and not asked yet, which a message sent to that session frees
//   finishing_current  the reading under way may still reach its pause (a question about to be read)
// Every change goes through hold, releaseHold and releaseHoldOf; heldByAnother tells whether to wait.

function isHeld(state) {
  return Boolean(state.dictating_since) && now() - state.dictating_since < CONFIG.max_dictation_seconds
}

function hold(state, owner, { sendBack = false, finishCurrent = false, since = now() } = {}) {
  Object.assign(state, { dictating_since: since, dictating_session: owner, held_by: sendBack ? 'send_back' : null, reading_requested: false, finishing_current: finishCurrent })
}

// The hold is over, whoever owned it: readings may go on.
function releaseHold(state) {
  Object.assign(state, { dictating_since: null, dictating_session: null, held_by: null, finishing_current: false })
}

// Only the owner's own hold is released (null: a free dictation's). False when another holds, or nothing does.
function releaseHoldOf(state, owner) {
  if (!isHeld(state) || state.dictating_session !== owner) return false
  releaseHold(state)
  return true
}

// Someone other than `owners` holds: a question, a permission request or a dictation must wait for it.
function heldByAnother(state, owners) {
  return isHeld(state) && ![].concat(owners).includes(state.dictating_session)
}

function startReaderUnlessRunning(state) {
  if (isAlive(state.reader_pid) || (isHeld(state) && !state.reading_requested)) return
  state.reader_pid = Number(shell(`osascript -l JavaScript ${quote(scriptPath())} --read >/dev/null 2>&1 & echo $!`)) || null
  state.announced_id = null
}

function killReader(state) {
  if (isAlive(state.reader_pid)) shell(`kill ${state.reader_pid}`)
  // Only our own voice: other `say` on the Mac are not ours to stop. A speak_command plays through a child of its own
  // (afplay…): both go.
  if (state.speaker_pid) shell(`pkill -P ${state.speaker_pid}; kill ${state.speaker_pid}`)
  state.reader_pid = null
  state.speaker_pid = null
  releaseLock(SPEECH_LOCK_PATH, true) // a line cut short frees the voice for whoever speaks next
}

// The session's name is said when the speaker changes; 'always' also says it at every reply and resumed reading.
function announcesItem(state, item) {
  const freshItem = state.announced_id !== item.id
  state.announced_id = item.id
  return speakerChanged(state, item.session) || (CONFIG.announce_session === 'always' && freshItem)
}

function speakerChanged(state, session) {
  const changed = session !== state.last_speaker
  state.last_speaker = session
  return changed
}

function introFor(data, entries) {
  const changed = withState((state) => speakerChanged(state, data.session_id))
  return changed || CONFIG.announce_session === 'always' ? announcement(sessionTitle(entries, data.cwd)) : ''
}

function announcement(title) {
  return `${SILENCE} ${PHRASE.session.replace('{title}', title)} ${SILENCE} `
}

// While an answer is dictated, only "Continue" or "Restart" read, and only the reply on hold: nothing new starts.
// A question about to be asked lets the reply under way reach its pause first.
function nextLineToSay(state) {
  const onlyCurrent = isHeld(state)
  if (onlyCurrent && !state.reading_requested && !state.finishing_current) return null
  for (;;) {
    const item = state.current
    if (item && item.position < Math.min(item.pause_at, item.lines.length)) {
      // Announced at the start of each reply and after every interruption, so chained replies stay attributable.
      const intro = announcesItem(state, item) ? announcement(item.title) : ''
      return { id: item.id, text: intro + item.lines[item.position] }
    }
    // Stopped after the first paragraph with more to come: say so once, or the rest goes unnoticed.
    if (item && item.position < item.lines.length && !item.more_announced) {
      item.more_announced = true
      return { id: item.id, text: PHRASE.more, cue: true }
    }
    if (!state.queue.length || onlyCurrent) return null
    state.current = state.queue.shift()
  }
}

function readQueue() {
  for (;;) {
    let resumeMedia = false
    const line = withState((state) => {
      const next = nextLineToSay(state)
      if (!next) {
        state.reader_pid = null
        state.reading_requested = false
        if (!isHeld(state)) resumeMedia = takeMediaPause(state)
      }
      return next
    })
    if (!line) {
      if (resumeMedia) sendMediaCommand('play')
      return
    }
    say(line.text)
    withState((state) => {
      if (!line.cue && state.current && state.current.id === line.id) state.current.position += 1
    })
    delay(CONFIG.pause_between_lines_seconds)
  }
}

function enqueue(data, entries, lines, pauseAt) {
  const title = sessionTitle(entries, data.cwd)
  withState((state) => {
    // The session that asked a question ends its turn: the question is over, even refused before it ran.
    if (data.session_id) releaseHoldOf(state, data.session_id)
    state.queue.push({ id: state.next_id, session: data.session_id, title, lines, position: 0, pause_at: pauseAt })
    state.next_id += 1
    startReaderUnlessRunning(state)
  })
}

// ---------- hooks


function currentTurn(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i].type === 'user' && !entries[i].isMeta && entries[i].turnOrigin && promptText(entries[i]).trim()) return entries.slice(i + 1)
  }
  return entries
}

// The question asked in the app's end-of-turn box, if any.
function appBoxQuestion(turn) {
  for (const e of turn) {
    if (e.type !== 'assistant') continue
    for (const b of (e.message || {}).content || []) {
      const ask = b && b.type === 'tool_use' && /wrap_up$/.test(b.name || '') ? ((b.input || {}).ask || '').trim() : ''
      if (ask) return ask
    }
  }
  return ''
}

// The question a reply puts in writing, and the rest of the reply around it; null for none. It need not be the last
// paragraph: a grill writes its options and a recommendation after it. It is in the last section: a title (a "#" line,
// "---", or a paragraph of one bold line with text after it) ends what came before, so a question in a title or above it is not one.
function writtenQuestion(reply) {
  const paragraphs = (reply || '').trim().split(/\n\s*\n/)
  const last = paragraphs.length - 1
  let fenced = false
  let found = -1
  paragraphs.forEach((paragraph, i) => {
    const lines = paragraph.trim().split('\n').filter((line) => {
      const fence = /^\s*```/.test(line)
      if (fence) fenced = !fenced
      return !fence && !fenced
    })
    const title = (line) => /^\s*(#{1,6}\s|-{3,}\s*$)/.test(line) || (lines.length === 1 && i < last && /^\s*\*\*[^*]+\*\*\s*$/.test(line))
    if (lines.some(title)) found = -1
    if (lines.some((line) => !title(line) && /\?\s*[»"*_)]*\s*$/.test(line))) found = i
  })
  if (found < 0) return null
  return { question: paragraphs[found].trim(), text: paragraphs.filter((_, i) => i !== found).join('\n\n') }
}

// A question only on screen is lost to someone who is not looking: the turn goes on until it is asked aloud.
// Every new question is sent back, also later in a turn already sent back once (`stop_hook_active`): a turn that goes
// on through several questions, one answer after another, asks each of them aloud. What stops a loop: the same
// question is never sent back twice in a row, nor more than MAX_SEND_BACKS without one asked in between.
function unspokenQuestionBlock(data, entries, reply) {
  if (!questionsCanBeSpoken() || userIsAway()) return null
  const written = writtenQuestion(reply)
  const question = written ? written.question : appBoxQuestion(currentTurn(entries))
  if (!question) return null
  // The reply stays on screen; it is read before the question asked next, without the question's paragraph when it is written.
  const text = written ? written.text : (reply || '').trim().split(/\n\s*\n/).join('\n\n')
  // A long reply: its summary comes with the question, so the first reading already covers it all.
  const long = CONFIG.summarize_rest && speakableLines(text).length - linesThroughFirstParagraph(text) >= SUMMARY_MIN_LINES
  const sendBack = withState((state) => {
    // Kept per session: several sessions may each be sent back meanwhile, and none must undo another's guard or text.
    const sentBacks = sessionNotes(state, 'sent_backs')
    const previous = sentBacks[data.session_id] || null
    if (data.stop_hook_active && previous && (previous.question === question || previous.count >= MAX_SEND_BACKS)) return false
    const at = now()
    sentBacks[data.session_id] = { question, count: data.stop_hook_active && previous ? previous.count + 1 : 1, at }
    const replies = sessionNotes(state, 'replies_before_question')
    if (text) replies[data.session_id] = { text, long, at: now() }
    else delete replies[data.session_id]
    // The question comes next: other sessions finish what they are reading, then wait for it. Another session's
    // question already under way keeps its hold: this one will wait for it to be answered. The hold is marked as a
    // send-back: the question may never be asked (Escape, a message typed instead), and a message sent frees it.
    if (!heldByAnother(state, data.session_id)) hold(state, data.session_id, { sendBack: true, finishCurrent: true, since: at })
    return true
  })
  if (!sendBack) return null
  const reason = FOR_CLAUDE.unspoken_question.replace('{tool}', questionTool())
  return JSON.stringify({ decision: 'block', reason: long ? `${reason} ${SUMMARY_FIRST}` : reason })
}

function queueNewReply() {
  const data = readStdin()
  const entries = readTranscript(data.transcript_path)
  if (startedByAnotherSession(entries)) return
  const reply = data.last_assistant_message || lastReply(entries)
  const block = unspokenQuestionBlock(data, entries, reply)
  if (block) return block
  const alreadyRead = withState((state) => {
    const before = takeSessionNote(state, 'read_before_questions', data.session_id)
    // Sent back but never asked: that reply is not waiting for a question any more.
    takeSessionNote(state, 'replies_before_question', data.session_id)
    return Boolean(before && before.text === reply.trim())
  })
  if (alreadyRead) return
  const lines = speakableLines(reply)
  if (!lines.length) lines.push(PHRASE.idle)
  const pauseAt = (CONFIG.first_paragraph_only ? linesThroughFirstParagraph(reply) : 0) || lines.length
  enqueue(data, entries, lines, pauseAt)
}

function queueWaitingNotice() {
  const data = readStdin()
  // Fired a few seconds into a question or permission prompt that is already being answered by voice.
  if (isHeld(readState())) return
  enqueue(data, readTranscript(data.transcript_path), [PHRASE.waiting], 1)
}

// The app's own ways of asking wait for a click or a pick on screen: in voice mode they are turned back to the dictation
// tool. A refusal does not stop Claude: it reads the reason as the tool's result and asks again, the spoken way.


function guardScreenOnlyQuestion() {
  const data = readStdin()
  if (!questionsCanBeSpoken() || userIsAway()) return ''
  const input = data.tool_input || {}
  const offer = /start_session$/.test(data.tool_name || '')
  if (offer && input.initiation !== 'offer') return '' // a proposal card waits for nobody
  const endOfTurn = /wrap_up$/.test(data.tool_name || '')
  if (endOfTurn && !String(input.ask || '').trim()) return '' // a recap alone asks nothing
  const reason = (offer ? FOR_CLAUDE.screen_only_session_offer : endOfTurn ? FOR_CLAUDE.screen_only_end_of_turn_question : FOR_CLAUDE.screen_only_question)
    .replace('{tool}', questionTool())
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } })
}


function idleSeconds() {
  const output = ENV.HANDFREE_IDLE_SECONDS || shell("ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'")
  return Number(output) || 0
}

function userIsAway() {
  return idleSeconds() >= CONFIG.away_after_idle_seconds
}

const MAX_SPOKEN_ACTION_CHARS = 160

function describeAction(toolName, toolInput) {
  const input = toolInput || {}
  if (toolName === 'Bash' && input.command) return input.command.slice(0, MAX_SPOKEN_ACTION_CHARS)
  const file = input.file_path || input.notebook_path || input.path
  if (file) return `${toolName} ${file.split('/').pop()}`
  return toolName.replace(/^mcp__/, '').replace(/__/g, ' ')
}

function answerOf(rpcResponse) {
  // macOS may hand accents decomposed.
  const text = (((rpcResponse || {}).result || {}).content || []).map((c) => c.text || '').join('\n').normalize('NFC')
  const answer = (text.match(/A:\s*([\s\S]*)$/) || [null, text])[1].toLowerCase()
  // The validation phrase may be several words ("c'est bon"): taken out whole, never inside another word.
  const phrase = CONFIG.validation_word.toLowerCase().normalize('NFC').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const without = answer.replace(new RegExp(`(^|[^a-zà-ÿ'-])${phrase}(?=$|[^a-zà-ÿ'-])`, 'g'), '$1 ')
  return without.split(/[^a-zà-ÿ'-]+/).filter(Boolean)
}

function decide(words) {
  const said = (list) => list.some((w) => (w.includes(' ') ? words.join(' ').includes(w) : words.includes(w)))
  if (said(YES_WORDS) && !said(NO_WORDS)) return 'allow'
  if (said(NO_WORDS) && !said(YES_WORDS)) return 'deny'
  return null
}

// The Handfree Code app answers on this Mac: dictation, questions, and the text dictated into the field in front.
function dictationUrl() {
  return ENV.HANDFREE_DICTATION_URL || CONFIG.dictation_url || 'http://localhost:51290'
}

function askDictation(question, seconds) {
  const url = dictationUrl()
  const call = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'ask_user_dictation', arguments: { questions: [question] } } }
  const output = shell(`curl -s -m ${Math.round(seconds || CONFIG.permission_answer_seconds)} -X POST ${quote(url)} -H 'Content-Type: application/json' -d ${quote(JSON.stringify(call))}`)
  try {
    return JSON.parse(output)
  } catch (e) {
    return null
  }
}

// PermissionRequest: read the request, take the answer by voice. No clear answer: the dialog shows as usual.
function answerPermission() {
  const data = readStdin()
  if (!CONFIG.voice_permissions || CONTEXT !== 'local' || userIsAway() || !dictationResponds()) return ''
  const entries = readTranscript(data.transcript_path)
  const question = PHRASE.permission.replace('{action}', describeAction(data.tool_name || '', data.tool_input))
  // Like a question: another dictation is waited for (one at a time in the app), and the hold is this request's own,
  // so that only its answer frees it. Still busy at the deadline: the usual dialog.
  const owner = `permission:${data.session_id}`
  const deadline = now() + PERMISSION_WAIT_SECONDS
  if (!waitForOtherDictation([owner, data.session_id], deadline)) return ''
  holdReaderAfterCurrentReading(owner, deadline)
  say(`${introFor(data, entries)}${question}`)
  startDictating(owner)
  const decision = decide(answerOf(askDictation(question)))
  withState((state) => {
    if (releaseHoldOf(state, owner)) startReaderUnlessRunning(state)
  })
  if (!decision) return ''
  const verdict = decision === 'allow' ? { behavior: 'allow' } : { behavior: 'deny', message: 'Refused by voice.' }
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: verdict } })
}

function readQuestion() {
  if (userIsAway()) {
    const reason = FOR_CLAUDE.away.replace('{minutes}', Math.round(idleSeconds() / 60))
    return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } })
  }
  const data = readStdin()
  const entries = readTranscript(data.transcript_path)
  const { context, questions } = splitQuestions((data.tool_input || {}).questions || [])
  const readUntil = now() + QUESTION_READING_SECONDS
  const deadline = now() + QUESTION_WAIT_SECONDS
  // Still another dictation at the deadline: the question goes in writing rather than over it, or into its answer.
  if (!waitForOtherDictation(data.session_id, deadline)) {
    const reason = FOR_CLAUDE.busy
    return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } })
  }
  // The queue stays paused: restarting it would talk over the answer being dictated.
  holdReaderAfterCurrentReading(data.session_id, deadline)
  const { sentBack, older } = withState((state) => {
    const sentBacks = sessionNotes(state, 'sent_backs')
    if (sentBacks[data.session_id]) sentBacks[data.session_id].count = 0
    // This session's own older reply, still waiting its turn behind another session's, comes before its question.
    const older = state.queue.filter((item) => item.session === data.session_id)
    state.queue = state.queue.filter((item) => item.session !== data.session_id)
    return { sentBack: takeSessionNote(state, 'replies_before_question', data.session_id) || { text: '' }, older }
  })
  let intro = introFor(data, entries)
  const olderLines = older.flatMap(linesBeforePause)
  if (olderLines.length) {
    const left = afterSaying(older, sayLines(olderLines, intro, readUntil))
    intro = ''
    if (left.length) withState((state) => state.queue.unshift(...left))
  }
  const written = textOfLastMessage(entries)
  const plan = planQuestionReading({ sentBack, written, context })
  const said = plan ? sayLines(plan.say, intro, readUntil) : 0
  if (plan) keepReadBeforeQuestion(data, entries, plan, said, written)
  // After a summary, the full text it sums up is kept: say how to hear it.
  const detailWaits = withState((state) => Boolean(state.detail && state.detail.session === data.session_id))
  if (detailWaits) say(`${plan ? '' : intro}${PHRASE.detail}`)
  say(`${plan || detailWaits ? '' : intro}${PHRASE.question} ${SILENCE} ${questions.join(' ')}`)
  delay(QUESTION_TAIL_SECONDS)
  startDictating(data.session_id)
}

// A queued reply's lines up to its pause, from where it is.
function linesBeforePause(item) {
  return item.lines.slice(item.position, Math.min(item.pause_at, item.lines.length))
}

// The replies once `said` of their lines before the pause were said, in order: those with lines left (cut short, or
// after their pause), which wait their turn again, as they would have.
function afterSaying(items, said) {
  let left = said
  return items
    .map((item) => {
      const step = Math.min(left, linesBeforePause(item).length)
      left -= step
      return Object.assign({}, item, { position: item.position + step })
    })
    .filter((item) => item.position < item.lines.length)
}

// Another session's question, or a free dictation, is under way: the app takes one at a time, and a question read now
// would be taken down with that answer. Wait for it to be answered (within the hook's time).
// False when it is still under way at the deadline. `own`: the holds that are not another's (a session's own send-back).
function waitForOtherDictation(owned, deadline) {
  for (;;) {
    if (!heldByAnother(readState(), owned)) return true
    if (now() >= deadline) return false
    delay(0.5)
  }
}


// Lines said one after another, the first with `intro`. "Quiet" said meanwhile (a voice command or its shortcut) stops
// them all, not only the line it cuts; so does the time `until`, when given. Returns how many were said.
function sayLines(lines, intro, until) {
  const start = now()
  for (let i = 0; i < lines.length; i++) {
    if (readState().quiet_since >= start || (until && now() >= until)) return i
    say(`${i === 0 ? intro || '' : ''}${lines[i]}`)
    delay(CONFIG.pause_between_lines_seconds)
  }
  return lines.length
}

// A question written in several paragraphs carries its context: the last paragraph is the question itself.
// Text written before the tool call can end up out of the transcript (kept as a thinking summary); the tool's input never does.
function splitQuestions(items) {
  const context = []
  const questions = items.map((item) => {
    const paragraphs = String(item).trim().split(/\n\s*\n/)
    context.push(...paragraphs.slice(0, -1))
    return paragraphs[paragraphs.length - 1]
  })
  return { context: context.join('\n\n'), questions }
}

// The paragraphs of `text` that `other` does not have.
function paragraphsNotIn(text, other) {
  const known = new Set((other || '').split(/\n\s*\n/).map((p) => p.replace(/\s+/g, ' ').trim()))
  return (text || '').trim().split(/\n\s*\n/).filter((p) => p.trim() && !known.has(p.replace(/\s+/g, ' ').trim())).join('\n\n')
}

// The same text, written in the message and copied into the question, is read once.
function uniqueParagraphs(...texts) {
  const seen = new Set()
  return texts
    .flatMap((text) => (text || '').trim().split(/\n\s*\n/))
    .filter((paragraph) => {
      const key = paragraph.replace(/\s+/g, ' ').trim()
      if (!key || seen.has(key)) return false
      seen.add(key)
      return true
    })
    .join('\n\n')
}

// What Claude wrote just before asking, or put in the question as its context, is part of its answer: its turn has not
// ended, so no reply reading will come. Its first paragraph is read before the question; the rest is what "the rest" reads.
//
// Decided from the text alone, no voice and no state (tests/unit.js checks it): what is said, what is kept as the reply
// under way for "the rest" (`keep`, paused at `pauseAt`), and after a summary the full text kept for "the details".
// null: nothing to read before the question. The text is the reply sent back (`sentBack`), what Claude wrote just
// before asking (`written`), and the question's own context paragraphs, read in full: Claude chose to say them.
function planQuestionReading({ sentBack, written, context }) {
  const replyText = uniqueParagraphs(sentBack.text, written)
  const ownContext = paragraphsNotIn(context, replyText)
  // A long reply: its first paragraph, then the summary put in the question; the rest waits for "the details".
  if (sentBack.long) {
    const replyLines = speakableLines(sentBack.text)
    const cut = linesThroughFirstParagraph(sentBack.text) || replyLines.length
    const lines = replyLines.slice(0, cut).concat(speakableLines(ownContext))
    return { say: lines, keep: lines, pauseAt: lines.length, detail: replyLines.slice(cut) }
  }
  const lines = speakableLines(replyText)
  const contextLines = speakableLines(ownContext)
  if (!lines.length && !contextLines.length) return null
  const pauseAt = lines.length ? (CONFIG.first_paragraph_only ? linesThroughFirstParagraph(replyText) : 0) || lines.length : 0
  return { say: lines.slice(0, pauseAt).concat(pauseAt < lines.length ? [PHRASE.more] : [], contextLines), keep: lines, pauseAt, detail: null }
}

// The reply read before the question becomes the one under way, for "the rest": cut short (by "Quiet" or the time) at
// the first line not said, and paused there. A summary keeps its full text for "the details"; otherwise what Claude
// wrote is noted as read, so that its turn's end does not read it again.
function keepReadBeforeQuestion(data, entries, plan, said, written) {
  const position = Math.min(said, plan.pauseAt)
  withState((state) => {
    state.current = { id: state.next_id, session: data.session_id, title: sessionTitle(entries, data.cwd), lines: plan.keep, position, pause_at: position, more_announced: true }
    state.announced_id = state.next_id
    state.next_id += 1
    if (plan.detail) return (state.detail = { session: data.session_id, lines: plan.detail })
    const read = sessionNotes(state, 'read_before_questions')
    if (written) read[data.session_id] = { text: written.trim(), at: now() }
    else delete read[data.session_id]
  })
}

// The text Claude wrote just before the question (written to the transcript before the call). Only what follows the
// last user entry counts: the tool call itself may not be in the transcript yet when the question's hook runs, and a
// user message, or an earlier question's answer (a tool result), met first means nothing was written since. The text
// before it was read already, with that message's reply or that earlier question.
function textOfLastMessage(entries) {
  let start = entries.length
  while (start > 0 && entries[start - 1].type !== 'user') start--
  return entries
    .slice(start)
    .filter((e) => e.type === 'assistant')
    .flatMap((e) => ((e.message || {}).content || []).filter((b) => b && b.type === 'text' && (b.text || '').trim()).map((b) => b.text))
    .join('\n')
}

// SessionStart, voice mode on. The session is noted as knowing the rules: switched off or on later, it is told at its next message.
function printSessionRules() {
  const data = readStdin()
  const rules = voiceRules()
  if (rules && data.session_id) withState((state) => (sessionNotes(state, 'voice_rules')[data.session_id] = { at: now() }))
  return rules
}

function voiceRules() {
  if (!questionsCanBeSpoken()) return ''
  return FOR_CLAUDE.rules.replace(/\{word\}/g, CONFIG.validation_word).replace('{tool}', questionTool())
}

// The bridge service marks the hooks it runs for a cloud session.
const CONTEXT = ENV.HANDFREE_CONTEXT === 'cloud' ? 'cloud' : 'local'

// Rules naming a tool the session cannot reach would send it looking for nothing.
function questionsCanBeSpoken() {
  const transport = Object.assign({}, DEFAULTS.question_transport, CONFIG.question_transport)[CONTEXT]
  if (transport === 'none') return false
  if (CONTEXT === 'cloud') return transport !== 'bridge' || dictationResponds() // a cloud session's own config is out of sight here
  return questionToolIsDeclared() && (transport !== 'bridge' || dictationResponds())
}

function dictationResponds() {
  if (ENV.HANDFREE_DICTATION_UP) return ENV.HANDFREE_DICTATION_UP === '1'
  const url = dictationUrl()
  return shell(`curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST ${quote(url)} -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":0,"method":"tools/list"}'`) === '200'
}

const QUESTION_TOOL = 'mcp__handfree__ask_user_dictation'

// The tool the rules name: the setting, else the app's own.
function questionTool() {
  return CONFIG.question_tool || QUESTION_TOOL
}

function questionToolIsDeclared() {
  const server = questionTool().split('__')[1]
  const settings = readJson(ENV.HANDFREE_CLAUDE_JSON || `${HOME}/.claude.json`) || {}
  const declared = [settings.mcpServers || {}, ...Object.values(settings.projects || {}).map((p) => p.mcpServers || {})]
  return declared.some((servers) => server in servers)
}

// Every script the services and the app run from the stable copy. The one list: SessionStart and the installers
// (--refresh-stable-copy) all copy through refreshStableCopy.
const STABLE_FILES = ['handfree.js', 'bridge-server.py', 'install-bridge.sh', 'speak-openai.sh', 'voice-commands.json', 'listener.py', 'install-listener.sh', 'mcp-relay.sh', 'set-question-transport.sh']

// The listener and the bridge service need a path that survives plugin updates; the plugin's folder changes with every version.
// A session still on an older version must not put its scripts back: the copy records the version it came from.
// `force`: an install, which the user asked for, copies whatever the version.
function refreshStableCopy(force = false) {
  const sourceDir = scriptPath().replace(/\/[^/]*$/, '')
  const stableDir = STABLE_COPY.replace(/\/[^/]*$/, '')
  if (sourceDir === stableDir) return // run from the copy itself (the bridge, the app)
  const version = (readJson(`${sourceDir}/../.claude-plugin/plugin.json`) || {}).version || null
  const copied = (readFile(`${stableDir}/version`) || '').trim() || null
  if (!force && copied && (!version || compareVersions(version, copied) < 0)) return
  if (version && version !== copied) writeFile(`${stableDir}/version`, version + '\n')
  for (const name of STABLE_FILES) {
    const source = readFile(`${sourceDir}/${name}`)
    if (!source || source === readFile(`${stableDir}/${name}`)) continue
    writeFile(`${stableDir}/${name}`, source)
    // A listener installed (install-listener.sh) restarts on its new version.
    if (name === 'listener.py' || name === 'voice-commands.json') restartService(LISTENER_LABEL)
    // So does the bridge (install-bridge.sh): Python does not reload its code, and the old one would go on serving.
    if (name === 'bridge-server.py') restartService(BRIDGE_LABEL)
  }
}

// "0.3.10" after "0.3.9": compared number by number.
function compareVersions(a, b) {
  const [x, y] = [a, b].map((v) => String(v).split('.').map((n) => parseInt(n, 10) || 0))
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0)
  return 0
}

// A service of the plugin's, when installed, starts over.
function restartService(label) {
  if (!readFile(`${LAUNCH_AGENTS_DIR}/${label}.plist`)) return
  if (ENV.HANDFREE_RESTART_LOG) return writeFile(ENV.HANDFREE_RESTART_LOG, (readFile(ENV.HANDFREE_RESTART_LOG) || '') + label + '\n')
  shell(`launchctl kickstart -k gui/$(id -u)/${label} >/dev/null 2>&1`)
}

function scriptPath() {
  return ObjC.unwrap($.NSProcessInfo.processInfo.arguments).map(ObjC.unwrap).find((a) => /\.js$/.test(a))
}

// ---------- voice commands

// A question records the session that asked; "Listen" records none.
// Music or a video is paused for the dictation too, and resumed once it is over (by the reader, when nothing is left):
// so is it whichever way the dictation treats media.
function startDictating(session) {
  pauseMediaIfPlaying()
  withState((state) => {
    killReader(state)
    hold(state, session || null)
  })
}

// A message sent to a session, however it was sent, ends a free dictation ("Listen") that no "Stop" ended: sent with
// Return, it would otherwise hold the readings until max_dictation_seconds. A question's dictation waits for its answer.
// A question sent back to that session and never asked (Escape, a message typed instead) holds nothing any more.
function promptSent() {
  const data = readStdin()
  // Voice mode switched since the session last heard of it: the rules, or that they no longer apply, come with this message.
  const rules = isVoiceModeOn() ? voiceRules() : ''
  const told = withState((state) => {
    const notes = sessionNotes(state, 'voice_rules')
    const knew = Boolean(notes[data.session_id])
    if (rules && data.session_id) notes[data.session_id] = { at: now() }
    else delete notes[data.session_id]
    if (!state.voice_off) endSendBackHold(state, data.session_id)
    return rules && !knew ? rules : !rules && knew ? FOR_CLAUDE.voice_off : ''
  })
  return told ? JSON.stringify({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: told } }) : ''
}

// A message sent ends a free dictation, or a send-back's hold whose question was never asked.
function endSendBackHold(state, session) {
  if (!isHeld(state)) return
  // The hold must still be the send-back's own: a question asked since by a session on an older version (which
  // leaves held_by as it was) holds from a later time.
  const sentBack = sessionNotes(state, 'sent_backs')[session]
  const sentBackHere = state.held_by === 'send_back' && state.dictating_session === session && Boolean(sentBack) && sentBack.at === state.dictating_since
  if (state.dictating_session && !sentBackHere) return
  releaseHold(state)
  startReaderUnlessRunning(state)
}

// "Claude Cancel": the listener pressed Escape, which cancels the dictation. A free dictation ends here, and the app it
// was said in comes back; a question's ends with its answer (reported skipped).
function cancelDictation() {
  const back = withState((state) => {
    if (!releaseHoldOf(state, null)) return null
    startReaderUnlessRunning(state)
    const previous = state.return_app
    if (previous && previous.armed) state.return_app = null
    return previous && previous.armed ? previous.bundle : null
  })
  if (back && (frontApp() || {}).name === CONFIG.target_app) bringBack(back)
}

// "Stop" ends a free dictation. A question's dictation (it has a session) is freed by its answer instead: that comes
// later, after "the rest" may have the question asked again, and a reading started meanwhile would be taken down.
function doneDictating() {
  const back = withState((state) => {
    if (!state.dictating_session) {
      releaseHold(state)
      startReaderUnlessRunning(state)
    }
    // A dictation abandoned without "Stop" leaves a note: too old, it no longer decides.
    const previous = state.return_app
    const due = previous && previous.armed && now() - previous.since < CONFIG.max_dictation_seconds
    if (previous && previous.armed) state.return_app = null
    return due ? previous.bundle : null
  })
  if (!back) return
  // The app pastes the text and sends it only while Claude is still in front: going back waits for the message to leave.
  if (ENV.HANDFREE_OPEN_LOG) return goBackOnceSent([back, String(now())]) // tests: no process in the background
  shell(`osascript -l JavaScript ${quote(scriptPath())} --go-back ${quote(back)} ${now()} >/dev/null 2>&1 &`)
}

// Claude Code records a message the moment it is sent, whether the session is at rest or working (a queue entry).
// None within the wait (a cloud session, a dictation that never came): Claude stays on screen.
function goBackOnceSent([bundle, since]) {
  const deadline = Number(since) + (Number(ENV.HANDFREE_RETURN_WAIT_SECONDS) || RETURN_WAIT_SECONDS)
  for (;;) {
    if (messageSentSince(Number(since))) return bringBack(bundle)
    if (now() > deadline) return
    delay(0.5)
  }
}

function messageSentSince(since) {
  const dir = ENV.HANDFREE_PROJECTS_DIR || `${ENV.CLAUDE_CONFIG_DIR || `${HOME}/.claude`}/projects`
  // do shell script hands lines back separated by \r.
  const files = shell(`find ${quote(dir)} -name '*.jsonl' -mtime -${RETURN_WAIT_SECONDS + 30}s 2>/dev/null`).split(/\r\n?|\n/).filter(Boolean)
  return files.some((file) =>
    shell(`tail -c 50000 ${quote(file)}`)
      .split(/\r\n?|\n/)
      .some((line) => {
        if (!line.includes('"queue-operation"') || !line.includes('"enqueue"')) return false
        try {
          const entry = JSON.parse(line)
          return Date.parse(entry.timestamp) / 1000 >= since && !String(entry.content || '').startsWith('<')
        } catch (e) {
          return false
        }
      }),
  )
}

// The app Claude was brought over: noted when "Listen", "Reply" or "Session" is said, gone back to after "Stop".
// Already in target_app, nothing is noted: "Stop" must leave Claude on screen. A note kept from "Session" is reused.
function rememberFrontApp(armed) {
  if (!CONFIG.return_to_previous_app) return
  const front = frontApp()
  withState((state) => {
    const kept = state.return_app && !state.return_app.armed && now() - state.return_app.since < RETURN_APP_KEPT_SECONDS ? state.return_app : null
    const noted = kept ? kept.bundle : front && front.name !== CONFIG.target_app ? front.bundle : null
    state.return_app = noted ? { bundle: noted, armed, since: now() } : null
  })
}

function frontApp() {
  if (ENV.HANDFREE_FRONT_APP !== undefined) return ENV.HANDFREE_FRONT_APP ? { name: ENV.HANDFREE_FRONT_APP, bundle: `id.${ENV.HANDFREE_FRONT_APP}` } : null
  try {
    const process = Application('System Events').processes.whose({ frontmost: true })[0]
    return { name: process.name(), bundle: process.bundleIdentifier() }
  } catch (e) {
    return null
  }
}

function bringBack(bundle) {
  if (ENV.HANDFREE_OPEN_LOG) return writeFile(ENV.HANDFREE_OPEN_LOG, (readFile(ENV.HANDFREE_OPEN_LOG) || '') + `back to ${bundle}\n`)
  shell(`open -b ${quote(bundle)}`)
}

const SUMMARY_MIN_LINES = 3 // a shorter rest is read as it is
const ASK_AGAIN = 'The user answered that they first want to hear the rest of what you wrote before this question; it has just been read aloud to them. Ask the same question again with the same tool, without repeating that text.'
const SUMMARY_FIRST =
  'Your reply is long. Unless its first paragraph (which is read) already sums all of it up, put first in the question one paragraph of two or three ' +
  'sentences summing up the rest of your reply, then the question as the last paragraph. The full reply stays on screen, and the user can ask to hear it.'
const ASK_SUMMARY =
  'The user answered that they first want the rest of what you wrote before this question, summed up. Ask the same question again with the same tool: ' +
  'a first paragraph of two or three sentences summing up that rest (everything after its first paragraph, which was read), then the question as the last paragraph. ' +
  'Do not repeat the full text: it is kept, and the user can ask to hear it.'

function answered() {
  const data = readStdin()
  const answer = answerOf({ result: { content: textBlocks(data.tool_response) } }).join(' ')
  const wantsMore = MORE_ANSWERS.includes(answer)
  const wantsDetail = DETAIL_ANSWERS.includes(answer)
  const { lines, reason } = withState((state) => {
    // The text read before the question, cut by "Quiet" or not.
    const item = [state.current, state.cut].find((i) => i && i.session === data.session_id) || null
    const rest = item ? item.lines.slice(item.position) : []
    const detail = state.detail && state.detail.session === data.session_id ? state.detail.lines : []
    const consumeRest = () => Object.assign(item, { position: item.lines.length, pause_at: item.lines.length })
    // Asking for more: the question is asked again right after, so the other sessions keep waiting. Only this session's
    // own question is released: a refused or failed call ("already recording") must not free a dictation under
    // way elsewhere, such as "Listen" said while this session worked.
    const held = wantsMore || wantsDetail
    const own = !isHeld(state) || state.dictating_session === data.session_id
    if (own && held) hold(state, data.session_id)
    else if (own) releaseHold(state)
    state.detail = null
    if (wantsMore && rest.length >= SUMMARY_MIN_LINES && CONFIG.summarize_rest) {
      consumeRest()
      state.detail = { session: data.session_id, lines: rest }
      return { lines: [], reason: ASK_SUMMARY }
    }
    // "The rest" reads what is left, "the details" what a summary summed up; each falls back on the other.
    const [first, second] = wantsDetail ? [detail, rest] : [rest, detail]
    const found = wantsMore || wantsDetail ? (first.length ? first : second) : []
    if (found.length && found === rest) consumeRest()
    if (!found.length && own) {
      releaseHold(state)
      startReaderUnlessRunning(state)
    }
    return { lines: found, reason: ASK_AGAIN }
  })
  if (reason === ASK_SUMMARY) return JSON.stringify({ decision: 'block', reason })
  if (!lines.length) return ''
  // Read here, before Claude asks again: its new question would cut a reading still going on.
  sayLines(lines)
  return JSON.stringify({ decision: 'block', reason })
}

// A tool's response comes as text, a list of content blocks, or an object holding them.
function textBlocks(value) {
  if (typeof value === 'string') return [{ text: value }]
  if (Array.isArray(value)) return value.flatMap(textBlocks)
  if (value && typeof value === 'object') return typeof value.text === 'string' ? [{ text: value.text }] : textBlocks(value.content || [])
  return []
}

// "Quiet" cuts the reply being read: a new one is read next, from its start, and the cut one comes back only on
// "Continue", from the line it was cut at. Lines said in a row by a question's hook stop too.
function quiet() {
  withState((state) => {
    killReader(state)
    state.quiet_since = now()
    const item = state.current
    if (item && item.position < item.lines.length) {
      // A reply cut earlier stays the one "Continue" takes back first; this one waits right behind it.
      if (state.cut) state.queue.unshift(item)
      else state.cut = item
      state.current = null
    }
  })
}

// A question lets the reading under way end first (up to where it pauses), then nothing else starts: two voices at once
// are not understood, and the dictation would take down the other one.
function holdReaderAfterCurrentReading(session, deadline) {
  const readerPid = withState((state) => {
    // The reader takes no new reply; an earlier "Continue" (reading_requested, cleared) would let it read on, or start
    // again, over the question.
    hold(state, session || null, { finishCurrent: true })
    return state.reader_pid
  })
  while (isAlive(readerPid) && now() < deadline) delay(0.2)
  withState((state) => {
    state.finishing_current = false
    killReader(state)
  })
}

// A reply cut by "Quiet" comes back first, from its cut line; the one read meanwhile waits its turn again.
function continueReading() {
  withState((state) => {
    takeBackCut(state)
    if (state.current) state.current.pause_at = state.current.lines.length
    state.reading_requested = true
    startReaderUnlessRunning(state)
  })
}

function restart() {
  withState((state) => {
    killReader(state)
    takeBackCut(state)
    if (state.current) Object.assign(state.current, { position: 0, pause_at: state.current.lines.length })
    state.reading_requested = true
    startReaderUnlessRunning(state)
  })
}

function takeBackCut(state) {
  if (!state.cut) return
  const reading = state.current
  if (reading && reading.position < reading.lines.length) {
    killReader(state) // its line would end on the other reply's position
    state.queue.unshift(reading)
  }
  state.current = state.cut
  state.cut = null
}

function switchVoiceMode(on) {
  const resumeMedia = withState((state) => {
    state.voice_off = !on
    if (on) return false
    killReader(state)
    releaseHold(state)
    Object.assign(state, { current: null, cut: null, queue: [] })
    return takeMediaPause(state)
  })
  if (resumeMedia) sendMediaCommand('play')
  say(on ? PHRASE.voice_on : PHRASE.voice_off)
  switchListener(on)
}

// Voice mode off stops listening altogether (the microphone is let go); on starts it again. Only once it is installed.
function switchListener(on) {
  const plist = `${LAUNCH_AGENTS_DIR}/${LISTENER_LABEL}.plist`
  // A state folder of its own (the tests) never touches the real service.
  if (ENV.HANDFREE_STATE_DIR || !readFile(plist)) return
  const domain = `gui/$(id -u)`
  shell(on ? `launchctl bootstrap ${domain} ${quote(plist)} >/dev/null 2>&1; true` : `launchctl bootout ${domain}/${LISTENER_LABEL} >/dev/null 2>&1; true`)
}

function isVoiceModeOn() {
  return withState((state) => !state.voice_off)
}

// ---------- "Listen": focus the message field and start the dictation

function click([x, y]) {
  const point = $.CGPointMake(x, y)
  $.CGEventPost(0, $.CGEventCreateMouseEvent(null, 1, point, 0))
  delay(0.05)
  $.CGEventPost(0, $.CGEventCreateMouseEvent(null, 2, point, 0))
}

function promptAt(win, path) {
  try {
    let element = win
    for (const i of path) element = element.uiElements[i]
    return element.description() === CONFIG.prompt_name ? element : null
  } catch (e) {
    return null
  }
}

function promptCenter(win, path) {
  try {
    const element = promptAt(win, path)
    if (!element) return null
    const [x, y] = element.position()
    const [w, h] = element.size()
    return [x + w / 2, y + h / 2]
  } catch (e) {
    return null
  }
}

function clickPrompt() {
  const win = Application('System Events').processes.byName(CONFIG.target_app).windows[0]
  const path = withState((state) => state.prompt_path) || []
  const center = promptCenter(win, path)
  if (center) return click(center)
  const [x, y] = win.position()
  const [w, h] = win.size()
  click([x + w * CONFIG.prompt_fallback.x_ratio, y + h - CONFIG.prompt_fallback.from_bottom])
  startLearningPromptPath()
}

function listen() {
  rememberFrontApp(true)
  if (canDictateBehind()) return startDictatingBehind(null)
  dictateInTargetApp()
}

// Claude in front: the dictation goes through the app's window too, which tells an Escape apart (the plugin then frees
// the readings, the music, the app to go back to). The app pasting into the field is kept for when the field cannot be
// reached, and with dictate_behind off.
function dictateInTargetApp() {
  startDictating()
  if (!ENV.HANDFREE_OPEN_LOG) {
    Application(CONFIG.target_app).activate()
    delay(CONFIG.activate_delay_seconds)
  }
  if (CONFIG.dictate_behind && CONFIG.target_app === 'Claude' && promptReachable()) return spawnDictation('-')
  if (ENV.HANDFREE_OPEN_LOG) return dictateIntoFront() // tests: no window, click or key; the app is the test's own
  const shouldClick = CONFIG.click_prompt === null ? CONFIG.target_app === 'Claude' : CONFIG.click_prompt
  if (shouldClick) {
    // System Events refused (a command run by the app's shortcut, before the app may control it): dictate all the same.
    try {
      clickPrompt()
      delay(CONFIG.after_click_delay_seconds)
    } catch (e) {
      logDictation(`could not click Claude's field: ${e}`)
    }
  }
  dictateIntoFront()
}

// The app records in its window, then pastes the text into the field in front and sends it (Return).
// The app asks for its local secret here (it types into the app in front): read by the shell from its file, never on a
// command line, where any process could see it.
function dictateIntoFront() {
  const call = { jsonrpc: '2.0', id: 1, method: 'dictation/insert', params: { send: true } }
  const secretFile = ENV.HANDFREE_APP_SECRET_FILE || `${HOME}/Library/Application Support/handfree-code/app-secret`
  const header = `{ printf 'X-Handfree-Secret: '; tr -d '\\n' < ${quote(secretFile)} 2>/dev/null; echo; }`
  shell(`${header} | curl -s -m 3 -o /dev/null -X POST ${quote(dictationUrl())} -H @- -H 'Content-Type: application/json' -d ${quote(JSON.stringify(call))}`)
}

// The app's links name a session by its own id (local_…); hooks know the Claude Code one, which the app's file records.
// The app records when each session was last shown (`lastFocusedAt`): the latest is the one in its window.
function appSessionOnScreen() {
  let latest = { at: 0, id: null }
  for (const file of shell(`find ${quote(APP_SESSIONS_DIR)} -name 'local_*.json' 2>/dev/null`).split(/\r\n?|\n/).filter(Boolean)) {
    try {
      const session = JSON.parse(readFile(file))
      const at = Number(session.lastFocusedAt) || 0
      if (at > latest.at) latest = { at, id: session.sessionId }
    } catch (e) {}
  }
  return latest.id
}

function appSessionId(sessionId) {
  if (!/^[0-9a-f-]{36}$/.test(sessionId || '')) return null
  const file = shell(`grep -rlF --include='local_*.json' ${quote(sessionId)} ${quote(APP_SESSIONS_DIR)} | head -1`)
  return (file.match(/(local_[A-Za-z0-9-]+)\.json$/) || [])[1] || null
}

// `behind`: the app is asked to stay where it is (open -g); it may still come forward.
function openAppLink(url, behind) {
  if (ENV.HANDFREE_OPEN_LOG) return writeFile(ENV.HANDFREE_OPEN_LOG, (readFile(ENV.HANDFREE_OPEN_LOG) || '') + url + '\n')
  shell(`open ${behind ? '-g ' : ''}${quote(url)}`)
}

// A cloud session, or one the app does not show, has no link: the session on screen is the one dictated to.
function replyCommand() {
  rememberFrontApp(true)
  const speaker = appSessionId(withState((state) => state.last_speaker))
  // Already on screen: nothing to open, so nothing comes forward.
  const session = speaker && speaker !== appSessionOnScreen() ? speaker : null
  if (canDictateBehind()) return startDictatingBehind(session)
  if (session) {
    openAppLink(`claude://code/continue?session=${session}`)
    if (!ENV.HANDFREE_OPEN_LOG) delay(CONFIG.open_session_delay_seconds)
  }
  dictateInTargetApp()
}

// ---------- dictating with Claude left behind

// Said in another app, "Listen" and "Reply" leave Claude where it is: the app records in its own window, then the text
// is put in Claude's message field and sent through accessibility. Claude in full screen shows no window to another
// Space, a terminal has no such field, the field's path may be stale: then Claude comes forward as before.
function canDictateBehind() {
  if (!CONFIG.dictate_behind || CONFIG.target_app !== 'Claude') return false
  const front = frontApp()
  if (!front || front.name === CONFIG.target_app) return false
  if (promptReachable()) return true
  logDictation(`as before: Claude's field out of reach from ${front.name} (full screen, or its path changed)`)
  return false
}

function promptReachable() {
  if (ENV.HANDFREE_PROMPT_REACHABLE !== undefined) return ENV.HANDFREE_PROMPT_REACHABLE === '1'
  return Boolean(reachablePrompt())
}

function reachablePrompt() {
  try {
    const process = Application('System Events').processes.byName(CONFIG.target_app)
    if (!process.windows().length) return null
    return promptAt(process.windows[0], withState((state) => state.prompt_path) || [])
  } catch (e) {
    return null
  }
}

// The command returns at once: the dictation runs in its own process, so "Stop" can be said while it waits.
function startDictatingBehind(session) {
  startDictating()
  spawnDictation(session)
}

function spawnDictation(session) {
  if (ENV.HANDFREE_OPEN_LOG) return writeFile(ENV.HANDFREE_OPEN_LOG, (readFile(ENV.HANDFREE_OPEN_LOG) || '') + `dictate behind ${session || '-'}\n`)
  shell(`osascript -l JavaScript ${quote(scriptPath())} --dictate-behind ${quote(session || '-')} >/dev/null 2>&1 &`)
}

function dictateBehind([session]) {
  if (session && session !== '-') {
    openAppLink(`claude://code/continue?session=${session}`, true)
    delay(CONFIG.open_session_delay_seconds)
    // The app comes forward on its links whatever `open -g` asks: the app it was said in goes back in front at once.
    if ((frontApp() || {}).name === CONFIG.target_app) {
      const back = withState((state) => (state.return_app || {}).bundle)
      for (let tries = 0; back && tries < 3 && (frontApp() || {}).name === CONFIG.target_app; tries++) {
        shell(`open -b ${quote(back)}`)
        delay(0.6)
      }
      // Still in front, or its field out of reach: dictate there, as before ("Stop" then goes back).
      const why = !back ? 'no app to go back to' : (frontApp() || {}).name === CONFIG.target_app ? `${back} did not come back in front` : !reachablePrompt() ? "Claude's field out of reach" : ''
      if (why) {
        logDictation(`as before, after opening the session: ${why}`)
        return dictateInTargetApp()
      }
      logDictation(`the session link brought Claude forward, ${back} brought back`)
    }
  }
  const text = dictatedText(askDictation(PHRASE.dictate, CONFIG.max_dictation_seconds))
  withState((state) => {
    releaseHoldOf(state, null)
    startReaderUnlessRunning(state)
  })
  if (!text) return cancelled()
  if (sendBehind(text)) return
  // Not sent: the text waits in Claude's field, in front, to be sent by hand.
  Application(CONFIG.target_app).activate()
  say(PHRASE.not_sent)
}

// Escape in the dictation window, or nothing said: nothing is sent, and the app "Listen" was said in comes back if Claude came forward.
function cancelled() {
  const back = withState((state) => {
    const previous = state.return_app
    if (previous && previous.armed) state.return_app = null
    return previous && previous.armed ? previous.bundle : null
  })
  logDictation('cancelled: nothing sent')
  if (back && (frontApp() || {}).name === CONFIG.target_app) bringBack(back)
}

function dictatedText(rpcResponse) {
  const text = (((rpcResponse || {}).result || {}).content || []).map((c) => c.text || '').join('\n').normalize('NFC')
  const answer = (text.match(/A:\s*([\s\S]*)$/) || [null, ''])[1].trim()
  if (/^\(skipped/i.test(answer)) return ''
  const word = CONFIG.validation_word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return answer.replace(new RegExp(`(?:[\\s,.!]*${word})+[\\s.!]*$`, 'i'), '').trim() // "stop. Stop." too
}

// The app takes text in only when its field gets the focus after the text was set, and with a delay: its Send button
// shows once it has. Sent means Claude Code recorded the message, or, for a cloud session, the field emptied.
// Each step goes to the log: accessibility on the app is undocumented and may change.
function sendBehind(text) {
  const prompt = reachablePrompt()
  if (!prompt) return failed('field not reachable')
  const since = now()
  try {
    prompt.value = text
    delay(0.3)
    prompt.attributes.byName('AXFocused').value = true
  } catch (e) {
    return failed(`could not fill the field: ${e}`)
  }
  for (let tries = 0; !sendButton(prompt); tries++) {
    if (now() > since + SEND_WAIT_SECONDS) return failed('no Send button showed')
    // Focus again now and then: the first one may come before the app has the text.
    if (tries % 4 === 3) {
      try {
        prompt.attributes.byName('AXFocused').value = true
      } catch (e) {}
    }
    delay(0.4)
  }
  // Return, sent to Claude itself (it is not in front), depends less on the app's layout than its button.
  delay(1)
  pressReturnIn(CONFIG.target_app)
  if (sentWithin(since, prompt, 3)) {
    logDictation('sent with Return')
    return true
  }
  // The button shows a little before the app is ready to send, and is redrawn meanwhile: wait, then press it
  // fresh each time, up to three times.
  for (let press = 1; press <= 3; press++) {
    delay(1)
    if (sentWithin(since, prompt, 0)) {
      logDictation(`sent (seen before press ${press})`)
      return true
    }
    const button = sendButton(prompt)
    if (!button) return failed(`the Send button went away before press ${press}`)
    try {
      button.actions.byName('AXPress').perform()
    } catch (e) {
      return failed(`Send could not be pressed: ${e}`)
    }
    if (sentWithin(since, prompt, 2)) {
      logDictation(`sent, press ${press}`)
      return true
    }
  }
  return failed('Send pressed three times, the message did not leave')
}

// Checked once at least, however long a check takes (it reads the recent transcripts).
function sentWithin(since, prompt, seconds) {
  const deadline = now() + seconds
  for (;;) {
    if (messageSentSince(since) || fieldIsEmpty(prompt)) return true
    if (now() > deadline) return false
    delay(0.4)
  }
}

function pressReturnIn(appName) {
  try {
    const pid = Application('System Events').processes.byName(appName).unixId()
    for (const down of [true, false]) $.CGEventPostToPid(pid, $.CGEventCreateKeyboardEvent(null, RETURN_KEY, down))
  } catch (e) {
    logDictation(`Return could not be sent: ${e}`)
  }
}

function failed(reason) {
  logDictation(`not sent: ${reason}`)
  return false
}

// Off by default; when on, only the last 200 lines are kept.
function logDictation(line) {
  if (!CONFIG.dictation_log) return
  const path = `${STATE_DIR}/dictate-behind.log`
  const kept = (readFile(path) || '').split('\n').filter(Boolean).slice(-200)
  writeFile(path, kept.concat(`${new Date().toISOString()} ${line}`).join('\n') + '\n')
}

function sendButton(prompt) {
  try {
    let node = prompt
    for (let up = 0; up < 8; up++) {
      node = node.attributes.byName('AXParent').value()
      const button = node.entireContents().find((e) => {
        try {
          return e.role() === 'AXButton' && SEND_BUTTON.test(e.description() || '') && e.enabled()
        } catch (x) {
          return false
        }
      })
      if (button) return button
    }
  } catch (e) {}
  return null
}

function fieldIsEmpty(prompt) {
  try {
    return !String(prompt.value() || '').trim()
  } catch (e) {
    return false
  }
}

// The session is chosen first: the "Stop" that picks it does not go back yet, the "Listen" that follows does.
function searchSession() {
  rememberFrontApp(false)
  startDictating()
  openAppLink('claude://code/search')
  if (ENV.HANDFREE_OPEN_LOG) return
  delay(CONFIG.activate_delay_seconds)
  dictateIntoFront()
}

// A full search of the window takes ~30 s: it runs behind, for the next "Listen".
function startLearningPromptPath() {
  const alreadyLearning = withState((state) => {
    if (state.learning_since && now() - state.learning_since < LEARNING_TIMEOUT_SECONDS) return true
    state.learning_since = now()
    return false
  })
  if (!alreadyLearning) shell(`osascript -l JavaScript ${quote(scriptPath())} --learn-prompt-path >/dev/null 2>&1 &`)
}

function learnPromptPath() {
  const process = Application('System Events').processes.byName(CONFIG.target_app)
  try {
    process.attributes.byName('AXManualAccessibility').value = true
  } catch (e) {}
  let found = null
  const walk = (element, path, depth) => {
    if (found || depth > 60) return
    let kids
    try {
      kids = element.uiElements()
    } catch (e) {
      return
    }
    for (let i = 0; i < kids.length && !found; i++) {
      try {
        if (kids[i].role() === 'AXTextArea' && kids[i].description() === CONFIG.prompt_name) {
          found = path.concat(i)
          return
        }
      } catch (e) {}
      walk(kids[i], path.concat(i), depth + 1)
    }
  }
  walk(process.windows[0], [], 0)
  withState((state) => {
    state.learning_since = null
    if (found) state.prompt_path = found
  })
}

// ---------- entry point

const COMMANDS = {
  '': queueNewReply,
  '--question': readQuestion,
  '--notify': queueWaitingNotice,
  '--permission': answerPermission,
  '--session-rules': printSessionRules,
  '--listen': listen,
  '--reply': replyCommand,
  '--search-session': searchSession,
  '--done': doneDictating,
  '--cancel': cancelDictation,
  '--answered': answered,
  '--prompt-sent': promptSent,
  '--dictating': startDictating,
  '--quiet': quiet,
  '--continue': continueReading,
  '--restart': restart,
  '--on': () => switchVoiceMode(true),
  '--off': () => switchVoiceMode(false),
  '--toggle': () => switchVoiceMode(!isVoiceModeOn()),
  '--read': readQueue,
  '--learn-prompt-path': learnPromptPath,
  '--go-back': goBackOnceSent,
  '--guard-question': guardScreenOnlyQuestion,
  '--dictate-behind': dictateBehind,
  '--refresh-stable-copy': () => refreshStableCopy(true),
}
// What still runs with voice mode off: the commands that end or undo something under way (a dictation, a reading),
// switch voice mode, tell a session it was switched, or keep the plugin's own processes going. Any other command, a new
// one included, is silent.
const RUNS_WHEN_OFF = ['--answered', '--prompt-sent', '--done', '--cancel', '--dictating', '--quiet', '--continue', '--restart', '--on', '--off', '--toggle', '--read', '--learn-prompt-path', '--go-back', '--dictate-behind', '--refresh-stable-copy']

function run(argv) {
  const command = argv[0] || ''
  if (!(command in COMMANDS)) return `unknown command: ${command}`
  // Before the voice-off check: the listener and the bridge get their new version even while voice mode is off.
  if (command === '--session-rules') refreshStableCopy()
  if (!RUNS_WHEN_OFF.includes(command) && !isVoiceModeOn()) return ''
  // Only "--go-back" and "--dictate-behind" take arguments: the others must not see them as their own parameters.
  const output = ['--go-back', '--dictate-behind'].includes(command) ? COMMANDS[command](argv.slice(1)) : COMMANDS[command]()
  return typeof output === 'string' ? output : ''
}
