-- ============================================================
--  kq_link — Test Suite: kq_link_banking_spec.lua
--  Suíte determinística de testes unitários para a ponte
--  financeira de kq_link com aust_banking v3 e ox_inventory
-- ============================================================

local testCount = 0
local passCount = 0
local failCount = 0

local function assertEqual(actual, expected, description)
    testCount = testCount + 1
    if actual == expected then
        passCount = passCount + 1
        print(string.format("  [PASS] %s", description))
    else
        failCount = failCount + 1
        print(string.format("  [FAIL] %s: Esperado [%s], obtido [%s]", description, tostring(expected), tostring(actual)))
    end
end

local function assertTrue(condition, description)
    assertEqual(condition, true, description)
end

local function assertFalse(condition, description)
    assertEqual(condition, false, description)
end

-- ============================================================
-- MOCKS DO AMBIENTE FIVEM / QBX / AUST_BANKING / OX_INVENTORY
-- ============================================================

_G.Link = {
    framework = 'qbox',
    inventory = 'ox_inventory'
}

_G.GetResourceState = function(res)
    if res == 'aust_banking' then return 'started' end
    if res == 'ox_inventory' then return 'started' end
    if res == 'qbx_core' then return 'started' end
    return 'missing'
end

_G.GetPlayers = function() return { 1 } end
_G.GetPlayerName = function(src) return "John Doe" end

local mockBankBalance = 80000
local mockCashCount = 5000
local mockCanCarryMoney = true
local mockLastCreditPayload = nil
local mockLastDebitPayload = nil
local mockAustCreditFail = false
local mockAustDebitFail = false

local mockRawPlayer = {
    PlayerData = {
        citizenid = 'KQ_CITIZEN_01',
        source = 1,
        job = {
            name = 'mechanic',
            grade = { level = 2 }
        },
        gang = {
            name = 'none',
            grade = { level = 0 }
        }
    },
    Functions = {
        AddMoney = function(acc, amt, note) return true end,
        RemoveMoney = function(acc, amt, note) return true end
    }
}

_G.exports = {
    qbx_core = {
        GetPlayer = function(self, src)
            if src == 1 then return mockRawPlayer end
            return nil
        end,
        GetMoney = function(self, src, acc)
            if acc == 'bank' then return mockBankBalance end
            if acc == 'cash' then return mockCashCount end
            return 0
        end,
        AddMoney = function(self, src, acc, amt, note) return true end,
        RemoveMoney = function(self, src, acc, amt, note) return true end
    },
    aust_banking = {
        GetBankBalance = function(self, cid)
            if cid == 'KQ_CITIZEN_01' then return mockBankBalance end
            return 0
        end,
        Credit = function(self, payload)
            mockLastCreditPayload = payload
            if mockAustCreditFail then return false end
            if payload and payload.amount and payload.amount > 0 then
                mockBankBalance = mockBankBalance + payload.amount
                return true
            end
            return false
        end,
        Debit = function(self, payload)
            mockLastDebitPayload = payload
            if mockAustDebitFail then return false end
            if payload and payload.amount and payload.amount > 0 then
                if mockBankBalance < payload.amount then return false end
                mockBankBalance = mockBankBalance - payload.amount
                return { ok = true, tx = 'tx_kq_01' }
            end
            return false
        end
    },
    ox_inventory = {
        GetItemCount = function(self, src, item)
            if item == 'money' then return mockCashCount end
            return 0
        end,
        CanCarryItem = function(self, src, item, amt)
            if item == 'money' then return mockCanCarryMoney end
            return true
        end,
        AddItem = function(self, src, item, amt)
            if item == 'money' then
                if not mockCanCarryMoney then return false end
                mockCashCount = mockCashCount + amt
                return true
            end
            return false
        end,
        RemoveItem = function(self, src, item, amt)
            if item == 'money' then
                if mockCashCount < amt then return false end
                mockCashCount = mockCashCount - amt
                return true
            end
            return false
        end
    }
}

-- Carregar o arquivo alvo
dofile("resources/[standalone]/kq_link/links/frameworks/qbox/server.lua")

print("\n--- INICIANDO TESTES DO KQ_LINK BANKING ---")

-- -----------------------------------------------------------
-- GRUPO 1: Consulta de Saldo e Verificação de Acessibilidade
-- -----------------------------------------------------------
print("\n[Grupo 1: Consulta e CanPlayerAfford]")
assertTrue(CanPlayerAfford(1, 1000, 'cash'), "CanPlayerAfford aceita valor dentro do limite de cash")
assertFalse(CanPlayerAfford(1, 10000, 'cash'), "CanPlayerAfford rejeita valor acima do limite de cash")
assertTrue(CanPlayerAfford(1, 50000, 'bank'), "CanPlayerAfford aceita valor dentro do limite de bank")
assertFalse(CanPlayerAfford(1, 100000, 'bank'), "CanPlayerAfford rejeita valor acima do limite de bank")
assertFalse(CanPlayerAfford(1, -50, 'bank'), "Rejeita valor negativo")
assertFalse(CanPlayerAfford(1, 0, 'bank'), "Rejeita valor zero")
assertFalse(CanPlayerAfford(1, 999999999999, 'bank'), "Rejeita valor acima de INT32")

-- -----------------------------------------------------------
-- GRUPO 2: Adição de Fundos Online (Cash e Bank)
-- -----------------------------------------------------------
print("\n[Grupo 2: AddPlayerMoney]")
local okAddCash = AddPlayerMoney(1, 2000, 'cash', { reason = 'Missao Concluida' })
assertTrue(okAddCash, "AddPlayerMoney em cash creditado via ox_inventory")
assertEqual(mockCashCount, 7000, "Saldo de dinheiro físico incrementado para 7000")

local okAddBank = AddPlayerMoney(1, 15000, 'bank', { ref = 'reward_01' })
assertTrue(okAddBank, "AddPlayerMoney em bank creditado via aust_banking")
assertEqual(mockBankBalance, 95000, "Saldo bancário incrementado para 95000")
assertEqual(mockLastCreditPayload.citizenid, 'KQ_CITIZEN_01', "Payload do crédito bancário contém citizenid")
assertEqual(mockLastCreditPayload.operationId, mockLastCreditPayload.operation_id, "operationId e operation_id idênticos")
assertTrue(#mockLastCreditPayload.operationId <= 64, "OpId respeita limite <= 64 chars")

-- -----------------------------------------------------------
-- GRUPO 3: Overflow Seguro (Cash -> Bank)
-- -----------------------------------------------------------
print("\n[Grupo 3: Overflow Seguro]")
mockCanCarryMoney = false -- Simula inventário físico lotado
local okOverflow = AddPlayerMoney(1, 5000, 'cash', { reason = 'Premio Grande' })
assertTrue(okOverflow, "AddPlayerMoney em cash faz overflow para bank quando inventário cheio")
assertEqual(mockCashCount, 7000, "Saldo em espécie mantido inalterado")
assertEqual(mockBankBalance, 100000, "Saldo bancário recebeu os R$ 5000 de overflow")
assertTrue(string.find(mockLastCreditPayload.reason, "overflow") ~= nil, "Motivo contábil explicita transbordo/overflow")

-- -----------------------------------------------------------
-- GRUPO 4: Remoção de Fundos Online (Fail-Closed)
-- -----------------------------------------------------------
print("\n[Grupo 4: RemovePlayerMoney]")
mockCanCarryMoney = true
local okRemCash = RemovePlayerMoney(1, 3000, 'cash', { reason = 'Taxa de Servico' })
assertTrue(okRemCash, "RemovePlayerMoney debitado de cash com sucesso")
assertEqual(mockCashCount, 4000, "Saldo em espécie debitado para 4000")

local okRemBank = RemovePlayerMoney(1, 20000, 'bank', { ref = 'debit_ref_1' })
assertTrue(okRemBank, "RemovePlayerMoney debitado do banco com sucesso")
assertEqual(mockBankBalance, 80000, "Saldo bancário debitado para 80000")
assertEqual(mockLastDebitPayload.citizenid, 'KQ_CITIZEN_01', "Payload de débito contém citizenid")

local failRem = RemovePlayerMoney(1, 999999, 'bank')
assertFalse(failRem, "RemovePlayerMoney bloqueado em saldo insuficiente")
assertEqual(mockBankBalance, 80000, "Saldo bancário preservado após bloqueio")

-- ============================================================
-- SUMÁRIO FINAL
-- ============================================================
print("\n=============================================================")
print(string.format("RESULTADO DOS TESTES: %d executados | %d passaram | %d falharam", testCount, passCount, failCount))
print("=============================================================\n")

if failCount > 0 then
    os.exit(1)
end
