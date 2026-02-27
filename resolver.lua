--[[
    Advanced Anti-Aim Resolver
    Platform: Gamesense (gamesense.pub)
    API Reference: https://gamesense.pub/forums/viewtopic.php?id=19
    
    Methods (priority order):
      1. Dormant / Air / Moving  -> safe point fallback
      2. Jitter detection        -> predict next side
      3. Freestand (damage-based)-> trace_bullet side
      4. Freestand (trace-based) -> trace_line side
      5. Animation Layer 6 delta -> move yaw side
      6. Bruteforce              -> cycle through offsets on miss
--]]

local ffi = require("ffi")

-- ─────────────────────────────────────────────────────────────────────────────
-- FFI Definitions
-- ─────────────────────────────────────────────────────────────────────────────
ffi.cdef[[
    typedef struct { float x, y, z; } vec3_t;

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

    typedef void*(__thiscall* get_client_entity_t)(void*, int);
]]

-- ─────────────────────────────────────────────────────────────────────────────
-- Entity List Interface
-- ─────────────────────────────────────────────────────────────────────────────
local entity_list      = ffi.cast("uintptr_t**",          client.create_interface("client.dll", "VClientEntityList003"))
local get_entity_raw   = ffi.cast("get_client_entity_t",  entity_list[0][3])

-- ─────────────────────────────────────────────────────────────────────────────
-- Constants
-- ─────────────────────────────────────────────────────────────────────────────
local ANIM_STATE_OFFSET = 0x9960
local ANIM_LAYERS_OFFSET = 0x2990
local MAX_RECORDS       = 6          -- how many ticks of history to keep
local MAX_MISSES        = 6          -- force safe point after this many misses
local BRUTE_SEQUENCE    = { 58, -58, 29, -29, 60, -60, 0 }
local LAYER_MOVE        = 6          -- 0-indexed layer for move (7th layer)
local LAYER_LAND        = 4          -- 0-indexed layer for landing
local PI                = math.pi
local DEG               = 180 / PI
local RAD               = PI / 180

-- ─────────────────────────────────────────────────────────────────────────────
-- Resolver State
-- ─────────────────────────────────────────────────────────────────────────────
local R = {
    enabled      = true,
    debug        = true,
    -- per-entity tables
    records      = {},   -- [ent] = { [1..MAX_RECORDS] = record }
    pdata        = {},   -- [ent] = { misses, last_side, last_method, last_yaw, last_simtime, was_dormant }
    jitter       = {},   -- [ent] = { switch_count, last_side, pattern[] }
    dbg          = {},   -- [ent] = debug display info
    -- global stats
    stats        = { hits = 0, misses = 0, total = 0 },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Math Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function normalize_yaw(y)
    y = y % 360
    if y > 180  then y = y - 360 end
    if y < -180 then y = y + 360 end
    return y
end

local function angle_diff(a, b)
    return normalize_yaw(a - b)
end

local function clamp(v, lo, hi)
    if v == nil then return lo end
    if lo > hi  then lo, hi = hi, lo end
    return v < lo and lo or (v > hi and hi or v)
end

local function vec2_len(x, y)
    return math.sqrt(x * x + y * y)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FFI Accessors
-- ─────────────────────────────────────────────────────────────────────────────
local function get_entity_ptr(ent)
    local p = get_entity_raw(entity_list, ent)
    if p == nil or p == ffi.NULL then return nil end
    return p
end

local function get_anim_state(ent)
    local ptr = get_entity_ptr(ent)
    if not ptr then return nil end
    local sp = ffi.cast("CCSGOPlayerAnimationState_t**",
                        ffi.cast("uintptr_t", ptr) + ANIM_STATE_OFFSET)
    if sp == nil or sp[0] == nil then return nil end
    return sp[0]
end

local function get_anim_layers(ent)
    local ptr = get_entity_ptr(ent)
    if not ptr then return nil end
    local lp = ffi.cast("C_AnimationLayer*",
                        ffi.cast("uintptr_t", ptr) + ANIM_LAYERS_OFFSET)
    if lp == nil then return nil end
    return lp   -- 0-indexed: lp[0] .. lp[12]
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entity Property Helpers  (Gamesense API)
-- ─────────────────────────────────────────────────────────────────────────────
local function get_velocity_2d(ent)
    local vx = entity.get_prop(ent, "m_vecVelocity[0]") or 0
    local vy = entity.get_prop(ent, "m_vecVelocity[1]") or 0
    return vec2_len(vx, vy)
end

local function is_on_ground(ent)
    return bit.band(entity.get_prop(ent, "m_fFlags") or 0, 1) ~= 0
end

local function is_ducking(ent)
    return (entity.get_prop(ent, "m_flDuckAmount") or 0) > 0.5
end

local function get_sim_time(ent)
    return entity.get_prop(ent, "m_flSimulationTime") or 0
end

local function time_to_ticks(t)
    return math.floor(0.5 + t / globals.tickinterval())
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lag Compensation Break Detection
-- ─────────────────────────────────────────────────────────────────────────────
local function is_breaking_lc(ent)
    local pd = R.pdata[ent]
    if not pd or not pd.last_simtime then return false end
    return time_to_ticks(get_sim_time(ent) - pd.last_simtime) > 16
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Max Desync Calculation  (matches game's CCSGOPlayerAnimState::SetUpVelocity)
-- ─────────────────────────────────────────────────────────────────────────────
local function calc_max_desync(as)
    if not as then return 58 end
    local speed = clamp(as.flSpeedNormalized, 0, 1)
    local frac  = clamp(as.flAffectedFraction, 0, 1)
    local avg   = (frac * -0.3 - 0.2) * speed + 1.0
    local duck  = clamp(as.flDuckAmount, 0, 1)
    if duck > 0 then
        avg = avg + duck * speed * (0.5 - avg)
    end
    return clamp(avg * 57.295779513082, 29, 58)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Jitter Detection
-- ─────────────────────────────────────────────────────────────────────────────
local function update_jitter(ent, goal_feet_yaw)
    if not R.jitter[ent] then
        R.jitter[ent] = { switch_count = 0, last_side = 0, pattern = {} }
    end
    local jd   = R.jitter[ent]
    local side = goal_feet_yaw > 0 and 1 or (goal_feet_yaw < 0 and -1 or 0)

    if jd.last_side ~= 0 and side ~= 0 and jd.last_side ~= side then
        jd.switch_count = jd.switch_count + 1
        local p = jd.pattern
        p[#p + 1] = side
        if #p > 10 then table.remove(p, 1) end
    end
    jd.last_side = side
end

local function detect_jitter(ent)
    local jd = R.jitter[ent]
    if not jd or jd.switch_count < 3 then return false, 0 end

    local p = jd.pattern
    local n = #p
    -- look for strict alternating pattern over last 4 entries
    if n >= 4 then
        local alt = true
        for i = n - 2, n do
            if p[i] ~= -p[i - 1] then alt = false; break end
        end
        if alt then return true, -p[n] end   -- predict opposite of last
    end

    if jd.switch_count >= 5 then
        return true, -jd.last_side
    end
    return false, 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Freestand Detection
-- ─────────────────────────────────────────────────────────────────────────────
local function freestand_trace(ent, local_ent)
    local ex, ey, ez = entity.get_origin(ent)
    if not ex then return 0 end
    local lx, ly = entity.get_origin(local_ent)
    if not lx then return 0 end

    local duck  = entity.get_prop(ent, "m_flDuckAmount") or 0
    local eye_z = ez + 64.0 - duck * 18.0

    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    local fx, fy  = lx - ex, ly - ey
    local flen    = vec2_len(fx, fy)
    if flen > 0 then fx, fy = fx / flen, fy / flen end

    local rx = math.cos((eye_yaw + 90) * RAD)
    local ry = math.sin((eye_yaw + 90) * RAD)

    local neg = client.trace_line(ent,
        ex - rx * 23, ey - ry * 23, eye_z,
        ex - rx * 23 + fx * 128, ey - ry * 23 + fy * 128, eye_z)
    local pos = client.trace_line(ent,
        ex + rx * 23, ey + ry * 23, eye_z,
        ex + rx * 23 + fx * 128, ey + ry * 23 + fy * 128, eye_z)

    if neg >= 0.99 and pos >= 0.99 then return 0 end
    if neg < pos  then return -1 end
    if pos < neg  then return  1 end
    return 0
end

local function freestand_damage(ent, local_ent)
    local head_x, head_y, head_z = entity.hitbox_position(ent, 0)
    if not head_x then return 0 end

    local lex, ley, lez = client.eye_position()
    if not lex then return 0 end

    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    local rx = math.cos((eye_yaw + 90) * RAD)
    local ry = math.sin((eye_yaw + 90) * RAD)

    local _, ldmg = client.trace_bullet(local_ent, lex, ley, lez,
        head_x - rx * 10, head_y - ry * 10, head_z, true)
    local _, rdmg = client.trace_bullet(local_ent, lex, ley, lez,
        head_x + rx * 10, head_y + ry * 10, head_z, true)

    ldmg, rdmg = ldmg or 0, rdmg or 0
    if ldmg == 0 and rdmg == 0 then return 0 end
    if ldmg > rdmg then return -1 end
    if rdmg > ldmg then return  1 end
    return 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sideways Check  (is enemy facing perpendicular to us?)
-- ─────────────────────────────────────────────────────────────────────────────
local function is_sideways(ent, local_ent)
    local lx, ly = entity.get_origin(local_ent)
    local ex, ey = entity.get_origin(ent)
    if not lx or not ex then return false end

    local eye_yaw = entity.get_prop(ent, "m_angEyeAngles[1]") or 0
    local to_us   = math.atan2(ly - ey, lx - ex) * DEG
    local delta   = math.abs(normalize_yaw(eye_yaw - to_us))
    return (delta > 65 and delta < 115) or (delta > 245 and delta < 295)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Animation Layer 6 Side Detection
-- ─────────────────────────────────────────────────────────────────────────────
local function detect_side_from_layers(ent, rec, old_rec)
    if not rec or not old_rec then return 0 end

    local velocity = get_velocity_2d(ent)

    -- micro-movement branch: velocity in [0, 1.4] but server says moving
    if velocity < 1.5 and (rec.velocity_2d or 0) > 0 then
        local delta = (rec.layer_move_playback or 0) - (old_rec.layer_move_playback or 0)
        -- normalise by velocity to get a consistent threshold
        local v_safe = math.max(velocity, 0.001)
        if (delta * 100000 / v_safe) > 5.9 then return 1 end
        return -1
    end

    -- standard move yaw
    local move_yaw = rec.move_yaw or 0
    if move_yaw > 175 or move_yaw < -175 then return -1 end
    if move_yaw > 0 then return -1 end
    return 1
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Animation Record Storage
-- ─────────────────────────────────────────────────────────────────────────────
local function store_record(ent)
    local as = get_anim_state(ent)
    local al = get_anim_layers(ent)
    if not as or not al then return end

    if not R.records[ent] then R.records[ent] = {} end
    local recs = R.records[ent]

    -- shift history
    for i = MAX_RECORDS, 2, -1 do recs[i] = recs[i - 1] end

    recs[1] = {
        sim_time            = get_sim_time(ent),
        eye_yaw             = as.flEyeYaw,
        goal_feet_yaw       = as.flGoalFeetYaw,
        velocity_2d         = as.flVelocityLenght2D,
        move_yaw            = as.flMoveYaw,
        last_update_inc     = as.flLastUpdateIncrement,
        duck_amount         = as.flDuckAmount,
        speed_norm          = as.flSpeedNormalized,
        affected_frac       = as.flAffectedFraction,
        -- layer 3 (land/crouch)
        layer_land_weight   = al[3].m_weight,
        layer_land_cycle    = al[3].m_cycle,
        -- layer 6 (move)
        layer_move_weight   = al[LAYER_MOVE].m_weight,
        layer_move_playback = al[LAYER_MOVE].m_playback_rate,
        layer_move_cycle    = al[LAYER_MOVE].m_cycle,
    }

    update_jitter(ent, as.flGoalFeetYaw)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- plist Application  (Gamesense plist API)
-- ─────────────────────────────────────────────────────────────────────────────
local function apply(ent, cfg)
    if not ent or ent == 0 then return end
    plist.set(ent, "Correction active",    cfg.correction  or false)
    plist.set(ent, "Force body yaw",       cfg.force_yaw   or false)
    plist.set(ent, "Force body yaw value", clamp(cfg.yaw_value or 0, -60, 60))
    plist.set(ent, "Override safe point",  cfg.safepoint   or "-")
end

local function apply_safe(ent)
    apply(ent, { safepoint = "On" })
end

local function apply_yaw(ent, yaw, method, pd)
    local clamped = clamp(yaw, -60, 60)
    apply(ent, { correction = true, force_yaw = true, yaw_value = clamped })
    if pd then
        pd.last_method = method
        pd.last_yaw    = clamped
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main Resolver
-- ─────────────────────────────────────────────────────────────────────────────
local function resolve(ent, local_ent)
    if not entity.is_alive(ent) then return end

    -- initialise per-player data
    if not R.pdata[ent] then
        R.pdata[ent] = { misses = 0, last_side = 0, last_method = "none", last_yaw = 0,
                         last_simtime = nil, was_dormant = false }
    end
    local pd = R.pdata[ent]

    local recs       = R.records[ent]
    local rec        = recs and recs[1]
    local old_rec    = recs and recs[2]

    local velocity   = get_velocity_2d(ent)
    local on_ground  = is_on_ground(ent)
    local ducking    = is_ducking(ent)
    local dormant    = entity.is_dormant(ent)
    local from_dorm  = pd.was_dormant and not dormant
    local lc_break   = is_breaking_lc(ent)
    local sideways   = is_sideways(ent, local_ent)

    -- update state
    pd.last_simtime  = get_sim_time(ent)
    pd.was_dormant   = dormant

    -- debug snapshot
    R.dbg[ent] = {
        name        = entity.get_player_name(ent) or "?",
        velocity    = velocity,
        on_ground   = on_ground,
        ducking     = ducking,
        sideways    = sideways,
        lc_break    = lc_break,
        from_dorm   = from_dorm,
        method      = "none",
        yaw         = 0,
        misses      = pd.misses,
        jitter      = false,
    }

    -- ── 0. Dormant ────────────────────────────────────────────────────────────
    if dormant then
        R.dbg[ent].method = "dormant"
        apply_safe(ent)
        return
    end

    -- ── 1. In Air ─────────────────────────────────────────────────────────────
    if not on_ground then
        R.dbg[ent].method = "air"
        apply_safe(ent)
        return
    end

    -- ── 2. Moving fast ────────────────────────────────────────────────────────
    if velocity > 80 then
        R.dbg[ent].method = "moving"
        apply_safe(ent)
        return
    end

    -- ── 3. No animation data ──────────────────────────────────────────────────
    local as = get_anim_state(ent)
    if not as or not rec then
        R.dbg[ent].method = "no data"
        apply_safe(ent)
        return
    end

    local max_desync = calc_max_desync(as)

    -- fill debug extras
    R.dbg[ent].eye_yaw   = rec.eye_yaw
    R.dbg[ent].goal_feet = rec.goal_feet_yaw
    R.dbg[ent].max_desync = max_desync

    -- ── 4. Max-miss safe point ────────────────────────────────────────────────
    if pd.misses >= MAX_MISSES then
        R.dbg[ent].method = "max_miss"
        apply_safe(ent)
        return
    end

    -- ── 5. Jitter ─────────────────────────────────────────────────────────────
    local is_jitter, jitter_side = detect_jitter(ent)
    R.dbg[ent].jitter = is_jitter

    if is_jitter then
        if jitter_side ~= 0 then
            local yaw_val = jitter_side * max_desync
            R.dbg[ent].method = "jitter"
            R.dbg[ent].yaw    = yaw_val
            apply_yaw(ent, yaw_val, "jitter", pd)
        else
            R.dbg[ent].method = "jitter_safe"
            apply_safe(ent)
        end
        return
    end

    -- ── 6. Freestand (sideways only) ──────────────────────────────────────────
    if sideways then
        local dmg_side   = freestand_damage(ent, local_ent)
        local trace_side = freestand_trace(ent, local_ent)
        local side       = dmg_side ~= 0 and dmg_side or trace_side

        if side ~= 0 then
            local yaw_val = side * 58
            local method  = dmg_side ~= 0 and "freestand_dmg" or "freestand_trace"
            R.dbg[ent].method = method
            R.dbg[ent].yaw    = yaw_val
            apply_yaw(ent, yaw_val, method, pd)
            return
        end
    end

    -- ── 7. Animation Layer 6 ──────────────────────────────────────────────────
    local anim_side = detect_side_from_layers(ent, rec, old_rec)
    if anim_side ~= 0 then
        local eye_foot_diff = math.abs(angle_diff(rec.eye_yaw, rec.goal_feet_yaw))
        local desync_delta  = clamp(eye_foot_diff, 29, max_desync)
        local yaw_val       = anim_side * desync_delta
        R.dbg[ent].method   = "animation"
        R.dbg[ent].yaw      = yaw_val
        apply_yaw(ent, yaw_val, "animation", pd)
        return
    end

    -- ── 8. Bruteforce ─────────────────────────────────────────────────────────
    local brute_yaw = BRUTE_SEQUENCE[(pd.misses % #BRUTE_SEQUENCE) + 1]
    local method    = ducking and "brute_duck" or "brute"
    R.dbg[ent].method = method
    R.dbg[ent].yaw    = brute_yaw
    apply_yaw(ent, brute_yaw, method, pd)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- net_update_end  (main tick)
-- ─────────────────────────────────────────────────────────────────────────────
client.set_event_callback("net_update_end", function()
    if not R.enabled then return end

    local local_ent = entity.get_local_player()
    if not local_ent or not entity.is_alive(local_ent) then return end

    local enemies = entity.get_players(true)
    if not enemies then return end

    -- first pass: store animation records for all live enemies
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            store_record(ent)
        end
    end

    -- second pass: resolve
    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) then
            resolve(ent, local_ent)
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- aim_miss
-- ─────────────────────────────────────────────────────────────────────────────
client.set_event_callback("aim_miss", function(e)
    if not R.enabled then return end
    -- Gamesense: e.reason can be "spread", "prediction_error", or nil (resolver miss)
    if e.reason ~= nil then return end   -- only count resolver misses

    local ent = e.target
    if not ent then return end

    if not R.pdata[ent] then R.pdata[ent] = { misses = 0 } end
    local pd = R.pdata[ent]
    pd.misses = pd.misses + 1

    R.stats.misses = R.stats.misses + 1
    R.stats.total  = R.stats.total  + 1

    if R.dbg[ent] then R.dbg[ent].misses = pd.misses end

    local name = entity.get_player_name(ent) or "?"
    client.color_log(255, 165, 0,
        string.format("[Resolver] Miss #%d on %s | method: %s | yaw: %.1f°",
            pd.misses, name, pd.last_method or "?", pd.last_yaw or 0))

    if pd.misses >= MAX_MISSES then
        client.color_log(255, 80, 80, "[Resolver] Max misses reached for " .. name .. " — safe point")
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- aim_hit
-- ─────────────────────────────────────────────────────────────────────────────
client.set_event_callback("aim_hit", function(e)
    if not R.enabled then return end

    local ent = e.target
    if not ent then return end

    R.stats.hits  = R.stats.hits  + 1
    R.stats.total = R.stats.total + 1

    local pd   = R.pdata[ent]
    local name = entity.get_player_name(ent) or "?"

    client.color_log(0, 220, 80,
        string.format("[Resolver] HIT %s | method: %s | yaw: %.1f° | dmg: %d",
            name,
            pd and pd.last_method or "?",
            pd and pd.last_yaw    or 0,
            e.damage or 0))

    -- reset miss counter on hit, keep last_method/yaw for logging
    if pd then
        pd.misses = 0
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- player_death
-- ─────────────────────────────────────────────────────────────────────────────
client.set_event_callback("player_death", function(e)
    local ent = client.userid_to_entindex(e.userid)
    if not ent then return end
    R.records[ent]  = nil
    R.pdata[ent]    = nil
    R.jitter[ent]   = nil
    R.dbg[ent]      = nil
    pcall(function() apply(ent, {}) end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- round_start
-- ─────────────────────────────────────────────────────────────────────────────
client.set_event_callback("round_start", function()
    R.records = {}
    R.pdata   = {}
    R.jitter  = {}
    R.dbg     = {}
    local enemies = entity.get_players(true)
    if enemies then
        for _, ent in ipairs(enemies) do
            pcall(function() apply(ent, {}) end)
        end
    end
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Debug Panel  (paint)
-- ─────────────────────────────────────────────────────────────────────────────
local METHOD_COLORS = {
    freestand_dmg   = { 50, 255, 150 },
    freestand_trace = {  0, 220, 100 },
    animation       = { 100, 200, 255 },
    brute           = { 255, 200, 100 },
    brute_duck      = { 255, 150,  50 },
    jitter          = { 255, 100, 255 },
    jitter_safe     = { 200,  80, 200 },
    air             = { 120, 120, 120 },
    moving          = { 120, 120, 120 },
    dormant         = {  80,  80,  80 },
    max_miss        = { 255,  60,  60 },
    ["no data"]     = { 160, 160, 160 },
}

local function draw_debug()
    if not R.debug then return end

    local sw, sh = client.screen_size()
    local x, y  = 10, 180
    local W      = 290

    -- header
    renderer.rectangle(x - 4, y - 4, W, 22, 0, 0, 0, 210)
    renderer.text(x, y, 255, 200, 80, 255, nil, 0, "[ RESOLVER ]")

    local acc_str
    if R.stats.total > 0 then
        acc_str = string.format("%.1f%% (%d/%d)",
            R.stats.hits / R.stats.total * 100, R.stats.hits, R.stats.total)
    else
        acc_str = "n/a"
    end
    renderer.text(x + 120, y, 160, 160, 160, 255, nil, 0, "Acc: " .. acc_str)
    y = y + 24

    local enemies = entity.get_players(true)
    if not enemies then return end

    for _, ent in ipairs(enemies) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local info = R.dbg[ent]
            if info then
                local row_h = info.jitter and 82 or 68
                renderer.rectangle(x - 4, y - 2, W, row_h, 14, 14, 14, 215)

                local mc  = METHOD_COLORS[info.method] or { 200, 200, 200 }
                local nc  = info.lc_break and { 255, 90, 90 } or { 240, 240, 240 }
                local tag = (info.lc_break and " [LC]" or "") .. (info.from_dorm and " [D]" or "")

                renderer.text(x, y,      nc[1], nc[2], nc[3], 255, nil, 0, info.name .. tag)
                renderer.text(x, y + 14, mc[1], mc[2], mc[3], 255, nil, 0, "Method: " .. info.method)
                renderer.text(x, y + 28, 150, 150, 150, 255, nil, 0,
                    string.format("Vel: %.1f  Yaw: %.1f  Max: %.1f",
                        info.velocity, info.yaw, info.max_desync or 58))
                renderer.text(x, y + 42, 150, 150, 150, 255, nil, 0,
                    string.format("Misses: %d  Duck: %s  Side: %s",
                        info.misses,
                        info.ducking  and "Y" or "N",
                        info.sideways and "Y" or "N"))
                if info.jitter then
                    renderer.text(x, y + 56, 255, 80, 255, 255, nil, 0, "⚡ JITTER DETECTED")
                end

                y = y + row_h + 3
                if y > sh - 80 then break end
            end
        end
    end
end

client.set_event_callback("paint", draw_debug)

-- ─────────────────────────────────────────────────────────────────────────────
-- Shutdown cleanup
-- ─────────────────────────────────────────────────────────────────────────────
client.set_event_callback("shutdown", function()
    local enemies = entity.get_players(true)
    if enemies then
        for _, ent in ipairs(enemies) do
            pcall(function() apply(ent, {}) end)
        end
    end
    client.color_log(255, 200, 80, "[Resolver] Unloaded — plist reset")
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- UI  (Gamesense ui.* API)
-- ─────────────────────────────────────────────────────────────────────────────
local ui_enable = ui.new_checkbox("LUA", "a", "Advanced Resolver")
local ui_debug  = ui.new_checkbox("LUA", "a", "Resolver Debug Panel")

ui.set_callback(ui_enable, function()
    R.enabled = ui.get(ui_enable)
    if not R.enabled then
        local enemies = entity.get_players(true)
        if enemies then
            for _, ent in ipairs(enemies) do pcall(function() apply(ent, {}) end) end
        end
        client.color_log(200, 200, 200, "[Resolver] Disabled")
    else
        client.color_log(0, 220, 80, "[Resolver] Enabled")
    end
end)

ui.set_callback(ui_debug, function()
    R.debug = ui.get(ui_debug)
end)

ui.set(ui_enable, true)
ui.set(ui_debug,  true)

client.log("[Resolver] Loaded — net_update_end | Layer6 | Freestand | Jitter | Brute")
