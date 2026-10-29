-- Mock Windower scan regression for Sortie NQ/+1/+2 unidentified earrings.
_addon = {}
local handlers, messages = {}, {}
local item_data = {
    [1] = {en = '??? Earring: RDM'},
    [2] = {en = '??? Ear.: BST +1', enl = '??? Earring: BST +1'},
    [3] = {en = '??? Ear.: THF +2'},
    [4] = {en = 'Old Case'},
    [5] = {en = '??? Ear.: BST +3'},
    [6] = {en = '??? Earring: UNKNOWN'},
}
local inventory = {
    {id = 1, count = 1, status = 0},
    {id = 2, count = 1, status = 0},
    {id = 3, count = 1, status = 0},
    {id = 4, count = 1, status = 0},
    {id = 5, count = 1, status = 0},
    {id = 6, count = 1, status = 0},
}
package.preload['resources'] = function()
    return {items = item_data, bags = {}}
end
package.preload['extdata'] = function()
    return {decode = function() return {augments = {}} end}
end
windower = {
    register_event = function(name, fn) handlers[name] = fn end,
    add_to_chat = function(_, msg) messages[#messages + 1] = msg end,
    send_command = function() error('Scan should not send commands') end,
    ffxi = {
        get_items = function(id)
            if id == 0 then return inventory end
            return {}
        end,
    },
}
dofile('SortieEarringCleanup.lua')
assert(type(handlers['addon command']) == 'function', 'Missing addon command')
handlers['addon command']('identify', 'scan')
local output = table.concat(messages, '\n')
assert(output:find('IDENTIFY SCAN: 3 unopened', 1, true), output)
assert(output:find('??? Earring: RDM x1', 1, true), output)
assert(output:find('??? Earring: BST +1 x1', 1, true), output)
assert(output:find('??? Ear.: THF +2 x1', 1, true), output)
assert(not output:find('Old Case', 1, true), output)
assert(not output:find('BST +3', 1, true), output)
assert(not output:find('UNKNOWN', 1, true), output)
print('PASS: Sortie unidentified earring scan NQ/+1/+2 and exclusions')
