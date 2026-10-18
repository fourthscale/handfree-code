// handfree-code — read Claude Code aloud and drive it by voice on macOS.
// Runs with `osascript -l JavaScript handfree.js <command>`: osascript ships with every Mac, unlike python3.
//
// Hooks
//   (none)            Stop: queues the new reply (stdin)
//   --question        PreToolUse on the Spokenly tool: pauses the queue, reads the question, then waits for the dictation
//   --notify          Notification: queues "Claude needs your answer"
//   --session-rules   SessionStart: prints the voice rules, refreshes the stable copy the listener and bridge run
//   --guard-question  PreToolUse on AskUserQuestion and the app's session offer: sends Claude to Spokenly instead
//   --permission      PermissionRequest: reads the request, answers it from a spoken yes or no (voice_permissions)
//   --answered        PostToolUse on the Spokenly tool: the answer is in, however it was sent; the queue goes on.
//                     Answered "the rest": the rest of the text before the question is read, and Claude asks again
// Spoken commands (bin/listener.py runs them)
//   --listen          "Claude Listen": silence, bring the app forward, click its message field, start Spokenly
//   --reply           "Claude Reply": the same, in the session that spoke last
//   --search-session  "Claude Session": open the app's session search and start Spokenly; "Stop" opens the one named
//   --done            "Stop": the dictation is sent, the queue goes on
//   --stop / --resume / --restart   "Claude Quiet" / "Claude Continue" / "Claude Restart"
//   --on / --off      "Claude Voice mode on" / "Claude Voice mode off" (--toggle: /vocal with no argument)
// Internal: --read (the reader process), --learn-prompt-path (background search of the message field),
//   --go-back <bundle> <since> (brings the app "Listen" was said in back, once the dictated message is sent)

ObjC.import('Foundation')
ObjC.import('AppKit')
ObjC.import('CoreGraphics')

const STATE_VERSION = 1
const HOME = ObjC.unwrap($.NSHomeDirectory())
const ENV = ObjC.deepUnwrap($.NSProcessInfo.processInfo.environment)
const CONFIG_PATH = ENV.HANDFREE_CONFIG || `${HOME}/.config/claude-speak.json`
const STATE_DIR = ENV.HANDFREE_STATE_DIR || `${HOME}/Library/Caches/claude-speak`
const STATE_PATH = `${STATE_DIR}/state.json`
const LOCK_PATH = `${STATE_DIR}/state.lock`
const SPEECH_LOCK_PATH = `${STATE_DIR}/speech.lock`
const STABLE_COPY = `${HOME}/Library/Application Support/handfree-code/handfree.js`
const LISTENER_LABEL = 'com.handfree-code.listener'
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
  max_dictation_seconds: 180, // a dictation abandoned without "Stop" frees the reader after this
  first_paragraph_only: true, // the rest waits for "Continue"
  summarize_rest: true, // answering "the rest" to a question: a summary first, "the details" for the full text
  validation_word: 'stop', // the spoken word that sends a dictation; Spokenly may transcribe it
  question_tool: 'mcp__spokenly__ask_user_dictation',
  target_app: 'Claude', // the app "Listen" brings forward
  dictate_behind: true, // said in another app, Claude stays behind: Spokenly records, the text is sent through accessibility
  dictation_log: false, // true: how each dictation with Claude behind went, in the state folder's dictate-behind.log
  return_to_previous_app: true, // after "Stop", back to the app "Listen" was said in (none if it was already target_app)
  click_prompt: null, // null: only for the Claude desktop app; a terminal has no field to click
  prompt_name: 'Prompt', // accessibility description of the desktop app's message field
  prompt_fallback: { x_ratio: 0.6, from_bottom: 55 }, // clicked while the field's path is relearnt
  spokenly_trigger: 'double_right_command', // or 'none' when Spokenly is started some other way
  activate_delay_seconds: 0.5,
  after_click_delay_seconds: 0.3,
  double_tap_gap_seconds: 0.12,
  open_session_delay_seconds: 0.8, // wait for the app to show the session "Claude Reply" opened
  away_after_idle_seconds: 300, // keyboard and mouse untouched this long: the user is not at the Mac (on the phone, say)
  // Answer permission prompts by voice. Off by default: a misheard "yes" would allow the action.
  voice_permissions: false,
  permission_answer_seconds: 90,
  // How a session reaches Spokenly: 'mcp' (its MCP server declared in the session), 'bridge' (through the tunnel),
  // or 'none' (questions stay written). Set per context; switch the local one with bin/set-question-transport.sh.
  question_transport: { local: 'mcp', cloud: 'bridge' },
  bridge_url: null, // the tunnel's public address, used when the local transport is 'bridge'
}

const PHRASES = {
  fr: { session: 'Session {title}.', question: 'Une question.', link: 'lien', code: 'Bloc de code omis.', more: 'Détail disponible.', detail: 'Pour tout entendre, réponds « le détail ».', dictate: 'Ton message pour Claude.', not_sent: 'Message pas envoyé : il attend dans Claude.', voice_on: 'Mode vocal activé.', voice_off: 'Mode vocal désactivé.', permission: 'Autorisation demandée : {action}. Autoriser ?', idle: "Claude t'attend", waiting: 'Claude attend ta réponse' },
  en: { session: 'Session {title}.', question: 'A question.', link: 'link', code: 'Code block skipped.', more: 'Details available.', detail: 'To hear it all, answer "the details".', dictate: 'Your message for Claude.', not_sent: 'Message not sent: it is waiting in Claude.', voice_on: 'Voice mode on.', voice_off: 'Voice mode off.', permission: 'Permission requested: {action}. Allow?', idle: 'Claude is waiting', waiting: 'Claude needs your answer' },
  de: { session: 'Sitzung {title}.', question: 'Eine Frage.', link: 'Link', code: 'Codeblock ausgelassen.', more: 'Details verfügbar.', detail: 'Um alles zu hören, antworte „die Details“.', dictate: 'Deine Nachricht an Claude.', not_sent: 'Nachricht nicht gesendet: sie wartet in Claude.', voice_on: 'Sprachmodus an.', voice_off: 'Sprachmodus aus.', permission: 'Erlaubnis angefragt: {action}. Erlauben?', idle: 'Claude wartet', waiting: 'Claude wartet auf deine Antwort' },
}

const SESSION_RULES = {
  fr:
    'Mode vocal actif.\n' +
    "- Quand tu dois me poser une question et attendre ma réponse (un grill, un choix, une validation), utilise l'outil `{tool}` plutôt que `AskUserQuestion`. " +
    "Y compris la question de fin de tour : les boutons de l'app ne me sont pas lus, je ne peux pas y répondre à la voix. " +
    "Quand la question porte sur un texte (des options, une explication), écris ce texte en entier dans ta réponse, la question à la fin, et termine ton tour sans appeler l'outil : " +
    "on te demandera alors de poser la question seule avec l'outil, et ton texte me sera lu avant. Le texte écrit juste avant un appel d'outil peut être caché dans l'app.\n" +
    "- Quand ta réponse est longue (plus de deux ou trois paragraphes), commence-la par un paragraphe de deux ou trois phrases qui la résume en entier : " +
    "c'est lui qui m'est lu, puis « détail disponible » ; le reste seulement si je le demande.\n" +
    "- Je dicte et je valide en disant « {word} » : un « {word} » en fin de message ou de réponse dictée est cette commande, pas une demande d'arrêter. Ignore-le.",
  en:
    'Voice mode is on.\n' +
    '- When you need to ask me a question and wait for the answer (a grill, a choice, a go-ahead), use the `{tool}` tool rather than `AskUserQuestion`, ' +
    "including the end-of-turn question: the app's buttons are not read to me and I cannot answer them by voice. " +
    "When the question is about some text (options, an explanation), write that text in full in your reply, the question last, and end your turn without calling the tool: " +
    "you will then be asked to put the question alone to the tool, and your text is read to me first. Text written just before a tool call may be hidden in the app.\n" +
    '- When your reply is long (more than two or three paragraphs), open it with a paragraph of two or three sentences summing it all up: ' +
    'that is what is read to me, then "details available"; the rest only if I ask for it.\n' +
    '- I dictate and send by saying "{word}": a trailing "{word}" in a dictated message or answer is that command, not a request to stop. Ignore it.',
}

const DELEGATED_TURN_ORIGINS = ['sdk', 'peer'] // an unknown value, after a Claude Code update, reads the reply
const LEARNING_TIMEOUT_SECONDS = 120
const MAX_SEND_BACKS = 3 // written questions sent back in a row with none asked aloud: then Claude is let go
const RETURN_KEY = 36
const SEND_WAIT_SECONDS = 5 // for the app to take the text in, then to send it
const SEND_BUTTON = /^(envoyer|send|senden|absenden)\b/i
const RETURN_WAIT_SECONDS = 30 // for the dictated message to be sent before going back
const RETURN_APP_KEPT_SECONDS = 300 // a session search abandoned long ago does not decide where "Stop" goes
const MAX_READING_WAIT_SECONDS = 60 // the question hook has 120 s in all, its own reading included
const LOCK_STALE_SECONDS = 10
const SPEECH_LOCK_STALE_SECONDS = 20 // the speaker touches it every 5 s: older, its holder is gone
const OTHER_QUESTION_WAIT_SECONDS = 60 // the question hook has 120 s in all

// ---------- system helpers

const app = Application.currentApplication()
app.includeStandardAdditions = true

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
const PHRASE = PHRASES[LANGUAGE] || PHRASES.en
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
    speakWith(CONFIG.say_path, CONFIG.voice ? ['-v', CONFIG.voice, text] : [text], seconds)
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
// The fallback below sees audio about ten seconds after it stops: within that window, it may be our own voice.
const AUDIO_SIGNAL_LINGER_SECONDS = 12

function loadMediaRemote() {
  $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load
}

// Asked of the Now Playing app itself: paused a second ago is paused. null when this macOS cannot say.
function nowPlayingIsPlaying() {
  if (ENV.HANDFREE_NOW_PLAYING) return { 1: true, 0: false }[ENV.HANDFREE_NOW_PLAYING] ?? null
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
function pauseMediaIfPlaying() {
  if (!CONFIG.pause_media) return
  withState((state) => {
    if (state.media_paused || !mediaIsPlaying(state)) return
    sendMediaCommand('pause')
    state.media_paused = true
  })
}

function resumeMediaIfPaused(state) {
  if (!state.media_paused) return
  sendMediaCommand('play')
  state.media_paused = false
}

function sendMediaCommand(name) {
  if (ENV.HANDFREE_MEDIA_KEY_LOG) return writeFile(ENV.HANDFREE_MEDIA_KEY_LOG, (readFile(ENV.HANDFREE_MEDIA_KEY_LOG) || '') + name + '\n')
  try {
    loadMediaRemote()
    ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']])
    $.MRMediaRemoteSendCommand(MEDIA_COMMAND[name], $())
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(MEDIA_COMMAND_SEND_SECONDS))
  } catch (e) {} // a command that cannot be sent must never silence the voice
}

// ---------- state, shared by every process, behind a lock

function emptyState() {
  return { version: STATE_VERSION, current: null, queue: [], announced_id: null, last_speaker: null, reader_pid: null, next_id: 0, dictating_since: null, dictating_session: null, reading_requested: false, finishing_current: false, return_app: null, sent_back: null, read_before_question: null, reply_before_question: null, detail: null, voice_off: false, prompt_path: null, learning_since: null, media_paused: false, last_speech_end: 0, speaker_pid: null }
}

function withState(change) {
  ensureDirectory(STATE_DIR)
  acquireLock()
  try {
    const saved = readJson(STATE_PATH)
    // A state written by another plugin version may mean something else: start over.
    const state = saved && saved.version === STATE_VERSION ? Object.assign(emptyState(), saved) : emptyState()
    const result = change(state)
    writeFile(STATE_PATH, JSON.stringify(state))
    return result
  } finally {
    releaseLock()
  }
}

function acquireLock(path = LOCK_PATH, staleSeconds = LOCK_STALE_SECONDS) {
  const manager = $.NSFileManager.defaultManager
  for (;;) {
    if (manager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, false, $(), null)) return
    const attributes = manager.attributesOfItemAtPathError(path, null)
    if (!attributes.isNil() && now() - attributes.fileModificationDate.timeIntervalSince1970 > staleSeconds) releaseLock(path)
    delay(0.02)
  }
}

function touch(path) {
  $.NSFileManager.defaultManager.setAttributesOfItemAtPathError($({ NSFileModificationDate: $.NSDate.date }), path, null)
}

function releaseLock(path = LOCK_PATH) {
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

function sessionTitle(entries, cwd) {
  const titles = entries.filter((e) => e.type === 'custom-title' && e.customTitle).map((e) => e.customTitle)
  return titles.length ? titles[titles.length - 1] : (cwd || '').split('/').pop() || '?'
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

function isDictating(state) {
  return Boolean(state.dictating_since) && now() - state.dictating_since < CONFIG.max_dictation_seconds
}

function startReaderUnlessRunning(state) {
  if (isAlive(state.reader_pid) || (isDictating(state) && !state.reading_requested)) return
  state.reader_pid = Number(shell(`osascript -l JavaScript ${quote(scriptPath())} --read >/dev/null 2>&1 & echo $!`)) || null
  state.announced_id = null
}

function killReader(state) {
  if (isAlive(state.reader_pid)) shell(`kill ${state.reader_pid}`)
  shell('killall say')
  // A speak_command plays through a child of its own (afplay…): both go.
  if (state.speaker_pid) shell(`pkill -P ${state.speaker_pid}; kill ${state.speaker_pid}`)
  state.reader_pid = null
  state.speaker_pid = null
  releaseLock(SPEECH_LOCK_PATH) // a line cut short frees the voice for whoever speaks next
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
  const onlyCurrent = isDictating(state)
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
    const line = withState((state) => {
      const next = nextLineToSay(state)
      if (!next) {
        state.reader_pid = null
        state.reading_requested = false
        if (!isDictating(state)) resumeMediaIfPaused(state)
      }
      return next
    })
    if (!line) return
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
    if (state.dictating_session && state.dictating_session === data.session_id) Object.assign(state, { dictating_since: null, dictating_session: null })
    state.queue.push({ id: state.next_id, session: data.session_id, title, lines, position: 0, pause_at: pauseAt })
    state.next_id += 1
    startReaderUnlessRunning(state)
  })
}

// ---------- hooks

const UNSPOKEN_QUESTION = {
  fr: "Ce tour se termine sur une question posée seulement à l'écrit ou dans la boîte de l'app : l'utilisateur pilote à la voix et ne peut pas y répondre. Pose-la maintenant avec l'outil `{tool}`, la question seule : ta réponse est affichée et lui est lue avant. Puis termine sans la répéter à l'écrit.",
  en: "This turn ends on a question asked only in writing or in the app's box: the user drives by voice and cannot answer it. Ask it now with the `{tool}` tool, the question alone: your reply is on screen and is read to them first. Then finish without repeating it in writing.",
}

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

function endsOnWrittenQuestion(reply) {
  const paragraphs = withoutCodeBlocks(reply).trim().split(/\n\s*\n/)
  return paragraphs[paragraphs.length - 1].split('\n').some((line) => /\?\s*[»"*_)]*\s*$/.test(line))
}

// A question only on screen is lost to someone who is not looking: the turn goes on until it is asked aloud.
// Every new question is sent back, also later in a turn already sent back once (`stop_hook_active`): a turn that goes
// on through several questions, one answer after another, asks each of them aloud. What stops a loop: the same
// question is never sent back twice in a row, nor more than MAX_SEND_BACKS without one asked in between.
function unspokenQuestionBlock(data, entries, reply) {
  if (!questionsCanBeSpoken() || userIsAway()) return null
  const paragraphs = (reply || '').trim().split(/\n\s*\n/)
  const written = endsOnWrittenQuestion(reply)
  const question = written ? paragraphs[paragraphs.length - 1].trim() : appBoxQuestion(currentTurn(entries))
  if (!question) return null
  const sendBack = withState((state) => {
    const previous = state.sent_back && state.sent_back.session === data.session_id ? state.sent_back : null
    if (data.stop_hook_active && previous && (previous.question === question || previous.count >= MAX_SEND_BACKS)) return false
    state.sent_back = { session: data.session_id, question, count: data.stop_hook_active && previous ? previous.count + 1 : 1 }
    // The question comes next: other sessions finish what they are reading, then wait for it. Another session's
    // question already under way keeps its hold: this one will wait for it to be answered.
    if (!(isDictating(state) && state.dictating_session !== data.session_id)) {
      Object.assign(state, { dictating_since: now(), dictating_session: data.session_id, reading_requested: false, finishing_current: true })
    }
    return true
  })
  if (!sendBack) return null
  const reason = (UNSPOKEN_QUESTION[LANGUAGE] || UNSPOKEN_QUESTION.en).replace('{tool}', CONFIG.question_tool)
  // The reply stays on screen; it is read before the question asked next, without its last paragraph when that is the question.
  const text = written ? paragraphs.slice(0, -1).join('\n\n') : paragraphs.join('\n\n')
  // A long reply: its summary comes with the question, so the first reading already covers it all.
  const long = CONFIG.summarize_rest && speakableLines(text).length - linesThroughFirstParagraph(text) >= SUMMARY_MIN_LINES
  withState((state) => (state.reply_before_question = text ? { session: data.session_id, text, long } : null))
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
    const before = state.read_before_question
    if (before && before.session === data.session_id) state.read_before_question = null
    // Sent back but never asked: that reply is not waiting for a question any more.
    if ((state.reply_before_question || {}).session === data.session_id) state.reply_before_question = null
    return Boolean(before && before.session === data.session_id && before.text === reply.trim())
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
  if (withState(isDictating)) return
  enqueue(data, readTranscript(data.transcript_path), [PHRASE.waiting], 1)
}

// The app's own ways of asking wait for a click or a pick on screen: in voice mode they are turned back to Spokenly.
// A refusal does not stop Claude: it reads the reason as the tool's result and asks again, the spoken way.
const SCREEN_ONLY_QUESTION = {
  fr: "Mode vocal actif : cette question s'affiche seulement à l'écran, l'utilisateur ne l'entend pas et ne peut pas y répondre à la voix. Pose-la avec l'outil `{tool}` à la place (la question seule ; le texte qu'elle concerne va dans ta réponse écrite).",
  en: 'Voice mode is on: this question only shows on screen; the user does not hear it and cannot answer it by voice. Ask it with the `{tool}` tool instead (the question alone; the text it is about goes in your written reply).',
}
const SCREEN_ONLY_SESSION_OFFER = {
  fr: "Mode vocal actif : cette proposition attend un clic à l'écran, l'utilisateur ne l'entend pas. Demande-lui avec l'outil `{tool}` s'il veut cette tâche dans une nouvelle session ou ici. S'il choisit une nouvelle session, lance-la (initiation \"user_asked\") ; sinon fais-la ici.",
  en: 'Voice mode is on: this offer waits for a click on screen; the user does not hear it. Ask them with the `{tool}` tool whether they want this task in a new session or here. If they pick a new session, start it (initiation "user_asked"); otherwise do it here.',
}

function guardScreenOnlyQuestion() {
  const data = readStdin()
  if (!questionsCanBeSpoken() || userIsAway()) return ''
  const offer = /start_session$/.test(data.tool_name || '')
  if (offer && (data.tool_input || {}).initiation !== 'offer') return '' // a proposal card waits for nobody
  const reasons = offer ? SCREEN_ONLY_SESSION_OFFER : SCREEN_ONLY_QUESTION
  const reason = (reasons[LANGUAGE] || reasons.en).replace('{tool}', CONFIG.question_tool)
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } })
}

const AWAY = {
  fr: "L'utilisateur n'est pas devant son Mac (aucune activité depuis {minutes} min) : Spokenly ne l'atteindrait pas. Pose ta question par écrit dans ta réponse.",
  en: 'The user is not at their Mac (no activity for {minutes} min): Spokenly would not reach them. Ask your question in writing in your reply.',
}

function idleSeconds() {
  const output = ENV.HANDFREE_IDLE_SECONDS || shell("ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'")
  return Number(output) || 0
}

function userIsAway() {
  return idleSeconds() >= CONFIG.away_after_idle_seconds
}

// Clear words only: anything else leaves the usual dialog on screen.
const YES_WORDS = ['oui', 'ouais', 'autorise', 'autoriser', 'vas-y', 'valide', "d'accord", 'yes', 'allow', 'approve', 'go ahead', 'ja', 'erlauben']
const NO_WORDS = ['non', 'refuse', 'refuser', 'no', 'deny', 'nein', 'ablehnen']
const MAX_SPOKEN_ACTION_CHARS = 160

function describeAction(toolName, toolInput) {
  const input = toolInput || {}
  if (toolName === 'Bash' && input.command) return input.command.slice(0, MAX_SPOKEN_ACTION_CHARS)
  const file = input.file_path || input.notebook_path || input.path
  if (file) return `${toolName} ${file.split('/').pop()}`
  return toolName.replace(/^mcp__/, '').replace(/__/g, ' ')
}

function answerOf(spokenlyReply) {
  // macOS may hand accents decomposed.
  const text = (((spokenlyReply || {}).result || {}).content || []).map((c) => c.text || '').join('\n').normalize('NFC')
  const answer = (text.match(/A:\s*([\s\S]*)$/) || [null, text])[1].toLowerCase()
  return answer.split(/[^a-zà-ÿ'-]+/).filter((word) => word && word !== CONFIG.validation_word.toLowerCase())
}

function decide(words) {
  const said = (list) => list.some((w) => (w.includes(' ') ? words.join(' ').includes(w) : words.includes(w)))
  if (said(YES_WORDS) && !said(NO_WORDS)) return 'allow'
  if (said(NO_WORDS) && !said(YES_WORDS)) return 'deny'
  return null
}

function askSpokenly(question, seconds) {
  const url = ENV.HANDFREE_SPOKENLY_URL || 'http://localhost:51089'
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
  if (!CONFIG.voice_permissions || CONTEXT !== 'local' || userIsAway() || !spokenlyResponds()) return ''
  const entries = readTranscript(data.transcript_path)
  const question = PHRASE.permission.replace('{action}', describeAction(data.tool_name || '', data.tool_input))
  holdReaderAfterCurrentReading()
  say(`${introFor(data, entries)}${question}`)
  startDictating()
  const decision = decide(answerOf(askSpokenly(question)))
  doneDictating()
  if (!decision) return ''
  const verdict = decision === 'allow' ? { behavior: 'allow' } : { behavior: 'deny', message: 'Refused by voice.' }
  return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: verdict } })
}

function readQuestion() {
  if (userIsAway()) {
    const reason = (AWAY[LANGUAGE] || AWAY.en).replace('{minutes}', Math.round(idleSeconds() / 60))
    return JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } })
  }
  const data = readStdin()
  const entries = readTranscript(data.transcript_path)
  const { context, questions } = splitQuestions((data.tool_input || {}).questions || [])
  waitForOtherDictation(data.session_id)
  // The queue stays paused: restarting it would talk over the answer being dictated.
  holdReaderAfterCurrentReading(data.session_id)
  withState((state) => {
    if (state.sent_back && state.sent_back.session === data.session_id) state.sent_back.count = 0
  })
  const intro = introFor(data, entries)
  const sentBack = withState((state) => {
    const reply = state.reply_before_question
    state.reply_before_question = null
    return reply && reply.session === data.session_id ? reply : { text: '' }
  })
  const written = textOfLastMessage(entries)
  const replyText = uniqueParagraphs(sentBack.text, written)
  // What Claude put in the question is what it chose to say: read in full, unlike the reply's paragraphs after the first.
  const ownContext = paragraphsNotIn(context, replyText)
  const before =
    // A long reply: its first paragraph is taken as its summary when Claude gives none with the question.
    sentBack.long
      ? readSummedUp(data, entries, intro, sentBack.text, ownContext)
      : readTextBeforeQuestion(data, entries, intro, replyText, ownContext, written)
  const detailWaits = withState((state) => Boolean(state.detail && state.detail.session === data.session_id))
  // After a summary, the full text it sums up is kept: say how to hear it.
  if (detailWaits) say(`${before ? '' : intro}${PHRASE.detail}`)
  say(`${before || detailWaits ? '' : intro}${PHRASE.question} ${SILENCE} ${questions.join(' ')}`)
  startDictating(data.session_id)
}

// Another session's question, or a free dictation, is under way: Spokenly takes one at a time, and a question read now
// would be taken down with that answer. Wait for it to be answered (within the hook's time).
function waitForOtherDictation(session) {
  const deadline = now() + OTHER_QUESTION_WAIT_SECONDS
  while (now() < deadline && withState((state) => isDictating(state) && state.dictating_session !== session)) delay(0.5)
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
function readTextBeforeQuestion(data, entries, intro, replyText, context, written) {
  const lines = speakableLines(replyText || '')
  const contextLines = speakableLines(context || '')
  if (!lines.length && !contextLines.length) return ''
  const pauseAt = lines.length ? (CONFIG.first_paragraph_only ? linesThroughFirstParagraph(replyText) : 0) || lines.length : 0
  let first = true
  const sayLine = (line) => {
    say(`${first ? intro : ''}${line}`)
    first = false
    delay(CONFIG.pause_between_lines_seconds)
  }
  lines.slice(0, pauseAt).forEach(sayLine)
  if (pauseAt < lines.length) say(PHRASE.more)
  contextLines.forEach(sayLine)
  withState((state) => {
    state.current = { id: state.next_id, session: data.session_id, title: sessionTitle(entries, data.cwd), lines, position: pauseAt, pause_at: pauseAt, more_announced: true }
    state.announced_id = state.next_id
    state.next_id += 1
    state.read_before_question = written ? { session: data.session_id, text: written.trim() } : null
  })
  return replyText || context
}

// A long reply sent back: its first paragraph, then the summary put in the question; the rest waits for "the details".
function readSummedUp(data, entries, intro, reply, summary) {
  const replyLines = speakableLines(reply)
  const cut = linesThroughFirstParagraph(reply) || replyLines.length
  const lines = replyLines.slice(0, cut).concat(speakableLines(summary))
  lines.forEach((line, i) => {
    say(`${i === 0 ? intro : ''}${line}`)
    delay(CONFIG.pause_between_lines_seconds)
  })
  withState((state) => {
    state.current = { id: state.next_id, session: data.session_id, title: sessionTitle(entries, data.cwd), lines, position: lines.length, pause_at: lines.length, more_announced: true }
    state.announced_id = state.next_id
    state.next_id += 1
    state.detail = { session: data.session_id, lines: replyLines.slice(cut) }
  })
  return reply
}

// The text blocks of the message that carries the question (they are written to the transcript before the call).
function textOfLastMessage(entries) {
  let last = null
  for (let i = entries.length - 1; i >= 0 && !last; i--) if (entries[i].type === 'assistant') last = entries[i]
  const id = last && (last.message || {}).id
  if (!id) return ''
  return entries
    .filter((e) => e.type === 'assistant' && (e.message || {}).id === id)
    .flatMap((e) => ((e.message || {}).content || []).filter((b) => b && b.type === 'text' && (b.text || '').trim()).map((b) => b.text))
    .join('\n')
}

function printSessionRules() {
  refreshStableCopy()
  if (!questionsCanBeSpoken()) return ''
  const rules = SESSION_RULES[LANGUAGE] || SESSION_RULES.en
  return rules.replace(/\{word\}/g, CONFIG.validation_word).replace('{tool}', CONFIG.question_tool)
}

// The bridge service marks the hooks it runs for a cloud session.
const CONTEXT = ENV.HANDFREE_CONTEXT === 'cloud' ? 'cloud' : 'local'

// Rules naming a tool the session cannot reach would send it looking for nothing.
function questionsCanBeSpoken() {
  const transport = Object.assign({}, DEFAULTS.question_transport, CONFIG.question_transport)[CONTEXT]
  if (transport === 'none') return false
  if (CONTEXT === 'cloud') return transport !== 'bridge' || spokenlyResponds() // a cloud session's own config is out of sight here
  return questionToolIsDeclared() && (transport !== 'bridge' || spokenlyResponds())
}

function spokenlyResponds() {
  if (ENV.HANDFREE_SPOKENLY_UP) return ENV.HANDFREE_SPOKENLY_UP === '1'
  const url = ENV.HANDFREE_SPOKENLY_URL || 'http://localhost:51089'
  return shell(`curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST ${quote(url)} -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":0,"method":"tools/list"}'`) === '200'
}

function questionToolIsDeclared() {
  const server = CONFIG.question_tool.split('__')[1]
  const settings = readJson(`${HOME}/.claude.json`) || {}
  const declared = [settings.mcpServers || {}, ...Object.values(settings.projects || {}).map((p) => p.mcpServers || {})]
  return declared.some((servers) => server in servers)
}

// The listener and the bridge service need a path that survives plugin updates; the plugin's folder changes with every version.
function refreshStableCopy() {
  const sourceDir = scriptPath().replace(/\/[^/]*$/, '')
  const stableDir = STABLE_COPY.replace(/\/[^/]*$/, '')
  for (const name of ['handfree.js', 'bridge-server.py', 'speak-openai.sh', 'listener.py', 'install-listener.sh']) {
    const source = readFile(`${sourceDir}/${name}`)
    if (!source || source === readFile(`${stableDir}/${name}`)) continue
    writeFile(`${stableDir}/${name}`, source)
    // A listener installed (install-listener.sh) restarts on its new version.
    if (name === 'listener.py' && readFile(`${HOME}/Library/LaunchAgents/${LISTENER_LABEL}.plist`)) shell(`launchctl kickstart -k gui/$(id -u)/${LISTENER_LABEL} >/dev/null 2>&1`)
  }
}

function scriptPath() {
  return ObjC.unwrap($.NSProcessInfo.processInfo.arguments).map(ObjC.unwrap).find((a) => /\.js$/.test(a))
}

// ---------- voice commands

// A question records the session that asked; "Listen" records none.
// Music or a video is paused for the dictation too, and resumed once it is over (by the reader, when nothing is left):
// so is it whichever way Spokenly treats media, which pauses it without always resuming.
function startDictating(session) {
  pauseMediaIfPlaying()
  withState((state) => {
    killReader(state)
    state.dictating_since = now()
    state.dictating_session = session || null
    state.reading_requested = false
  })
}

// "Stop" ends a free dictation. A question's dictation (it has a session) is freed by its answer instead: that comes
// later, after "the rest" may have the question asked again, and a reading started meanwhile would be taken down.
function doneDictating() {
  const back = withState((state) => {
    if (!state.dictating_session) {
      state.dictating_since = null
      startReaderUnlessRunning(state)
    }
    // A dictation abandoned without "Stop" leaves a note: too old, it no longer decides.
    const previous = state.return_app
    const due = previous && previous.armed && now() - previous.since < CONFIG.max_dictation_seconds
    if (previous && previous.armed) state.return_app = null
    return due ? previous.bundle : null
  })
  if (!back) return
  // Spokenly inserts the text and sends it only while Claude is still in front: going back waits for the message to leave.
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

// Answers that only ask for the rest of the text read before the question: summed up first, then in full.
const MORE_ANSWERS = ['la suite', 'suite', 'continue', 'lis la suite', 'the rest', 'more', 'go on', 'weiter', 'mehr', 'der rest']
const DETAIL_ANSWERS = ['le détail', 'détail', 'les détails', 'détails', 'montre le détail', 'lis le détail', 'tout', 'the details', 'details', 'the detail', 'detail', 'all of it', 'die details', 'details zeigen', 'alles']
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
    const item = state.current && state.current.session === data.session_id ? state.current : null
    const rest = item ? item.lines.slice(item.position) : []
    const detail = state.detail && state.detail.session === data.session_id ? state.detail.lines : []
    const consumeRest = () => Object.assign(item, { position: item.lines.length, pause_at: item.lines.length })
    // Asking for more: the question is asked again right after, so the other sessions keep waiting. Only this session's
    // own question is released: a refused or failed call ("Spokenly already recording") must not free a dictation under
    // way elsewhere, such as "Listen" said while this session worked.
    const held = wantsMore || wantsDetail
    const own = !isDictating(state) || state.dictating_session === data.session_id
    if (own) Object.assign(state, { dictating_since: held ? now() : null, dictating_session: held ? data.session_id : null })
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
      Object.assign(state, { dictating_since: null, dictating_session: null })
      startReaderUnlessRunning(state)
    }
    return { lines: found, reason: ASK_AGAIN }
  })
  if (reason === ASK_SUMMARY) return JSON.stringify({ decision: 'block', reason })
  if (!lines.length) return ''
  // Read here, before Claude asks again: its new question would cut a reading still going on.
  lines.forEach((line) => {
    say(line)
    delay(CONFIG.pause_between_lines_seconds)
  })
  return JSON.stringify({ decision: 'block', reason })
}

// A tool's response comes as text, a list of content blocks, or an object holding them.
function textBlocks(value) {
  if (typeof value === 'string') return [{ text: value }]
  if (Array.isArray(value)) return value.flatMap(textBlocks)
  if (value && typeof value === 'object') return typeof value.text === 'string' ? [{ text: value.text }] : textBlocks(value.content || [])
  return []
}

function stop() {
  withState(killReader)
}

// A question lets the reading under way end first (up to where it pauses), then nothing else starts: two voices at once
// are not understood, and Spokenly would take down the other one.
function holdReaderAfterCurrentReading(session) {
  const readerPid = withState((state) => {
    state.dictating_since = now() // the reader takes no new reply
    state.dictating_session = session || null
    state.reading_requested = false // an earlier "Continue" would let it read on, or start again, over the question
    state.finishing_current = true
    return state.reader_pid
  })
  const deadline = now() + MAX_READING_WAIT_SECONDS
  while (isAlive(readerPid) && now() < deadline) delay(0.2)
  withState((state) => {
    state.finishing_current = false
    killReader(state)
  })
}

function resume() {
  withState((state) => {
    if (state.current) state.current.pause_at = state.current.lines.length
    state.reading_requested = true
    startReaderUnlessRunning(state)
  })
}

function restart() {
  withState((state) => {
    killReader(state)
    if (state.current) Object.assign(state.current, { position: 0, pause_at: state.current.lines.length })
    state.reading_requested = true
    startReaderUnlessRunning(state)
  })
}

function switchVoiceMode(on) {
  withState((state) => {
    state.voice_off = !on
    if (!on) {
      killReader(state)
      Object.assign(state, { current: null, queue: [], dictating_since: null })
      resumeMediaIfPaused(state)
    }
  })
  say(on ? PHRASE.voice_on : PHRASE.voice_off)
  switchListener(on)
}

// Voice mode off stops listening altogether (the microphone is let go); on starts it again. Only once it is installed.
function switchListener(on) {
  const plist = `${HOME}/Library/LaunchAgents/${LISTENER_LABEL}.plist`
  // A state folder of its own (the tests) never touches the real service.
  if (ENV.HANDFREE_STATE_DIR || !readFile(plist)) return
  const domain = `gui/$(id -u)`
  shell(on ? `launchctl bootstrap ${domain} ${quote(plist)} >/dev/null 2>&1; true` : `launchctl bootout ${domain}/${LISTENER_LABEL} >/dev/null 2>&1; true`)
}

function isVoiceModeOn() {
  return withState((state) => !state.voice_off)
}

// ---------- "Listen": focus the message field and start Spokenly

const RIGHT_COMMAND = 54
const FLAGS_CHANGED = 12
const COMMAND_FLAG = 0x100000 | 0x10

function click([x, y]) {
  const point = $.CGPointMake(x, y)
  $.CGEventPost(0, $.CGEventCreateMouseEvent(null, 1, point, 0))
  delay(0.05)
  $.CGEventPost(0, $.CGEventCreateMouseEvent(null, 2, point, 0))
}

function tapRightCommand() {
  const down = $.CGEventCreateKeyboardEvent(null, RIGHT_COMMAND, true)
  $.CGEventSetType(down, FLAGS_CHANGED)
  $.CGEventSetFlags(down, COMMAND_FLAG)
  $.CGEventPost(0, down)
  delay(0.03)
  const up = $.CGEventCreateKeyboardEvent(null, RIGHT_COMMAND, false)
  $.CGEventSetType(up, FLAGS_CHANGED)
  $.CGEventSetFlags(up, 0)
  $.CGEventPost(0, up)
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

function dictateInTargetApp() {
  startDictating()
  if (ENV.HANDFREE_OPEN_LOG) return // tests: no window, click or key
  Application(CONFIG.target_app).activate()
  delay(CONFIG.activate_delay_seconds)
  const shouldClick = CONFIG.click_prompt === null ? CONFIG.target_app === 'Claude' : CONFIG.click_prompt
  if (shouldClick) {
    clickPrompt()
    delay(CONFIG.after_click_delay_seconds)
  }
  startSpokenly()
}

function startSpokenly() {
  if (CONFIG.spokenly_trigger !== 'double_right_command') return
  tapRightCommand()
  delay(CONFIG.double_tap_gap_seconds)
  tapRightCommand()
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
function reply() {
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

// Said in another app, "Listen" and "Reply" leave Claude where it is: Spokenly records in its own window, then the text
// is put in Claude's message field and sent through accessibility. Claude in full screen shows no window to another
// Space, a terminal has no such field, the field's path may be stale: then Claude comes forward as before.
function canDictateBehind() {
  if (!CONFIG.dictate_behind || CONFIG.target_app !== 'Claude') return false
  const front = frontApp()
  if (!front || front.name === CONFIG.target_app) return false
  if (ENV.HANDFREE_PROMPT_REACHABLE !== undefined) return ENV.HANDFREE_PROMPT_REACHABLE === '1'
  if (reachablePrompt()) return true
  logDictation(`as before: Claude's field out of reach from ${front.name} (full screen, or its path changed)`)
  return false
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
  const text = dictatedText(askSpokenly(PHRASE.dictate, CONFIG.max_dictation_seconds))
  withState((state) => {
    state.dictating_since = null
    state.dictating_session = null
    startReaderUnlessRunning(state)
  })
  if (!text) return
  if (sendBehind(text)) return
  // Not sent: the text waits in Claude's field, in front, to be sent by hand.
  Application(CONFIG.target_app).activate()
  say(PHRASE.not_sent)
}

function dictatedText(spokenlyReply) {
  const text = (((spokenlyReply || {}).result || {}).content || []).map((c) => c.text || '').join('\n').normalize('NFC')
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
  startSpokenly()
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
  '--reply': reply,
  '--search-session': searchSession,
  '--done': doneDictating,
  '--answered': answered,
  '--dictating': startDictating,
  '--stop': stop,
  '--resume': resume,
  '--restart': restart,
  '--on': () => switchVoiceMode(true),
  '--off': () => switchVoiceMode(false),
  '--toggle': () => switchVoiceMode(!isVoiceModeOn()),
  '--read': readQueue,
  '--learn-prompt-path': learnPromptPath,
  '--go-back': goBackOnceSent,
  '--guard-question': guardScreenOnlyQuestion,
  '--dictate-behind': dictateBehind,
}
const SILENT_WHEN_OFF = ['', '--question', '--guard-question', '--notify', '--session-rules', '--listen', '--reply', '--search-session', '--permission']

function run(argv) {
  const command = argv[0] || ''
  if (!(command in COMMANDS)) return `unknown command: ${command}`
  if (SILENT_WHEN_OFF.includes(command) && !isVoiceModeOn()) return ''
  // Only "--go-back" and "--dictate-behind" take arguments: the others must not see them as their own parameters.
  const output = ['--go-back', '--dictate-behind'].includes(command) ? COMMANDS[command](argv.slice(1)) : COMMANDS[command]()
  return typeof output === 'string' ? output : ''
}
