import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'

const code = (await readFile(new URL('../client.js', import.meta.url), 'utf8'))
  .replace('return { inject, apply }', 'return { createReplySource, registerUi }')
function load() {
  let exports
  const window = new EventTarget()
  const document = new EventTarget()
  document.visibilityState = 'visible'
  document.focused = false
  document.hasFocus = () => document.focused
  window.__ModuleLoader__ = { load(module) { exports = module.factory(() => ({})) } }
  vm.runInNewContext(code, { window, document, console, queueMicrotask, AbortController })
  return { ...exports, window, document }
}
const final = (seq, text, attemptId = 'one') => ({ event: {
  seq, type: 'assistant/message', data: { attemptId, message: { id: String(seq), content: [{ type: 'text', text }] } }
} })
const delta = (text, attemptId = 'one') => ({ event: {
  type: 'assistant/live-chunk', data: { attemptId, chunk: { type: 'text-delta', text } }
} })
function feed() {
  let value = { revision: 0, entries: [], change: { kind: 'replace', entries: [] } }
  const listeners = new Set()
  return { getSnapshot: () => value, subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn) },
    set(next) { value = next; for (const fn of listeners) fn() },
    emit(kind, rows) { this.set({ revision: value.revision + 1, entries: rows,
      change: kind === 'settle-assistant' ? { kind, attemptId: 'one', entry: rows[0] } : { kind, entries: rows } }) }
  }
}

test('history is silent; streaming replaces one notification; duplicate final is ignored', () => {
  const { createReplySource } = load()
  const source = createReplySource('A', () => false)
  const stream = feed()
  stream.subscribe(() => source.consume(stream.getSnapshot()))
  source.consume(stream.getSnapshot())
  stream.emit('replace', [final(1, '历史回复')])
  assert.equal(source.get().text, '历史回复')
  assert.equal(source.items.length, 0)
  stream.emit('append', [{ event: { type: 'user/message' } }, delta('新')])
  stream.emit('append', [delta('回复')])
  assert.equal(source.items.length, 1)
  assert.equal(source.items[0].state, 'streaming')
  stream.emit('settle-assistant', [final(2, '新回复')])
  assert.equal(source.items.length, 1)
  assert.equal(source.items[0].text, '新回复')
  assert.equal(source.items[0].state, 'done')
  stream.emit('append', [final(2, '新回复')])
  assert.equal(source.items.length, 1)
  stream.emit('append', [final(3, '另一条', 'two')])
  assert.equal(source.items.length, 2)
  stream.emit('prepend', [final(0, '更早历史')])
  assert.equal(source.get().text, '另一条')
  assert.equal(source.items.length, 2)
  source.markRead()
  assert.ok(source.items.every(item => !item.unread))
})

test('multi-session replies route to the selected Session; focus/navigation marks only that Session read', async () => {
  const { registerUi, window, document } = load()
  const feeds = { A: feed(), B: feed() }
  const selection = feed()
  selection.set({ sessionId: 'A' })
  const list = feed()
  list.set({ phase: 'ready', ids: ['A', 'B'], byId: {
    A: { running: true, displayTitle: '任务 A' }, B: { running: true, displayTitle: '任务 B' }
  } })
  const reports = []; const opened = []; const released = []
  let slot
  const remote = { reportState: async state => { reports.push(state); return { ok: true, value: true } } }
  const ctx = {
    sessions: { list, retain(id) { return { binding: { eventSource: feeds[id] }, ready: Promise.resolve(), release() { released.push(id) } } }, scope() {} },
    remote: { $stream() { return { async *[Symbol.asyncIterator]() {}, dispose() {} } } },
    effect(fn) { fn() }, locale: { register() {} },
    slots: { inject(name, fn) { return fn() }, register(config) { slot = config } }
  }
  const ui = { selection, openSession(id) { opened.push(id); selection.set({ sessionId: id }) } }
  const dispose = registerUi(ctx, remote, {}, ui)
  await Promise.resolve()
  const controller = slot.inject('A').controller
  document.focused = true
  window.dispatchEvent(new Event('focus'))
  assert.equal(controller.notificationItems().length, 2, 'Running Sessions stay visible before the first token, including the viewed Session')
  assert.equal(reports.at(-1).replyUnread, 0)
  document.focused = false
  feeds.A.emit('settle-assistant', [final(1, 'A 的回复')])
  feeds.B.emit('settle-assistant', [final(2, 'B 的回复')])
  await Promise.resolve()
  assert.equal(controller.notificationItems().length, 2)
  assert.equal(reports.at(-1).replyUnread, 2)
  // Expanding preview is not a read action.
  await controller.reportState('A', { expanded: true })
  assert.equal(controller.notificationItems().length, 2)
  controller.openReply('B')
  assert.deepEqual(opened, ['B'])
  assert.equal(controller.notificationItems().length, 2, 'Background navigation must not mark read')
  document.focused = true
  window.dispatchEvent(new Event('focus'))
  assert.equal(controller.notificationItems().length, 1)
  assert.equal(controller.notificationItems()[0].sessionId, 'A')
  controller.openReply('A')
  assert.equal(controller.notificationItems().length, 0)
  controller.openReply('deleted')
  assert.deepEqual(opened, ['B', 'A'])
  document.focused = false
  feeds.B.emit('settle-assistant', [final(4, '后台继续回复')])
  assert.equal(controller.notificationItems().length, 1)
  list.set({ phase: 'ready', ids: ['A'], byId: { A: { running: false } } })
  assert.equal(controller.notificationItems().length, 0)
  await dispose()
  assert.ok(released.includes('A') && released.includes('B'))
})

test('DSH append settlement without attemptId replaces live card using turn and step; reasoning is excluded', () => {
  const { createReplySource } = load()
  const source = createReplySource('A', () => false)
  const stream = feed()
  source.consume(stream.getSnapshot())
  stream.subscribe(() => source.consume(stream.getSnapshot()))
  source.setRunning(true)
  stream.emit('replace', [final(1, '上次的历史回复')])
  assert.equal(source.items[0].state, 'streaming', 'Hydrating history must preserve the running placeholder')
  assert.equal(source.items.length, 1)
  const chunk = (type, text) => ({ event: { type: 'assistant/live-chunk', data: {
    attemptId: 'attempt-1', turn: 3, step: 0, chunk: { type, text }
  } } })
  stream.emit('append', [chunk('reasoning-delta', 'The user wants a summary of the conversation.')])
  assert.equal(source.items.length, 1)
  assert.equal(source.items[0].text, '')
  stream.emit('append', [chunk('text-delta', '上面这段对话很短。')])
  assert.equal(source.items[0].text, '上面这段对话很短。')
  stream.emit('append', [{ event: { type: 'assistant/live-chunk', data: {
    attemptId: 'attempt-1', turn: 3, step: 0,
    chunk: { type: 'block-end', block: { type: 'text', text: '上面这段对话很短。' } }
  } } }])
  assert.equal(source.items[0].text, '上面这段对话很短。', 'Block end must not duplicate the text deltas')
  const settlement = { event: { type: 'assistant/message', seq: 12, surfaceOp: 'append', data: {
    turn: 3, step: 0, message: { content: [
      { type: 'reasoning', text: 'The user wants a summary of the conversation.' },
      { type: 'text', text: '上面这段对话很短，就几件事：' }
    ] }
  } } }
  stream.emit('append', [settlement])
  assert.equal(source.items.length, 1)
  assert.equal(source.items[0].state, 'done')
  assert.equal(source.items[0].text, '上面这段对话很短，就几件事：')
  stream.set({ revision: stream.getSnapshot().revision + 1,
    change: { kind: 'settle-assistant', attemptId: 'attempt-1' } })
  source.setRunning(false)
  assert.equal(source.items.length, 1)
  assert.equal(source.items[0].state, 'done')
  source.setRunning(true)
  source.setRunning(false)
  assert.equal(source.items.length, 1, 'Cancel before the first token removes only the pending card')
})
