window.__ModuleLoader__.load({
  id: '@local/dsh-global-voice-input',
  factory(require) {
    const React = require('react')
    const { useEffect, useRef, useState, useSyncExternalStore } = React

const TYPERT_REMOTE = {
  package: '@local/dsh-global-voice-input',
  descriptors: [{
    id: '@local/dsh-global-voice-input#globalVoice/follow',
    service: 'globalVoiceController', namespace: 'globalVoice', method: 'follow', mode: 'stream',
    invocation: { kind: 'direct' }, parameters: [], cancellation: { parameter: 'signal' },
    result: { mode: 'strict', typeSymbol: '@local/dsh-global-voice-input#globalVoice/follow:result', create: () => ({
      parse(value) {
        if (!value || typeof value.type !== 'string') throw new Error('Invalid global voice event')
        return value
      }
    }) }
  }, {
    id: '@local/dsh-global-voice-input#globalVoice/reportState',
    service: 'globalVoiceController', namespace: 'globalVoice', method: 'reportState',
    invocation: { kind: 'direct' },
    parameters: [{ name: 'state', wire: 'state', source: 'json', codec: {
      mode: 'strict', typeSymbol: '@local/dsh-global-voice-input#globalVoice/reportState:state',
      create: () => ({ parse(value) { if (!value || typeof value !== 'object') throw new Error('Invalid overlay state'); return value } })
    } }],
    result: { mode: 'strict', typeSymbol: '@local/dsh-global-voice-input#globalVoice/reportState:result', create: () => ({
      parse(value) { if (typeof value !== 'boolean') throw new Error('Invalid overlay state result'); return value }
    }) }
  }]
}


    const NS = 'global-voice-input'
    const DEFAULT_SILENCE_MS = 1200
    const MIN_SPEECH_MS = 300
    const NO_SPEECH_TIMEOUT_MS = 5000
    const DEFAULT_MAX_DURATION_MS = 60000
    
    const zh = {
      ready: '按一次 Ctrl+Alt+Space 开始语音输入',
      requesting: '正在请求麦克风…',
      recording: '正在录音',
      transcribing: '正在转写…',
      waiting: '当前会话正在运行，语音输入已排队',
      unavailable: '当前会话不可用，未创建新会话',
      model: '语音模型尚未就绪，请先在语音输入设置中准备模型',
      empty: '没有识别到语音',
      microphone: '麦克风不可用或权限被拒绝',
      conflict: '草稿已变化，转写结果未自动发送',
      failed: '语音输入失败：{message}',
      helper: '全局快捷键不可用：{message}',
      textInput: '打开文字输入',
      textPlaceholder: '输入到当前 Session',
      send: '发送',
      expandReply: '展开回复',
      collapseReply: '收起回复',
      start: '开始语音输入',
      cancel: '取消语音输入'
    }
    
    function createSnapshot(initial) {
      let value = initial
      const listeners = new Set()
      return {
        get: () => value,
        set(next) { value = next; for (const listener of listeners) listener(value) },
        subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener) }
      }
    }
    
    function rms(analyser, buffer) {
      analyser.getByteTimeDomainData(buffer)
      let sum = 0
      for (const value of buffer) { const centered = (value - 128) / 128; sum += centered * centered }
      return Math.sqrt(sum / buffer.length)
    }
    
    function writeWav(samples, sampleRate) {
      // Emit the exact 44-byte PCM WAV layout expected by remote.speech.
      // Keep all values integral and finite so the decoder cannot reject the
      // payload as a non-canonical recording.
      const channels = 1
      const bitsPerSample = 16
      const blockAlign = channels * bitsPerSample / 8
      const dataSize = samples.length * blockAlign
      const bytes = new ArrayBuffer(44 + dataSize)
      const view = new DataView(bytes)
      const text = (offset, value) => { for (let i = 0; i < value.length; i++) view.setUint8(offset + i, value.charCodeAt(i)) }
      text(0, 'RIFF')
      view.setUint32(4, 36 + dataSize, true)
      text(8, 'WAVE')
      text(12, 'fmt ')
      view.setUint32(16, 16, true)
      view.setUint16(20, 1, true)
      view.setUint16(22, channels, true)
      view.setUint32(24, sampleRate, true)
      view.setUint32(28, sampleRate * blockAlign, true)
      view.setUint16(32, blockAlign, true)
      view.setUint16(34, bitsPerSample, true)
      text(36, 'data')
      view.setUint32(40, dataSize, true)
      for (let index = 0; index < samples.length; index++) {
        const value = Number.isFinite(samples[index]) ? Math.max(-1, Math.min(1, samples[index])) : 0
        const pcm = value < 0 ? Math.round(value * 0x8000) : Math.round(value * 0x7fff)
        view.setInt16(44 + index * 2, pcm, true)
      }
      return new Uint8Array(bytes)
    }
    
    function base64(bytes) {
      let binary = ''
      const step = 0x8000
      for (let offset = 0; offset < bytes.length; offset += step) binary += String.fromCharCode(...bytes.subarray(offset, offset + step))
      return btoa(binary)
    }
    
    class BrowserRecording {
      constructor(options = {}) {
        this.stream = undefined
        this.samples = []
        this.sampleRate = 48000
        this.processor = undefined
        this.interval = undefined
        this.stopTimer = undefined
        this.startedAt = 0
        this.speechAt = 0
        this.silentAt = 0
        this.stopPromise = undefined
        this.silenceMs = options.silenceMs ?? DEFAULT_SILENCE_MS
        this.maxDurationMs = options.maxDurationMs ?? DEFAULT_MAX_DURATION_MS
        this.onLevel = options.onLevel
        this.finishedPromise = new Promise((resolve, reject) => {
          this.resolveFinished = resolve
          this.rejectFinished = reject
        })
      }
    
      async start(onFailure) {
        try {
          if (!navigator.mediaDevices?.getUserMedia) throw new Error('media devices unavailable')
          this.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
          this.startedAt = performance.now()
          const context = new AudioContext()
          await context.resume().catch(() => {})
          const source = context.createMediaStreamSource(this.stream)
          const analyser = context.createAnalyser()
          analyser.fftSize = 1024
          source.connect(analyser)
          const processor = context.createScriptProcessor(4096, 1, 1)
          const sink = context.createGain()
          sink.gain.value = 0
          processor.onaudioprocess = (event) => {
            const channel = event.inputBuffer.getChannelData(0)
            this.samples.push(new Float32Array(channel))
          }
          source.connect(processor)
          processor.connect(sink)
          sink.connect(context.destination)
          this.processor = processor
          this.sampleRate = context.sampleRate
          this.analyser = analyser
          this.audioContext = context
          const buffer = new Uint8Array(analyser.fftSize)
          this.interval = setInterval(() => {
            const now = performance.now()
            const level = rms(analyser, buffer)
            this.onLevel?.(Math.min(1, level * 7))
            if (level >= 0.035) { this.speechAt ||= now; this.silentAt = 0 }
            else if (this.speechAt) { this.silentAt ||= now; if (now - this.silentAt >= this.silenceMs && now - this.speechAt >= MIN_SPEECH_MS) this.stop() }
            else if (now - this.startedAt >= NO_SPEECH_TIMEOUT_MS) this.stop()
            if (now - this.startedAt >= this.maxDurationMs) this.stop()
          }, 100)
        } catch (error) {
          await this.dispose()
          this.onLevel?.(0)
          onFailure?.(error)
          throw error
        }
      }
    
      async stop() {
        if (this.stopPromise) return this.stopPromise
        this.stopPromise = this.finish().then((audio) => {
          this.resolveFinished?.(audio)
          return audio
        }, (error) => {
          this.rejectFinished?.(error)
          throw error
        })
        return this.stopPromise
      }

      waitForStop() {
        return this.finishedPromise
      }

      cancel() {
        this.resolveFinished?.(new Uint8Array())
        return this.dispose()
      }
    
      async finish() {
        clearInterval(this.interval); this.interval = undefined
        clearTimeout(this.stopTimer)
        this.onLevel?.(0)
        try {
          const source = new Float32Array(this.samples.reduce((total, chunk) => total + chunk.length, 0))
          let offset = 0
          for (const chunk of this.samples) { source.set(chunk, offset); offset += chunk.length }
          const length = Math.max(1, Math.ceil(source.length * 16000 / this.sampleRate))
          const samples = new Float32Array(length)
          for (let i = 0; i < length; i++) {
            const sourceIndex = Math.min(source.length - 1, Math.floor(i * this.sampleRate / 16000))
            samples[i] = source[sourceIndex] || 0
          }
          return writeWav(samples, 16000)
        } finally {
          await this.dispose()
        }
      }
    
      async dispose() {
        clearInterval(this.interval); this.interval = undefined
        clearTimeout(this.stopTimer)
        this.processor?.disconnect()
        this.processor = undefined
        this.stream?.getTracks().forEach((track) => track.stop())
        this.stream = undefined
        await this.audioContext?.close().catch(() => {})
        this.audioContext = undefined
      }
    }
    
    function interpolate(text, values) { return text.replace(/\{(\w+)\}/g, (_, key) => values[key] ?? '') }

    function assistantText(event) {
      if (event?.type === 'assistant/live-chunk') {
        const chunk = event.data?.chunk
        if (chunk?.type === 'text-delta') return chunk.text || ''
        // block-end repeats the accumulated text; only deltas append to it.
        return ''
      }
      if (event?.type === 'assistant/message') {
        const content = event.data?.message?.content
        if (!Array.isArray(content)) return ''
        return content.filter((block) => block?.kind === 'text' || block?.type === 'text').map((block) => block.text || '').join('')
      }
      return ''
    }

    function isReplyEvent(event) {
      return event?.type === 'assistant/live-chunk' || event?.type === 'assistant/message'
    }

    // Notifications are per reply, not per text delta. History replacement and
    // pagination only hydrate the preview; they never create unread items.
    function createReplySource(sessionId, isViewing) {
      const source = createSnapshot({ text: '' })
      source.items = []
      let revision = -1
      let running = false
      const seen = new Set()
      const publish = (text = source.get().text) => source.set({ text })
      source.setRunning = (next) => {
        if (running === next) return
        running = next
        if (next && !source.items.some(item => item.state === 'streaming')) {
          source.items.push({ id: `${sessionId}:waiting`, text: '', state: 'streaming',
            unread: !isViewing(), receivedAt: Date.now() })
        } else if (!next) {
          source.items = source.items.filter(item => item.state !== 'streaming')
        }
        publish()
      }
      source.clearPreview = () => publish('')
      source.markRead = () => {
        if (!source.items.some(item => item.unread)) return
        source.items = source.items.map(item => ({ ...item, unread: false }))
        publish()
      }
      source.consume = (snapshot) => {
        if (!snapshot || revision === snapshot.revision) return
        const initial = revision === -1
        revision = snapshot.revision
        const change = snapshot.change
        const history = initial || change?.kind === 'replace' || change?.kind === 'prepend'
        const rows = initial ? (snapshot.entries || change?.entries || [])
          : change?.entries || (change?.entry ? [change.entry] : [])
        let text = source.get().text
        if (change?.kind === 'settle-assistant' && !change.entry) {
          source.items = source.items.filter(item => item.attemptId !== change.attemptId)
        }
        for (const row of rows) {
          const event = row.event || row
          if (event.type === 'user/message') { if (change?.kind !== 'prepend') text = ''; continue }
          if (!isReplyEvent(event)) continue
          const final = event.type === 'assistant/message'
          const body = assistantText(event)
          const attemptId = event.data?.attemptId || change?.attemptId || 'current'
          const turn = event.data?.turn
          const step = event.data?.step
          // Durable assistant/message has turn + step, but no attemptId.
          // Match those fields before replacing the transient attempt.
          const pending = source.items.find(item => item.state === 'streaming' && (
            item.attemptId === attemptId || (turn !== undefined && step !== undefined && item.turn === turn && item.step === step)))
          const pendingId = pending?.id || `${sessionId}:live:${attemptId}`
          if (final) {
            const messageId = event.data?.message?.id || event.seq || row.id || event.id
            const id = `${sessionId}:${messageId ?? `revision:${revision}`}`
            if (seen.has(id)) continue
            seen.add(id)
            if (change?.kind !== 'prepend') text = body
            if (!history) source.items = source.items.filter(item => item.id !== pendingId && item.id !== `${sessionId}:waiting`)
            if (body.trim() && !history) source.items.push({
              id, text: body.slice(0, 4000), state: 'done', unread: !isViewing(), receivedAt: Date.now()
            })
          } else {
            text = (pending?.text || '') + body
            if (!history) {
              const item = { id: pendingId, attemptId, turn, step, text: text.slice(-4000), state: 'streaming',
                unread: pending ? pending.unread : !isViewing(), receivedAt: pending?.receivedAt || Date.now() }
              source.items = source.items.filter(item => item.id !== pendingId && item.id !== `${sessionId}:waiting`)
              source.items.push(item)
            }
          }
        }
        source.items = source.items.slice(-20)
        publish(text)
      }
      return source
    }
    
    function VoiceInput({ sessionId, inputActions, locked, onActiveChange, controller }) {
      const [phase, setPhase] = useState('idle')
      const [message, setMessage] = useState('')
      const [level, setLevel] = useState(0)
      const config = useSyncExternalStore(controller.settingsSource.subscribe, controller.settingsSource.get)
      const active = useRef(undefined)
      const queued = useRef(false)
      const actionsRef = useRef(inputActions)
      const lockedRef = useRef(locked)
      const phaseRef = useRef(phase)
      actionsRef.current = inputActions
      lockedRef.current = locked
      phaseRef.current = phase
    
      const stop = () => {
        const run = active.current
        if (!run) return
        run.abort.abort()
        void run.capture.cancel()
        active.current = undefined
        setPhase('idle'); setMessage('')
      }
    
      const run = async () => {
        if (active.current) return
        if (lockedRef.current) { queued.current = true; setPhase('waiting'); setMessage(zh.waiting); return }
        if (!controller.isSpeechReady()) { setPhase('feedback'); setMessage(zh.model); return }
        if (!actionsRef.current?.captureInsertion || typeof actionsRef.current.insertText !== 'function' || typeof actionsRef.current.submit !== 'function') {
          setPhase('feedback'); setMessage(zh.unavailable); return
        }
        queued.current = false
        const capture = new BrowserRecording({ ...controller.settings(), onLevel: setLevel })
        const abort = new AbortController()
        const span = actionsRef.current.captureInsertion()
        const current = { capture, abort }
        active.current = current
        setMessage(''); setPhase('requesting')
        try {
          await capture.start((error) => setMessage(interpolate(zh.failed, { message: error.message })))
          if (abort.signal.aborted) return
          setPhase('recording')
          // Recording ends when the silence detector (or the duration limit)
          // calls stop(). Do not stop immediately after getUserMedia resolves.
          const audio = await capture.waitForStop()
          setLevel(0)
          if (abort.signal.aborted) return
          setPhase('transcribing')
          const result = await controller.transcribe({ audioBase64: base64(audio), ...controller.selection() }, abort.signal)
          if (!result?.ok) throw result?.error || new Error('transcription failed')
          const text = result.value?.text?.trim() || ''
          if (!text) { setPhase('feedback'); setMessage(zh.empty); return }
          if (!actionsRef.current.insertText(text, span)) { setPhase('feedback'); setMessage(zh.conflict); return }
          controller.clearReply(sessionId)
          if (controller.settings().autoSubmit !== false) actionsRef.current.submit()
          setPhase('idle')
        } catch (error) {
          setLevel(0)
          if (!abort.signal.aborted) { setPhase('feedback'); setMessage(error?.name === 'NotAllowedError' ? zh.microphone : interpolate(zh.failed, { message: error?.message || String(error) })) }
        } finally {
          setLevel(0)
          if (active.current === current) active.current = undefined
        }
      }

      // A global shortcut arrives through the Remote stream and can be handled
      // before React has committed the next render. Set the visible phase at
      // the edge of the trigger so the desktop overlay responds immediately.
      const announceTrigger = () => {
        if (active.current || ['requesting', 'recording', 'transcribing', 'waiting'].includes(phaseRef.current)) return false
        setMessage('')
        setPhase('requesting')
        return true
      }
    

      useEffect(() => {
        if (phase !== 'feedback') return
        const timer = setTimeout(() => { setPhase('idle'); setMessage('') }, 5000)
        return () => clearTimeout(timer)
      }, [phase])

      useEffect(() => {
        onActiveChange?.(phase !== 'idle')
        return () => onActiveChange?.(false)
      }, [phase, onActiveChange])
    
      useEffect(() => {
        const unregister = controller.register(sessionId, {
          trigger: run,
          announceTrigger,
          cancel: stop,
          voice: () => phaseRef.current === 'idle' || phaseRef.current === 'feedback' ? run() : stop(),
          openInput: () => setInputOpen(true),
          toggleReply: () => setExpanded((value) => !value),
          submitText,
          isCurrent: () => !lockedRef.current
        })
        return () => { unregister(); stop() }
      }, [controller, sessionId])
    
      useEffect(() => {
        if (!locked && queued.current) void run()
      }, [locked])
    
      const reply = controller.reply(sessionId)
      const replySnapshot = useSyncExternalStore(reply.subscribe, reply.get)
      const replyText = replySnapshot.text
      const notificationVersion = useSyncExternalStore(controller.notificationSource.subscribe, controller.notificationSource.get)
      const [expanded, setExpanded] = useState(false)
      const [inputOpen, setInputOpen] = useState(false)
      const [draft, setDraft] = useState('')
      const icon = phase === 'recording' ? '◉' : phase === 'requesting' ? '…' : phase === 'transcribing' ? '⟳' : phase === 'feedback' ? '!' : '⌁'
      const submitText = (externalValue) => {
        const value = String(externalValue ?? draft).trim()
        if (!value || !actionsRef.current?.insertText || !actionsRef.current?.submit) return
        const span = actionsRef.current.captureInsertion?.()
        if (span && actionsRef.current.insertText(value, span)) actionsRef.current.submit()
        setDraft(''); setInputOpen(false)
      }
      useEffect(() => {
        void controller.reportState(sessionId, {
          phase, level, message, reply: replyText, expanded,
          showReplyPreview: config.showReplyPreview !== false
        })
      }, [controller, sessionId, phase, level, message, replyText, notificationVersion, expanded, config.showReplyPreview])
      // The composer slot is retained as an invisible controller only. All
      // user-facing controls live in the desktop overlay; rendering any DOM
      // here duplicates the native DSH composer and can leave a stale reply
      // preview inside the conversation page.
      return React.createElement(React.Fragment, null)
    }
    
    const CONFIG_FIELDS = [
      ['enabled', '启用全局语音输入', 'checkbox'],
      ['hotkey', '全局快捷键', 'hotkey'],
      ['silenceMs', '静音结束时间（毫秒）', 'number', 300, 5000],
      ['maxDurationMs', '最长录音时间（毫秒）', 'number', 5000, 300000],
      ['autoSubmit', '转写后自动发送', 'checkbox'],
      ['showOverlay', '显示桌面置顶悬浮窗', 'checkbox'],
      ['showReplyPreview', '允许展开回复预览', 'checkbox']
    ]

    function eventHotkeyKey(event) {
      if (event.code === 'Space' || event.key === ' ') return 'Space'
      if (/^F(?:[1-9]|1[0-2])$/i.test(event.key)) return event.key.toUpperCase()
      if (/^[a-z]$/i.test(event.key)) return event.key.toUpperCase()
      if (/^[0-9]$/.test(event.key)) return event.key
      if (/^Key[A-Z]$/.test(event.code)) return event.code.slice(3).toUpperCase()
      if (/^Digit[0-9]$/.test(event.code)) return event.code.slice(5)
      if (/^F(?:[1-9]|1[0-2])$/i.test(event.code)) return event.code.toUpperCase()
      return ''
    }

    function HotkeyCapture({ value, disabled, onChange }) {
      const [listening, setListening] = useState(false)
      const capture = (event) => {
        event.preventDefault()
        event.stopPropagation()
        if (event.key === 'Escape') { setListening(false); return }
        if (event.key === 'Control' || event.key === 'Alt' || event.key === 'Shift' || event.key === 'Meta') return
        const key = eventHotkeyKey(event)
        if (!key) return
        const modifiers = []
        if (event.ctrlKey) modifiers.push('Ctrl')
        if (event.altKey) modifiers.push('Alt')
        if (event.shiftKey) modifiers.push('Shift')
        if (event.metaKey) modifiers.push('Win')
        if (!modifiers.length) return
        onChange([...modifiers, key].join('+'))
        setListening(false)
      }
      return React.createElement('button', {
        type: 'button', disabled, 'aria-pressed': listening,
        'aria-label': listening ? '请按下快捷键，按 Esc 取消' : `当前快捷键：${value || '未设置'}`,
        onClick: () => setListening(true), onKeyDown: capture,
        style: { width: 250, minHeight: 34, padding: '7px 10px', borderRadius: 8,
          border: `1px solid ${listening ? 'var(--dsw-alias-state-info-primary)' : 'var(--dsw-alias-border-l2)'}`,
          background: listening ? 'var(--dsw-alias-bg-layer-2)' : 'var(--dsw-alias-bg-layer-1)',
          color: 'inherit', textAlign: 'left', cursor: disabled ? 'default' : 'pointer' }
      }, listening ? '请按下快捷键（Esc 取消）' : (value || '点击设置快捷键'))
    }

    function VoiceSettings({ form }) {
      const snapshot = useSyncExternalStore(form.subscribe, form.getSnapshot)
      const [draft, setDraft] = useState(null)
      const [saving, setSaving] = useState(false)
      const [notice, setNotice] = useState('')
      const baseline = useRef(null)
      const value = draft || snapshot.value || {}
      const editable = snapshot.status === 'ready' && snapshot.writable && !saving
      const edit = (key, next) => {
        if (!draft) baseline.current = { revision: snapshot.revision, value: snapshot.value }
        setDraft({ ...value, [key]: next }); setNotice('')
      }
      const save = async (event) => {
        event.preventDefault()
        if (!editable || !draft) return
        const hotkey = String(draft.hotkey).trim()
        if (!/^(?:(?:Ctrl|Control|Alt|Shift|Win|Windows|Meta)\+)+(?:Space|[A-Z0-9]|F(?:[1-9]|1[0-2]))$/i.test(hotkey)) {
          setNotice('快捷键格式示例：Ctrl+Alt+Space、Ctrl+Shift+V。'); return
        }
        const next = { ...draft, hotkey }
        for (const [key, label, type, min, max] of CONFIG_FIELDS) {
          if (type !== 'number') continue
          next[key] = Number(next[key])
          if (!Number.isInteger(next[key]) || next[key] < min || next[key] > max) {
            setNotice(`${label}应在 ${min} 到 ${max} 之间。`); return
          }
        }
        setSaving(true); setNotice('')
        try {
          const ops = CONFIG_FIELDS.filter(([key]) => next[key] !== baseline.current.value[key]).map(([key]) => ({ op: 'set', path: [key], value: next[key] }))
          const ok = !ops.length || await form.mutate(ops, baseline.current.revision)
          if (ok) { setDraft(null); setNotice('已保存，配置已生效。') }
          else { setDraft(null); setNotice('保存失败或配置已变化，已重新读取，请重试。') }
        } catch (error) { setNotice(`保存失败：${error.message || error}`) }
        finally { setSaving(false) }
      }
      return React.createElement('form', { onSubmit: save, style: { display: 'grid', gap: 16, maxWidth: 540, color: 'var(--dsw-alias-label-primary)' } },
        React.createElement('h3', { style: { margin: 0 } }, '全局语音输入设置'),
        React.createElement('p', { style: { margin: 0, fontSize: 13 } }, '悬浮窗显示在主屏幕右下角。点击快捷键按钮后按下组合键，Esc 可取消本次修改。快捷键按一次开始录音，静音后结束。'),
        snapshot.status !== 'ready' && React.createElement('p', { role: 'status' }, '正在等待插件配置，请确认插件组件已启用。'),
        CONFIG_FIELDS.map(([key, label, type, min, max]) => React.createElement('label', { key, style: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 16, fontSize: 14 } }, label,
          type === 'hotkey' ? React.createElement(HotkeyCapture, { value: value[key] ?? '', disabled: !editable, onChange: (next) => edit(key, next) }) :
          React.createElement('input', { type, min, max, step: type === 'number' ? 1 : undefined, disabled: !editable,
            ...(type === 'checkbox' ? { checked: Boolean(value[key]) } : { value: value[key] ?? '' }),
            onChange: (event) => edit(key, type === 'checkbox' ? event.target.checked : event.target.value),
            style: type === 'checkbox' ? { width: 18, height: 18 } : { width: 190, padding: '7px 9px', borderRadius: 8, border: '1px solid var(--dsw-alias-border-l2)', background: 'var(--dsw-alias-bg-layer-1)', color: 'inherit' }
          }))),
        React.createElement('div', { style: { display: 'flex', gap: 12 } },
          React.createElement('button', { type: 'submit', disabled: !editable || !draft }, saving ? '正在保存…' : '保存设置'),
          React.createElement('button', { type: 'button', disabled: saving || !draft, onClick: () => { setDraft(null); setNotice('') } }, '放弃修改')),
        notice && React.createElement('p', { role: 'status' }, notice))
    }

    function registerSettings(ctx) {
      const source = ctx.configForms.get('global-voice-input')
      const form = { subscribe: (fn) => source.subscribe(fn), getSnapshot: () => source.getSnapshot(), mutate: (ops, revision) => source.mutate(ops, revision) }
      ctx.effect(() => ctx.slots.inject('plugins.bundle.config', () => ctx.slots.register({
        name: 'plugins.bundle.config', key: '@local/dsh-global-voice-input', locale: NS, inject: () => ({ form })
      }, VoiceSettings)))
    }

    function registerUi(ctx, remoteGlobal, remoteSpeech, uiWorkspace) {
      const readiness = createSnapshot(null)
      const entries = new Map()
      const settings = createSnapshot({ silenceMs: DEFAULT_SILENCE_MS, maxDurationMs: DEFAULT_MAX_DURATION_MS, autoSubmit: true, showOverlay: true, showReplyPreview: true })
      const replies = new Map()
      const notifications = createSnapshot(0)
      let latest = undefined
      let lastTrigger = ''
      let lastTriggerAt = 0
      let overlayRevision = Date.now()
      let overlayReportFailed = false
      let disposed = false
      let lastOverlayState = { phase: 'idle', expanded: false }
      let notificationScheduled = false
      const watches = new Map()
      const isViewing = (id) => uiWorkspace.selection.getSnapshot().sessionId === id
        && watches.get(id)?.ready === true
        && document.visibilityState === 'visible' && document.hasFocus()
      const controller = {
        register(id, entry) {
          entries.set(id, entry); latest = id
          observeSession(id)
          return () => { if (entries.get(id) === entry) entries.delete(id); if (latest === id) latest = [...entries.keys()].at(-1) }
        },
        isSpeechReady() {
          const catalog = readiness.get(); const provider = catalog?.providers?.find((item) => item.id === catalog.selection?.providerId)
          return Boolean(provider && ['ready', 'standby', 'waking'].includes(provider.preparation?.phase))
        },
        settingsSource: settings,
        settings() { return settings.get() || {} },
        notificationSource: notifications,
        notificationItems() {
          const summaries = ctx.sessions.list?.getSnapshot?.()?.byId || {}
          return [...replies.entries()].flatMap(([sessionId, source]) => source.items
            // Keep an active streaming reply visible even when the user is
            // already viewing that Session (which intentionally makes it
            // read immediately). Completed read replies stay hidden.
            .filter((item) => item.unread || item.state === 'streaming')
            .map((item) => ({ id: item.id, text: item.text, state: item.state,
              unread: item.unread, receivedAt: item.receivedAt, sessionId,
              title: summaries[sessionId]?.displayTitle || summaries[sessionId]?.title || `Session ${sessionId.slice(0, 8)}`
            }))).sort((a, b) => a.receivedAt - b.receivedAt).slice(-20)
        },
        reply(sessionId) {
          let source = replies.get(sessionId)
          if (source) return source
          source = createReplySource(sessionId, () => isViewing(sessionId))
          replies.set(sessionId, source)
          source.subscribe(() => notifications.set(notifications.get() + 1))
          return source
        },
        clearReply(sessionId) { replies.get(sessionId)?.clearPreview() },
        markReplyRead(sessionId) { replies.get(sessionId)?.markRead() },
        openReply(sessionId) {
          if (!sessionId || !ctx.sessions.list.getSnapshot().byId[sessionId]) return
          // Navigation completion/foreground observation marks it read, never
          // the click itself: a rejected or deleted target must stay unread.
          uiWorkspace.openSession(sessionId)
        },
        selection() { const catalog = readiness.get(); return catalog?.selection || {} },
        transcribe(request, signal) { return remoteSpeech.transcribe(request, signal) },
        async reportState(sessionId, state) {
          if (disposed) return false
          const selected = uiWorkspace.selection.getSnapshot().sessionId
          if (sessionId && selected && sessionId !== selected) return false
          lastOverlayState = { ...lastOverlayState, ...state, sessionId }
          const replies = controller.notificationItems()
          try {
            // Remote calls resolve to { ok, value/error }; RPC failures do
            // not reject the promise and must be checked explicitly.
            const result = await remoteGlobal.reportState({ ...lastOverlayState, replies, replyCount: replies.length, replyUnread: replies.filter(item => item.state === 'done' && item.unread).length, revision: ++overlayRevision })
            if (!result?.ok) throw result?.error || new Error('No overlay state response')
            overlayReportFailed = false
            return result.value
          } catch (error) {
            if (!overlayReportFailed) console.error('[global-voice-input] 悬浮窗状态同步失败', error)
            overlayReportFailed = true
            return false
          }
        }
      }
    
      function observeSession(id) {
        if (!id || watches.has(id) || disposed) return
        // Retain the event feed when leaving a generating Session. Merely
        // borrowing binding() would lose it as soon as the main view releases.
        watches.set(id, {})
        try {
          const reference = ctx.sessions.retain(id, { source: 'globalVoiceNotifications' })
          const source = controller.reply(id)
          const feed = reference.binding.eventSource
          const consume = () => source.consume(feed.getSnapshot())
          const unsubscribe = feed.subscribe(consume)
          const watch = { reference, unsubscribe, ready: false }
          watches.set(id, watch)
          consume()
          reference.ready.then(() => {
            if (disposed || watches.get(id) !== watch) return
            watch.ready = true
            if (isViewing(id)) controller.markReplyRead(id)
          }).catch((error) => console.warn('[global-voice-input] 回复订阅失败', error))
        } catch (error) {
          watches.delete(id)
          console.warn('[global-voice-input] 回复订阅失败', error)
        }
      }
      function syncCatalog() {
        if (disposed) return
        const catalog = ctx.sessions.list.getSnapshot()
        for (const id of catalog.ids || []) {
          if (catalog.byId[id]?.running) observeSession(id)
          replies.get(id)?.setRunning(Boolean(catalog.byId[id]?.running))
        }
        if (catalog.phase === 'ready') {
          for (const [id, watch] of watches) {
            if (catalog.byId[id]) continue
            watches.delete(id)
            watch.unsubscribe?.()
            watch.reference?.release()
            replies.delete(id)
          }
        }
        notifications.set(notifications.get() + 1)
      }
      function readVisible() {
        const id = uiWorkspace.selection.getSnapshot().sessionId
        observeSession(id)
        if (isViewing(id)) controller.markReplyRead(id)
      }
      const stopCatalog = ctx.sessions.list.subscribe(syncCatalog)
      const stopSelection = uiWorkspace.selection.subscribe(readVisible)
      const stopNotifications = notifications.subscribe(() => {
        // Collapse repeated synchronous catalog/feed notifications into one
        // report after the snapshot mutation is complete.
        if (notificationScheduled) return
        notificationScheduled = true
        queueMicrotask(() => {
          notificationScheduled = false
          void controller.reportState(uiWorkspace.selection.getSnapshot().sessionId, lastOverlayState)
        })
      })
      window.addEventListener('focus', readVisible)
      document.addEventListener('visibilitychange', readVisible)
      syncCatalog()
      readVisible()

      const stream = ctx.remote.$stream({
        name: 'Global voice shortcut',
        open: (signal) => remoteGlobal.follow(signal),
        ended: () => new Error('Global voice stream ended'),
        carrierFailed: (error) => readiness.set({ error: error?.message || String(error) })
      })
      const observing = (async () => {
        try {
          for await (const item of stream) {
            const event = item.value
            if (event.type === 'ready' && ('silenceMs' in event || 'maxDurationMs' in event || 'autoSubmit' in event || 'showOverlay' in event || 'showReplyPreview' in event)) settings.set({
              silenceMs: event.silenceMs ?? DEFAULT_SILENCE_MS,
              maxDurationMs: event.maxDurationMs ?? DEFAULT_MAX_DURATION_MS,
              autoSubmit: event.autoSubmit !== false,
              showOverlay: event.showOverlay !== false,
              showReplyPreview: event.showReplyPreview !== false
            })
            if (event.type === 'overlay-action') {
              const target = entries.get(latest) || [...entries.values()].at(-1)
              if (event.action === 'voice') target?.voice?.()
              else if (event.action === 'openInput') target?.openInput?.()
              else if (event.action === 'toggleReply') target?.toggleReply?.()
              else if (event.action === 'openReply') controller.openReply(event.sessionId)
              else if (event.action === 'submitText' && typeof event.text === 'string') target?.submitText?.(event.text)
            } else if (event.type === 'trigger' && event.id !== lastTrigger) {
              lastTrigger = event.id
              const now = Date.now()
              // Windows may deliver repeated WM_HOTKEY notifications while
              // the key combination is held. Treat the shortcut as a single
              // edge so one recording cannot be restarted by key repeat.
              if (now - lastTriggerAt < 1000) { item.accept(); continue }
              lastTriggerAt = now
              const targetId = entries.has(latest) ? latest : [...entries.keys()].at(-1)
              const target = entries.get(targetId)
              if (target?.announceTrigger?.()) void controller.reportState(targetId, { phase: 'requesting', message: '' })
              target?.trigger()
            } else if (event.type === 'error') readiness.set({ error: event.message })
            item.accept()
          }
        } catch (error) { if (!disposed) readiness.set({ error: error?.message || String(error) }) }
      })()
    
      const speechStream = ctx.remote.$stream({
        name: 'Speech readiness for global voice',
        open: (signal) => remoteSpeech.follow(signal),
        ended: () => new Error('Speech readiness stream ended'),
        carrierFailed: (error) => readiness.set({ error: error?.message || String(error) })
      })
      const observingSpeech = (async () => {
        try { for await (const item of speechStream) { readiness.set(item.value); item.accept() } } catch {}
      })()
    
      ctx.effect(() => ctx.locale.register(NS, { zh, en: zh }))
      ctx.effect(() => ctx.slots.inject('conversation.input.dock', () => ctx.slots.register({
        name: 'conversation.input.dock',
        id: 'global-voice-input',
        order: 30,
        locale: NS,
        inject: (sessionId) => {
          const actx = ctx.sessions.scope(sessionId)
          if (!actx) return { sessionId, inputActions: undefined, locked: true, controller }
          const conversation = actx.get('conversation')
          const input = conversation?.input?.for(actx)
          return { sessionId, inputActions: input?.actions, locked: false, controller }
        }
      }, VoiceInput)))
      return async () => {
        disposed = true
        stopCatalog(); stopSelection(); stopNotifications()
        window.removeEventListener('focus', readVisible)
        document.removeEventListener('visibilitychange', readVisible)
        for (const watch of watches.values()) { watch.unsubscribe?.(); watch.reference?.release() }
        watches.clear()
        await Promise.allSettled([stream.dispose?.(), speechStream.dispose?.(), observing, observingSpeech])
        for (const entry of entries.values()) entry.cancel?.()
        entries.clear()
        for (const reply of replies.values()) reply.disposeReply?.()
        replies.clear()
      }
    }
    
    const inject = ['remote', 'slots', 'locale', 'sessions', 'conversation', 'configForms']
    
    async function apply(ctx) {
      const disposeRemote = await ctx.remote.$mount(TYPERT_REMOTE)
      const settingsUi = ctx.inject(['configForms', 'slots'], registerSettings)
      const ui = ctx.inject(['remote.globalVoice', 'remote.speech', 'slots', 'locale', 'sessions', 'conversation', 'uiWorkspace'], (inner) => registerUi(inner, inner.remote.globalVoice, inner.remote.speech, inner.uiWorkspace))
      try { await ui } catch (error) { await ui.dispose(); await disposeRemote(); throw error }
      return async () => { await settingsUi.dispose(); await ui.dispose(); await disposeRemote() }
    }
    
        return { inject, apply }
  }
})





