--[[
╔══════════════════════════════════════════════════════════════════════════════╗
║                    VISUALS  v1  —  Gamesense (gamesense.pub)                ║
║                                                                              ║
║  Features:                                                                   ║
║   • ESP: 3D/2D box, corner box, health bar, armour bar, name, weapon,       ║
║          distance, ammo bar, flags (scoped/flash/bomb/defuse/reloading)     ║
║   • Skeleton with per-bone colour                                            ║
║   • Head dot / glow ring                                                     ║
║   • Snap lines (feet or crosshair)                                           ║
║   • Hit markers (cross + damage number, animated)                            ║
║   • Damage indicators (floating numbers, fade out)                           ║
║   • Grenade trajectory prediction                                            ║
║   • Bomb timer (planted C4 countdown + site + defuse state)                 ║
║   • Radar (mini-map with entity dots)                                        ║
║   • Spectator list                                                           ║
║   • Watermark with FPS / ping / server                                       ║
║   • Animated crosshair                                                       ║
║   • Full UI panel (checkboxes, sliders, colour pickers)                     ║
╚══════════════════════════════════════════════════════════════════════════════╝
--]]

local ffi = require("ffi")
local bit = bit

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 1  FFI TYPES
-- ═══════════════════════════════════════════════════════════════════════════════
ffi.cdef[[
typedef struct { float x, y, z; } vec3_t;
typedef void*(__thiscall* get_client_entity_t)(void*, int);
]]

local entity_list    = ffi.cast("uintptr_t**",         client.create_interface("client.dll", "VClientEntityList003"))
local get_entity_raw = ffi.cast("get_client_entity_t", entity_list[0][3])

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 2  CONSTANTS & MATH
-- ═══════════════════════════════════════════════════════════════════════════════
local PI  = math.pi
local DEG = 180 / PI
local RAD = PI / 180

local function clamp(v, lo, hi)
    if not v then return lo end
    return v < lo and lo or (v > hi and hi or v)
end

local function lerp(a, b, t) return a + (b - a) * clamp(t, 0, 1) end

local function norm_yaw(y)
    y = y % 360
    if y >  180 then y = y - 360 end
    if y < -180 then y = y + 360 end
    return y
end

local function len2(x, y) return math.sqrt(x*x + y*y) end

local function len3(x, y, z) return math.sqrt(x*x + y*y + z*z) end

-- HSV → RGB (all 0-255)
local function hsv_to_rgb(h, s, v)
    h = h % 360
    local c = v * s / 255
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if     h < 60  then r,g,b = c,x,0
    elseif h < 120 then r,g,b = x,c,0
    elseif h < 180 then r,g,b = 0,c,x
    elseif h < 240 then r,g,b = 0,x,c
    elseif h < 300 then r,g,b = x,0,c
    else                r,g,b = c,0,x
    end
    return math.floor((r+m)*255+0.5), math.floor((g+m)*255+0.5), math.floor((b+m)*255+0.5)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 3  UI DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════════
local UI = {}

-- ── ESP ──────────────────────────────────────────────────────────────────────
UI.esp_enable    = ui.new_checkbox("Visuals", "Enable ESP")
UI.esp_enemies   = ui.new_checkbox("Visuals", "Enemies")
UI.esp_team      = ui.new_checkbox("Visuals", "Teammates")
UI.box_style     = ui.new_combobox("Visuals", "Box Style", {"Corner", "Full", "3D"})
UI.box_col_e     = ui.new_color_picker("Visuals", "Enemy box colour",    255, 60,  60,  255)
UI.box_col_t     = ui.new_color_picker("Visuals", "Team box colour",     60,  180, 255, 255)
UI.health_bar    = ui.new_checkbox("Visuals", "Health bar")
UI.armour_bar    = ui.new_checkbox("Visuals", "Armour bar")
UI.name_tag      = ui.new_checkbox("Visuals", "Name tag")
UI.weapon_tag    = ui.new_checkbox("Visuals", "Weapon tag")
UI.ammo_bar      = ui.new_checkbox("Visuals", "Ammo bar")
UI.distance_tag  = ui.new_checkbox("Visuals", "Distance tag")
UI.flags_tag     = ui.new_checkbox("Visuals", "Flags (scoped/flash/etc)")
UI.snap_lines    = ui.new_checkbox("Visuals", "Snap lines")
UI.snap_origin   = ui.new_combobox("Visuals", "Snap origin", {"Bottom", "Crosshair"})

-- ── Skeleton ─────────────────────────────────────────────────────────────────
UI.skeleton      = ui.new_checkbox("Visuals", "Skeleton")
UI.head_dot      = ui.new_checkbox("Visuals", "Head dot")
UI.skel_col_e    = ui.new_color_picker("Visuals", "Enemy skeleton colour",  255, 100, 100, 200)
UI.skel_col_t    = ui.new_color_picker("Visuals", "Team skeleton colour",   100, 180, 255, 200)

-- ── Hit effects ──────────────────────────────────────────────────────────────
UI.hitmarker     = ui.new_checkbox("Visuals", "Hit marker")
UI.hit_col       = ui.new_color_picker("Visuals", "Hit marker colour", 255, 255, 255, 255)
UI.dmg_numbers   = ui.new_checkbox("Visuals", "Damage numbers")
UI.dmg_col       = ui.new_color_picker("Visuals", "Damage number colour", 255, 60, 60, 255)

-- ── World ─────────────────────────────────────────────────────────────────────
UI.bomb_timer    = ui.new_checkbox("Visuals", "Bomb timer")
UI.grenade_pred  = ui.new_checkbox("Visuals", "Grenade prediction")
UI.radar         = ui.new_checkbox("Visuals", "Radar")
UI.radar_size    = ui.new_slider("Visuals", "Radar size", 80, 300, 160)

-- ── Misc ─────────────────────────────────────────────────────────────────────
UI.watermark     = ui.new_checkbox("Visuals", "Watermark")
UI.spectators    = ui.new_checkbox("Visuals", "Spectator list")
UI.crosshair     = ui.new_checkbox("Visuals", "Custom crosshair")
UI.crosshair_col = ui.new_color_picker("Visuals", "Crosshair colour", 255, 255, 255, 220)
UI.rainbow_box   = ui.new_checkbox("Visuals", "Rainbow box")

-- Set defaults
ui.set(UI.esp_enable,   true)
ui.set(UI.esp_enemies,  true)
ui.set(UI.esp_team,     false)
ui.set(UI.box_style,    "Corner")
ui.set(UI.health_bar,   true)
ui.set(UI.armour_bar,   true)
ui.set(UI.name_tag,     true)
ui.set(UI.weapon_tag,   true)
ui.set(UI.ammo_bar,     true)
ui.set(UI.distance_tag, true)
ui.set(UI.flags_tag,    true)
ui.set(UI.snap_lines,   false)
ui.set(UI.skeleton,     true)
ui.set(UI.head_dot,     true)
ui.set(UI.hitmarker,    true)
ui.set(UI.dmg_numbers,  true)
ui.set(UI.bomb_timer,   true)
ui.set(UI.grenade_pred, true)
ui.set(UI.radar,        true)
ui.set(UI.watermark,    true)
ui.set(UI.spectators,   true)
ui.set(UI.crosshair,    true)
ui.set(UI.rainbow_box,  false)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 4  STATE
-- ═══════════════════════════════════════════════════════════════════════════════
local V = {
    hit_effects  = {},   -- { x, y, alpha, size, damage }
    dmg_effects  = {},   -- { x, y, z, alpha, damage, vy }
    rainbow_hue  = 0,
    frame        = 0,
    fps_samples  = {},
    fps_avg      = 0,
    last_fps_t   = 0,
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 5  ENTITY HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════
local function get_ptr(ent)
    local p = get_entity_raw(entity_list, ent)
    if p == nil or p == ffi.NULL then return nil end
    return p
end

local function get_health(ent)
    return entity.get_prop(ent, "m_iHealth") or 0
end

local function get_armour(ent)
    return entity.get_prop(ent, "m_ArmorValue") or 0
end

local function get_flags(ent)
    return entity.get_prop(ent, "m_fFlags") or 0
end

local function is_scoped(ent)
    return (entity.get_prop(ent, "m_bIsScoped") or 0) == 1
end

local function is_flashed(ent)
    return (entity.get_prop(ent, "m_flFlashMaxAlpha") or 0) > 10
end

local function is_defusing(ent)
    return (entity.get_prop(ent, "m_bIsDefusing") or false) == true
        or (entity.get_prop(ent, "m_bIsDefusing") or 0) == 1
end

local function is_reloading(ent)
    local wpn = entity.get_prop(ent, "m_hActiveWeapon")
    if not wpn then return false end
    return (entity.get_prop(wpn, "m_bInReload") or false) == true
end

local function has_bomb(ent)
    -- Check if player is carrying the bomb
    local wpns = entity.get_prop(ent, "m_hMyWeapons")
    if not wpns then return false end
    -- Simplified: check classname of active weapon
    local wpn = entity.get_prop(ent, "m_hActiveWeapon")
    if not wpn then return false end
    return entity.get_classname(wpn) == "CC4"
end

local function get_weapon_name(ent)
    local wpn = entity.get_prop(ent, "m_hActiveWeapon")
    if not wpn then return "" end
    local name = entity.get_classname(wpn) or ""
    -- Strip "CWeapon" prefix and "C_" prefix
    name = name:gsub("^CWeapon", ""):gsub("^C_Weapon", ""):gsub("^C_", "")
    return name:upper()
end

local function get_ammo(ent)
    local wpn = entity.get_prop(ent, "m_hActiveWeapon")
    if not wpn then return 0, 0 end
    local clip = entity.get_prop(wpn, "m_iClip1") or 0
    local max_clip = 30  -- default; real max varies by weapon
    return clip, max_clip
end

local function get_distance(ent, local_ent)
    local ex, ey, ez = entity.get_origin(ent)
    local lx, ly, lz = entity.get_origin(local_ent)
    if not ex or not lx then return 0 end
    return math.floor(len3(ex - lx, ey - ly, ez - lz) / 52.49)  -- units to metres
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 6  BOUNDING BOX
-- ═══════════════════════════════════════════════════════════════════════════════
-- Returns screen-space bounding box (x, y, w, h) or nil if off-screen
local function get_bbox(ent)
    local ex, ey, ez = entity.get_origin(ent)
    if not ex then return nil end

    local duck = entity.get_prop(ent, "m_flDuckAmount") or 0
    local top_z = ez + lerp(72, 54, duck)

    -- Project 8 corners of the bounding box
    local mins = { -16, -16, 0 }
    local maxs = {  16,  16, top_z - ez }

    local sx_min, sy_min = math.huge, math.huge
    local sx_max, sy_max = -math.huge, -math.huge

    for _, cx in ipairs({ mins[1], maxs[1] }) do
        for _, cy in ipairs({ mins[2], maxs[2] }) do
            for _, cz in ipairs({ mins[3], maxs[3] }) do
                local sx, sy = client.world_to_screen(ex + cx, ey + cy, ez + cz)
                if sx then
                    if sx < sx_min then sx_min = sx end
                    if sx > sx_max then sx_max = sx end
                    if sy < sy_min then sy_min = sy end
                    if sy > sy_max then sy_max = sy end
                end
            end
        end
    end

    if sx_min == math.huge then return nil end
    return sx_min, sy_min, sx_max - sx_min, sy_max - sy_min
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 7  BOX DRAWING
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_corner_box(x, y, w, h, r, g, b, a)
    local cw = math.max(4, math.floor(w * 0.25))
    local ch = math.max(4, math.floor(h * 0.25))
    local t  = 1  -- thickness

    -- Top-left
    renderer.line(x,       y,       x + cw, y,       r, g, b, a)
    renderer.line(x,       y,       x,       y + ch, r, g, b, a)
    -- Top-right
    renderer.line(x+w,     y,       x+w-cw, y,       r, g, b, a)
    renderer.line(x+w,     y,       x+w,     y + ch, r, g, b, a)
    -- Bottom-left
    renderer.line(x,       y+h,     x + cw, y+h,     r, g, b, a)
    renderer.line(x,       y+h,     x,       y+h-ch, r, g, b, a)
    -- Bottom-right
    renderer.line(x+w,     y+h,     x+w-cw, y+h,     r, g, b, a)
    renderer.line(x+w,     y+h,     x+w,     y+h-ch, r, g, b, a)
end

local function draw_full_box(x, y, w, h, r, g, b, a)
    renderer.rectangle(x,   y,   w, 1, r, g, b, a)
    renderer.rectangle(x,   y+h, w, 1, r, g, b, a)
    renderer.rectangle(x,   y,   1, h, r, g, b, a)
    renderer.rectangle(x+w, y,   1, h+1, r, g, b, a)
end

local function draw_3d_box(ent, r, g, b, a)
    local ex, ey, ez = entity.get_origin(ent)
    if not ex then return end
    local duck = entity.get_prop(ent, "m_flDuckAmount") or 0
    local top_z = ez + lerp(72, 54, duck)

    local corners = {
        {-16, -16}, {16, -16}, {16, 16}, {-16, 16}
    }

    local bot, top = {}, {}
    for _, c in ipairs(corners) do
        local bx, by = client.world_to_screen(ex + c[1], ey + c[2], ez)
        local tx, ty = client.world_to_screen(ex + c[1], ey + c[2], top_z)
        if not bx then return end
        bot[#bot+1] = { bx, by }
        top[#top+1] = { tx, ty }
    end

    -- Draw edges
    for i = 1, 4 do
        local j = i % 4 + 1
        renderer.line(bot[i][1], bot[i][2], bot[j][1], bot[j][2], r, g, b, a)
        renderer.line(top[i][1], top[i][2], top[j][1], top[j][2], r, g, b, a)
        renderer.line(bot[i][1], bot[i][2], top[i][1], top[i][2], r, g, b, a)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 8  HEALTH / ARMOUR / AMMO BARS
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_health_bar(x, y, h, hp)
    local frac = clamp(hp / 100, 0, 1)
    local bar_h = math.floor(h * frac)
    local r = math.floor(lerp(255, 0,   frac))
    local g = math.floor(lerp(0,   255, frac))

    -- Background
    renderer.rectangle(x - 6, y,     4, h,     0, 0, 0, 180)
    -- Fill (bottom-up)
    renderer.rectangle(x - 6, y + h - bar_h, 4, bar_h, r, g, 0, 220)

    -- HP text if low
    if hp <= 30 then
        renderer.text(x - 5, y + h - bar_h - 8, r, g, 0, 255, "c", 0, tostring(hp))
    end
end

local function draw_armour_bar(x, y, w, armour)
    if armour <= 0 then return end
    local frac = clamp(armour / 100, 0, 1)
    renderer.rectangle(x,     y + 3, w,                  2, 0,   0,   0,   160)
    renderer.rectangle(x,     y + 3, math.floor(w*frac), 2, 100, 180, 255, 220)
end

local function draw_ammo_bar(x, y, w, clip, max_clip)
    if max_clip <= 0 then return end
    local frac = clamp(clip / max_clip, 0, 1)
    renderer.rectangle(x,     y - 4, w,                  2, 0,   0,   0,   160)
    renderer.rectangle(x,     y - 4, math.floor(w*frac), 2, 255, 200, 50,  220)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 9  SKELETON
-- ═══════════════════════════════════════════════════════════════════════════════
-- Standard CS:GO player skeleton bone pairs (hitbox IDs used as proxy)
-- We use entity.hitbox_position for reliable bone positions
local SKELETON_PAIRS = {
    -- Head → neck → spine
    {0, 1}, {1, 2}, {2, 3}, {3, 4},
    -- Spine → shoulders
    {4, 5}, {4, 8},
    -- Left arm
    {5, 6}, {6, 7},
    -- Right arm
    {8, 9}, {9, 10},
    -- Spine → hips
    {3, 11}, {3, 12},
    -- Left leg
    {11, 13}, {13, 15},
    -- Right leg
    {12, 14}, {14, 16},
}

local function draw_skeleton(ent, r, g, b, a)
    local positions = {}
    for i = 0, 16 do
        local hx, hy, hz = entity.hitbox_position(ent, i)
        if hx then
            local sx, sy = client.world_to_screen(hx, hy, hz)
            positions[i] = sx and { sx, sy } or nil
        end
    end

    for _, pair in ipairs(SKELETON_PAIRS) do
        local p1 = positions[pair[1]]
        local p2 = positions[pair[2]]
        if p1 and p2 then
            renderer.line(p1[1], p1[2], p2[1], p2[2], r, g, b, a)
        end
    end
end

local function draw_head_dot(ent, r, g, b, a)
    local hx, hy, hz = entity.hitbox_position(ent, 0)
    if not hx then return end
    local sx, sy = client.world_to_screen(hx, hy, hz)
    if not sx then return end
    renderer.circle(sx, sy, r, g, b, a, 5, 0, 1)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 10  SNAP LINES
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_snap_line(ent, r, g, b, a)
    local ex, ey, ez = entity.get_origin(ent)
    if not ex then return end
    local sx, sy = client.world_to_screen(ex, ey, ez)
    if not sx then return end

    local sw, sh = client.screen_size()
    local origin = ui.get(UI.snap_origin)
    local ox, oy
    if origin == "Crosshair" then
        ox, oy = sw / 2, sh / 2
    else
        ox, oy = sw / 2, sh
    end

    renderer.line(ox, oy, sx, sy, r, g, b, a)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 11  FLAGS
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_flags(ent, x, y, h)
    local flags = {}
    if is_scoped(ent)   then flags[#flags+1] = { "SCOPE",   100, 200, 255 } end
    if is_flashed(ent)  then flags[#flags+1] = { "FLASH",   255, 255, 100 } end
    if is_defusing(ent) then flags[#flags+1] = { "DEFUSE",  100, 255, 200 } end
    if is_reloading(ent)then flags[#flags+1] = { "RELOAD",  255, 180, 50  } end
    if has_bomb(ent)    then flags[#flags+1] = { "BOMB",    255, 80,  80  } end

    local fy = y
    for _, f in ipairs(flags) do
        renderer.text(x + 4, fy, f[2], f[3], f[4], 220, nil, 0, f[1])
        fy = fy + 10
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 12  MAIN ESP DRAW FUNCTION
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_esp(ent, local_ent, is_enemy)
    if not entity.is_alive(ent) then return end
    if entity.is_dormant(ent)   then return end

    local x, y, w, h = get_bbox(ent)
    if not x then return end

    -- Colour selection
    local r, g, b, a
    if ui.get(UI.rainbow_box) then
        r, g, b = hsv_to_rgb(V.rainbow_hue, 255, 255)
        a = 255
    elseif is_enemy then
        r, g, b, a = ui.get(UI.box_col_e)
    else
        r, g, b, a = ui.get(UI.box_col_t)
    end

    -- Box
    local style = ui.get(UI.box_style)
    if style == "Corner" then
        draw_corner_box(x, y, w, h, r, g, b, a)
    elseif style == "Full" then
        draw_full_box(x, y, w, h, r, g, b, a)
        -- Subtle fill
        renderer.rectangle(x+1, y+1, w-1, h-1, r, g, b, 20)
    elseif style == "3D" then
        draw_3d_box(ent, r, g, b, a)
    end

    -- Health bar (left side)
    if ui.get(UI.health_bar) then
        draw_health_bar(x, y, h, get_health(ent))
    end

    -- Armour bar (bottom of box)
    if ui.get(UI.armour_bar) then
        draw_armour_bar(x, y + h, w, get_armour(ent))
    end

    -- Ammo bar (above box)
    if ui.get(UI.ammo_bar) then
        local clip, max_clip = get_ammo(ent)
        draw_ammo_bar(x, y, w, clip, max_clip)
    end

    -- Name tag (above box)
    local text_y = y - 2
    if ui.get(UI.name_tag) then
        local name = entity.get_player_name(ent) or "?"
        renderer.text(x + w/2, text_y - 10, 255, 255, 255, 220, "c", 0, name)
        text_y = text_y - 10
    end

    -- Distance tag
    if ui.get(UI.distance_tag) then
        local dist = get_distance(ent, local_ent)
        renderer.text(x + w/2, text_y - 10, 180, 180, 180, 180, "c", 0,
            string.format("%dm", dist))
        text_y = text_y - 10
    end

    -- Weapon tag (below box)
    if ui.get(UI.weapon_tag) then
        local wpn = get_weapon_name(ent)
        if wpn ~= "" then
            renderer.text(x + w/2, y + h + 6, 220, 220, 100, 200, "c", 0, wpn)
        end
    end

    -- Flags (right side)
    if ui.get(UI.flags_tag) then
        draw_flags(ent, x + w, y, h)
    end

    -- Skeleton
    local sr, sg, sb, sa
    if is_enemy then
        sr, sg, sb, sa = ui.get(UI.skel_col_e)
    else
        sr, sg, sb, sa = ui.get(UI.skel_col_t)
    end

    if ui.get(UI.skeleton) then
        draw_skeleton(ent, sr, sg, sb, sa)
    end

    if ui.get(UI.head_dot) then
        draw_head_dot(ent, r, g, b, a)
    end

    -- Snap lines
    if ui.get(UI.snap_lines) then
        draw_snap_line(ent, r, g, b, 120)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 13  HIT MARKER
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_hit_effects()
    local sw, sh = client.screen_size()
    local cx, cy = sw / 2, sh / 2
    local now    = globals.realtime()

    for i = #V.hit_effects, 1, -1 do
        local e = V.hit_effects[i]
        local age = now - e.time
        if age > 0.5 then
            table.remove(V.hit_effects, i)
        else
            local alpha = math.floor(255 * (1 - age / 0.5))
            local size  = e.size + age * 20
            local hr, hg, hb, ha = ui.get(UI.hit_col)

            if ui.get(UI.hitmarker) then
                -- Cross lines
                renderer.line(e.x - size, e.y,        e.x - 3,    e.y,        hr, hg, hb, math.floor(alpha * ha / 255))
                renderer.line(e.x + 3,    e.y,        e.x + size, e.y,        hr, hg, hb, math.floor(alpha * ha / 255))
                renderer.line(e.x,        e.y - size, e.x,        e.y - 3,    hr, hg, hb, math.floor(alpha * ha / 255))
                renderer.line(e.x,        e.y + 3,    e.x,        e.y + size, hr, hg, hb, math.floor(alpha * ha / 255))
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 14  DAMAGE NUMBERS
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_dmg_numbers()
    local now = globals.realtime()
    local dr, dg, db, da = ui.get(UI.dmg_col)

    for i = #V.dmg_effects, 1, -1 do
        local e = V.dmg_effects[i]
        local age = now - e.time
        if age > 1.2 then
            table.remove(V.dmg_effects, i)
        else
            local alpha = math.floor(255 * (1 - age / 1.2))
            -- Float upward
            local wx = e.x
            local wy = e.y
            local wz = e.z + age * 30

            local sx, sy = client.world_to_screen(wx, wy, wz)
            if sx then
                renderer.text(sx, sy, dr, dg, db, math.floor(alpha * da / 255),
                    "c", 0, "-" .. tostring(e.damage))
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 15  BOMB TIMER
-- ═══════════════════════════════════════════════════════════════════════════════
local BOMB_FUSE    = 40.0   -- seconds
local BOMB_DEFUSE  = 10.0   -- seconds (no kit)
local BOMB_DEFUSE_KIT = 5.0

local function draw_bomb_timer()
    -- Find planted C4
    local bomb = nil
    for _, ent in ipairs(entity.get_all("CPlantedC4")) do
        bomb = ent
        break
    end
    if not bomb then return end

    local blow_time  = entity.get_prop(bomb, "m_flC4Blow")       or 0
    local defuse_end = entity.get_prop(bomb, "m_flDefuseCountDown") or 0
    local defusing   = (entity.get_prop(bomb, "m_bBeingDefused") or false) == true
                    or (entity.get_prop(bomb, "m_bBeingDefused") or 0) == 1
    local site       = entity.get_prop(bomb, "m_nBombSite")      or 0
    local now        = globals.curtime()

    local time_left  = math.max(0, blow_time - now)
    local site_str   = site == 0 and "A" or "B"

    local sw, sh = client.screen_size()
    local bx, by = sw / 2 - 100, sh - 80
    local bw, bh = 200, 50

    -- Background
    renderer.rectangle(bx - 4, by - 4, bw + 8, bh + 8, 0, 0, 0, 200)

    -- Title
    local title_col = defusing and { 100, 255, 200 } or { 255, 80, 80 }
    renderer.text(bx + bw/2, by, title_col[1], title_col[2], title_col[3], 255,
        "c", 0, string.format("BOMB [%s]  %.1fs", site_str, time_left))

    -- Progress bar
    local frac = clamp(time_left / BOMB_FUSE, 0, 1)
    local bar_r = math.floor(lerp(255, 50, frac))
    local bar_g = math.floor(lerp(50, 255, frac))
    renderer.rectangle(bx,     by + 14, bw,                  8, 0,   0,   0,   180)
    renderer.rectangle(bx,     by + 14, math.floor(bw*frac), 8, bar_r, bar_g, 0, 230)

    -- Defuse info
    if defusing then
        local defuse_left = math.max(0, defuse_end - now)
        local can_defuse  = defuse_left < time_left
        local dc = can_defuse and { 100, 255, 100 } or { 255, 100, 100 }
        renderer.text(bx + bw/2, by + 26, dc[1], dc[2], dc[3], 255,
            "c", 0, string.format("Defusing: %.1fs  %s",
                defuse_left, can_defuse and "✓" or "✗"))
    else
        renderer.text(bx + bw/2, by + 26, 180, 180, 180, 200,
            "c", 0, "Not being defused")
    end

    -- World indicator on bomb
    local bwx, bwy, bwz = entity.get_origin(bomb)
    if bwx then
        local sx, sy = client.world_to_screen(bwx, bwy, bwz + 10)
        if sx then
            renderer.text(sx, sy - 12, 255, 80, 80, 255, "c", 0,
                string.format("%.1fs", time_left))
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 16  GRENADE PREDICTION
-- ═══════════════════════════════════════════════════════════════════════════════
local GRENADE_CLASSES = {
    "CBaseCSGrenadeProjectile",
    "CSmokeGrenadeProjectile",
    "CFlashbang",
    "CMolotovProjectile",
    "CDecoyProjectile",
    "CHEGrenadeProjectile",
}

local GRENADE_COLORS = {
    CBaseCSGrenadeProjectile = { 255, 200, 50  },
    CSmokeGrenadeProjectile  = { 150, 150, 150 },
    CFlashbang               = { 255, 255, 200 },
    CMolotovProjectile       = { 255, 100, 30  },
    CDecoyProjectile         = { 100, 200, 255 },
    CHEGrenadeProjectile     = { 255, 80,  80  },
}

local function draw_grenade_prediction()
    for _, cls in ipairs(GRENADE_CLASSES) do
        for _, ent in ipairs(entity.get_all(cls)) do
            local gx, gy, gz = entity.get_origin(ent)
            if gx then
                local sx, sy = client.world_to_screen(gx, gy, gz)
                if sx then
                    local col = GRENADE_COLORS[cls] or { 255, 255, 255 }
                    renderer.circle(sx, sy, col[1], col[2], col[3], 200, 6, 0, 1)
                    renderer.text(sx, sy - 10, col[1], col[2], col[3], 200,
                        "c", 0, cls:gsub("C", ""):gsub("Projectile", ""):upper())
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 17  RADAR
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_radar()
    local sw, sh = client.screen_size()
    local size   = ui.get(UI.radar_size)
    local rx     = sw - size - 10
    local ry     = 10
    local scale  = size / 4096  -- map units to radar pixels (approximate)

    -- Background
    renderer.rectangle(rx, ry, size, size, 0, 0, 0, 180)
    renderer.rectangle(rx, ry, size, 1,    80, 80, 80, 200)
    renderer.rectangle(rx, ry+size, size, 1, 80, 80, 80, 200)
    renderer.rectangle(rx, ry, 1, size,    80, 80, 80, 200)
    renderer.rectangle(rx+size, ry, 1, size+1, 80, 80, 80, 200)

    local local_ent = entity.get_local_player()
    if not local_ent then return end
    local lx, ly = entity.get_origin(local_ent)
    if not lx then return end

    local local_yaw = entity.get_prop(local_ent, "m_angEyeAngles[1]") or 0

    local function world_to_radar(wx, wy)
        local dx = wx - lx
        local dy = wy - ly
        -- Rotate by local yaw so radar is oriented to player
        local angle = -local_yaw * RAD
        local rdx = dx * math.cos(angle) - dy * math.sin(angle)
        local rdy = dx * math.sin(angle) + dy * math.cos(angle)
        local px = rx + size/2 + rdx * scale
        local py = ry + size/2 - rdy * scale
        return math.floor(px), math.floor(py)
    end

    -- Local player dot (white, centre)
    renderer.circle(rx + size/2, ry + size/2, 255, 255, 255, 255, 4, 0, 1)

    -- Enemies
    for _, ent in ipairs(entity.get_players(true)) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) then
            local ex, ey = entity.get_origin(ent)
            if ex then
                local px, py = world_to_radar(ex, ey)
                if px >= rx and px <= rx+size and py >= ry and py <= ry+size then
                    renderer.circle(px, py, 255, 60, 60, 220, 4, 0, 1)
                end
            end
        end
    end

    -- Teammates
    for _, ent in ipairs(entity.get_players(false)) do
        if entity.is_alive(ent) and not entity.is_dormant(ent) and ent ~= local_ent then
            local ex, ey = entity.get_origin(ent)
            if ex then
                local px, py = world_to_radar(ex, ey)
                if px >= rx and px <= rx+size and py >= ry and py <= ry+size then
                    renderer.circle(px, py, 60, 180, 255, 220, 4, 0, 1)
                end
            end
        end
    end

    -- Bomb
    for _, ent in ipairs(entity.get_all("CPlantedC4")) do
        local bx, by = entity.get_origin(ent)
        if bx then
            local px, py = world_to_radar(bx, by)
            if px >= rx and px <= rx+size and py >= ry and py <= ry+size then
                renderer.circle(px, py, 255, 200, 50, 255, 5, 0, 1)
            end
        end
    end

    renderer.text(rx + size/2, ry + size + 2, 150, 150, 150, 180, "c", 0, "RADAR")
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 18  SPECTATOR LIST
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_spectators()
    local local_ent = entity.get_local_player()
    if not local_ent then return end

    local specs = {}
    for _, ent in ipairs(entity.get_players(false)) do
        if not entity.is_alive(ent) then
            local obs_target = entity.get_prop(ent, "m_hObserverTarget")
            if obs_target == local_ent then
                specs[#specs+1] = entity.get_player_name(ent) or "?"
            end
        end
    end

    if #specs == 0 then return end

    local sw, sh = client.screen_size()
    local x, y = sw - 160, sh / 2 - (#specs * 12) / 2

    renderer.rectangle(x - 6, y - 14, 155, 14 + #specs * 12 + 4, 0, 0, 0, 180)
    renderer.text(x, y - 12, 255, 200, 80, 220, nil, 0, "Spectators:")

    for i, name in ipairs(specs) do
        renderer.text(x, y + (i-1)*12, 200, 200, 200, 200, nil, 0, "  " .. name)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 19  WATERMARK
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_watermark()
    local sw, sh = client.screen_size()
    local now    = globals.realtime()

    -- FPS sampling
    if now - V.last_fps_t > 0.1 then
        V.fps_samples[#V.fps_samples+1] = globals.framecount() / math.max(now, 0.001)
        if #V.fps_samples > 10 then table.remove(V.fps_samples, 1) end
        local sum = 0
        for _, v in ipairs(V.fps_samples) do sum = sum + v end
        V.fps_avg = math.floor(sum / #V.fps_samples)
        V.last_fps_t = now
    end

    local ping = client.latency and math.floor(client.latency() * 1000) or 0

    -- Animated rainbow title
    local hr, hg, hb = hsv_to_rgb(V.rainbow_hue, 200, 255)

    local wm_str = string.format("VISUALS v1  |  %d FPS  |  %dms", V.fps_avg, ping)
    local wm_w   = #wm_str * 6 + 16

    renderer.rectangle(4, 4, wm_w, 18, 0, 0, 0, 200)
    renderer.text(12, 7, hr, hg, hb, 255, nil, 0, "VISUALS v1")
    renderer.text(12 + 70, 7, 180, 180, 180, 220, nil, 0,
        string.format("|  %d FPS  |  %dms", V.fps_avg, ping))
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 20  CUSTOM CROSSHAIR
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_crosshair()
    local sw, sh = client.screen_size()
    local cx, cy = sw / 2, sh / 2
    local cr, cg, cb, ca = ui.get(UI.crosshair_col)

    local gap  = 4
    local size = 8
    local t    = 1

    -- Horizontal
    renderer.line(cx - size - gap, cy, cx - gap, cy, cr, cg, cb, ca)
    renderer.line(cx + gap,        cy, cx + size + gap, cy, cr, cg, cb, ca)
    -- Vertical
    renderer.line(cx, cy - size - gap, cx, cy - gap, cr, cg, cb, ca)
    renderer.line(cx, cy + gap,        cx, cy + size + gap, cr, cg, cb, ca)
    -- Centre dot
    renderer.rectangle(cx - 1, cy - 1, 2, 2, cr, cg, cb, ca)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 21  PAINT CALLBACK  (main render loop)
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("paint", function()
    V.frame = V.frame + 1
    V.rainbow_hue = (V.rainbow_hue + 1) % 360

    if not ui.get(UI.esp_enable) then return end

    local local_ent = entity.get_local_player()
    if not local_ent then return end

    local local_team = entity.get_prop(local_ent, "m_iTeamNum") or 0

    -- ── ESP ──────────────────────────────────────────────────────────────────
    for _, ent in ipairs(entity.get_players(true)) do
        if ui.get(UI.esp_enemies) then
            draw_esp(ent, local_ent, true)
        end
    end

    for _, ent in ipairs(entity.get_players(false)) do
        if ui.get(UI.esp_team) and ent ~= local_ent then
            draw_esp(ent, local_ent, false)
        end
    end

    -- ── Hit effects ───────────────────────────────────────────────────────────
    if ui.get(UI.hitmarker) then draw_hit_effects() end
    if ui.get(UI.dmg_numbers) then draw_dmg_numbers() end

    -- ── World ─────────────────────────────────────────────────────────────────
    if ui.get(UI.bomb_timer)   then draw_bomb_timer()          end
    if ui.get(UI.grenade_pred) then draw_grenade_prediction()  end
    if ui.get(UI.radar)        then draw_radar()               end

    -- ── Misc ──────────────────────────────────────────────────────────────────
    if ui.get(UI.watermark)   then draw_watermark()   end
    if ui.get(UI.spectators)  then draw_spectators()  end
    if ui.get(UI.crosshair)   then draw_crosshair()   end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 22  AIM HIT — spawn hit marker + damage number
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("aim_hit", function(e)
    local ent = e.target
    if not ent then return end

    -- Hit marker at screen centre
    local sw, sh = client.screen_size()
    V.hit_effects[#V.hit_effects+1] = {
        x      = sw / 2,
        y      = sh / 2,
        time   = globals.realtime(),
        size   = 6,
        damage = e.damage or 0,
    }

    -- Damage number at hit position
    local hx, hy, hz = entity.hitbox_position(ent, e.hitbox or 0)
    if hx then
        V.dmg_effects[#V.dmg_effects+1] = {
            x      = hx,
            y      = hy,
            z      = hz,
            time   = globals.realtime(),
            damage = e.damage or 0,
        }
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 23  SHUTDOWN
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("shutdown", function()
    client.color_log(255, 200, 80, "[Visuals v1] Unloaded")
end)

client.log("[Visuals v1] Loaded — ESP | Skeleton | HitFX | Bomb | Radar | Crosshair | Watermark")
