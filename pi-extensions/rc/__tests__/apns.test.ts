import { describe, expect, it } from 'vitest'
import {
    finishedCollapseId,
    finishedPayload,
    questionCollapseId,
    questionPayload,
} from '../apns'

// Pure payload/collapse-id builders only — no APNs network calls, no config
// file access. The builders take the session id as a parameter; sendApnsPush
// (which does the sending) is not under test here.
const SESSION_ID = '11111111-1111-4111-8111-111111111111'
const OTHER_SESSION_ID = '22222222-2222-4222-8222-222222222222'

describe('per-session collapse ids (spec Decision 9)', () => {
    it('finishedCollapseId is finished:<sessionId>', () => {
        expect(finishedCollapseId(SESSION_ID)).toBe(`finished:${SESSION_ID}`)
    })

    it('questionCollapseId is question:<sessionId>', () => {
        expect(questionCollapseId(SESSION_ID)).toBe(`question:${SESSION_ID}`)
    })

    it('different sessions get different collapse ids (no cross-session dedupe)', () => {
        expect(finishedCollapseId(SESSION_ID)).not.toBe(finishedCollapseId(OTHER_SESSION_ID))
        expect(questionCollapseId(SESSION_ID)).not.toBe(questionCollapseId(OTHER_SESSION_ID))
        // Same kind + session: the dedupe id is stable ("latest settle wins").
        expect(finishedCollapseId(SESSION_ID)).toBe(finishedCollapseId(SESSION_ID))
    })
})

describe('finished payload (wire shape)', () => {
    it('carries the custom sessionId key and thread-id == session id', () => {
        const payload = finishedPayload(SESSION_ID, 'done with 3 tests')

        expect(payload.sessionId).toBe(SESSION_ID)
        expect((payload.aps as Record<string, unknown>)['thread-id']).toBe(SESSION_ID)
        expect(payload).toEqual({
            aps: {
                alert: { title: 'Agent finished', body: 'done with 3 tests' },
                sound: 'default',
                'thread-id': SESSION_ID,
            },
            sessionId: SESSION_ID,
        })
    })
})

describe('question payload (wire shape)', () => {
    it('carries the custom sessionId key and thread-id == session id', () => {
        const payload = questionPayload(SESSION_ID, 'which branch?')

        expect(payload.sessionId).toBe(SESSION_ID)
        expect((payload.aps as Record<string, unknown>)['thread-id']).toBe(SESSION_ID)
        expect(payload).toEqual({
            aps: {
                alert: { title: 'Agent has a question', body: 'which branch?' },
                sound: 'default',
                'thread-id': SESSION_ID,
                timeSensitive: true,
            },
            sessionId: SESSION_ID,
        })
    })
})
