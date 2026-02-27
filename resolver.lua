--[[
╔══════════════════════════════════════════════════════════════════════════════╗
║          ADVANCED ANTI-AIM RESOLVER  v2  —  Gamesense (gamesense.pub)       ║
║                                                                              ║
║  Full FFI memory access + Gamesense Lua API                                 ║
║                                                                              ║
║  Resolution pipeline (confidence-weighted, highest wins):                   ║
║    1. LBY (Lower Body Yaw) update detection  — highest confidence           ║
║    2. Jitter pattern prediction              — high confidence               ║
║    3. Freestand damage trace                 — high confidence               ║
║    4. Freestand geometry trace               — medium confidence             ║
║    5. Animation Layer 6 delta                — medium confidence             ║
║    6. Adaptive bruteforce (per-player)       — low confidence                ║
║                                                                              ║
║  FFI reads: anim state, anim layers, entity props (velocity, flags, etc.)   ║
║  Gamesense API: plist, client.trace_line, client.trace_bullet,              ║
║                 client.eye_position, entity.*, globals.*, renderer.*        ║
╚══════════════════════════════════════════════════════════════════════════════╝
--]]

local ffi = require("ffi")
local bit = bit

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 1  FFI TYPE DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════════
ffi.cdef[[
/* ── basic types ─────────────────────────────────────────────────────────── */
typedef struct { float x, y, z;    } vec3_t;
typedef struct { float x, y, z, w; } vec4_t;

/* ── animation layer (13 per player, 0-indexed) ──────────────────────────── */
typedef struct {
    float   m_anim_time;
    float   m_fade_out_time;
    int     m_flags;
    int     m_activity;
    int     m_priority;
    int     m_order;
    int     m_sequence;
    float   m_prev_cycle;
    float   m_weight;
    float   m_weight_delta_rate;
    float   m_playback_rate;
    float   m_cycle;
    void*   m_owner;
    int     m_bits;
} C_AnimationLayer;

/* ── CCSGOPlayerAnimationState ───────────────────────────────────────────── */
typedef struct {
    char    pad0[0x60];
    void*   pEntity;
    void*   pActiveWeapon;
    void*   pLastActiveWeapon;
    float   flLastUpdateTime;
    int     iLastUpdateFrame;
    float   flLastUpdateIncrement;
    float   flEyeYaw;
    float   flEyePitch;
    float   flGoalFeetYaw;
    float   flLastFeetYaw;
    float   flMoveYaw;
    float   flLastMoveYaw;
    float   flLeanAmount;
    char    pad1[0x4];
    float   flFeetCycle;
    float   flMoveWeight;
    float   flMoveWeightSmoothed;
    float   flDuckAmount;
    float   flHitGroundCycle;
    float   flRecrouchWeight;
    vec3_t  vecOrigin;
    vec3_t  vecLastOrigin;
    vec3_t  vecVelocity;
    vec3_t  vecVelocityNormalized;
    vec3_t  vecVelocityNormalizedNonZero;
    float   flVelocityLenght2D;
    float   flJumpFallVelocity;
    float   flSpeedNormalized;
    float   flRunningSpeed;
    float   flDuckingSpeed;
    float   flDurationMoving;
    float   flDurationStill;
    bool    bOnGround;
    bool    bHitGroundAnimation;
    char    pad2[0x2];
    float   flNextLowerBodyYawUpdateTime;
    float   flDurationInAir;
    float   flLeftGroundHeight;
    float   flHitGroundWeight;
    float   flWalkToRunTransition;
    char    pad3[0x4];
    float   flAffectedFraction;
    char    pad4[0x208];
    char    pad_extra[0x4];
    float   flMinBodyYaw;
    float   flMaxBodyYaw;
    float   flMinPitch;
    float   flMaxPitch;
    int     iAnimsetVersion;
} CCSGOPlayerAnimationState_t;

/* ── entity vtable helpers ───────────────────────────────────────────────── */
typedef void*(__thiscall* get_client_entity_t)(void*, int);

/* ── direct prop reads via FFI (faster than entity.get_prop) ─────────────── */
/* We read raw floats/ints at known offsets from the entity pointer.          */
/* Offsets are for CS:GO build matching Gamesense's supported version.        */
typedef struct {
    char    pad_base[0x100];
    /* 0x100 */ int     m_fFlags;
    char    pad1[0x4];
    /* 0x108 */ vec3_t  m_vecVelocity;
    char    pad2[0x14];
    /* 0x124 */ float   m_flSimulationTime;
    char    pad3[0x4];
    /* 0x12C */ float   m_flOldSimulationTime;
    char    pad4[0x1C4];
    /* 0x2F4 */ float   m_flDuckAmount;
    char    pad5[0x4];
    /* 0x2FC */ float   m_flDuckSpeed;
} CBasePlayer_partial_t;
]]

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 2  INTERFACE ACQUISITION
-- ═══════════════════════════════════════════════════════════════════════════════
local entity_list    = ffi.cast("uintptr_t**",         client.create_interface("client.dll", "VClientEntityList003"))
local get_entity_raw = ffi.cast("get_client_entity_t", entity_list[0][3])

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 3  CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════════
local ANIM_STATE_OFFSET  = 0x9960   -- CCSPlayer -> CCSGOPlayerAnimationState_t*
local ANIM_LAYERS_OFFSET = 0x2990   -- CCSPlayer -> C_AnimationLayer[13]
local EYE_ANGLES_OFFSET  = 0x31E8   -- CCSPlayer -> QAngle m_angEyeAngles (pitch=+0, yaw=+4)

local LAYER_MOVE         = 6        -- 0-indexed: move layer
local LAYER_LAND         = 4        -- 0-indexed: land layer
local LAYER_LEAN         = 3        -- 0-indexed: lean/crouch layer
local NUM_LAYERS         = 13

local MAX_RECORDS        = 8        -- ticks of animation history
local MAX_MISSES         = 7        -- misses before forcing safe point
local BRUTE_BASE         = { 58, -58, 29, -29, 60, -60, 45, -45, 0 }

local PI  = math.pi
local DEG = 180.0 / PI
local RAD = PI / 180.0

-- Confidence weights for each method
local CONF = {
    lby          = 95,
    jitter       = 85,
    freestand_dmg= 80,
    freestand_geo= 65,
    animation    = 60,
    adaptive     = 45,
    brute        = 20,
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 4  RESOLVER STATE
-- ═══════════════════════════════════════════════════════════════════════════════
local R = {
    enabled  = true,
    debug    = true,
    -- per-entity
    records  = {},   -- [ent] = ring buffer of animation snapshots
    pdata    = {},   -- [ent] = persistent player data
    jitter   = {},   -- [ent] = jitter tracking
    lby      = {},   -- [ent] = LBY tracking
    adaptive = {},   -- [ent] = per-player yaw success map
    dbg      = {},   -- [ent] = debug display
    -- global
    stats    = { hits = 0, misses = 0, total = 0 },
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 5  MATH UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════════
local function norm_yaw(y)
    y = y % 360.0
    if y >  180.0 then y = y - 360.0 end
    if y < -180.0 then y = y + 360.0 end
    return y
end

local function adiff(a, b) return norm_yaw(a - b) end

local function clamp(v, lo, hi)
    if not v then return lo end
    if lo > hi then lo, hi = hi, lo end
    return v < lo and lo or (v > hi and hi or v)
end

local function len2(x, y) return math.sqrt(x*x + y*y) end

local function lerp(a, b, t) return a + (b - a) * t end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 6  FFI ENTITY ACCESSORS
-- ═══════════════════════════════════════════════════════════════════════════════
local function get_ptr(ent)
    local p = get_entity_raw(entity_list, ent)
    if p == nil or p == ffi.NULL then return nil end
    return p
end

local function get_anim_state(ent)
    local p = get_ptr(ent)
    if not p then return nil end
    local sp = ffi.cast("CCSGOPlayerAnimationState_t**",
                        ffi.cast("uintptr_t", p) + ANIM_STATE_OFFSET)
    if sp == nil or sp[0] == nil then return nil end
    return sp[0]
end

local function get_layers(ent)
    local p = get_ptr(ent)
    if not p then return nil end
    local lp = ffi.cast("C_AnimationLayer*",
                        ffi.cast("uintptr_t", p) + ANIM_LAYERS_OFFSET)
    if lp == nil then return nil end
    return lp  -- 0-indexed access: lp[0] .. lp[12]
end

-- Read eye angles directly from memory (faster than entity.get_prop)
local function get_eye_yaw_ffi(ent)
    local p = get_ptr(ent)
    if not p then return nil end
    local angles = ffi.cast("float*", ffi.cast("uintptr_t", p) + EYE_ANGLES_OFFSET)
    if angles == nil then return nil end
    return angles[1]  -- [0]=pitch, [1]=yaw, [2]=roll
end

-- Read velocity directly from memory
local function get_velocity_ffi(ent)
    local p = get_ptr(ent)
    if not p then return 0, 0, 0 end
    local bp = ffi.cast("CBasePlayer_partial_t*", p)
    if bp == nil then return 0, 0, 0 end
    return bp.m_vecVelocity.x, bp.m_vecVelocity.y, bp.m_vecVelocity.z
end

local function get_velocity_2d(ent)
    local vx, vy = get_velocity_ffi(ent)
    return len2(vx, vy)
end

-- Read flags directly from memory
local function get_flags_ffi(ent)
    local p = get_ptr(ent)
    if not p then return 0 end
    local bp = ffi.cast("CBasePlayer_partial_t*", p)
    if bp == nil then return 0 end
    return bp.m_fFlags
end

local function is_on_ground(ent)
    return bit.band(get_flags_ffi(ent), 1) ~= 0
end

-- Read duck amount directly from memory
local function get_duck_ffi(ent)
    local p = get_ptr(ent)
    if not p then return 0 end
    local bp = ffi.cast("CBasePlayer_partial_t*", p)
    if bp == nil then return 0 end
    return bp.m_flDuckAmount
end

local function is_ducking(ent)
    return get_duck_ffi(ent) > 0.5
end

-- Read simulation time directly from memory
local function get_simtime_ffi(ent)
    local p = get_ptr(ent)
    if not p then return 0 end
    local bp = ffi.cast("CBasePlayer_partial_t*", p)
    if bp == nil then return 0 end
    return bp.m_flSimulationTime
end

local function get_old_simtime_ffi(ent)
    local p = get_ptr(ent)
    if not p then return 0 end
    local bp = ffi.cast("CBasePlayer_partial_t*", p)
    if bp == nil then return 0 end
    return bp.m_flOldSimulationTime
end

local function time_to_ticks(t)
    return math.floor(0.5 + t / globals.tickinterval())
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 7  LAG COMPENSATION BREAK DETECTION
-- ═══════════════════════════════════════════════════════════════════════════════
local function is_breaking_lc(ent)
    local pd = R.pdata[ent]
    if not pd or not pd.last_simtime then return false end
    local diff = time_to_ticks(get_simtime_ffi(ent) - pd.last_simtime)
    return diff > 16 or diff < 0
end

-- Detect if the player is choking packets (simtime not advancing)
local function is_choking(ent)
    local pd = R.pdata[ent]
    if not pd or not pd.last_simtime then return false end
    local diff = time_to_ticks(get_simtime_ffi(ent) - pd.last_simtime)
    return diff == 0
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 8  MAX DESYNC CALCULATION
--      Mirrors CCSGOPlayerAnimState::SetUpVelocity() desync cap logic
-- ═══════════════════════════════════════════════════════════════════════════════
local function calc_max_desync(as)
    if not as then return 58.0 end
    local speed = clamp(as.flSpeedNormalized,  0.0, 1.0)
    local frac  = clamp(as.flAffectedFraction, 0.0, 1.0)
    local avg   = (frac * -0.3 - 0.2) * speed + 1.0
    local duck  = clamp(as.flDuckAmount, 0.0, 1.0)
    if duck > 0.0 then
        avg = avg + duck * speed * (0.5 - avg)
    end
    return clamp(avg * 57.295779513082, 29.0, 58.0)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 9  LBY (LOWER BODY YAW) TRACKER
--      When a standing player's LBY updates, it reveals the real body direction.
--      The eye-to-LBY delta tells us which side the desync is on.
-- ═══════════════════════════════════════════════════════════════════════════════
local function update_lby(ent, as)
    if not as then return end
    if not R.lby[ent] then
        R.lby[ent] = {
            last_lby      = as.flGoalFeetYaw,
            last_eye      = as.flEyeYaw,
            update_time   = as.flNextLowerBodyYawUpdateTime,
            updated       = false,
            predicted_side= 0,
            confidence    = 0,
        }
        return
    end

    local ld = R.lby[ent]
    local cur_lby  = as.flGoalFeetYaw
    local cur_eye  = as.flEyeYaw
    local cur_time = as.flNextLowerBodyYawUpdateTime

    -- LBY just updated (timer reset or value changed significantly)
    local lby_delta = math.abs(adiff(cur_lby, ld.last_lby))
    local time_changed = cur_time ~= ld.update_time

    if lby_delta > 0.1 or time_changed then
        -- The eye-to-LBY delta at update time reveals the desync direction
        local eye_lby_diff = adiff(cur_eye, cur_lby)
        if math.abs(eye_lby_diff) > 5.0 then
            ld.predicted_side = eye_lby_diff > 0 and 1 or -1
            ld.confidence     = math.min(95, 60 + math.floor(math.abs(eye_lby_diff) / 2))
            ld.updated        = true
        end
    else
        ld.updated = false
    end

    ld.last_lby    = cur_lby
    ld.last_eye    = cur_eye
    ld.update_time = cur_time
end

local function get_lby_side(ent)
    local ld = R.lby[ent]
    if not ld or not ld.updated then return 0, 0 end
    return ld.predicted_side, ld.confidence
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 10  JITTER DETECTOR
--       Tracks goal_feet_yaw side switches; detects alternating AA patterns.
-- ═══════════════════════════════════════════════════════════════════════════════
local function update_jitter(ent, as)
    if not as then return end
    if not R.jitter[ent] then
        R.jitter[ent] = { switches = 0, last_side = 0, pattern = {}, streak = 0 }
    end
    local jd   = R.jitter[ent]
    local gfy  = as.flGoalFeetYaw
    local side = gfy > 0.5 and 1 or (gfy < -0.5 and -1 or 0)

    if side ~= 0 and jd.last_side ~= 0 and side ~= jd.last_side then
        jd.switches = jd.switches + 1
        jd.streak   = jd.streak + 1
        local p = jd.pattern
        p[#p + 1] = side
        if #p > 12 then table.remove(p, 1) end
    else
        jd.streak = 0
    end
    jd.last_side = side
end

local function detect_jitter(ent)
    local jd = R.jitter[ent]
    if not jd or jd.switches < 3 then return false, 0, 0 end

    local p = jd.pattern
    local n = #p
    if n < 2 then return false, 0, 0 end

    -- Check for strict alternating pattern (most common jitter AA)
    if n >= 4 then
        local alt_count = 0
        for i = n - 2, n do
            if p[i] == -p[i - 1] then alt_count = alt_count + 1 end
        end
        if alt_count >= 2 then
            -- Predict opposite of last observed side
            local predicted = -p[n]
            local conf = math.min(85, 50 + jd.switches * 3)
            return true, predicted, conf
        end
    end

    -- High switch count = likely jitter even without perfect pattern
    if jd.switches >= 6 then
        return true, -jd.last_side, 55
    end

    return false, 0, 0
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 11  FREESTAND DETECTION
-- ═══════════════════════════════════════════════════════════════════════════════
local function freestand_geo(ent, local_ent)
    local ex, ey, ez = entity.get_origin(ent)
    if not ex then return 0, 0 end
    local lx, ly = entity.get_origin(local_ent)
    if not lx then return 0, 0 end

    local duck  = get_duck_ffi(ent)
    local eye_z = ez + 64.0 - duck * 18.0

    local eye_yaw = get_eye_yaw_ffi(ent) or (entity.get_prop(ent, "m_angEyeAngles[1]") or 0)
    local fx, fy  = lx - ex, ly - ey
    local flen    = len2(fx, fy)
    if flen > 0 then fx, fy = fx / flen, fy / flen end

    local rx = math.cos((eye_yaw + 90.0) * RAD)
    local ry = math.sin((eye_yaw + 90.0) * RAD)

    local neg = client.trace_line(ent,
        ex - rx * 23, ey - ry * 23, eye_z,
        ex - rx * 23 + fx * 128, ey - ry * 23 + fy * 128, eye_z)
    local pos = client.trace_line(ent,
        ex + rx * 23, ey + ry * 23, eye_z,
        ex + rx * 23 + fx * 128, ey + ry * 23 + fy * 128, eye_z)

    if neg >= 0.99 and pos >= 0.99 then return 0, 0 end
    if neg < pos  then return -1, CONF.freestand_geo end
    if pos < neg  then return  1, CONF.freestand_geo end
    return 0, 0
end

local function freestand_dmg(ent, local_ent)
    local hx, hy, hz = entity.hitbox_position(ent, 0)
    if not hx then return 0, 0 end

    local lex, ley, lez = client.eye_position()
    if not lex then return 0, 0 end

    local eye_yaw = get_eye_yaw_ffi(ent) or (entity.get_prop(ent, "m_angEyeAngles[1]") or 0)
    local rx = math.cos((eye_yaw + 90.0) * RAD)
    local ry = math.sin((eye_yaw + 90.0) * RAD)

    local _, ldmg = client.trace_bullet(local_ent, lex, ley, lez,
        hx - rx * 10, hy - ry * 10, hz, true)
    local _, rdmg = client.trace_bullet(local_ent, lex, ley, lez,
        hx + rx * 10, hy + ry * 10, hz, true)

    ldmg, rdmg = ldmg or 0, rdmg or 0
    if ldmg == 0 and rdmg == 0 then return 0, 0 end

    -- Confidence scales with damage difference
    local diff = math.abs(ldmg - rdmg)
    local conf = math.min(80, 40 + diff)

    if ldmg > rdmg then return -1, conf end
    if rdmg > ldmg then return  1, conf end
    return 0, 0
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 12  SIDEWAYS CHECK
-- ═══════════════════════════════════════════════════════════════════════════════
local function is_sideways(ent, local_ent)
    local lx, ly = entity.get_origin(local_ent)
    local ex, ey = entity.get_origin(ent)
    if not lx or not ex then return false end

    local eye_yaw = get_eye_yaw_ffi(ent) or (entity.get_prop(ent, "m_angEyeAngles[1]") or 0)
    local to_us   = math.atan2(ly - ey, lx - ex) * DEG
    local delta   = math.abs(norm_yaw(eye_yaw - to_us))
    return (delta > 60 and delta < 120) or (delta > 240 and delta < 300)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 13  ANIMATION LAYER 6 SIDE DETECTION
--       Uses move layer playback rate delta to infer movement direction.
-- ═══════════════════════════════════════════════════════════════════════════════
local function detect_side_anim(ent, rec, old_rec, as)
    if not rec or not old_rec or not as then return 0, 0 end

    local velocity = get_velocity_2d(ent)

    -- Micro-movement: client velocity near zero but server says moving
    if velocity < 1.5 and (rec.vel2d or 0) > 0.1 then
        local delta  = (rec.l6_playback or 0) - (old_rec.l6_playback or 0)
        local v_safe = math.max(velocity, 0.001)
        local ratio  = delta * 100000.0 / v_safe
        if ratio > 5.9 then return  1, CONF.animation end
        return -1, CONF.animation
    end

    -- Standard: use move_yaw from anim state
    local move_yaw = as.flMoveYaw
    if move_yaw > 175.0 or move_yaw < -175.0 then return -1, CONF.animation - 10 end
    if move_yaw > 0.0 then return -1, CONF.animation end
    return 1, CONF.animation
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 14  ADAPTIVE BRUTEFORCE
--       Tracks which yaw offsets have historically worked per player.
--       Successful yaws get higher priority in the sequence.
-- ═══════════════════════════════════════════════════════════════════════════════
local function get_adaptive_sequence(ent)
    if not R.adaptive[ent] then
        R.adaptive[ent] = {}
        for _, v in ipairs(BRUTE_BASE) do
            R.adaptive[ent][v] = 0  -- score = 0
        end
    end
    -- Sort by score descending, then by absolute value ascending (prefer smaller offsets)
    local seq = {}
    for yaw, score in pairs(R.adaptive[ent]) do
        seq[#seq + 1] = { yaw = yaw, score = score }
    end
    table.sort(seq, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return math.abs(a.yaw) < math.abs(b.yaw)
    end)
    local result = {}
    for _, v in ipairs(seq) do result[#result + 1] = v.yaw end
    return result
end

local function adaptive_hit(ent, yaw)
    if not R.adaptive[ent] then return end
    local rounded = math.floor(yaw + 0.5)
    -- Find closest entry
    local best_key, best_dist = nil, 999
    for k in pairs(R.adaptive[ent]) do
        local d = math.abs(k - rounded)
        if d < best_dist then best_dist = d; best_key = k end
    end
    if best_key and best_dist <= 5 then
        R.adaptive[ent][best_key] = (R.adaptive[ent][best_key] or 0) + 3
    end
end

local function adaptive_miss(ent, yaw)
    if not R.adaptive[ent] then return end
    local rounded = math.floor(yaw + 0.5)
    local best_key, best_dist = nil, 999
    for k in pairs(R.adaptive[ent]) do
        local d = math.abs(k - rounded)
        if d < best_dist then best_dist = d; best_key = k end
    end
    if best_key and best_dist <= 5 then
        R.adaptive[ent][best_key] = math.max(-5, (R.adaptive[ent][best_key] or 0) - 1)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 15  ANIMATION RECORD STORAGE
-- ═══════════════════════════════════════════════════════════════════════════════
local function store_record(ent)
    local as = get_anim_state(ent)
    local al = get_layers(ent)
    if not as or not al then return end

    -- Update sub-systems that need per-tick data
    update_lby(ent, as)
    update_jitter(ent, as)

    if not R.records[ent] then R.records[ent] = {} end
    local recs = R.records[ent]

    -- Shift ring buffer
    for i = MAX_RECORDS, 2, -1 do recs[i] = recs[i - 1] end

    recs[1] = {
        sim_time     = get_simtime_ffi(ent),
        eye_yaw      = as.flEyeYaw,
        goal_feet    = as.flGoalFeetYaw,
        last_feet    = as.flLastFeetYaw,
        move_yaw     = as.flMoveYaw,
        vel2d        = as.flVelocityLenght2D,
        speed_norm   = as.flSpeedNormalized,
        duck         = as.flDuckAmount,
        aff_frac     = as.flAffectedFraction,
        on_ground    = as.bOnGround,
        -- Layer snapshots (0-indexed FFI access)
        l3_weight    = al[LAYER_LEAN].m_weight,
        l3_cycle     = al[LAYER_LEAN].m_cycle,
        l4_weight    = al[LAYER_LAND].m_weight,
        l4_cycle     = al[LAYER_LAND].m_cycle,
        l6_weight    = al[LAYER_MOVE].m_weight,
        l6_playback  = al[LAYER_MOVE].m_playback_rate,
        l6_cycle     = al[LAYER_MOVE].m_cycle,
        -- All layer sequences for deep analysis
        sequences    = (function()
            local s = {}
            for i = 0, NUM_LAYERS - 1 do s[i] = al[i].m_sequence end
            return s
        end)(),
    }
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 16  PLIST APPLICATION
-- ═══════════════════════════════════════════════════════════════════════════════
local function apply(ent, cfg)
    if not ent or ent == 0 then return end
    plist.set(ent, "Correction active",    cfg.correction or false)
    plist.set(ent, "Force body yaw",       cfg.force_yaw  or false)
    plist.set(ent, "Force body yaw value", clamp(cfg.yaw or 0, -60, 60))
    plist.set(ent, "Override safe point",  cfg.safepoint  or "-")
end

local function apply_safe(ent)
    apply(ent, { safepoint = "On" })
end

local function apply_yaw(ent, yaw, method, conf, pd)
    local y = clamp(yaw, -60, 60)
    apply(ent, { correction = true, force_yaw = true, yaw = y })
    if pd then
        pd.last_method = method
        pd.last_yaw    = y
        pd.last_conf   = conf
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 17  MAIN RESOLVER
-- ═══════════════════════════════════════════════════════════════════════════════
local function resolve(ent, local_ent)
    if not entity.is_alive(ent) then return end

    -- Init per-player data
    if not R.pdata[ent] then
        R.pdata[ent] = {
            misses       = 0,
            last_method  = "none",
            last_yaw     = 0,
            last_conf    = 0,
            last_simtime = nil,
            was_dormant  = false,
        }
    end
    local pd = R.pdata[ent]

    local recs    = R.records[ent]
    local rec     = recs and recs[1]
    local old_rec = recs and recs[2]

    local velocity  = get_velocity_2d(ent)
    local on_ground = is_on_ground(ent)
    local ducking   = is_ducking(ent)
    local dormant   = entity.is_dormant(ent)
    local from_dorm = pd.was_dormant and not dormant
    local lc_break  = is_breaking_lc(ent)
    local choking   = is_choking(ent)
    local sideways  = is_sideways(ent, local_ent)

    pd.last_simtime = get_simtime_ffi(ent)
    pd.was_dormant  = dormant

    -- Debug snapshot
    R.dbg[ent] = {
        name       = entity.get_player_name(ent) or "?",
        velocity   = velocity,
        on_ground  = on_ground,
        ducking    = ducking,
        sideways   = sideways,
        lc_break   = lc_break,
        choking    = choking,
        from_dorm  = from_dorm,
        method     = "none",
        yaw        = 0,
        conf       = 0,
        misses     = pd.misses,
        jitter     = false,
        max_desync = 58,
    }

    -- ── Dormant ───────────────────────────────────────────────────────────────
    if dormant then
        R.dbg[ent].method = "dormant"
        apply_safe(ent)
        return
    end

    -- ── In air ────────────────────────────────────────────────────────────────
    if not on_ground then
        R.dbg[ent].method = "air"
        apply_safe(ent)
        return
    end

    -- ── Moving fast (AA irrelevant) ───────────────────────────────────────────
    if velocity > 80 then
        R.dbg[ent].method = "moving"
        apply_safe(ent)
        return
    end

    -- ── No animation data ─────────────────────────────────────────────────────
    local as = get_anim_state(ent)
    if not as or not rec then
        R.dbg[ent].method = "no_data"
        apply_safe(ent)
        return
    end

    local max_desync = calc_max_desync(as)
    R.dbg[ent].max_desync = max_desync

    -- ── Max misses → safe point ───────────────────────────────────────────────
    if pd.misses >= MAX_MISSES then
        R.dbg[ent].method = "max_miss"
        apply_safe(ent)
        return
    end

    -- ═══════════════════════════════════════════════════════════════════════════
    -- CONFIDENCE-WEIGHTED RESOLUTION
    -- Collect all candidate (side, confidence, method) tuples, pick highest.
    -- ═══════════════════════════════════════════════════════════════════════════
    local best_side, best_conf, best_method = 0, 0, "none"

    local function consider(side, conf, method)
        if side ~= 0 and conf > best_conf then
            best_side, best_conf, best_method = side, conf, method
        end
    end

    -- ── Candidate 1: LBY update ───────────────────────────────────────────────
    local lby_side, lby_conf = get_lby_side(ent)
    consider(lby_side, lby_conf, "lby")

    -- ── Candidate 2: Jitter ───────────────────────────────────────────────────
    local is_jitter, jitter_side, jitter_conf = detect_jitter(ent)
    R.dbg[ent].jitter = is_jitter
    if is_jitter then
        consider(jitter_side, jitter_conf, "jitter")
    end

    -- ── Candidates 3 & 4: Freestand (sideways only) ──────────────────────────
    if sideways then
        local ds, dc = freestand_dmg(ent, local_ent)
        consider(ds, dc, "freestand_dmg")

        local gs, gc = freestand_geo(ent, local_ent)
        consider(gs, gc, "freestand_geo")
    end

    -- ── Candidate 5: Animation layer 6 ───────────────────────────────────────
    local as_side, as_conf = detect_side_anim(ent, rec, old_rec, as)
    consider(as_side, as_conf, "animation")

    -- ── Apply best candidate if confidence is sufficient ─────────────────────
    if best_conf >= CONF.animation then
        local eye_foot = math.abs(adiff(rec.eye_yaw, rec.goal_feet))
        local desync   = clamp(eye_foot, 29.0, max_desync)
        -- LBY and freestand use full desync; animation uses measured delta
        local yaw_val
        if best_method == "lby" or best_method == "freestand_dmg" or best_method == "freestand_geo" then
            yaw_val = best_side * max_desync
        else
            yaw_val = best_side * desync
        end

        R.dbg[ent].method = best_method
        R.dbg[ent].yaw    = yaw_val
        R.dbg[ent].conf   = best_conf
        apply_yaw(ent, yaw_val, best_method, best_conf, pd)
        return
    end

    -- ── Candidate 6: Adaptive bruteforce ─────────────────────────────────────
    local seq      = get_adaptive_sequence(ent)
    local brute_i  = (pd.misses % #seq) + 1
    local brute_y  = seq[brute_i] or 0
    local method   = ducking and "brute_duck" or "brute"

    R.dbg[ent].method = method
    R.dbg[ent].yaw    = brute_y
    R.dbg[ent].conf   = CONF.brute
    apply_yaw(ent, brute_y, method, CONF.brute, pd)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 18  NET UPDATE END  (main tick hook)
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("net_update_end", function()
    if not R.enabled then return end

    local local_ent = entity.get_local_player()
    if not local_ent or not entity.is_alive(local_ent) then return end

    local enemies = entity.get_players(true)
    if not enemies then return end

    -- Pass 1: store animation records (must happen before resolve)
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            store_record(ent)
        end
    end

    -- Pass 2: resolve
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) then
            resolve(ent, local_ent)
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 19  AIM EVENTS
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("aim_miss", function(e)
    if not R.enabled then return end
    -- Gamesense: e.reason is nil for resolver misses, string for spread/prediction
    if e.reason ~= nil then return end

    local ent = e.target
    if not ent then return end

    if not R.pdata[ent] then R.pdata[ent] = { misses = 0, last_method = "?", last_yaw = 0 } end
    local pd = R.pdata[ent]
    pd.misses = pd.misses + 1

    -- Penalise the yaw that was used
    adaptive_miss(ent, pd.last_yaw or 0)

    R.stats.misses = R.stats.misses + 1
    R.stats.total  = R.stats.total  + 1
    if R.dbg[ent] then R.dbg[ent].misses = pd.misses end

    client.color_log(255, 140, 0,
        string.format("[Resolver] Miss #%d | %s | method: %s | yaw: %.1f° | conf: %d",
            pd.misses,
            entity.get_player_name(ent) or "?",
            pd.last_method or "?",
            pd.last_yaw    or 0,
            pd.last_conf   or 0))

    if pd.misses >= MAX_MISSES then
        client.color_log(255, 60, 60,
            "[Resolver] Max misses — safe point for " .. (entity.get_player_name(ent) or "?"))
    end
end)

client.set_event_callback("aim_hit", function(e)
    if not R.enabled then return end

    local ent = e.target
    if not ent then return end

    R.stats.hits  = R.stats.hits  + 1
    R.stats.total = R.stats.total + 1

    local pd = R.pdata[ent]
    if pd then
        -- Reward the yaw that worked
        adaptive_hit(ent, pd.last_yaw or 0)
        client.color_log(0, 220, 80,
            string.format("[Resolver] HIT | %s | method: %s | yaw: %.1f° | conf: %d | dmg: %d",
                entity.get_player_name(ent) or "?",
                pd.last_method or "?",
                pd.last_yaw    or 0,
                pd.last_conf   or 0,
                e.damage       or 0))
        pd.misses = 0
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 20  GAME EVENTS
-- ═══════════════════════════════════════════════════════════════════════════════
local function clear_player(ent)
    R.records[ent]  = nil
    R.pdata[ent]    = nil
    R.jitter[ent]   = nil
    R.lby[ent]      = nil
    R.dbg[ent]      = nil
    -- Keep adaptive data across deaths (it's per-player, not per-life)
    pcall(function() apply(ent, {}) end)
end

client.set_event_callback("player_death", function(e)
    local ent = client.userid_to_entindex(e.userid)
    if ent then clear_player(ent) end
end)

client.set_event_callback("round_start", function()
    R.records = {}
    R.pdata   = {}
    R.jitter  = {}
    R.lby     = {}
    R.dbg     = {}
    -- Reset adaptive scores at round start (fresh start)
    R.adaptive = {}
    local enemies = entity.get_players(true)
    if enemies then
        for _, ent in ipairs(enemies) do pcall(function() apply(ent, {}) end) end
    end
end)

client.set_event_callback("shutdown", function()
    local enemies = entity.get_players(true)
    if enemies then
        for _, ent in ipairs(enemies) do pcall(function() apply(ent, {}) end) end
    end
    client.color_log(255, 200, 80, "[Resolver v2] Unloaded — plist reset")
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 21  DEBUG PANEL
-- ═══════════════════════════════════════════════════════════════════════════════
local METHOD_COLOR = {
    lby           = { 50, 255, 200 },
    jitter        = { 255, 100, 255 },
    freestand_dmg = { 50,  255, 130 },
    freestand_geo = {  0,  200, 100 },
    animation     = { 100, 200, 255 },
    brute         = { 255, 200, 100 },
    brute_duck    = { 255, 150,  50 },
    air           = { 120, 120, 120 },
    moving        = { 120, 120, 120 },
    dormant       = {  80,  80,  80 },
    max_miss      = { 255,  50,  50 },
    no_data       = { 160, 160, 160 },
    none          = { 160, 160, 160 },
}

local function draw_debug()
    if not R.debug then return end

    local sw, sh = client.screen_size()
    local x, y  = 10, 180
    local W      = 310

    -- Header bar
    renderer.rectangle(x - 4, y - 4, W, 22, 0, 0, 0, 220)
    renderer.text(x, y, 255, 200, 60, 255, nil, 0, "[ RESOLVER v2 ]")

    local acc_str
    if R.stats.total > 0 then
        acc_str = string.format("%.1f%% (%d/%d)",
            R.stats.hits / R.stats.total * 100, R.stats.hits, R.stats.total)
    else
        acc_str = "n/a"
    end
    renderer.text(x + 140, y, 160, 160, 160, 255, nil, 0, "Acc: " .. acc_str)
    y = y + 24

    local enemies = entity.get_players(true)
    if not enemies then return end

    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local info = R.dbg[ent]
            if info then
                local row_h = 84
                renderer.rectangle(x - 4, y - 2, W, row_h, 14, 14, 14, 220)

                local mc  = METHOD_COLOR[info.method] or { 200, 200, 200 }
                local nc  = info.lc_break and { 255, 80, 80 } or { 240, 240, 240 }
                local tag = ""
                if info.lc_break  then tag = tag .. " [LC]"  end
                if info.from_dorm then tag = tag .. " [D]"   end
                if info.choking   then tag = tag .. " [CHK]" end
                if info.jitter    then tag = tag .. " [JIT]" end

                renderer.text(x, y,      nc[1], nc[2], nc[3], 255, nil, 0, info.name .. tag)
                renderer.text(x, y + 14, mc[1], mc[2], mc[3], 255, nil, 0,
                    string.format("Method: %s  (conf: %d%%)", info.method, info.conf))
                renderer.text(x, y + 28, 150, 150, 150, 255, nil, 0,
                    string.format("Vel: %.1f  Yaw: %.1f°  MaxDS: %.1f°",
                        info.velocity, info.yaw, info.max_desync))
                renderer.text(x, y + 42, 150, 150, 150, 255, nil, 0,
                    string.format("Misses: %d  Duck: %s  Side: %s",
                        info.misses,
                        info.ducking  and "Y" or "N",
                        info.sideways and "Y" or "N"))
                renderer.text(x, y + 56, 130, 130, 130, 255, nil, 0,
                    string.format("Ground: %s  LC: %s  Choke: %s",
                        info.on_ground and "Y" or "N",
                        info.lc_break  and "!" or "N",
                        info.choking   and "!" or "N"))

                y = y + row_h + 3
                if y > sh - 80 then break end
            end
        end
    end
end

client.set_event_callback("paint", draw_debug)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 22  UI
-- ═══════════════════════════════════════════════════════════════════════════════
local ui_enable = ui.new_checkbox("LUA", "a", "Advanced Resolver v2")
local ui_debug  = ui.new_checkbox("LUA", "a", "Resolver Debug Panel")

ui.set_callback(ui_enable, function()
    R.enabled = ui.get(ui_enable)
    if not R.enabled then
        local enemies = entity.get_players(true)
        if enemies then
            for _, ent in ipairs(enemies) do pcall(function() apply(ent, {}) end) end
        end
        client.color_log(200, 200, 200, "[Resolver v2] Disabled")
    else
        client.color_log(0, 220, 80, "[Resolver v2] Enabled")
    end
end)

ui.set_callback(ui_debug, function()
    R.debug = ui.get(ui_debug)
end)

ui.set(ui_enable, true)
ui.set(ui_debug,  true)

client.log("[Resolver v2] Loaded — FFI direct reads | LBY | Jitter | Freestand | Anim | Adaptive Brute")
