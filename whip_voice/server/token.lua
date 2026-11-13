-- ============================================
-- whip_voice — voice server tokens and random voice identities
-- ============================================
--
-- The voice server (LiveKit) lets a player in only with a "token": a short note saying who they are
-- and what they may do, signed with the secret from server.cfg so it cannot be forged or edited (a
-- JWT signed HS256, which is HMAC-SHA256). SHA-256 and HMAC are written out below in plain Lua. They
-- were a JavaScript file once, and any JavaScript in a resource has FXServer enter it every server
-- frame whether it has work or not (about 0.4 ms a second, for a token every few minutes).
--
--   VoiceToken.sign(claims, ttl)   a signed token, or nil when server.cfg has no key or secret
--   VoiceToken.randomId()          16 hex characters nobody can guess
--
-- SERVER ONLY, and not exported: nothing outside whip_voice can sign. The secret never leaves here.

VoiceToken = {}

-- ============================================
-- SHA-256 (FIPS 180-4) and HMAC (RFC 2104), on Lua 5.4's 64-bit integers kept to 32 bits
-- ============================================

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local M32 = 0xffffffff

local function rrot(x, n)
    return ((x >> n) | (x << (32 - n))) & M32
end

--- The 32-byte digest of `msg`, as a binary string.
local function sha256(msg)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    -- Padding: a 1 bit, zeros to 56 bytes past a block boundary, the length in bits as 8 bytes.
    local bits = #msg * 8
    msg = msg .. '\128' .. string.rep('\0', (55 - #msg) % 64) .. string.pack('>I8', bits)

    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do w[i] = (string.unpack('>I4', msg, chunk + i * 4)) end
        for i = 16, 63 do
            local a, b = w[i - 15], w[i - 2]
            local s0 = rrot(a, 7) ~ rrot(a, 18) ~ (a >> 3)
            local s1 = rrot(b, 17) ~ rrot(b, 19) ~ (b >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M32
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
            local ch = (e & f) ~ ((~e) & g)
            local t1 = (h + S1 + ch + K[i + 1] + w[i]) & M32
            local S0 = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & M32
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) & M32, c, b, a, (t1 + t2) & M32
        end

        h0, h1, h2, h3 = (h0 + a) & M32, (h1 + b) & M32, (h2 + c) & M32, (h3 + d) & M32
        h4, h5, h6, h7 = (h4 + e) & M32, (h5 + f) & M32, (h6 + g) & M32, (h7 + h) & M32
    end

    return string.pack('>I4I4I4I4I4I4I4I4', h0, h1, h2, h3, h4, h5, h6, h7)
end

local function xorEach(s, byte)
    return (s:gsub('.', function(c) return string.char(c:byte() ~ byte) end))
end

--- HMAC-SHA256 of `msg` under `key`, as a binary string.
local function hmac(key, msg)
    if #key > 64 then key = sha256(key) end
    key = key .. string.rep('\0', 64 - #key)
    return sha256(xorEach(key, 0x5c) .. sha256(xorEach(key, 0x36) .. msg))
end

-- ============================================
-- Base64url (RFC 4648 §5, no padding)
-- ============================================

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

local function b64url(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1)
        out[#out + 1] = B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
        if b then out[#out + 1] = B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) end
        if c then out[#out + 1] = B64:sub((n & 63) + 1, (n & 63) + 1) end
    end
    return table.concat(out)
end

-- For the offline checks (dev/): the building blocks, and nothing that reads the secret.
VoiceToken._sha256, VoiceToken._hmac, VoiceToken._b64url = sha256, hmac, b64url

-- ============================================
-- Tokens
-- ============================================

--- Sign a voice server token.
---@param claims table  what the token says: { sub = identity, video = { grants } }
---@param ttl number    seconds it stays valid (10 at the least)
---@return string|nil   the token, or nil when server.cfg has no key or secret
function VoiceToken.sign(claims, ttl)
    local key = GetConvar('whip_voice_key', '')
    local secret = GetConvar('whip_voice_secret', '')
    if key == '' or secret == '' then return nil end

    local now = os.time()
    local body = {}
    for k, v in pairs(claims or {}) do body[k] = v end
    body.iss = key
    body.nbf = now - 10                                      -- a little slack for clock drift
    body.exp = now + math.max(10, math.floor(tonumber(ttl) or 60))

    local data = b64url(json.encode({ alg = 'HS256', typ = 'JWT' })) .. '.' .. b64url(json.encode(body))
    return data .. '.' .. b64url(hmac(secret, data))
end

-- ============================================
-- Identities
-- ============================================

local _made = 0

--- A fresh voice identity: 16 hex characters. Everyone in the voice room sees every identity in it,
--- so it must say nothing about who the player is and must not be guessable. Lua's own random is not
--- built for that; an HMAC under the server's secret is: without the secret, nobody can work out the
--- next one from the last. (No secret means no voice anyway; the hash then only keeps names apart.)
---@return string
function VoiceToken.randomId()
    _made = _made + 1
    local seed = ('voice-id|%d|%d|%s|%d|%d'):format(_made, os.time(), tostring(os.clock()), GetGameTimer(),
        math.random(0, 0x7fffffff))
    local secret = GetConvar('whip_voice_secret', '')
    local bytes = secret ~= '' and hmac(secret, seed) or sha256(seed)
    return (bytes:sub(1, 8):gsub('.', function(c) return ('%02x'):format(c:byte()) end))
end
