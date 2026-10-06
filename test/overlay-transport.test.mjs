import assert from 'node:assert/strict'
import { test } from 'node:test'
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { once } from 'node:events'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { GlobalVoiceController } from '../index.js'

// Use the actual DSH gateway, including its SRC signature parser. A direct
// controller call or the overlay's visual self-test cannot catch this bug.
const dependencies = process.env.DSH_TEST_NODE_MODULES
  ? pathToFileURL(resolve(process.env.DSH_TEST_NODE_MODULES) + '/').href
  : new URL('../../dsh-sdk/dsh/node_modules/', import.meta.url).href
const { Context } = await import(new URL('@deepseek-ai/cordis/lib/index.js', dependencies))
const { TypertRegistry } = await import(new URL('@deepseek-ai/dsh-typert-registry/lib/index.js', dependencies))
const { TypertGatewayService } = await import(new URL('@deepseek-ai/dsh-api-gateway/lib/index.js', dependencies))

function setup(Controller = GlobalVoiceController) {
  const ctx = new Context()
  new TypertRegistry(ctx)
  const gateway = new TypertGatewayService(ctx, { websocketHeartbeatIntervalMs: 30000, streamInboxBytes: 1048576 })
  // Suppress production effects so tests never register a real shortcut.
  const controller = new Controller({ on() {}, effect() {} }, { showOverlay: true })
  ctx.provide('globalVoiceController', controller)
  const report = (state) => gateway.invoke({ namespace: 'globalVoice', method: 'reportState', args: { state } })
  return { controller, report }
}

test('DSH gateway reproduces the old default-parameter failure', async () => {
  class LegacyController extends GlobalVoiceController {
    reportState(state = {}) { return super.reportState(state) }
  }
  const marker = '@deepseek-ai/dsh-typert-protocol/remote-methods'
  Object.defineProperty(LegacyController.prototype, marker,
    Object.getOwnPropertyDescriptor(GlobalVoiceController.prototype, marker))
  const { report } = setup(LegacyController)
  await assert.rejects(report({ phase: 'recording' }), { code: 'gateway/signature-invalid' })
})

test('DSH gateway delivers recording, level, reply and stop to the native overlay', {
  skip: process.platform !== 'win32', timeout: 20000
}, async (t) => {
  const { controller, report } = setup()
  const child = spawn('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-STA',
    '-File', fileURLToPath(new URL('../native/desktop-overlay.ps1', import.meta.url)),
    '-ParentPid', String(process.pid), '-StateTest'
  ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
  controller.overlay = child
  const exit = once(child, 'exit')
  t.after(async () => { child.stdin.end(); child.kill(); await exit })
  let diagnostic = ''
  child.stderr.on('data', (chunk) => { diagnostic += chunk })
  const lines = createInterface({ input: child.stdout })
  const iterator = lines[Symbol.asyncIterator]()
  const read = async (type) => {
    for (;;) {
      const item = await iterator.next()
      assert.equal(item.done, false, diagnostic || 'Overlay exited before acknowledgement')
      const event = JSON.parse(item.value)
      assert.notEqual(event.type, 'error', event.message)
      if (event.type === type) return event
    }
  }
  await read('overlay-ready')
  let revision = 0
  const send = async (state) => {
    assert.equal(await report({ ...state, revision: ++revision }), true)
    const applied = await read('state-applied')
    assert.equal(applied.revision, revision)
    assert.equal(applied.phase, state.phase)
    return applied
  }
  assert.equal((await send({ phase: 'requesting' })).waveform, false)
  const quiet = await send({ phase: 'recording', level: 0.05 })
  const loud = await send({ phase: 'recording', level: 0.85 })
  assert.equal(loud.waveform, true)
  assert.equal(loud.heights.length, 7)
  assert.ok(loud.heights[2] > quiet.heights[2], 'Wave height must follow microphone level')
  assert.equal((await send({ phase: 'transcribing', level: 0 })).waveform, false)
  const idle = await send({ phase: 'idle', level: 0, reply: '回复已经传到悬浮窗', expanded: true })
  assert.equal(idle.waveform, false)
  assert.equal(idle.reply, '回复已经传到悬浮窗')
  // Real clients include expanded/reply with every audio level report.
  // Check actual dependency-property changes, including intermediate sizes:
  // the old code shrank to 48 then grew again even when final sizes matched.
  for (let index = 0; index < 12; index++) {
    const update = await send({ phase: 'recording', level: index / 12, reply: idle.reply, expanded: true })
    assert.equal(update.waveform, true)
    assert.equal(update.height, idle.height)
    assert.deepEqual(update.heightChanges, [], 'Volume reports must not resize the expanded window')
  }
  let previousHeight = idle.height
  for (let index = 1; index <= 12; index++) {
    const reply = '连续传输中的回复内容。'.repeat(index)
    const update = await send({ phase: 'idle', reply, expanded: true })
    assert.equal(update.reply, reply)
    assert.ok(update.height >= previousHeight, 'Growing reply should not collapse the preview')
    assert.ok(update.heightChanges.length <= 1, 'Each reply chunk should resize at most once')
    assert.ok(update.heightChanges.every((height) => height > 48), 'Expanded preview must never shrink to capsule height')
    previousHeight = update.height
  }
  const collapsed = await send({ phase: 'idle', expanded: false })
  assert.equal(collapsed.height, 48)
  assert.equal(collapsed.width, 178)
  assert.equal(await report({ phase: 'recording', revision: 1 }), false, 'Stale state must not restore recording')
  assert.equal((await send({ phase: 'feedback', message: '测试错误提示' })).waveform, false)
  assert.equal((await send({ phase: 'idle' })).waveform, false)
})
