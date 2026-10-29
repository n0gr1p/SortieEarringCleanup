-- SortieEarringCleanup.lua
-- Temporary augment-aware Sortie JSE earring organizer for Windower 4.
--
-- Install:
--   Windower4\addons\SortieEarringCleanup\SortieEarringCleanup.lua
--
-- Commands:
--   //sec scan   - print best/redundant classification only
--   //sec run    - keep best copy in Wardrobes, stage weaker copies in Inventory
--   //sec abort  - stop the current move queue
--   //sec status - show queue status
--   //sec identify scan - list unidentified Sortie earrings in main Inventory
--   //sec identify      - use all unidentified Sortie earrings, one by one
--
-- Safety:
--   * Never drops/deletes anything.
--   * Exact-slot movement preserves augment identity.
--   * +2 > +1 > NQ.
--   * Within a tier, higher coherent Sortie augment roll wins.
--   * Ties prefer a copy already in a Wardrobe.
--   * Preflight occurs before any movement.
--   * Every move is verified before proceeding.
--   * Identify only uses known Sortie ??? Earrings in main Inventory.
--   * Identification checks each consumption before proceeding; no cases are opened.

_addon.name = 'SortieEarringCleanup'
_addon.author = 'Inventory Gremlin'
_addon.version = '1.2.2'
_addon.commands = {'sec', 'sortieearrings'}

local extdata = require('extdata')
local res = require('resources')

local MOVE_DELAY = 2.0
local IDENTIFY_DELAY = 5.0

local wardrobe_ids = {
    [8] = true,   -- Mog Wardrobe
    [10] = true,  -- Mog Wardrobe 2
    [11] = true,
    [12] = true,
    [13] = true,
    [14] = true,
    [15] = true,
    [16] = true,  -- Mog Wardrobe 8
}
local wardrobe_order = {8, 10, 11, 12, 13, 14, 15, 16}

-- Physical bags that can contain these earrings.
-- Temporary bag 3 is intentionally excluded.
local scan_bags = {0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

-- Appraised Sortie JSE earring NQ base IDs.
-- +1 = base + 1, +2 = base + 2.
local sortie_bases = {
    [25420] = 'WAR', -- Boii
    [25426] = 'MNK', -- Bhikku
    [25432] = 'WHM', -- Ebers
    [25438] = 'BLM', -- Wicce
    [25444] = 'RDM', -- Lethargy
    [25450] = 'THF', -- Skulker
    [25456] = 'PLD', -- Chevalier
    [25462] = 'DRK', -- Heathen
    [25468] = 'BST', -- Nukumi
    [25474] = 'BRD', -- Fili
    [25480] = 'RNG', -- Amini
    [25486] = 'SAM', -- Kasuga
    [25492] = 'NIN', -- Hattori
    [25498] = 'DRG', -- Peltast
    [25504] = 'SMN', -- Beckoner
    [25510] = 'BLU', -- Hashishin
    [25516] = 'COR', -- Chasseur
    [25522] = 'PUP', -- Karagoz
    [25528] = 'DNC', -- Maculele
    [25534] = 'SCH', -- Arbatel
    [25540] = 'GEO', -- Azimuth
    [25546] = 'RUN', -- Erilaz
}

local sortie_jobs = {}
for _, job in pairs(sortie_bases) do
    sortie_jobs[job] = true
end

local identify_state = {
    running = false,
    generation = 0,
    processed = 0,
    initial_total = 0,
    pending = nil,
}

local state = {
    running = false,
    queue = {},
    index = 1,
    current = nil,
    phase = nil,
    keepers = {},
    redundant = {},
}

local function chat(color, text)
    windower.add_to_chat(color or 207, '[SortieEarring] '..text)
end

local function echo(text)
    windower.send_command('input /echo [Inventory Gremlin] '..text)
end

local function bag_name(id)
    local b = res.bags[id]
    return b and (b.en or b.english or tostring(id)) or tostring(id)
end

local function is_wardrobe(id)
    return wardrobe_ids[id] == true
end

local function item_name(id)
    local r = res.items[id]
    return r and (r.en or r.english or tostring(id)) or tostring(id)
end

local function classify_id(id)
    for base, job in pairs(sortie_bases) do
        local tier = id - base
        if tier >= 0 and tier <= 2 then
            return base, job, tier
        end
    end
    return nil
end

-- Only the 22 Sortie JSE job families (NQ/+1/+2) qualify.
-- FFXI's abbreviated earring names must also be recognized.
local function is_sortie_unidentified_name(name)
    if type(name) ~= 'string' then return false end
    local job, suffix = name:match('^%?%?%?%s+Earring:%s+([A-Z]+)(.*)$')
    if not job then
        job, suffix = name:match('^%?%?%?%s+Ear%.:%s+([A-Z]+)(.*)$')
    end
    return job ~= nil and sortie_jobs[job] == true
        and (suffix == '' or suffix == ' +1' or suffix == ' +2')
end

local function unidentified_earring_name(id)
    local entry = res.items[id]
    if not entry then return nil end
    local long_name = entry.enl or entry.english_log
    if is_sortie_unidentified_name(long_name) then return long_name end
    local short_name = entry.en or entry.english
    if is_sortie_unidentified_name(short_name) then return short_name end
    return nil
end

local function scan_unidentified()
    local items = windower.ffxi.get_items(0)
    if not items then return nil end

    local scan = {total = 0, locked = 0, first = nil, names = {}}
    for slot, item in ipairs(items) do
        if item and item.id and item.id > 0 and item.id ~= 0xFFFF then
            local name = unidentified_earring_name(item.id)
            if name and (item.count or 0) > 0 then
                scan.total = scan.total + item.count
                scan.names[name] = (scan.names[name] or 0) + item.count
                if (item.status or 0) ~= 0 then
                    scan.locked = scan.locked + item.count
                elseif not scan.first then
                    scan.first = {id = item.id, name = name, slot = slot}
                end
            end
        end
    end
    return scan
end

local function count_unidentified_id(id)
    local items = windower.ffxi.get_items(0)
    if not items then return nil end
    local count = 0
    for _, item in ipairs(items) do
        if item and item.id == id then
            count = count + (item.count or 0)
        end
    end
    return count
end

local function decode_augments(item)
    local ok, decoded = pcall(extdata.decode, item)
    if not ok or not decoded then
        return {}
    end
    return decoded.augments or {}
end

local function augment_quality(item)
    local augments = decode_augments(item)
    for _, aug in ipairs(augments) do
        if type(aug) == 'string' and not aug:lower():find('system:', 1, true) then
            local n = aug:match('[%+%-](%d+)')
            if n then
                return tonumber(n), augments
            end
        end
    end
    return -1, augments
end

local function augment_text(copy)
    local parts = {}
    for _, aug in ipairs(copy.augments or {}) do
        if type(aug) == 'string'
            and not aug:lower():find('system:', 1, true)
            and aug:lower() ~= 'none' then
            parts[#parts + 1] = aug
        end
    end
    return table.concat(parts, ', ')
end

local function same_copy(item, copy)
    if not item or item.id ~= copy.id then
        return false
    end

    -- extdata is the safest identity available for augmented same-name copies.
    if copy.extdata and item.extdata then
        return item.extdata == copy.extdata
    end

    return true
end

local function collect()
    local families = {}

    for _, bag_id in ipairs(scan_bags) do
        local items = windower.ffxi.get_items(bag_id)
        if items then
            for slot, item in ipairs(items) do
                if item and item.id and item.id ~= 0 and item.id ~= 0xFFFF then
                    local base, job, tier = classify_id(item.id)
                    if base then
                        local quality, augments = augment_quality(item)
                        families[base] = families[base] or {
                            base = base,
                            job = job,
                            copies = {},
                        }
                        families[base].copies[#families[base].copies + 1] = {
                            base = base,
                            job = job,
                            id = item.id,
                            name = item_name(item.id),
                            tier = tier,
                            quality = quality,
                            augments = augments,
                            bag = bag_id,
                            slot = slot,
                            status = item.status or 0,
                            extdata = item.extdata,
                        }
                    end
                end
            end
        end
    end

    return families
end

local function better(a, b)
    if a.tier ~= b.tier then
        return a.tier > b.tier
    end
    if a.quality ~= b.quality then
        return a.quality > b.quality
    end
    if is_wardrobe(a.bag) ~= is_wardrobe(b.bag) then
        return is_wardrobe(a.bag)
    end
    if a.bag ~= b.bag then
        return a.bag < b.bag
    end
    return a.slot < b.slot
end

local function build_plan(families)
    local keepers = {}
    local redundant = {}

    for _, family in pairs(families) do
        table.sort(family.copies, better)
        if family.copies[1] then
            keepers[#keepers + 1] = family.copies[1]
            for i = 2, #family.copies do
                redundant[#redundant + 1] = family.copies[i]
            end
        end
    end

    table.sort(keepers, function(a, b)
        if a.job ~= b.job then return a.job < b.job end
        return better(a, b)
    end)

    table.sort(redundant, function(a, b)
        if a.job ~= b.job then return a.job < b.job end
        if a.tier ~= b.tier then return a.tier > b.tier end
        if a.quality ~= b.quality then return a.quality > b.quality end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)

    return keepers, redundant
end

local function inventory_free()
    local info = windower.ffxi.get_bag_info(0)
    if not info then return 0 end
    return math.max((info.max or 0) - (info.count or 0), 0)
end

local function bag_enabled(id)
    if id == 0 then return true end
    local info = windower.ffxi.get_bag_info(id)
    return info and info.enabled
end

local function total_wardrobe_free()
    local free = 0
    for _, id in ipairs(wardrobe_order) do
        local info = windower.ffxi.get_bag_info(id)
        if info and info.enabled and info.max and info.count then
            free = free + math.max(info.max - info.count, 0)
        end
    end
    return free
end

local function find_free_wardrobe()
    for _, id in ipairs(wardrobe_order) do
        local info = windower.ffxi.get_bag_info(id)
        if info and info.enabled and info.max and info.count and info.count < info.max then
            return id
        end
    end
    return nil
end

local function source_matches(copy)
    local item = windower.ffxi.get_items(copy.bag, copy.slot)
    return same_copy(item, copy)
end

local function find_in_inventory(copy)
    local items = windower.ffxi.get_items(0)
    if not items then return nil end
    for slot, item in ipairs(items) do
        if same_copy(item, copy) then
            return slot
        end
    end
    return nil
end

local function find_in_wardrobes(copy)
    for _, bag_id in ipairs(wardrobe_order) do
        local items = windower.ffxi.get_items(bag_id)
        if items then
            for slot, item in ipairs(items) do
                if same_copy(item, copy) then
                    return bag_id, slot
                end
            end
        end
    end
    return nil
end

local function print_plan(keepers, redundant)
    local player = windower.ffxi.get_player()
    chat(207, ('%s: %d Sortie families, %d redundant copies, %d keeper(s) outside Wardrobes.')
        :format(
            player and player.name or '?',
            #keepers,
            #redundant,
            (function()
                local n = 0
                for _, c in ipairs(keepers) do
                    if not is_wardrobe(c.bag) then n = n + 1 end
                end
                return n
            end)()
        ))

    for _, copy in ipairs(keepers) do
        chat(8, ('BEST %-3s %-18s tier=%d q=%d [%s] {%s:%d}')
            :format(copy.job, copy.name, copy.tier, copy.quality,
                augment_text(copy), bag_name(copy.bag), copy.slot))
    end

    if #redundant > 0 then
        chat(8, '--- dominated/redundant copies ---')
        for _, copy in ipairs(redundant) do
            chat(8, ('WEAK %-3s %-18s tier=%d q=%d [%s] {%s:%d}')
                :format(copy.job, copy.name, copy.tier, copy.quality,
                    augment_text(copy), bag_name(copy.bag), copy.slot))
        end
    end
end

local function preflight(keepers, redundant)
    local info = windower.ffxi.get_info()
    if not info or not info.mog_house then
        return false, 'Run this inside a Mog House/Rent-a-Room.'
    end

    local keeper_moves = 0
    local keeper_from_inventory = 0
    local keeper_from_other = 0
    local redundant_moves = 0

    for _, copy in ipairs(keepers) do
        if not is_wardrobe(copy.bag) then
            keeper_moves = keeper_moves + 1

            if copy.bag == 0 then
                keeper_from_inventory = keeper_from_inventory + 1
            else
                keeper_from_other = keeper_from_other + 1
                if not bag_enabled(copy.bag) then
                    return false, ('Keeper %s is in inaccessible %s.')
                        :format(copy.name, bag_name(copy.bag))
                end
            end

            if copy.status ~= 0 then
                return false, ('Keeper %s needs movement but is equipped/locked (status %d).')
                    :format(copy.name, copy.status)
            end
        end
    end

    for _, copy in ipairs(redundant) do
        if copy.bag ~= 0 then
            redundant_moves = redundant_moves + 1

            if not bag_enabled(copy.bag) then
                return false, ('Redundant %s is in inaccessible %s.')
                    :format(copy.name, bag_name(copy.bag))
            end

            if copy.status ~= 0 then
                return false, ('Redundant %s is equipped/locked (status %d).')
                    :format(copy.name, copy.status)
            end
        end
    end

    if total_wardrobe_free() < keeper_moves then
        return false, ('Need %d free Wardrobe slots; only %d are free.')
            :format(keeper_moves, total_wardrobe_free())
    end

    local free_now = inventory_free()
    local projected_free = free_now + keeper_from_inventory

    if projected_free < redundant_moves then
        return false, ('Need %d Inventory slots to stage redundant earrings; projected free is %d.')
            :format(redundant_moves, projected_free)
    end

    if keeper_from_other > 0 and projected_free < 1 then
        return false, 'Need at least one temporary Inventory slot to move a keeper into a Wardrobe.'
    end

    return true
end

local function stop_with_error(message)
    state.running = false
    chat(167, 'STOP: '..message)
    local player = windower.ffxi.get_player()
    echo(('Sortie earring cleanup STOPPED on %s: %s')
        :format(player and player.name or '?', message))
end

local function finish()
    state.running = false

    local families = collect()
    local keepers, redundant = build_plan(families)

    local keeper_bad = 0
    for _, copy in ipairs(keepers) do
        if not is_wardrobe(copy.bag) then
            keeper_bad = keeper_bad + 1
        end
    end

    local redundant_bad = 0
    for _, copy in ipairs(redundant) do
        if copy.bag ~= 0 then
            redundant_bad = redundant_bad + 1
        end
    end

    local player = windower.ffxi.get_player()
    if keeper_bad == 0 and redundant_bad == 0 then
        chat(207, ('COMPLETE: %d best earrings in Wardrobes; %d redundant earrings staged in Inventory.')
            :format(#keepers, #redundant))
        echo(('%s Sortie earrings complete: %d keepers in Wardrobes, %d redundants in Inventory.')
            :format(player and player.name or '?', #keepers, #redundant))
    else
        chat(167, ('VERIFY WARNING: %d keeper(s) outside Wardrobes, %d redundant copy/copies outside Inventory.')
            :format(keeper_bad, redundant_bad))
        echo(('Sortie earring cleanup needs review on %s.')
            :format(player and player.name or '?'))
    end
end

local advance

local function next_operation()
    state.index = state.index + 1
    state.current = nil
    state.phase = nil
    advance:schedule(MOVE_DELAY)
end

local function process_keeper(op)
    local copy = op.copy

    if state.phase == nil then
        -- Copy may already be in Inventory.
        if copy.bag == 0 then
            local inv_slot = copy.slot
            local current = windower.ffxi.get_items(0, inv_slot)
            if not same_copy(current, copy) then
                inv_slot = find_in_inventory(copy)
            end
            if not inv_slot then
                stop_with_error(('Cannot locate keeper %s in Inventory.'):format(copy.name))
                return
            end

            local destination = find_free_wardrobe()
            if not destination then
                stop_with_error('No free enabled Wardrobe remains.')
                return
            end

            op.inv_slot = inv_slot
            op.destination = destination
            windower.ffxi.put_item(destination, inv_slot, 1)
            state.phase = 'verify_put'
            advance:schedule(MOVE_DELAY)
            return
        end

        if not source_matches(copy) then
            stop_with_error(('Keeper source changed before move: %s {%s:%d}.')
                :format(copy.name, bag_name(copy.bag), copy.slot))
            return
        end

        if inventory_free() < 1 then
            stop_with_error(('No temporary Inventory slot available for keeper %s.'):format(copy.name))
            return
        end

        windower.ffxi.get_item(copy.bag, copy.slot, 1)
        state.phase = 'verify_get'
        advance:schedule(MOVE_DELAY)
        return
    end

    if state.phase == 'verify_get' then
        if source_matches(copy) then
            stop_with_error(('Retrieve did not complete for keeper %s from %s slot %d.')
                :format(copy.name, bag_name(copy.bag), copy.slot))
            return
        end

        local inv_slot = find_in_inventory(copy)
        if not inv_slot then
            stop_with_error(('Retrieved keeper %s was not found in Inventory.'):format(copy.name))
            return
        end

        local destination = find_free_wardrobe()
        if not destination then
            stop_with_error('No free enabled Wardrobe remains.')
            return
        end

        op.inv_slot = inv_slot
        op.destination = destination
        windower.ffxi.put_item(destination, inv_slot, 1)
        state.phase = 'verify_put'
        advance:schedule(MOVE_DELAY)
        return
    end

    if state.phase == 'verify_put' then
        local inv_item = op.inv_slot and windower.ffxi.get_items(0, op.inv_slot)
        if inv_item and same_copy(inv_item, copy) then
            stop_with_error(('Wardrobe put did not complete for keeper %s.'):format(copy.name))
            return
        end

        local bag = find_in_wardrobes(copy)
        if not bag then
            stop_with_error(('Keeper %s was not found in any Wardrobe after put.'):format(copy.name))
            return
        end

        chat(207, ('KEEP  %-3s %-18s q%-2d -> %s')
            :format(copy.job, copy.name, copy.quality, bag_name(bag)))
        next_operation()
        return
    end
end

local function process_redundant(op)
    local copy = op.copy

    if state.phase == nil then
        if copy.bag == 0 then
            chat(207, ('STAGE %-3s %-18s q%-2d already in Inventory')
                :format(copy.job, copy.name, copy.quality))
            next_operation()
            return
        end

        if not source_matches(copy) then
            stop_with_error(('Redundant source changed before move: %s {%s:%d}.')
                :format(copy.name, bag_name(copy.bag), copy.slot))
            return
        end

        if inventory_free() < 1 then
            stop_with_error(('Inventory filled before staging %s.'):format(copy.name))
            return
        end

        windower.ffxi.get_item(copy.bag, copy.slot, 1)
        state.phase = 'verify_get'
        advance:schedule(MOVE_DELAY)
        return
    end

    if state.phase == 'verify_get' then
        if source_matches(copy) then
            stop_with_error(('Retrieve did not complete for redundant %s from %s slot %d.')
                :format(copy.name, bag_name(copy.bag), copy.slot))
            return
        end

        local inv_slot = find_in_inventory(copy)
        if not inv_slot then
            stop_with_error(('Staged redundant %s was not found in Inventory.'):format(copy.name))
            return
        end

        chat(207, ('STAGE %-3s %-18s q%-2d <- %s')
            :format(copy.job, copy.name, copy.quality, bag_name(copy.bag)))
        next_operation()
        return
    end
end

advance = function()
    if not state.running then
        return
    end

    local op = state.queue[state.index]
    if not op then
        finish()
        return
    end

    state.current = op

    if op.kind == 'keeper' then
        process_keeper(op)
    else
        process_redundant(op)
    end
end

local function begin_run()
    if identify_state.running then
        chat(167, 'Identification is already running. Use //sec abort first.')
        return
    end
    if state.running then
        chat(167, 'A cleanup is already running. Use //sec status or //sec abort.')
        return
    end

    local families = collect()
    local keepers, redundant = build_plan(families)

    if #keepers == 0 then
        chat(207, 'No appraised Sortie JSE earrings found.')
        return
    end

    print_plan(keepers, redundant)

    local ok, reason = preflight(keepers, redundant)
    if not ok then
        chat(167, 'Preflight FAILED: '..reason)
        echo('Sortie earring cleanup aborted during preflight.')
        return
    end

    local keeper_ops = {}
    local redundant_ops = {}

    -- Put keepers already in Inventory first. This frees staging room.
    for _, copy in ipairs(keepers) do
        if not is_wardrobe(copy.bag) and copy.bag == 0 then
            keeper_ops[#keeper_ops + 1] = {kind = 'keeper', copy = copy}
        end
    end
    for _, copy in ipairs(keepers) do
        if not is_wardrobe(copy.bag) and copy.bag ~= 0 then
            keeper_ops[#keeper_ops + 1] = {kind = 'keeper', copy = copy}
        end
    end

    for _, copy in ipairs(redundant) do
        if copy.bag ~= 0 then
            redundant_ops[#redundant_ops + 1] = {kind = 'redundant', copy = copy}
        end
    end

    state.queue = {}
    for _, op in ipairs(keeper_ops) do state.queue[#state.queue + 1] = op end
    for _, op in ipairs(redundant_ops) do state.queue[#state.queue + 1] = op end

    state.index = 1
    state.current = nil
    state.phase = nil
    state.keepers = keepers
    state.redundant = redundant
    state.running = true

    chat(207, ('Preflight passed. %d exact move operation(s) queued. Starting in 2 seconds...')
        :format(#state.queue))

    -- IMPORTANT: scheduled addon function, not coroutine.sleep in lua exec.
    advance:schedule(MOVE_DELAY)
end

local function scan_only()
    local families = collect()
    local keepers, redundant = build_plan(families)

    if #keepers == 0 then
        chat(207, 'No appraised Sortie JSE earrings found.')
        return
    end

    print_plan(keepers, redundant)

    local ok, reason = preflight(keepers, redundant)
    if ok then
        chat(207, 'SCAN ONLY: preflight would pass. Nothing moved.')
    else
        chat(167, 'SCAN ONLY: preflight would fail: '..reason)
    end
end

-- Identification is intentionally independent of the cleanup movement queue.
local function identify_stop(reason)
    identify_state.running = false
    identify_state.pending = nil
    identify_state.generation = identify_state.generation + 1
    chat(167, 'IDENTIFY STOP: '..reason)
end

local identify_advance

local function identify_schedule(delay)
    local generation = identify_state.generation
    local callback = function()
        if identify_state.running and identify_state.generation == generation then
            identify_advance()
        end
    end
    callback:schedule(delay)
end

identify_advance = function()
    if not identify_state.running then return end

    -- Verify the previous /item actually consumed exactly one of the requested ID.
    local pending = identify_state.pending
    if pending then
        local current_count = count_unidentified_id(pending.id)
        if current_count == nil then
            identify_stop('Inventory could not be read after using '..pending.name..'.')
            return
        end
        if current_count ~= pending.before - 1 then
            identify_stop(('No verified one-item consumption for %s (before=%d, now=%d).')
                :format(pending.name, pending.before, current_count))
            return
        end
        identify_state.processed = identify_state.processed + 1
        chat(207, ('IDENTIFIED %d/%d: %s')
            :format(identify_state.processed, identify_state.initial_total, pending.name))
        identify_state.pending = nil
    end

    local scan = scan_unidentified()
    if not scan then
        identify_stop('Main Inventory is unavailable.')
        return
    end

    if scan.total == 0 then
        identify_state.running = false
        identify_state.generation = identify_state.generation + 1
        chat(207, ('IDENTIFY COMPLETE: %d Sortie earring(s) appraised. No unidentified earrings remain in main Inventory.')
            :format(identify_state.processed))
        return
    end

    if scan.locked > 0 then
        identify_stop(('%d unidentified earring(s) are not in a usable state.'):format(scan.locked))
        return
    end

    local player = windower.ffxi.get_player()
    if not player or player.status ~= 0 then
        identify_stop('Character must be idle to use items.')
        return
    end

    if inventory_free() < 1 then
        identify_stop('Keep at least one free main Inventory slot for appraisal results.')
        return
    end

    local next_item = scan.first
    if not next_item then
        identify_stop('No usable unidentified earring was found.')
        return
    end

    local before = count_unidentified_id(next_item.id)
    if not before or before < 1 then
        identify_stop('Selected earring disappeared before use.')
        return
    end

    identify_state.pending = {id = next_item.id, name = next_item.name, before = before}
    chat(207, ('IDENTIFY USING %s (remaining=%d)'):format(next_item.name, scan.total))
    windower.send_command('input /item "'..next_item.name..'" <me>')
    identify_schedule(IDENTIFY_DELAY)
end

local function identify_scan_only()
    local scan = scan_unidentified()
    if not scan then
        chat(167, 'Main Inventory is unavailable.')
        return
    end
    chat(207, ('IDENTIFY SCAN: %d unopened Sortie earring(s) in main Inventory (%d locked).')
        :format(scan.total, scan.locked))
    local names = {}
    for name in pairs(scan.names) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        chat(8, ('  %s x%d'):format(name, scan.names[name]))
    end
end

local function begin_identify()
    if identify_state.running or state.running then
        chat(167, 'An earring operation is already running. Use //sec status or //sec abort.')
        return
    end

    local scan = scan_unidentified()
    if not scan then
        chat(167, 'Main Inventory is unavailable.')
        return
    end
    if scan.total == 0 then
        chat(207, 'No unidentified Sortie earrings in main Inventory.')
        return
    end
    if scan.locked > 0 then
        chat(167, ('Cannot start: %d unidentified earring(s) locked.'):format(scan.locked))
        return
    end
    local player = windower.ffxi.get_player()
    if not player or player.status ~= 0 then
        chat(167, 'Character must be idle to identify earrings.')
        return
    end
    if inventory_free() < 1 then
        chat(167, 'Free at least one main Inventory slot before identifying earrings.')
        return
    end

    identify_state.running = true
    identify_state.generation = identify_state.generation + 1
    identify_state.processed = 0
    identify_state.initial_total = scan.total
    identify_state.pending = nil
    chat(207, ('Identifying %d Sortie earring(s), one at a time. Use //sec abort to stop.')
        :format(scan.total))
    identify_advance()
end

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = tostring(args[1] or 'help'):lower()

    if cmd == 'scan' then
        scan_only()
        return
    end

    if cmd == 'run' then
        begin_run()
        return
    end

    if cmd == 'identify' then
        local subcommand = tostring(args[2] or ''):lower()
        if subcommand == 'scan' then
            identify_scan_only()
        elseif subcommand == '' then
            begin_identify()
        else
            chat(207, 'Usage: //sec identify [scan]')
        end
        return
    end

    if cmd == 'abort' then
        if identify_state.running then
            identify_state.running = false
            identify_state.pending = nil
            identify_state.generation = identify_state.generation + 1
            chat(167, ('Identification aborted after %d earring(s). Already appraised items remain appraised.')
                :format(identify_state.processed))
            return
        end
        if state.running then
            state.running = false
            chat(167, 'Cleanup aborted by user. Already-completed moves are left in place.')
            echo('Sortie earring cleanup aborted by user.')
        else
            chat(207, 'No cleanup is currently running.')
        end
        return
    end

    if cmd == 'status' then
        if identify_state.running then
            local pending = identify_state.pending
            chat(207, ('Identifying %d/%d, %s')
                :format(identify_state.processed, identify_state.initial_total,
                    pending and ('waiting to verify '..pending.name) or 'scanning next item'))
            return
        end
        if not state.running then
            chat(207, 'Idle.')
        else
            local op = state.queue[state.index]
            chat(207, ('Running %d/%d: %s %s (%s)')
                :format(
                    state.index,
                    #state.queue,
                    op and op.kind or '?',
                    op and op.copy.name or '?',
                    state.phase or 'start'
                ))
        end
        return
    end

    chat(207, 'Commands: //sec scan | //sec run | //sec identify [scan] | //sec status | //sec abort')
end)

windower.register_event('load', function()
    chat(207, 'Loaded v1.2.2. Use //sec scan, //sec run, or //sec identify.')
end)
