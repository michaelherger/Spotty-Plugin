import { Hono } from 'hono/tiny'
import { Context } from 'hono'

interface CallbackState {
    nonce: string
}

interface PrepareRequestBody {
    url: string,
    ua: string
}

interface PrepareResponsBody {
    nonce?: string
}

interface StoredState {
    url: string,
    ua: string
}

const app = new Hono()
const uaStringCheck = new RegExp(/^iTunes.*L(?:yrion|ogitech) M(?:usic|edia) Server/)

const DEFAULT_CACHE_TTL = 60 * 15
const DEFAULT_REDIRECT = 'https://lyrion.org/invalid/path'

const acceptedPaths = new Set([
    '/plugins/Spotty/settings/callback'
])

app.get('/', async (c: Context) => {
    return c.redirect('https://lyrion.org')
})

app.get('/auth/callback', async(c: Context) => {
    const uaString = c.req.header('User-Agent') as string
    const code = c.req.query('code')
    const state = c.req.query('state')

    let redirectUri;

    try {
        if (!code) throw('Missing code')
        if (!state) throw('Missing state')

        const parsedState: CallbackState = JSON.parse(atob(state))

        if (!parsedState
            || !parsedState.nonce
        ) throw('Invalid state - missing nonce')

        const storedStateBlob: string = await c.env.store.get(parsedState.nonce)
        const storedState: StoredState = JSON.parse(storedStateBlob || '{}')

        if (!storedState
            || !storedState.url
            || !storedState.ua
            || storedState.ua !== uaString
        ) throw('No stored state found or stored state does not match')

        redirectUri = storedState.url + '?code=' + code
    }
    catch(e) {
        console.error(e)
        c.status(400)
        return c.text('')
    }

    return c.redirect(redirectUri || DEFAULT_REDIRECT)
})

app.post('/auth/prepare', async (c: Context) => {
    const uaString = c.req.header('User-Agent') as string

    const responseBody: PrepareResponsBody = {}

    try {
        const body = await c.req.json() as PrepareRequestBody

        if (!uaStringCheck.test(uaString)) throw('Invalid caller UA string')
        if (!body.url || !body.ua) throw('Invalid Body')

        const redirectUri = new URL(body.url)
        console.warn(redirectUri.port, redirectUri.pathname, redirectUri.protocol, redirectUri.search, redirectUri.hash)
        if (!redirectUri
            || !redirectUri.port
            || parseInt(redirectUri.port) < 1024
            || !redirectUri.pathname
            || !acceptedPaths.has(redirectUri.pathname)
            || redirectUri.protocol !== 'http:'
            || redirectUri.search
            || redirectUri.hash
        ) throw('Invalid redirect URI')

        const uuid = crypto.randomUUID()

        await c.env.store.put(uuid, JSON.stringify({
            url: body.url,
            ua: body.ua
        } as StoredState), { expirationTtl: DEFAULT_CACHE_TTL })

        responseBody.nonce = uuid
    }
    catch(e) {
        console.error(e)
        c.status(400)
    }

    return c.json(responseBody)
})

export default app