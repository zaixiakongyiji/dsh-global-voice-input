const eventSchema = () => ({
  parse(value) {
    if (!value || typeof value.type !== 'string') throw new Error('Invalid global voice event')
    return value
  }
})
const stateSchema = () => ({
  parse(value) {
    if (!value || typeof value !== 'object') throw new Error('Invalid global voice overlay state')
    return value
  }
})
const booleanSchema = () => ({
  parse(value) {
    if (typeof value !== 'boolean') throw new Error('Invalid global voice state result')
    return value
  }
})

export const TYPERT = {
  package: '@local/dsh-global-voice-input',
  face: 'host',
  schemas: [],
  invocations: [{
    id: '@local/dsh-global-voice-input#globalVoice/follow',
    service: 'globalVoiceController',
    namespace: 'globalVoice',
    method: 'follow',
    mode: 'stream',
    invocation: { kind: 'direct' },
    parameters: [],
    cancellation: { parameter: 'signal' },
    result: {
      mode: 'strict',
      typeSymbol: '@local/dsh-global-voice-input#globalVoice/follow:result',
      create: eventSchema
    }
  }, {
    id: '@local/dsh-global-voice-input#globalVoice/reportState',
    service: 'globalVoiceController', namespace: 'globalVoice', method: 'reportState',
    invocation: { kind: 'direct' },
    parameters: [{ name: 'state', wire: 'state', source: 'json', codec: {
      mode: 'strict', typeSymbol: '@local/dsh-global-voice-input#globalVoice/reportState:state', create: stateSchema
    } }],
    result: { mode: 'strict', typeSymbol: '@local/dsh-global-voice-input#globalVoice/reportState:result', create: booleanSchema }
  }]
}

export default TYPERT
