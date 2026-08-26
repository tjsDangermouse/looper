import { describe, expect, it } from 'vitest'
import { flag } from '../src/config.js'
import { DEFAULT_FLAGS } from '../src/loops/flags.js'

describe('reading an algorithm flag out of the environment', () => {
  it('turns one on only when it was asked for in so many words', () => {
    expect(flag('true', false)).toBe(true)
    expect(flag('1', false)).toBe(true)
  })

  it('turns one off when it was asked for in so many words', () => {
    expect(flag('false', true)).toBe(false)
    expect(flag('0', true)).toBe(false)
  })

  it('leaves a typo as whatever ships, rather than as an unproven algorithm', () => {
    expect(flag('yes', false)).toBe(false)
    expect(flag('TRUE', true)).toBe(false)
  })

  it('treats absent and empty the same, whichever the flag ships as', () => {
    // Compose passes a variable nobody set through as an empty string rather
    // than as nothing. Reading that as "not true, therefore false" would take
    // every flag that ships on and switch it off across a whole deployment.
    for (const shipped of [true, false]) {
      expect(flag(undefined, shipped)).toBe(shipped)
      expect(flag('', shipped)).toBe(shipped)
    }
  })

  it('leaves every flag exactly as it ships when nothing is set at all', () => {
    const asDeployed = Object.fromEntries(
      Object.entries(DEFAULT_FLAGS).map(([name, shipped]) => [name, flag('', shipped)]),
    )
    expect(asDeployed).toEqual(DEFAULT_FLAGS)
  })
})
