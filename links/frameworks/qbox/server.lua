if Link.framework ~= 'qbox' and Link.framework ~= 'qbx' and Link.framework ~= 'qbx-core' then
    return
end


function GetPlayerJob(player)
    local xPlayer = exports.qbx_core:GetPlayer(player)
    local job = xPlayer and xPlayer.PlayerData.job and xPlayer.PlayerData.job.name
    local grade = xPlayer and xPlayer.PlayerData.job and xPlayer.PlayerData.job.grade and xPlayer.PlayerData.job.grade.level

    return job, grade
end

function GetPlayerGang(player)
    local xPlayer = exports.qbx_core:GetPlayer(player)
    local gang = xPlayer and xPlayer.PlayerData and xPlayer.PlayerData.gang
    local name = gang and gang.name
    local grade = gang and gang.grade and gang.grade.level

    return name, grade
end

function GetPlayersWithJob(jobs, minGrade)
    local matchingPlayers = {}
    local players = GetPlayers()
    local isTable = type(jobs) == 'table'
    minGrade = minGrade or 0

    for _, playerId in ipairs(players) do
        local src = tonumber(playerId)
        local job, grade = GetPlayerJob(src)

        if job and grade then
            if isTable then
                for _, name in ipairs(jobs) do
                    if job == name and grade >= minGrade then
                        table.insert(matchingPlayers, src)
                        break
                    end
                end
            elseif job == jobs and grade >= minGrade then
                table.insert(matchingPlayers, src)
            end
        end
    end

    return matchingPlayers
end

local ACCOUNT_ALIASES = {
    money = 'cash',
    wallet = 'cash',
    dirty_money = 'cash',
    black_money = 'cash',
    dirty = 'cash',
    black = 'cash',
    marked_bills = 'cash',
    markedbills = 'cash',
}

local function ParseAccount(account)
    if not account then
        return nil
    end

    return ACCOUNT_ALIASES[account] or account
end

local _bootNonce = string.format("%x", math.random(0x1000, 0xffff))
local _opSeq = 0

local function normalizeAmount(value)
    local amount = tonumber(value)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then
        return nil
    end
    local rounded = math.floor(amount + 0.5)
    if rounded <= 0 or rounded > 2147483647 then
        return nil
    end
    return rounded
end

local function makeOpId(action, cid, ref)
    local safeAct = tostring(action or "tx"):gsub("[^%w_]", "_"):sub(1, 16)
    local safeCid = tostring(cid or "sys"):gsub("[^%w_]", "_"):sub(1, 18)
    if ref and ref ~= "" then
        local safeRef = tostring(ref):gsub("[^%w_]", "_"):sub(1, 24)
        return string.format("kq:%s:%s:%s", safeAct, safeCid, safeRef):sub(1, 64)
    end
    _opSeq = (_opSeq + 1) % 1000000
    return string.format("kq:%s:%s:%s:%d", safeAct, safeCid, _bootNonce, _opSeq):sub(1, 64)
end

local function getPlayerMoney(player, account)
    local src = tonumber(player)
    if not src then return 0 end
    account = ParseAccount(account) or 'cash'

    if account == 'bank' then
        if GetResourceState('aust_banking') == 'started' then
            local cid = GetPlayerCharacterId(src)
            if cid then
                local ok, bal = pcall(function() return exports.aust_banking:GetBankBalance(cid) end)
                if ok and type(bal) == 'number' then return bal end
            end
        end
        return exports.qbx_core:GetMoney(src, 'bank') or 0
    end

    -- 'cash'
    if GetResourceState('ox_inventory') == 'started' then
        local ok, count = pcall(function() return exports.ox_inventory:GetItemCount(src, 'money') end)
        if ok and type(count) == 'number' then return count end
    end
    return exports.qbx_core:GetMoney(src, 'cash') or 0
end

function CanPlayerAfford(player, amount, account)
    local cleanAmount = normalizeAmount(amount)
    if not cleanAmount then return false end
    account = ParseAccount(account)

    if account then
        return getPlayerMoney(player, account) >= cleanAmount
    end

    if getPlayerMoney(player, 'cash') >= cleanAmount then
        return true
    end

    if getPlayerMoney(player, 'bank') >= cleanAmount then
        return true
    end

    return false
end

function AddPlayerMoney(player, amount, account, opts)
    local src = tonumber(player)
    if not src then return false end
    local cleanAmount = normalizeAmount(amount)
    if not cleanAmount then return false end

    account = ParseAccount(account) or 'cash'
    opts = opts or {}
    local note = opts.reason or opts.note or 'kq_link'

    if account == 'bank' then
        local cid = GetPlayerCharacterId(src)
        if GetResourceState('aust_banking') == 'started' and cid then
            local opId = opts.operationId or opts.operation_id or makeOpId('credit', cid, opts.ref)
            local ok, res = pcall(function()
                return exports.aust_banking:Credit({
                    citizenid    = cid,
                    amount       = cleanAmount,
                    reason       = note,
                    note         = note,
                    operationId  = opId,
                    operation_id = opId,
                    source       = 'kq_link',
                })
            end)
            if ok and (res == true or (type(res) == 'table' and (res.ok == true or res.success == true))) then
                return true
            end
            return false
        end
        local xPlayer = exports.qbx_core:GetPlayer(src)
        return xPlayer and xPlayer.Functions and xPlayer.Functions.AddMoney('bank', cleanAmount, note) == true
    end

    -- 'cash'
    if GetResourceState('ox_inventory') == 'started' then
        local okCarry, canCarry = pcall(function()
            return exports.ox_inventory:CanCarryItem(src, 'money', cleanAmount)
        end)
        if okCarry and canCarry then
            local okAdd, added = pcall(function()
                return exports.ox_inventory:AddItem(src, 'money', cleanAmount)
            end)
            if okAdd and added then
                return true
            end
        end
        -- Overflow para conta bancária caso bolsa esteja no limite físico
        local cid = GetPlayerCharacterId(src)
        if GetResourceState('aust_banking') == 'started' and cid then
            local opId = opts.operationId or opts.operation_id or makeOpId('overflow', cid, opts.ref)
            local ok, res = pcall(function()
                return exports.aust_banking:Credit({
                    citizenid    = cid,
                    amount       = cleanAmount,
                    reason       = note .. ' (overflow)',
                    note         = note,
                    operationId  = opId,
                    operation_id = opId,
                    source       = 'kq_link',
                })
            end)
            if ok and (res == true or (type(res) == 'table' and (res.ok == true or res.success == true))) then
                return true
            end
        end
        return false
    end

    local xPlayer = exports.qbx_core:GetPlayer(src)
    return xPlayer and xPlayer.Functions and xPlayer.Functions.AddMoney('cash', cleanAmount, note) == true
end

function RemovePlayerMoney(player, amount, account, opts)
    local src = tonumber(player)
    if not src then return false end
    local cleanAmount = normalizeAmount(amount)
    if not cleanAmount then return false end

    account = ParseAccount(account)
    opts = opts or {}
    local note = opts.reason or opts.note or 'kq_link'

    if not account then
        if CanPlayerAfford(src, cleanAmount, 'cash') then
            account = 'cash'
        elseif CanPlayerAfford(src, cleanAmount, 'bank') then
            account = 'bank'
        else
            return false
        end
    end

    if not CanPlayerAfford(src, cleanAmount, account) then
        return false
    end

    if account == 'bank' then
        local cid = GetPlayerCharacterId(src)
        if GetResourceState('aust_banking') == 'started' and cid then
            local opId = opts.operationId or opts.operation_id or makeOpId('debit', cid, opts.ref)
            local ok, res = pcall(function()
                return exports.aust_banking:Debit({
                    citizenid    = cid,
                    amount       = cleanAmount,
                    reason       = note,
                    note         = note,
                    operationId  = opId,
                    operation_id = opId,
                    source       = 'kq_link',
                })
            end)
            if ok and (res == true or (type(res) == 'table' and (res.ok == true or res.success == true))) then
                return true
            end
            return false
        end
        return exports.qbx_core:RemoveMoney(src, 'bank', cleanAmount, note) == true
    end

    -- 'cash'
    if GetResourceState('ox_inventory') == 'started' then
        local okRem, rem = pcall(function()
            return exports.ox_inventory:RemoveItem(src, 'money', cleanAmount)
        end)
        return okRem and (rem and true or false)
    end

    return exports.qbx_core:RemoveMoney(src, 'cash', cleanAmount, note) == true
end

if Link.inventory == 'framework' then
    Link.inventory = 'ox_inventory'
end

function GetPlayerCharacterId(player)
    local xPlayer = exports.qbx_core:GetPlayer(tonumber(player))

    if not xPlayer or not xPlayer.PlayerData then
        return nil
    end

    return xPlayer.PlayerData.citizenid
end

function GetPlayerCharacterName(player)
    local xPlayer = exports.qbx_core:GetPlayer(tonumber(player))
    if not xPlayer or not xPlayer.PlayerData or not xPlayer.PlayerData.charinfo then
        return GetPlayerName(player) or 'Unknown'
    end

    local charinfo = xPlayer.PlayerData.charinfo
    local firstName = charinfo.firstname
    local lastName = charinfo.lastname

    if firstName and lastName then
        return firstName .. ' ' .. lastName
    end

    return GetPlayerName(player) or 'Unknown'
end

-- QBox uses ox_inventory by default, weapon functions defined in inventory file

function RegisterUsableItem(...)
    return true -- This system doesn't have it
end
