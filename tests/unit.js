// Fast checks of handfree.js's pure logic: the text read aloud, the answers, the reading plan before a question, the
// hold. No voice, no process, no sleep. Run by tests/run.sh (osascript -l JavaScript tests/unit.js), with its scratch
// state and settings: loading handfree.js reads them, and it touches nothing of the real ones.
ObjC.import('Foundation')

const ROOT = ObjC.unwrap($.NSProcessInfo.processInfo.arguments)
  .map(ObjC.unwrap)
  .find((a) => /unit\.js$/.test(a))
  .replace(/\/?tests\/unit\.js$/, '') || '.'
const SOURCE = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(`${ROOT}/bin/handfree.js`, $.NSUTF8StringEncoding, null))
if (!SOURCE) throw new Error(`cannot read ${ROOT}/bin/handfree.js`)
// What is checked below, handed back by handfree.js once evaluated: its own `run` is never called, so it runs no command.
const NAMES = ['speakableLines', 'linesThroughFirstParagraph', 'endsOnWrittenQuestion', 'answerOf', 'decide', 'dictatedText',
  'compareVersions', 'splitQuestions', 'uniqueParagraphs', 'paragraphsNotIn', 'planQuestionReading', 'afterSaying',
  'linesBeforePause', 'textOfLastMessage', 'emptyState', 'hold', 'isHeld', 'heldByAnother', 'releaseHoldOf', 'nextLineToSay',
  'now', 'CONFIG', 'PHRASE']
// In a function of its own, with no name of this script around: its declarations stay apart from the checks' names.
function loadPlugin() {
  return eval(`${SOURCE}\n;({ ${NAMES.join(', ')} })`)
}

function run() {
  const plugin = loadPlugin()
  const { speakableLines, linesThroughFirstParagraph, endsOnWrittenQuestion, answerOf, decide, dictatedText, compareVersions,
    splitQuestions, uniqueParagraphs, paragraphsNotIn, planQuestionReading, afterSaying, linesBeforePause, textOfLastMessage,
    emptyState, hold, isHeld, heldByAnother, releaseHoldOf, nextLineToSay, now, CONFIG, PHRASE } = plugin

  const results = []
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
  function check(name, got, expected) {
    results.push(same(got, expected) ? `ok   unit: ${name}` : `FAIL unit: ${name}\n     expected: ${JSON.stringify(expected)}\n     got: ${JSON.stringify(got)}`)
  }

  // ---------- the text read aloud

  check('markdown is read as plain text', speakableLines('**Bold** and [a link](https://x.y)'), ['Bold and a link.'])
  check('a web address is read as "link"', speakableLines('See https://x.y/z.'), ['See link.'])
  check('a code block is announced, not read', speakableLines('Before.\n```js\nx()\n```\nAfter.'), ['Before.', 'Code block skipped.', 'After.'])
  check('a table row is read as a sentence', speakableLines('| a | b |\n|---|---|\n| 1 | 2 |'), ['a, b.', '1, 2.'])
  check('a list item loses its bullet', speakableLines('- one\n2. two'), ['one.', 'two.'])
  check('the first paragraph counts its lines', linesThroughFirstParagraph('A.\nB.\n\nC.'), 2)
  check('a heading first does not end the first paragraph', linesThroughFirstParagraph('# Title\n\nA.\n\nB.'), 2)
  check('a reply ending on a question', endsOnWrittenQuestion('Done.\n\nShall I go on?'), true)
  check('a question mark earlier does not count', endsOnWrittenQuestion('Why? Because.\n\nDone.'), false)

  // ---------- answers

  const response = (text) => ({ result: { content: [{ type: 'text', text }] } })
  check('an answer loses its question and its validation word', answerOf(response('Q: Allow?\nA: Oui stop')), ['oui'])
  check('a yes alone allows', decide(['oui']), 'allow')
  check('a no alone denies', decide(['nein']), 'deny')
  check('yes and no together decide nothing', decide(['yes', 'no']), null)
  check('a two-word yes is heard', decide(['go', 'ahead']), 'allow')
  check('a dictation loses its trailing stop, the stop before it too', dictatedText(response('Q: x\nA: Send this. Stop. Stop.')), 'Send this')
  check('a skipped dictation is nothing', dictatedText(response('Q: x\nA: (skipped by user)')), '')
  check('versions compare number by number', compareVersions('0.3.10', '0.3.9') > 0, true)

  // ---------- the question and what is read before it

  check('a question keeps its context paragraphs apart', splitQuestions(['Context.\n\nWhich one?']), { context: 'Context.', questions: ['Which one?'] })
  check('the same paragraph is kept once', uniqueParagraphs('A.\n\nB.', 'B.\n\nC.'), 'A.\n\nB.\n\nC.')
  check('only the paragraphs the other text lacks', paragraphsNotIn('A.\n\nB.', 'B.'), 'A.')
  const shortPlan = planQuestionReading({ sentBack: { text: 'First.\n\nSecond.' }, written: '', context: 'Own context.' })
  check('before a question: the first paragraph, "details available", then the context', shortPlan.say, ['First.', 'Details available.', 'Own context.'])
  check('and the reply kept for "the rest", paused after its first paragraph', [shortPlan.keep, shortPlan.pauseAt], [['First.', 'Second.'], 1])
  check('nothing written: nothing read before the question', planQuestionReading({ sentBack: { text: '' }, written: '', context: '' }), null)
  const longPlan = planQuestionReading({ sentBack: { text: 'Gist.\n\nOne.\n\nTwo.\n\nThree.', long: true }, written: '', context: 'Summary.' })
  check('a long reply: its first paragraph and the summary', longPlan.say, ['Gist.', 'Summary.'])
  check('and the rest kept for "the details"', longPlan.detail, ['One.', 'Two.', 'Three.'])
  const older = [
    { id: 1, lines: ['a1', 'a2', 'a3'], position: 0, pause_at: 2 },
    { id: 2, lines: ['b1'], position: 0, pause_at: 1 },
  ]
  check('older replies: what is left after their pause waits again', afterSaying(older, 3).map((i) => [i.id, i.position]), [[1, 2]])
  check('cut short: from the first line not said', afterSaying(older, 1).map((i) => [i.id, i.position]), [[1, 1], [2, 0]])
  check('the lines they had before their pause', older.flatMap(linesBeforePause), ['a1', 'a2', 'b1'])
  const transcript = [
    { type: 'assistant', message: { content: [{ type: 'text', text: 'Old.' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result' }] } },
    { type: 'assistant', message: { content: [{ type: 'text', text: 'New.' }] } },
  ]
  check('written before the question: only what follows the last user entry', textOfLastMessage(transcript), 'New.')

  // ---------- the hold and the reader

  const state = emptyState()
  hold(state, 'a', { sendBack: true })
  check('a send-back holds for its session', [isHeld(state), state.held_by], [true, 'send_back'])
  check('another session waits for it', heldByAnother(state, 'b'), true)
  check('its own session does not', heldByAnother(state, 'a'), false)
  check('another session cannot release it', [releaseHoldOf(state, 'b'), isHeld(state)], [false, true])
  check('a free dictation\'s release does not either', releaseHoldOf(state, null), false)
  check('its owner does', [releaseHoldOf(state, 'a'), isHeld(state)], [true, false])
  hold(state, null)
  state.dictating_since = now() - CONFIG.max_dictation_seconds - 1
  check('an abandoned hold holds nothing', [isHeld(state), heldByAnother(state, 'a')], [false, false])

  const reading = Object.assign(emptyState(), {
    current: { id: 1, session: 'a', title: 'A', lines: ['One.', 'Two.'], position: 1, pause_at: 1, more_announced: false },
    queue: [{ id: 2, session: 'b', title: 'B', lines: ['Next.'], position: 0, pause_at: 1 }],
    last_speaker: 'a',
    announced_id: 1,
  })
  check('at a pause with more to come, the reader says so once', nextLineToSay(reading).text, PHRASE.more)
  check('then goes on to the next reply, announced', /Session B\..*Next\./.test(nextLineToSay(reading).text), true)
  hold(reading, 'c')
  check('held, the reader starts nothing new', nextLineToSay(reading), null)

  return results.join('\n')
}
