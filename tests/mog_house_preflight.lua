-- Regression for conditional Mog House preflight (Lua 5.1).
_addon = {}
local handlers, messages = {}, {}
local in_house = false
local bags = {}
local names = {[0]='Inventory',[1]='Mog Safe',[2]='Storage',[4]='Mog Locker',[8]='Mog Wardrobe',[9]='Mog Safe 2',[10]='Mog Wardrobe 2'}
package.preload['resources'] = function()
    local b = {}
    for id, name in pairs(names) do b[id] = {en = name} end
    return {bags=b,items={[25420]={en='Boii Earring'},[25421]={en='Boii Earring +1'}}}
end
package.preload['extdata'] = function()
    return {decode=function() return {augments={}} end}
end
windower = {
    register_event=function(name, fn) handlers[name] = fn end,
    add_to_chat=function(_, msg) messages[#messages+1] = msg end,
    send_command=function() end,
    ffxi={
        get_info=function() return {mog_house=in_house} end,
        get_player=function() return {name='Tester'} end,
        get_items=function(bag, slot)
            if slot then return (bags[bag] or {})[slot] end
            return bags[bag] or {}
        end,
        get_bag_info=function(bag)
            local n=0
            for _, item in ipairs(bags[bag] or {}) do
                if item.id and item.id > 0 then n=n+1 end
            end
            return {enabled=true,max=80,count=n}
        end,
        put_item=function() error('No moves should occur before scheduled execution') end,
        get_item=function() error('No moves should occur before scheduled execution') end,
    },
}
dofile('SortieEarringCleanup.lua')
local command = assert(handlers['addon command'])
local function output() return table.concat(messages,'\n') end
local function reset(storage)
    messages={}
    bags={[0]={{id=25420,status=0,extdata='nq'}},
          [8]={{id=25421,status=0,extdata='plus1'}}}
    if storage then
        bags[storage]={{id=25420,status=0,extdata='older'}}
    end
end
-- Inventory keeper/wardrobe redundant preflight works outside the house.
reset()
command('run')
assert(output():find('Preflight passed.',1,true),output())
assert(not output():find('WARNING:',1,true),output())
-- A redundant Safe/Locker/Storage/Safe 2 source blocks without any moves.
for _, bag in ipairs({1,2,4,9}) do
    reset(bag)
    command('run')
    assert(output():find('WARNING:',1,true),output())
    assert(output():find(names[bag],1,true),output())
    assert(not output():find('Preflight passed.',1,true),output())
    reset(bag)
    command('scan')
    assert(output():find('SCAN ONLY WARNING:',1,true),output())
end
-- No blanket restriction when inspecting a portable-only plan.
reset()
command('scan')
assert(output():find('SCAN ONLY: preflight would pass.',1,true),output())
-- A Mog House run can include restricted retrievals.
in_house=true
reset(1)
command('run')
assert(output():find('Preflight passed.',1,true),output())
print('PASS: conditional Mog House cleanup preflight')
