--[[
╔══════════════════════════════════════════════════════════════════════════════╗
║                    HITLOG  v1  —  Gamesense (gamesense.pub)                 ║
║                                                                              ║
║  A fully-featured, animated hit log panel with:                             ║
║   • Animated slide-in entries with fade-out                                 ║
║   • Per-hitgroup icons (head/body/arm/leg)                                  ║
║   • Colour-coded damage (green→yellow→red by damage amount)                 ║
║   • Hit/miss tracking with resolver method display                          ║
║   • Session stats bar (hits, misses, accuracy, total damage, kills)         ║
║   • Kill feed integration (skull icon on kill)                              ║
║   • Scrollable history (last 50 events)                                     ║
║   • Animated rainbow header                                                 ║
║   • Configurable position, size, opacity                                    ║
║   • Export session stats to console on round end                            ║
╚══════════════════════════════════════════════════════════════════════════════╝
--]]

local ffi = require("ffi")
local bit = bit

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 1  MATH / COLOUR HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════
local PI  = math.pi
local DEG = 180 / PI
local RAD = PI / 180

local function clamp(v, lo, hi)
    if not v then return lo end
    return v < lo and lo or (v > hi and hi or v)
end

local function lerp(a, b, t) return a + (b - a) * clamp(t, 0, 1) end

-- HSV → RGB (all 0-255)
local function hsv(h, s, v)
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

-- Damage → colour (green=1, yellow=50, red=100+)
local function dmg_color(dmg)
    if dmg >= 100 then return 255, 50,  50  end
    if dmg >= 50  then return 255, 180, 50  end
    if dmg >= 25  then return 255, 255, 80  end
    return 80, 220, 80
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 2  HITGROUP DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════════
local HITGROUP = {
    [0]  = { name = "Generic",   icon = "◆",  r = 200, g = 200, b = 200 },
    [1]  = { name = "Head",      icon = "◉",  r = 255, g = 80,  b = 80  },
    [2]  = { name = "Chest",     icon = "▣",  r = 255, g = 180, b = 50  },
    [3]  = { name = "Stomach",   icon = "▣",  r = 255, g = 200, b = 80  },
    [4]  = { name = "L.Arm",     icon = "◁",  r = 100, g = 200, b = 255 },
    [5]  = { name = "R.Arm",     icon = "▷",  r = 100, g = 200, b = 255 },
    [6]  = { name = "L.Leg",     icon = "▽",  r = 100, g = 255, b = 180 },
    [7]  = { name = "R.Leg",     icon = "▽",  r = 100, g = 255, b = 180 },
    [10] = { name = "Gear",      icon = "⚙",  r = 180, g = 180, b = 180 },
}

local function get_hg(id)
    return HITGROUP[id] or HITGROUP[0]
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 3  UI
-- ═══════════════════════════════════════════════════════════════════════════════
local UI = {}

UI.enable       = ui.new_checkbox("LUA", "a", "Hitlog: Enable")
UI.show_misses  = ui.new_checkbox("LUA", "a", "Hitlog: Show misses")
UI.show_method  = ui.new_checkbox("LUA", "a", "Hitlog: Show resolver method")
UI.show_stats   = ui.new_checkbox("LUA", "a", "Hitlog: Show stats bar")
UI.show_kills   = ui.new_checkbox("LUA", "a", "Hitlog: Highlight kills")
UI.max_entries  = ui.new_slider("LUA", "a", "Hitlog: Max entries", 3, 20, 10)
UI.entry_life   = ui.new_slider("LUA", "a", "Hitlog: Entry lifetime (s)", 2, 15, 6)
UI.panel_x      = ui.new_slider("LUA", "a", "Hitlog: Panel X", 0, 1920, 10)
UI.panel_y      = ui.new_slider("LUA", "a", "Hitlog: Panel Y", 0, 1080, 300)
UI.panel_w      = ui.new_slider("LUA", "a", "Hitlog: Panel width", 200, 500, 320)
UI.bg_alpha     = ui.new_slider("LUA", "a", "Hitlog: BG opacity", 0, 255, 180)
UI.rainbow_hdr  = ui.new_checkbox("LUA", "a", "Hitlog: Rainbow header")
UI.hdr_col      = ui.new_color_picker("LUA", "a", "Hitlog: Header colour", 255, 200, 60, 255)
UI.hit_col      = ui.new_color_picker("LUA", "a", "Hitlog: Hit colour", 80, 220, 80, 255)
UI.miss_col     = ui.new_color_picker("LUA", "a", "Hitlog: Miss colour", 255, 80, 80, 255)
UI.kill_col     = ui.new_color_picker("LUA", "a", "Hitlog: Kill colour", 255, 60, 200, 255)
UI.slide_anim   = ui.new_checkbox("LUA", "a", "Hitlog: Slide animation")
UI.dmg_col_mode = ui.new_checkbox("LUA", "a", "Hitlog: Colour by damage")

-- Defaults
ui.set(UI.enable,       true)
ui.set(UI.show_misses,  true)
ui.set(UI.show_method,  true)
ui.set(UI.show_stats,   true)
ui.set(UI.show_kills,   true)
ui.set(UI.max_entries,  10)
ui.set(UI.entry_life,   6)
ui.set(UI.panel_x,      10)
ui.set(UI.panel_y,      300)
ui.set(UI.panel_w,      320)
ui.set(UI.bg_alpha,     180)
ui.set(UI.rainbow_hdr,  true)
ui.set(UI.slide_anim,   true)
ui.set(UI.dmg_col_mode, true)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 4  STATE
-- ═══════════════════════════════════════════════════════════════════════════════
local HL = {
    entries     = {},   -- list of log entries (newest first)
    rainbow_hue = 0,
    stats = {
        hits        = 0,
        misses      = 0,
        total_dmg   = 0,
        kills       = 0,
        hs_kills    = 0,
        rounds      = 0,
    },
    -- Per-player resolver tracking (populated by resolver.lua if loaded)
    resolver_data = {},
}

-- Entry structure:
-- {
--   time        = realtime(),
--   kind        = "hit" | "miss" | "kill",
--   target_name = string,
--   damage      = number,
--   hitgroup    = number,
--   hp_left     = number,
--   method      = string,   -- resolver method
--   weapon      = string,
--   is_kill     = bool,
--   is_hs       = bool,
--   slide_t     = realtime(),  -- for animation
-- }

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 5  ENTRY MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════════
local MAX_HISTORY = 50

local function push_entry(e)
    e.slide_t = globals.realtime()
    table.insert(HL.entries, 1, e)
    if #HL.entries > MAX_HISTORY then
        table.remove(HL.entries)
    end
end

local function prune_entries()
    local now      = globals.realtime()
    local lifetime = ui.get(UI.entry_life)
    local max_vis  = ui.get(UI.max_entries)
    local count    = 0

    for i = #HL.entries, 1, -1 do
        local e = HL.entries[i]
        if now - e.time > lifetime then
            table.remove(HL.entries, i)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 6  DRAWING HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════
-- Rounded rectangle (simulated with overlapping rects)
local function rounded_rect(x, y, w, h, r2, g2, b2, a2, fill_r, fill_g, fill_b, fill_a)
    -- Border
    renderer.rectangle(x,   y,   w, h, r2, g2, b2, a2)
    -- Fill (1px inset)
    if fill_a and fill_a > 0 then
        renderer.rectangle(x+1, y+1, w-2, h-2, fill_r, fill_g, fill_b, fill_a)
    end
end

-- Gradient bar (horizontal, left colour → right colour)
local function gradient_bar(x, y, w, h, r1, g1, b1, r2, g2, b2, a)
    local steps = math.max(1, math.floor(w / 2))
    for i = 0, steps - 1 do
        local t  = i / steps
        local r  = math.floor(lerp(r1, r2, t))
        local g  = math.floor(lerp(g1, g2, t))
        local b  = math.floor(lerp(b1, b2, t))
        local sw = math.ceil(w / steps)
        renderer.rectangle(x + i * sw, y, sw + 1, h, r, g, b, a)
    end
end

-- Thin separator line
local function separator(x, y, w, a)
    renderer.rectangle(x, y, w, 1, 80, 80, 80, a)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 7  MAIN PANEL DRAW
-- ═══════════════════════════════════════════════════════════════════════════════
local ENTRY_H    = 28   -- pixels per entry
local HEADER_H   = 22
local STATS_H    = 36
local PADDING    = 6

local function draw_panel()
    if not ui.get(UI.enable) then return end

    prune_entries()

    local now       = globals.realtime()
    local px        = ui.get(UI.panel_x)
    local py        = ui.get(UI.panel_y)
    local pw        = ui.get(UI.panel_w)
    local bg_a      = ui.get(UI.bg_alpha)
    local max_vis   = ui.get(UI.max_entries)
    local show_miss = ui.get(UI.show_misses)
    local show_meth = ui.get(UI.show_method)
    local show_stat = ui.get(UI.show_stats)
    local slide_on  = ui.get(UI.slide_anim)
    local dmg_mode  = ui.get(UI.dmg_col_mode)

    -- Collect visible entries
    local visible = {}
    for _, e in ipairs(HL.entries) do
        if e.kind == "hit" or e.kind == "kill" or (e.kind == "miss" and show_miss) then
            visible[#visible+1] = e
            if #visible >= max_vis then break end
        end
    end

    local num_entries = #visible
    local stats_h     = show_stat and STATS_H or 0
    local total_h     = HEADER_H + num_entries * ENTRY_H + stats_h + PADDING * 2

    -- ── Outer panel background ────────────────────────────────────────────────
    renderer.rectangle(px - 1, py - 1, pw + 2, total_h + 2, 40, 40, 40, math.floor(bg_a * 0.6))
    renderer.rectangle(px,     py,     pw,     total_h,     10, 10, 10, bg_a)

    -- ── Header ────────────────────────────────────────────────────────────────
    HL.rainbow_hue = (HL.rainbow_hue + 0.8) % 360

    local hr, hg, hb
    if ui.get(UI.rainbow_hdr) then
        hr, hg, hb = hsv(HL.rainbow_hue, 220, 255)
    else
        hr, hg, hb = ui.get(UI.hdr_col)
    end

    -- Header gradient bar
    gradient_bar(px, py, pw, HEADER_H, hr, hg, hb, math.floor(hr*0.3), math.floor(hg*0.3), math.floor(hb*0.3), 220)

    -- Header text
    renderer.text(px + PADDING, py + 4, 255, 255, 255, 255, nil, 0, "⚡ HITLOG")

    -- Stats summary in header (right side)
    local acc = HL.stats.hits + HL.stats.misses > 0
        and string.format("%.0f%%", HL.stats.hits / (HL.stats.hits + HL.stats.misses) * 100)
        or "n/a"
    renderer.text(px + pw - PADDING, py + 4, 200, 200, 200, 220, "r", 0,
        string.format("H:%d  M:%d  Acc:%s", HL.stats.hits, HL.stats.misses, acc))

    -- ── Entries ───────────────────────────────────────────────────────────────
    local ey = py + HEADER_H + PADDING

    for i, e in ipairs(visible) do
        local age      = now - e.time
        local lifetime = ui.get(UI.entry_life)
        local fade_t   = math.max(0, 1 - (age - (lifetime - 1.5)) / 1.5)
        local alpha    = math.floor(clamp(fade_t, 0, 1) * 255)
        if age < 0.3 then alpha = math.floor(age / 0.3 * 255) end  -- fade in

        -- Slide-in animation
        local slide_off = 0
        if slide_on then
            local slide_age = now - e.slide_t
            slide_off = math.max(0, (1 - clamp(slide_age / 0.15, 0, 1))) * (pw + 20)
        end

        local ex = px - slide_off

        -- Entry background
        local bg_r, bg_g, bg_b = 18, 18, 18
        if e.kind == "kill" and ui.get(UI.show_kills) then
            bg_r, bg_g, bg_b = 40, 10, 40
        elseif e.kind == "miss" then
            bg_r, bg_g, bg_b = 35, 10, 10
        end
        renderer.rectangle(ex, ey, pw, ENTRY_H - 1, bg_r, bg_g, bg_b, math.floor(alpha * 0.9))

        -- Left accent bar (colour by kind/damage)
        local ar, ag, ab
        if e.kind == "miss" then
            local mr, mg, mb = ui.get(UI.miss_col)
            ar, ag, ab = mr, mg, mb
        elseif e.kind == "kill" and ui.get(UI.show_kills) then
            local kr, kg, kb = ui.get(UI.kill_col)
            ar, ag, ab = kr, kg, kb
        elseif dmg_mode then
            ar, ag, ab = dmg_color(e.damage or 0)
        else
            local cr2, cg2, cb2 = ui.get(UI.hit_col)
            ar, ag, ab = cr2, cg2, cb2
        end
        renderer.rectangle(ex, ey, 3, ENTRY_H - 1, ar, ag, ab, alpha)

        -- Hitgroup icon
        local hg_info = get_hg(e.hitgroup or 0)
        renderer.text(ex + 7, ey + 7, hg_info.r, hg_info.g, hg_info.b, alpha,
            nil, 0, hg_info.icon)

        -- Kill skull overlay
        if e.is_kill and ui.get(UI.show_kills) then
            renderer.text(ex + 7, ey + 7, 255, 60, 200, alpha, nil, 0, "☠")
        end

        -- Target name
        local name_str = e.target_name or "?"
        if #name_str > 16 then name_str = name_str:sub(1, 14) .. ".." end
        renderer.text(ex + 20, ey + 4, 230, 230, 230, alpha, nil, 0, name_str)

        -- Damage + hitgroup
        if e.kind ~= "miss" then
            local dmg_r, dmg_g, dmg_b = dmg_color(e.damage or 0)
            renderer.text(ex + 20, ey + 15, dmg_r, dmg_g, dmg_b, alpha, nil, 0,
                string.format("-%d hp  [%s]", e.damage or 0, hg_info.name))
        else
            renderer.text(ex + 20, ey + 15, 255, 80, 80, alpha, nil, 0, "MISS")
        end

        -- HP remaining
        if e.kind ~= "miss" and e.hp_left ~= nil then
            local hp_r = e.hp_left <= 0 and 255 or 180
            local hp_g = e.hp_left <= 0 and 50  or 180
            renderer.text(ex + pw - PADDING, ey + 4, hp_r, hp_g, 100, alpha, "r", 0,
                e.hp_left <= 0 and "DEAD" or (tostring(e.hp_left) .. " hp"))
        end

        -- Resolver method (right side, bottom row)
        if show_meth and e.method and e.method ~= "" and e.method ~= "?" then
            local method_colors = {
                lby           = { 50,  255, 200 },
                jitter        = { 255, 100, 255 },
                freestand_dmg = { 50,  255, 130 },
                freestand_geo = {  0,  200, 100 },
                animation     = { 100, 200, 255 },
                brute         = { 255, 200, 100 },
                brute_duck    = { 255, 150,  50 },
            }
            local mc = method_colors[e.method] or { 160, 160, 160 }
            renderer.text(ex + pw - PADDING, ey + 15, mc[1], mc[2], mc[3], alpha, "r", 0,
                e.method)
        end

        -- Weapon (small, grey)
        if e.weapon and e.weapon ~= "" then
            renderer.text(ex + pw/2, ey + 4, 140, 140, 140, math.floor(alpha * 0.7), "c", 0,
                e.weapon)
        end

        -- Headshot star
        if e.is_hs then
            renderer.text(ex + pw - PADDING - 60, ey + 4, 255, 220, 50, alpha, nil, 0, "★HS")
        end

        -- Bottom separator
        separator(ex, ey + ENTRY_H - 1, pw, math.floor(alpha * 0.4))

        ey = ey + ENTRY_H
    end

    -- ── Session Stats Bar ─────────────────────────────────────────────────────
    if show_stat then
        local sy = ey + 2
        renderer.rectangle(px, sy, pw, STATS_H, 15, 15, 15, math.floor(bg_a * 0.9))
        separator(px, sy, pw, 120)

        local s = HL.stats
        local total_shots = s.hits + s.misses
        local acc_pct = total_shots > 0 and (s.hits / total_shots * 100) or 0

        -- Accuracy bar
        local bar_w = pw - PADDING * 2
        renderer.rectangle(px + PADDING, sy + 4, bar_w, 4, 30, 30, 30, 200)
        if total_shots > 0 then
            local fill = math.floor(bar_w * acc_pct / 100)
            local br, bg2, bb = hsv(acc_pct * 1.2, 220, 220)  -- green at 100%, red at 0%
            renderer.rectangle(px + PADDING, sy + 4, fill, 4, br, bg2, bb, 220)
        end

        -- Stats text row 1
        renderer.text(px + PADDING, sy + 11, 200, 200, 200, 220, nil, 0,
            string.format("Hits: %d  Misses: %d  Acc: %.1f%%", s.hits, s.misses, acc_pct))

        -- Stats text row 2
        renderer.text(px + PADDING, sy + 22, 180, 180, 180, 200, nil, 0,
            string.format("Dmg: %d  Kills: %d  HS: %d  Rounds: %d",
                s.total_dmg, s.kills, s.hs_kills, s.rounds))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 8  GAME EVENTS
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("aim_hit", function(e)
    if not ui.get(UI.enable) then return end

    local ent    = e.target
    local name   = ent and (entity.get_player_name(ent) or "?") or "?"
    local hp     = ent and (entity.get_prop(ent, "m_iHealth") or 0) or 0
    local is_kill = hp <= 0
    local hg_id  = e.hitbox or 0
    local is_hs  = hg_id == 1  -- hitbox 0 = head in Gamesense aim events

    -- Weapon name
    local wpn_name = ""
    if ent then
        local wpn = entity.get_prop(ent, "m_hActiveWeapon")
        if wpn then
            local cn = entity.get_classname(wpn) or ""
            wpn_name = cn:gsub("^CWeapon", ""):gsub("^C_Weapon", ""):upper()
        end
    end

    -- Resolver method (from resolver.lua shared state if available)
    local method = "?"
    if _G.R and _G.R.pdata and ent and _G.R.pdata[ent] then
        method = _G.R.pdata[ent].last_method or "?"
    end

    push_entry({
        time        = globals.realtime(),
        kind        = is_kill and "kill" or "hit",
        target_name = name,
        damage      = e.damage or 0,
        hitgroup    = hg_id,
        hp_left     = hp,
        method      = method,
        weapon      = wpn_name,
        is_kill     = is_kill,
        is_hs       = is_hs,
    })

    HL.stats.hits      = HL.stats.hits + 1
    HL.stats.total_dmg = HL.stats.total_dmg + (e.damage or 0)
    if is_kill then
        HL.stats.kills = HL.stats.kills + 1
        if is_hs then HL.stats.hs_kills = HL.stats.hs_kills + 1 end
    end

    -- Console log
    local hg_info = get_hg(hg_id)
    client.color_log(
        is_kill and 255 or 80,
        is_kill and 60  or 220,
        is_kill and 200 or 80,
        string.format("[Hitlog] %s %s | -%d hp | %s | %s | method: %s",
            is_kill and "☠ KILLED" or "HIT",
            name,
            e.damage or 0,
            hg_info.name,
            wpn_name,
            method))
end)

client.set_event_callback("aim_miss", function(e)
    if not ui.get(UI.enable) then return end
    if not ui.get(UI.show_misses) then return end
    if e.reason ~= nil then return end  -- only resolver misses

    local ent  = e.target
    local name = ent and (entity.get_player_name(ent) or "?") or "?"

    local method = "?"
    if _G.R and _G.R.pdata and ent and _G.R.pdata[ent] then
        method = _G.R.pdata[ent].last_method or "?"
    end

    push_entry({
        time        = globals.realtime(),
        kind        = "miss",
        target_name = name,
        damage      = 0,
        hitgroup    = 0,
        hp_left     = nil,
        method      = method,
        weapon      = "",
        is_kill     = false,
        is_hs       = false,
    })

    HL.stats.misses = HL.stats.misses + 1

    client.color_log(255, 100, 50,
        string.format("[Hitlog] MISS → %s | method: %s", name, method))
end)

client.set_event_callback("round_start", function()
    HL.stats.rounds = HL.stats.rounds + 1
    -- Print round summary
    local s = HL.stats
    local total = s.hits + s.misses
    local acc   = total > 0 and string.format("%.1f%%", s.hits / total * 100) or "n/a"
    client.color_log(255, 200, 60,
        string.format("[Hitlog] Round %d | Hits: %d | Misses: %d | Acc: %s | Dmg: %d | Kills: %d (HS: %d)",
            s.rounds, s.hits, s.misses, acc, s.total_dmg, s.kills, s.hs_kills))
end)

client.set_event_callback("shutdown", function()
    local s = HL.stats
    local total = s.hits + s.misses
    local acc   = total > 0 and string.format("%.1f%%", s.hits / total * 100) or "n/a"
    client.color_log(255, 200, 60,
        string.format("[Hitlog] Session: Hits=%d Misses=%d Acc=%s Dmg=%d Kills=%d HS=%d",
            s.hits, s.misses, acc, s.total_dmg, s.kills, s.hs_kills))
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 9  PAINT
-- ═══════════════════════════════════════════════════════════════════════════════
client.set_event_callback("paint", draw_panel)

-- ═══════════════════════════════════════════════════════════════════════════════
-- § 10  EXPOSE STATE (for resolver.lua integration)
-- ═══════════════════════════════════════════════════════════════════════════════
_G.HL = HL

client.log("[Hitlog v1] Loaded — animated panel | stats bar | resolver integration | kill feed")
