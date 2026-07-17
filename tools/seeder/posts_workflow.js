export const meta = {
  name: 'generate-bot-posts',
  description: 'Each persona writes a short post on assigned seeded topics for the boards',
  phases: [{ title: 'Write', detail: 'one Haiku agent per persona' }],
}

const PERSONAS = [
  { name: 'Horse Dentist', voice: 'deadpan equine-dental professional; relates everything to teeth, decay, maintenance; never breaks character; short flat sentences.' },
  { name: 'erowid smoothie', voice: 'all lowercase, comma splices, trip-report register applied to mundane life, sudden profundity, gentle.' },
  { name: 'DigimonOtis', voice: 'unhinged planetarium enthusiast; lateral connections to astronomy/deep sea/folklore/90s ephemera that somehow land; footnote energy.' },
  { name: 'Beef Inspector', voice: 'clipboard authority; grades everything on official-sounding scales that do not exist; calm, never says where the badge came from.' },
  { name: 'coupon warlock', voice: 'lowercase except RITUAL TERMS; speaks of deals/savings like grimoire summoning; deadly serious about discounts.' },
  { name: 'mothman apologist', voice: 'defense-attorney passion for cryptids; wistful about the night sky; cites eyewitness accounts like case law; he tried to WARN us.' },
]

const SCHEMA = {
  type: 'object',
  required: ['posts'],
  properties: {
    posts: {
      type: 'array',
      items: {
        type: 'object',
        required: ['topic', 'body'],
        properties: {
          topic: { type: 'string' },
          body: { type: 'string', description: 'the persona\'s post, 1-3 sentences' },
        },
      },
    },
  },
}

phase('Write')
const topics = typeof args === 'string' ? JSON.parse(args) : args
log(`${PERSONAS.length} personas x ${topics.length} topics`)

const results = await parallel(
  PERSONAS.map((p) => () =>
    agent(
      `You are ${p.name}, a regular on "party line". Voice: ${p.voice}

Below are discussion topics. Write ${p.name}'s POST for each — their take, answer, or hot opinion, exactly as ${p.name} would say it. This is a forum post, not chat: 1-3 sentences, in character, funny or weirdly insightful. No @-mentions, no "as ${p.name}" preamble, no quotes around it. Just the post.

Topics:
${topics.map((t, i) => `${i + 1}. ${t}`).join('\n')}

Return one post per topic, same order.`,
      { label: `post:${p.name}`, phase: 'Write', model: 'haiku', schema: SCHEMA }
    ).then((r) => ({ author: p.name, posts: r && r.posts ? r.posts : [] }))
  )
)

return { authors: results.filter(Boolean) }
